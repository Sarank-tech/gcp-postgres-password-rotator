"""Rotate Cloud SQL PostgreSQL user passwords and store them in Secret Manager.

Runs as a Cloud Run Job. For each ``user -> secret`` pair in SECRET_MAPPINGS:

1. Read the user's current password from Secret Manager (kept in memory only,
   used to roll back the secret if the database change cannot be committed).
2. Generate a new random password.
3. Inside a transaction, ``ALTER USER ... WITH PASSWORD`` using a pre-computed
   SCRAM-SHA-256 verifier, so the plaintext never reaches the server (and so
   never appears in PostgreSQL statement logs).
4. Add the new password as a new Secret Manager version.
5. Commit. If the commit fails, re-add the old password as the latest secret
   version so the secret keeps matching the database.
6. Disable every older enabled version of the secret, so only the current
   password can be read. Failing this step is logged as a warning: the
   database and the secret already match, so the rotation still counts.

Steps 3-5 mean the database and secret can only disagree if both the commit
and the rollback write fail; that case is logged at CRITICAL.

The job connects as an admin user (default ``postgres``) whose current
password is read from its mapped secret. Passwords are never logged.

The connection goes through the Cloud SQL Python Connector, which fetches a
short-lived client certificate for mutual TLS and verifies the server's
identity, so it works whatever SSL mode the instance enforces.

Environment variables:
    PROJECT_ID                GCP project holding the secrets (required).
    INSTANCE_CONNECTION_NAME  Cloud SQL connection name,
                              "project:region:instance" (required).
    SECRET_MAPPINGS           JSON object of {db_user: secret_id} (required).
    DB_IP_TYPE                "private" (default) or "public".
    DB_NAME                   Database to connect to. Default "postgres".
    DB_ADMIN_USER             User to connect as. Default "postgres"; must be a
                              key of SECRET_MAPPINGS unless DB_ADMIN_SECRET is
                              set.
    DB_ADMIN_SECRET           Secret ID holding the admin password (optional).
    PASSWORD_LENGTH           Generated password length. Default 32, min 20.
"""

import base64
import hashlib
import hmac
import json
import logging
import os
import secrets
import string
import sys
from dataclasses import dataclass

from google.cloud import secretmanager
from google.cloud.sql.connector import Connector, IPTypes

MIN_PASSWORD_LENGTH = 20
SCRAM_ITERATIONS = 4096

# Excluded so the password survives downstream consumers: quotes and
# backslashes (SQL literals, shell), "#" (comment in .env/properties files,
# value cut off there), "$" (variable expansion), "@" and "%" (connection
# URLs), "&" and ";" (query and connection strings).
PASSWORD_SYMBOLS = "!()*+,-./:<=>?[]^_{|}~"

logger = logging.getLogger("rotator")


###############################################################################
# Logging
###############################################################################

class JsonFormatter(logging.Formatter):
    """Emit one JSON object per line; Cloud Logging maps ``severity``."""

    def format(self, record):
        entry = {
            "severity": record.levelname,
            "message": record.getMessage(),
            "logger": record.name,
        }
        entry.update(getattr(record, "fields", {}))
        return json.dumps(entry)


def configure_logging():
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    logging.basicConfig(level=logging.INFO, handlers=[handler], force=True)


def log(level, message, **fields):
    logger.log(level, message, extra={"fields": fields})


def describe_error(exc, *sensitive):
    """Return a loggable description of ``exc`` with secrets scrubbed out."""
    text = f"{type(exc).__name__}: {exc}"
    for value in sensitive:
        if value:
            text = text.replace(value, "[REDACTED]")
    return text


###############################################################################
# Configuration
###############################################################################

class ConfigError(Exception):
    """Raised when required configuration is missing or invalid."""


@dataclass(frozen=True)
class Config:
    project_id: str
    instance_connection_name: str
    mappings: dict
    ip_type: IPTypes
    db_name: str
    admin_user: str
    admin_secret: str
    password_length: int


def _require_env(name):
    value = os.environ.get(name, "").strip()
    if not value:
        raise ConfigError(f"Environment variable {name} is required")
    return value


