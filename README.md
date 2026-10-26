# GCP PostgreSQL Password Rotator

Rotates the passwords of PostgreSQL users on a Cloud SQL instance on a schedule
and stores each new password in Secret Manager, with no human ever seeing it.

A Cloud Run Job, triggered by Cloud Scheduler about every 120 days, connects to
Cloud SQL over its private IP, changes each user's password, and adds the new
password as a new version of that user's secret. Applications that read the
`latest` secret version pick up the new password on their next fetch.

| Item | Value (dev) |
| --- | --- |
| GCP project | `ingka-dp-sap-dev` (`europe-west1`) |
| Cloud SQL instance | `testsergio` (PostgreSQL 16) |
| Rotated users → secrets | `postgres` → `postgres_pwd`, `int_mdm_012` → `int_mdm_012_pwd`, `int_mdm_013` → `int_mdm_013_pwd`, `int_mdm_016` → `int_mdm_016_pwd` |
| Cloud Run Job | `postgres-password-rotator-dev` |
| Schedule | `0 0 1 */4 *` UTC (1 Jan, 1 May, 1 Sep) |
| Image | `europe-west1-docker.pkg.dev/ingka-dp-sap-dev/rotator-repo/rotator` |

See [ARCHITECTURE.md](ARCHITECTURE.md) for how the pieces fit together.

## Tech stack

