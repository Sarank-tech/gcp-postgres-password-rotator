# Architecture

## Overview

The system is a **scheduled batch job**: it starts, rotates every configured
user's password, and exits. There is no long-running service, no database of
its own, and no inbound network traffic.

Three separate concerns, each owned by one part of the repo:

| Concern | Owner | How it changes |
| --- | --- | --- |
| Rotation logic | `rotator.py` (+ `Dockerfile`) | Push to `main` → GitHub Actions builds and deploys |
| GCP infrastructure | `terraform/` | `terraform apply`, run by hand |
| Delivery pipeline | `.github/workflows/deploy.yaml` | Push to `main` |
| Environments | `terraform/envs/<env>.tfvars` + `<env>.backend.hcl`, GitHub Environments | One GCP project and one state bucket per environment (dev, test, stage, prod) |

```mermaid
flowchart LR
    subgraph GitHub
        GH[Push to main] --> GA[GitHub Actions]
    end
    subgraph GCP["GCP project per environment, e.g. ingka-dp-sap-dev (europe-west1)"]
        WIF[Workload Identity<br/>Federation]
        AR[(Artifact Registry<br/>rotator-repo)]
        SCH[Cloud Scheduler<br/>0 0 1 */3 *]
        JOB[Cloud Run Job<br/>postgres-password-rotator-&lt;env&gt;]
        VPCC[Serverless VPC<br/>Access connector]
        SQL[(Cloud SQL<br/>staging-database<br/>private IP)]
        SM[(Secret Manager<br/>*_pwd secrets)]
    end
    GA -- OIDC token --> WIF
    GA -- push image --> AR
    GA -- update image --> JOB
    SCH -- "POST :run (OAuth)" --> JOB
    AR -. pull .-> JOB
    JOB -- read / add versions --> SM
    JOB --> VPCC -- "SQL over TLS" --> SQL
```

## Patterns

- **Infrastructure as Code.** Every GCP resource is in Terraform with remote
  state in GCS. The Cloud SQL instance and the secrets already existed and are
  only *looked up* (`data` sources), never managed, so Terraform can't delete
  them.
- **Configuration through environment variables.** Terraform injects
  everything the job needs; the image has no environment-specific values.
- **Keyless CI/CD.** GitHub Actions exchanges its OIDC token for short-lived
  GCP credentials. No service account keys exist anywhere.
