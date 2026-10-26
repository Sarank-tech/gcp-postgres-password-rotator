# CLAUDE.md

Scheduled Cloud Run Job that rotates PostgreSQL user passwords on Cloud SQL
and stores them in Secret Manager. GCP project `shriramblue` (number
`242762429775`), region `europe-west1`, env `dev`. Human docs:
[README.md](README.md), [ARCHITECTURE.md](ARCHITECTURE.md).

## Layout

- `rotator.py`: the entire app (single module, no package). Config from env
  vars, documented in its module docstring.
- `requirements.txt`, `Dockerfile`: image (`python:3.11-slim`, non-root).
- `terraform/`: all GCP infra in one `main.tf` with numbered sections; dev
  values in `terraform.tfvars` (committed, no secrets).
- `.github/workflows/deploy.yaml`: on push to `main`, build → push → update
  Cloud Run Job image by digest.

## Architecture rules

- **One connection, one transaction per user.** `rotate_user` does
  read old secret → `ALTER USER` (uncommitted) → add secret version →
  `COMMIT`. Secret failure → rollback. Commit failure → re-add old password
  as latest version. Keep this ordering in any change.
- **Send only the SCRAM-SHA-256 verifier to PostgreSQL**
  (`scram_sha256_verifier`), never the plaintext, so it can't show up in
  server logs.
- **Connect via `DB_PRIVATE_IP`** (`10.10.32.3` today, read from the instance
  by a Terraform data source, never hardcoded) through the VPC connector, as
  `postgres`, with SSL. The instance only accepts encrypted connections.
- **Admin user rotates last** (`rotation_order`).
- **Exit codes:** `0` all ok, `1` any user failed or couldn't connect, `2`
  invalid config. One user's failure must not stop the others.
- **Cloud SQL instance, secrets, state bucket and Private Services Access are
  pre-existing.** Terraform only reads them via `data` sources. Never turn
  them into managed resources.
- **Cloud Scheduler uses `oauth_token`, not OIDC.** It calls
  `run.googleapis.com`, and Google APIs reject OIDC tokens.
- **CI owns the job's image.** Terraform has `ignore_changes` on it; don't
  remove that, or `apply` will roll back deploys.

## Commands

```sh
# Setup
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# Lint (PEP 8, 79-char lines). No formatter is configured; don't add one.
pip install pycodestyle && pycodestyle rotator.py

# Terraform format / validate (offline, no state access)
cd terraform && terraform fmt -check -diff \
  && terraform init -backend=false -input=false && terraform validate
rm -rf terraform/.terraform   # if you inited with -backend=false

# Terraform plan (reads live GCP + GCS state; safe)
cd terraform && terraform init -input=false && terraform plan

# Build
docker build -t rotator:local .

# Deployed job config (read-only)
gcloud run jobs describe postgres-password-rotator-dev \
  --region=europe-west1 --project=shriramblue
```

**Tests:** there is no test suite. To check changes to `rotator.py` offline,
write throwaway scripts in the scratchpad (not the repo) that:
- generate many passwords and assert length and character classes;
- compare `scram_sha256_verifier` output to
  `scramp.ScramMechanism("SCRAM-SHA-256").make_auth_info(pw, iteration_count=4096, salt=...)`;
- drive `rotate_user` with fake `conn`/`store` objects for the success,
  secret-failure and commit-failure paths, and assert no password appears in
  the captured logs.

## Coding standards

- PEP 8, max 79 chars, stdlib + the three pinned deps only.
- `snake_case` functions, `PascalCase` classes, private helpers prefixed `_`.
- Section banners (`####...` comment blocks) group code in both `rotator.py`
  and `main.tf`; put new code in the matching section.
- Logging goes only through `log(level, message, **fields)`, which emits JSON
  with `severity`. Always include `db_user`, `secret_id`, `step` for per-user
  events.
- **Never log a password, verifier or secret payload**, not even in error
  text. Wrap exceptions with `describe_error(exc, *sensitive_values)`, or log
  only `type(exc).__name__`.
- Config errors raise `ConfigError` from `load_config()`; validate there, not
  later.
- SQL that can't take bind parameters (`ALTER USER`) must use `quote_ident` /
  `quote_literal`.
- Terraform: names suffixed with `${var.environment}`; every new variable has a
  description and a dev default; new APIs go in `local.required_apis`; IAM is
  `*_iam_member` (never `*_iam_policy`/`*_iam_binding`), scoped to the
  smallest resource possible.
- GitHub Actions: pin every action to a full commit SHA with a `# vX.Y.Z`
  comment; use versions released at least two weeks ago.

## Critical constraints

- **Never run the job** (`gcloud run jobs execute ...` or `python rotator.py`
  against real secrets) without explicit user confirmation. There is no
  dry run; it changes production-like passwords.
- **Never `terraform apply`** without showing the plan and getting
  confirmation. Never touch the GCS state directly.
- **Never commit or push** unless asked; the user pushes. Pushing to `main`
  deploys.
- The `backend "gcs"` block in `terraform/main.tf` is hardcoded (backends
  can't use variables); keep it in sync with `var.tfstate_bucket`.
- **WIF only accepts `Sarank-tech/gcp-postgres-password-rotator` on
  `refs/heads/main`** (`attribute_condition`). The repo name is
  case-sensitive. CI from other branches fails auth by design.
- **`scramp==1.4.17` is pinned on purpose:** scramp 1.5.0 removed
  `make_channel_binding`, which pg8000 1.31.2 calls on SSL connections. Don't
  unpin or bump without checking pg8000 compatibility.
- PostgreSQL 16: `postgres` (in `cloudsqlsuperuser`, not superuser) can only
  alter roles it has `ADMIN OPTION` on. Permission errors on a user → needs
  `GRANT <user> TO postgres WITH ADMIN OPTION;`.
- The custom role ID is `projects/shriramblue/roles/CustomPostgresRotatorDev`
  (not `roles/...`). A deleted custom role ID can't be reused for ~37 days, so
  don't rename it casually.
- Don't edit `.terraform.lock.hcl` by hand; regenerate with `terraform init
  -upgrade` only when bumping providers.

## Known gaps (don't "fix" silently; raise with the user)

- Custom role is bound project-wide, so it covers all secrets; the
  `cloudsql.*` permissions are unused.
- Indirect dependencies other than `scramp` are unpinned.
- SSL default is `require` (no cert verification); `verify-ca` needs the
  instance CA cert at `DB_SSL_ROOT_CERT`.