def load_config():
    """Build a Config from environment variables, validating as we go."""
    try:
        mappings = json.loads(_require_env("SECRET_MAPPINGS"))
    except json.JSONDecodeError as exc:
        raise ConfigError(f"SECRET_MAPPINGS is not valid JSON: {exc}") from exc
    if not isinstance(mappings, dict) or not mappings:
        raise ConfigError("SECRET_MAPPINGS must be a non-empty JSON object")
    for user, secret_id in mappings.items():
        if not isinstance(secret_id, str) or not user or not secret_id:
            raise ConfigError(
                "SECRET_MAPPINGS entries must be non-empty strings"
            )

    admin_user = os.environ.get("DB_ADMIN_USER", "postgres")
    admin_secret = (
        os.environ.get("DB_ADMIN_SECRET") or mappings.get(admin_user)
    )
    if not admin_secret:
        raise ConfigError(
            f"No secret for admin user {admin_user!r}: add it to "
            "SECRET_MAPPINGS or set DB_ADMIN_SECRET"
        )

    ip_types = {"private": IPTypes.PRIVATE, "public": IPTypes.PUBLIC}
    ip_type_name = os.environ.get("DB_IP_TYPE", "private").strip().lower()
    if ip_type_name not in ip_types:
        raise ConfigError(f"Unsupported DB_IP_TYPE {ip_type_name!r}")

    try:
        password_length = int(os.environ.get("PASSWORD_LENGTH", "32"))
    except ValueError as exc:
        raise ConfigError(f"Invalid integer setting: {exc}") from exc
    if password_length < MIN_PASSWORD_LENGTH:
        raise ConfigError(f"PASSWORD_LENGTH must be >= {MIN_PASSWORD_LENGTH}")

    return Config(
        project_id=_require_env("PROJECT_ID"),
        instance_connection_name=_require_env("INSTANCE_CONNECTION_NAME"),
        mappings=mappings,
        ip_type=ip_types[ip_type_name],
        db_name=os.environ.get("DB_NAME", "postgres"),
        admin_user=admin_user,
        admin_secret=admin_secret,
        password_length=password_length,
    )


###############################################################################
# Passwords
###############################################################################

def generate_password(length):
    """Return a random password with at least one char from every class."""
    classes = [
        string.ascii_uppercase,
        string.ascii_lowercase,
        string.digits,
        PASSWORD_SYMBOLS,
    ]
    alphabet = "".join(classes)
    chars = [secrets.choice(cls) for cls in classes]
    chars += [secrets.choice(alphabet) for _ in range(length - len(chars))]
    secrets.SystemRandom().shuffle(chars)
    return "".join(chars)


def scram_sha256_verifier(password):
    """Compute the SCRAM-SHA-256 verifier PostgreSQL stores for ``password``.

    Sending this instead of the plaintext means the cleartext password never
    leaves this process, even if the server logs the ALTER statement.
    Generated passwords are printable ASCII, so SASLprep is a no-op.
    """
    salt = secrets.token_bytes(16)
    salted = hashlib.pbkdf2_hmac(
        "sha256", password.encode("utf-8"), salt, SCRAM_ITERATIONS
    )
    client_key = hmac.new(salted, b"Client Key", hashlib.sha256).digest()
    stored_key = hashlib.sha256(client_key).digest()
    server_key = hmac.new(salted, b"Server Key", hashlib.sha256).digest()

    def b64(data):
        return base64.b64encode(data).decode("ascii")

    return (
        f"SCRAM-SHA-256${SCRAM_ITERATIONS}:{b64(salt)}"
        f"${b64(stored_key)}:{b64(server_key)}"
    )


###############################################################################
# SQL helpers
###############################################################################

def quote_ident(name):
    """Quote a PostgreSQL identifier (ALTER USER cannot take parameters)."""
    return '"' + name.replace('"', '""') + '"'


def quote_literal(value):
    """Quote a PostgreSQL string literal."""
    return "'" + value.replace("'", "''") + "'"


###############################################################################
# Secret Manager
###############################################################################

class SecretStore:
    """Thin wrapper over the Secret Manager client for one project."""

    def __init__(self, project_id):
        self._client = secretmanager.SecretManagerServiceClient()
        self._project_id = project_id

    def _secret_path(self, secret_id):
        return self._client.secret_path(self._project_id, secret_id)

    def read_latest(self, secret_id):
        name = f"{self._secret_path(secret_id)}/versions/latest"
        response = self._client.access_secret_version(request={"name": name})
        return response.payload.data.decode("utf-8")

    def add_version(self, secret_id, value):
        """Add a new version and return its resource name."""
        response = self._client.add_secret_version(
            request={
                "parent": self._secret_path(secret_id),
                "payload": {"data": value.encode("utf-8")},
            }
        )
        return response.name

    def disable_other_versions(self, secret_id, keep_version):
        """Disable every enabled version except ``keep_version``.

        Returns the names of the versions disabled.
        """
        keep_id = keep_version.rsplit("/", 1)[-1]
        disabled = []
        for version in self._client.list_secret_versions(
            request={
                "parent": self._secret_path(secret_id),
                "filter": "state:ENABLED",
            }
        ):
            if version.name.rsplit("/", 1)[-1] == keep_id:
                continue
            self._client.disable_secret_version(
                request={"name": version.name}
            )
            disabled.append(version.name)
        return disabled


###############################################################################
# Database
###############################################################################