- **Least privilege, one identity per role.** Separate service accounts for
  deploying, running the job, and triggering it (see
  [Identities](#identities-and-permissions)).
- **Immutable deploys.** CI deploys by image digest, not by tag. Terraform
  ignores the image field so it never rolls back a CI deploy.
- **Transactional rotation with compensation.** Each user's change is held in
  an open database transaction until the secret is written (see
  [Data flow](#data-flow)).

## Directory structure

```
.
├── rotator.py                  # The whole application: config, password
│                               #   generation, SQL, Secret Manager, logging
├── requirements.txt            # Pinned Python dependencies (scramp pinned
│                               #   explicitly for pg8000 compatibility)
├── Dockerfile                  # python:3.11-slim, non-root, ENTRYPOINT rotator.py
├── .github/workflows/
│   └── deploy.yaml             # Build once → dev → test (approval), on main
└── terraform/
    ├── main.tf                 # Backend, provider, and all resources, in
    │                           #   numbered sections (APIs, WIF, CI SA,
    │                           #   runtime SA + secret IAM, VPC connector,
    │                           #   Artifact Registry, Cloud Run Job, Scheduler)
    ├── variables.tf            # Inputs; project_id and environment required
    ├── envs/
    │   ├── <env>.tfvars        # Per-environment values (committed; no secrets)
    │   └── <env>.backend.hcl   # Per-environment state bucket and prefix
    ├── outputs.tf              # WIF provider, SA emails, registry URL, ...
    └── .terraform.lock.hcl     # Provider version lock (committed)
```

### Inside `rotator.py`

The script is split into sections with no shared state except the `Config`
object, the DB connection and the `SecretStore`:

| Section | Responsibility |
| --- | --- |
| Logging | `JsonFormatter` writes one JSON object per line with `severity`, which Cloud Logging parses; `describe_error` scrubs secrets out of exception text |
| Configuration | `load_config()` validates env vars into a frozen `Config`; bad config exits with code 2 |
| Passwords | `generate_password()` (CSPRNG, all four character classes; no quotes, backslashes, `#`, `$`, `@`, `%`, `&` or `;`) and `scram_sha256_verifier()` |
| SQL helpers | `quote_ident` / `quote_literal`, needed because `ALTER USER` can't take bind parameters |
| Secret Manager | `SecretStore`: `read_latest()` and `add_version()` |
| Database | `connect()` through the Cloud SQL Python Connector (`pg8000` driver, private IP by default) |
| Rotation | `rotate_user()`, plus `rotation_order()` and `main()` |

## Data flow

On each execution:

1. **Start-up.** `main()` loads config from the environment, reads the admin
   (`postgres`) password from its secret, and opens one connection as
   `postgres` through the Cloud SQL connector. The connector looks up the
   instance's private IP, gets a short-lived client certificate from the Cloud
   SQL Admin API, and connects with mutual TLS on port 3307. That works even
   when the instance requires trusted client certificates.
2. **Order.** Users are processed in `SECRET_MAPPINGS` order, with the admin
   user moved to the end.
3. **Per user** (`rotate_user`):

   ```mermaid
   sequenceDiagram
       participant R as rotator.py
       participant SM as Secret Manager
       participant DB as Cloud SQL
       R->>SM: access latest version (old password, kept in memory)
       R->>R: generate password + SCRAM-SHA-256 verifier
       R->>DB: ALTER USER ... WITH PASSWORD '<verifier>' (uncommitted)
       R->>SM: add version (new password)
       R->>DB: COMMIT
   ```

   - Secret write fails → the transaction is **rolled back**; DB and secret
     still both hold the old password.
   - `COMMIT` fails → the old password is **re-added** as the latest secret
     version, so the secret matches the DB again.
   - Both of those fail → logged at `CRITICAL`; needs manual repair.

   Only the SCRAM verifier, a salted hash, is sent to PostgreSQL. The plaintext
   password exists only in the job's memory and in Secret Manager, so it can't
   end up in PostgreSQL's logs.
4. **Exit.** Code `0` if every user succeeded, `1` if any failed (Cloud Run
   marks the execution failed), `2` for invalid config. One user's failure
   doesn't stop the others.

### Delivery flow

`push to main` → **dev job** (GitHub Environment `dev`): authenticates through
WIF as dev's `sa-cicd-deployer` → `docker build` → push `rotator:<sha>` and
`rotator:latest` to dev's registry → `gcloud run jobs update
--image=rotator@sha256:<digest>`.

→ **test job** (GitHub Environment `test`, waits for a required reviewer):
pulls that digest with dev's identity, checks its revision label equals the
commit SHA, switches to test's WIF identity and points test's job at the same
digest in dev's registry, then tags it `deployed-test` (as dev). Nothing is
rebuilt or copied: dev's registry is the only one, test's Cloud Run service
agent reads from it, and the `deployed-<env>` tag stops dev's cleanup policy
from deleting an image test still runs. If the image is cleaned up before
someone approves test, the test job fails at the pull; approve a newer run
instead.

## Identities and permissions

| Service account | Used by | Permissions |
| --- | --- | --- |
| `sa-cicd-deployer` | GitHub Actions through WIF (only `ingka-group-digital/mdm-postgrespwd-rotator`, branch `main`) | Run admin, Cloud Functions developer, Cloud Build editor, Scheduler admin, VPC Access user, Artifact Registry writer (dev only); object admin on the state bucket; `actAs` on `sa-db-rotator-<env>` only |
| Cloud Run service agent of test (and later envs) | Cloud Run, pulling the image | `roles/artifactregistry.reader` on dev's `rotator-repo` only |
| `sa-db-rotator-<env>` | The Cloud Run Job | `roles/secretmanager.secretAccessor` and `roles/secretmanager.secretVersionAdder` on the four `*_pwd` secrets only; `roles/cloudsql.client` conditioned to the target instance only |
| `sa-rotator-scheduler-<env>` | Cloud Scheduler | `roles/run.invoker` on this job only |

Notes:

- The rotator needs no Cloud SQL IAM role: passwords change over SQL, not the
  Cloud SQL Admin API. Built-in roles are used instead of a custom role, so
  no environment needs `iam.roles.create`.
- Inside PostgreSQL the job connects as `postgres` (a member of
  `cloudsqlsuperuser`, not a true superuser). On PostgreSQL 16 it can only
  change passwords of roles it has `ADMIN OPTION` on.

## Infrastructure and network dependencies

| Dependency | Purpose | Managed by |
| --- | --- | --- |
| Cloud SQL `staging-database` | Target database; reached on private IP from `ingka-dp-vpc-1` VPC; server requires trusted client certificates (mTLS via the Cloud SQL connector) | **Not** Terraform (data source only) |
| Secret Manager `*_pwd` secrets | Source of current and store of new passwords | **Not** Terraform (data source only) |
| Serverless VPC Access connector `pg-rotator-conn-<env>` | Gives the job a path into `ingka-dp-vpc-1` VPC (`vpc_connector_cidr`, `10.8.0.0/28` in dev; egress `PRIVATE_RANGES_ONLY`) | Terraform |
| Private Services Access on `ingka-dp-vpc-1` VPC | Peering that gives Cloud SQL its private IP | Set up manually, outside Terraform |
| Artifact Registry `rotator-repo` (dev only) | The single image store for all environments; keeps the 3 newest versions and every `deployed-<env>` image, deletes all others | Terraform |
| Cloud Run Job | Runs the container (1 task, 600 s timeout, 1 retry) | Terraform (image: CI) |
| Cloud Scheduler | Calls `run.googleapis.com/v2/.../jobs/...:run` with an OAuth token | Terraform |
| Workload Identity Pool `github-actions-pool-<env>` | Trusts `token.actions.githubusercontent.com` | Terraform |
| GCS bucket `mdm-postgrespwd-tfstate-<env>` | Terraform state (`postgres-password-rotator/<env>`) | **Not** Terraform (pre-existing) |

Outbound calls from the job: Secret Manager API (public Google endpoint;
egress is private-ranges-only, so it doesn't go through the connector) and
Cloud SQL on its private IP (through the connector). Nothing calls into the
job except Cloud Scheduler, through the Cloud Run Admin API.

## Known limitations

- Rotations are about every 90 days: quarterly on the 1st, so gaps are 90-92
  days (cron can't do an exact day count).
- No dry-run mode and no automated tests.
- Applications that cache the password keep the old one until they re-read the
  secret, and the old password stops working right away. Consumers need to
  re-fetch the secret when authentication fails.
- Only `scramp` is pinned beyond the top-level dependencies; other indirect
  dependencies can still change between builds.