- **Python 3.11**: `rotator.py`, a single script, using
  [pg8000](https://github.com/tlocke/pg8000) (pure-Python PostgreSQL driver)
  and `google-cloud-secret-manager`.
- **Docker**: `python:3.11-slim` image, runs as a non-root user.
- **Terraform** (`hashicorp/google ~> 5.0`): all GCP infrastructure, state in
  GCS bucket `p2p-postgrespwd-tfstate-dev`.
- **GitHub Actions**: builds and deploys on every push to `main`, authenticating
  through Workload Identity Federation (no service account keys).

## Prerequisites

- Python 3.11+
- Docker
- Terraform >= 1.5
- Google Cloud SDK (`gcloud`), authenticated with access to `ingka-dp-sap-dev`:

  ```sh
  gcloud auth login
  gcloud auth application-default login
  gcloud config set project ingka-dp-sap-dev
  ```

  Setting up the project for the first time? See
  [First-time environment setup](#first-time-environment-setup).

## Local setup

```sh
git clone https://github.com/ingka-group-digital/p2p-postgrespwd-rotator.git
cd p2p-postgrespwd-rotator

python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Running locally

> **Warning:** the rotator has no dry-run mode. Running it changes real
> passwords and writes real secret versions. Point it at a throwaway user and
> secret, never at the shared mapping below, unless you mean to rotate.

The job normally reaches Cloud SQL on its private IP, which isn't reachable from
a laptop. Locally, use the
[Cloud SQL Auth Proxy](https://cloud.google.com/sql/docs/postgres/sql-proxy)
over the public IP instead (it encrypts the connection itself):

```sh
# Terminal 1: proxy to localhost:5432
cloud-sql-proxy ingka-dp-sap-dev:europe-west1:testsergio --port 5432

# Terminal 2
export PROJECT_ID=ingka-dp-sap-dev
export INSTANCE_CONNECTION_NAME=ingka-dp-sap-dev:europe-west1:testsergio
export DB_PRIVATE_IP=127.0.0.1
export DB_SSL_MODE=disable          # proxy already encrypts
export DB_ADMIN_SECRET=postgres_pwd # password used to connect as postgres
export SECRET_MAPPINGS='{"test_user": "test_user_pwd"}'

python rotator.py
```

Your own gcloud account needs `secretmanager.versions.access`/`add` on the
secrets involved. The full list of environment variables is in the
`rotator.py` module docstring.

## Tests and checks

There is no automated test suite yet. Before opening a PR, run:

```sh
pip install pycodestyle && pycodestyle rotator.py   # PEP 8

cd terraform
terraform fmt -check
terraform init -backend=false && terraform validate
```

## Building

```sh
docker build -t rotator:local .
```

To run the container locally, pass the same environment variables with `-e`,
plus Application Default Credentials (for example by mounting
`~/.config/gcloud` and setting `GOOGLE_APPLICATION_CREDENTIALS`).

## First-time environment setup

Run once to stand up `ingka-dp-sap-dev`, using a user account with admin
access to the project (the "bootstrap account"). After this, application
deploys go through CI, and this account is only needed for Terraform changes.

**1. Log in as the bootstrap account.** Replace `<your-account-email>` with
your own GCP login. Terraform uses Application Default Credentials, so the
`application-default` login is the one that matters:

```sh
gcloud auth login <your-account-email>
gcloud config set account <your-account-email>
gcloud config set project ingka-dp-sap-dev
gcloud auth application-default login
gcloud auth application-default set-quota-project ingka-dp-sap-dev
```

**2. Check the account's access.** It needs `roles/owner` on the project, or
at least: Service Usage Admin, Service Account Admin, Project IAM Admin,
Workload Identity Pool Admin, Cloud Run Admin, Cloud Scheduler Admin,
Serverless VPC Access Admin, Artifact Registry Administrator, Service Account
User, Cloud SQL Viewer, Secret Manager Admin (to grant access on the password
secrets), and Storage Admin on the state bucket. No custom-role permissions
are needed.

**3. Create what Terraform expects to already exist:**

```sh
# APIs Terraform needs before it can enable the rest
gcloud services enable cloudresourcemanager.googleapis.com \
  serviceusage.googleapis.com --project=ingka-dp-sap-dev

# State bucket (versioned, private)
gcloud storage buckets create gs://p2p-postgrespwd-tfstate-dev \
  --project=ingka-dp-sap-dev --location=europe-west1 \
  --uniform-bucket-level-access --public-access-prevention
gcloud storage buckets update gs://p2p-postgrespwd-tfstate-dev --versioning
```

Also required, and not created by Terraform:

- Cloud SQL instance `testsergio` with a **private IP** on the
  `ingka-dp-vpc-1` VPC (Private Services Access set up on that network).
- Secrets `postgres_pwd`, `int_mdm_012_pwd`, `int_mdm_013_pwd`,
  `int_mdm_016_pwd`, each holding that user's **current** password.
- On PostgreSQL 16, for each `int_mdm_*` user:
  `GRANT <user> TO postgres WITH ADMIN OPTION;`

**4. Apply:**

```sh
cd terraform
terraform init
terraform plan    # review before applying
terraform apply
```

**5. Check the outputs match the workflow.** `terraform output
wif_provider_name` and `terraform output cicd_service_account_email` must equal
`WIF_PROVIDER` and `DEPLOY_SA` in `.github/workflows/deploy.yaml`. Then push to
`main` (or run the workflow manually) to build and deploy the real image.

## Deploying

**Application:** push to `main`. `.github/workflows/deploy.yaml` builds the
image, pushes it tagged with the commit SHA and `latest`, and points the Cloud
Run Job at the new image digest. Only the `main` branch of this repository can
authenticate to GCP.

**Infrastructure:** run Terraform by hand (CI does not run it):

```sh
cd terraform
terraform init
terraform plan
terraform apply
```

**Run a rotation now** (changes real passwords):

```sh
gcloud run jobs execute postgres-password-rotator-dev \
  --region=europe-west1 --project=ingka-dp-sap-dev --wait
```

Logs are in Cloud Logging under resource type `cloud_run_job`, one JSON entry
per step, with fields `db_user`, `secret_id` and `step`. Passwords are never
logged.

## Adding a user to rotation

1. Create the secret in Secret Manager with the user's current password.
2. Add the `user = "secret_id"` pair to `user_secret_mappings` in
   `terraform/terraform.tfvars`.
3. Make sure `postgres` can change that user's password (PostgreSQL 16:
   `GRANT <user> TO postgres WITH ADMIN OPTION;`).
4. Run `terraform apply`.