def connect(connector, config, admin_password):
    return connector.connect(
        config.instance_connection_name,
        "pg8000",
        user=config.admin_user,
        password=admin_password,
        db=config.db_name,
        timeout=30,
        application_name="postgres-password-rotator",
    )


###############################################################################
# Rotation
###############################################################################

def rotate_user(conn, store, config, username, secret_id):
    """Rotate one user's password. Returns True on success."""
    ctx = {"db_user": username, "secret_id": secret_id}
    old_password = None
    new_password = None
    verifier = None

    try:
        log(logging.INFO, "Starting rotation", step="start", **ctx)

        old_password = store.read_latest(secret_id)
        log(logging.INFO, "Read current secret version", step="read_secret",
            **ctx)

        new_password = generate_password(config.password_length)
        verifier = scram_sha256_verifier(new_password)

        cursor = conn.cursor()
        try:
            cursor.execute(
                f"ALTER USER {quote_ident(username)} "
                f"WITH PASSWORD {quote_literal(verifier)}"
            )
        finally:
            cursor.close()
        log(logging.INFO, "Password altered (uncommitted)", step="alter_user",
            **ctx)

        version = store.add_version(secret_id, new_password)
        log(logging.INFO, "Added new secret version", step="add_version",
            secret_version=version, **ctx)
    except Exception as exc:
        _safe_rollback(conn, ctx)
        log(logging.ERROR, "Rotation failed; database change rolled back",
            step="failed",
            error=describe_error(exc, old_password, new_password, verifier),
            **ctx)
        return False

    try:
        conn.commit()
    except Exception as exc:
        log(logging.ERROR, "Commit failed; restoring previous secret value",
            step="commit",
            error=describe_error(exc, old_password, new_password, verifier),
            **ctx)
        _restore_secret(store, secret_id, old_password, ctx)
        return False

    log(logging.INFO, "Rotation succeeded", step="done", **ctx)
    _disable_old_versions(store, secret_id, version, ctx)
    return True


def _disable_old_versions(store, secret_id, keep_version, ctx):
    try:
        disabled = store.disable_other_versions(secret_id, keep_version)
        log(logging.INFO, "Disabled previous secret versions",
            step="disable_versions", disabled_versions=disabled, **ctx)
    except Exception as exc:
        log(logging.WARNING,
            "Could not disable previous secret versions; disable them "
            "manually",
            step="disable_versions", error=type(exc).__name__, **ctx)


def _safe_rollback(conn, ctx):
    try:
        conn.rollback()
    except Exception as exc:  # Connection may already be broken.
        log(logging.WARNING, "Rollback failed", step="rollback",
            error=type(exc).__name__, **ctx)


def _restore_secret(store, secret_id, old_password, ctx):
    try:
        version = store.add_version(secret_id, old_password)
        log(logging.WARNING, "Previous password restored as latest version",
            step="restore_secret", secret_version=version, **ctx)
    except Exception as exc:
        log(logging.CRITICAL,
            "Secret could not be restored; secret and database may disagree. "
            "Manual intervention required.",
            step="restore_secret", error=type(exc).__name__, **ctx)


def rotation_order(config):
    """Rotate the admin user last, after everything it is needed for."""
    users = [u for u in config.mappings if u != config.admin_user]
    if config.admin_user in config.mappings:
        users.append(config.admin_user)
    return users


def main():
    configure_logging()

    try:
        config = load_config()
    except ConfigError as exc:
        log(logging.CRITICAL, "Invalid configuration", error=str(exc))
        return 2

    log(logging.INFO, "Rotation job starting",
        instance=config.instance_connection_name,
        users=list(config.mappings), admin_user=config.admin_user)

    store = SecretStore(config.project_id)
    # Lazy refresh: the job is short-lived, so fetch the client certificate
    # on connect instead of refreshing it on a background thread.
    with Connector(ip_type=config.ip_type,
                   refresh_strategy="lazy") as connector:
        return rotate_all(connector, store, config)


def rotate_all(connector, store, config):
    """Connect as the admin user and rotate every mapped user."""
    admin_password = None
    try:
        admin_password = store.read_latest(config.admin_secret)
        conn = connect(connector, config, admin_password)
    except Exception as exc:
        log(logging.CRITICAL, "Could not connect to the database",
            instance=config.instance_connection_name,
            error=describe_error(exc, admin_password))
        return 1
    finally:
        admin_password = None

    failed = []
    try:
        for username in rotation_order(config):
            if not rotate_user(conn, store, config, username,
                               config.mappings[username]):
                failed.append(username)
    finally:
        try:
            conn.close()
        except Exception:
            pass

    if failed:
        log(logging.ERROR, "Rotation job finished with failures",
            failed_users=failed,
            succeeded=len(config.mappings) - len(failed))
        return 1

    log(logging.INFO, "Rotation job finished successfully",
        succeeded=len(config.mappings))
    return 0


if __name__ == "__main__":
    sys.exit(main())
