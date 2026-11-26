# GCP PostgreSQL Password Rotator

Rotates the passwords of PostgreSQL users on a Cloud SQL instance on a schedule
and stores each new password in Secret Manager, with no human ever seeing it.

A Cloud Run Job, triggered by Cloud Scheduler about every 90 days, connects to
Cloud SQL over its private IP, changes each user's password, and adds the new
password as a new version of that user's secret. Applications that read the
`latest` secret version pick up the new password on their next fetch.

| Item | Value (dev) |
| --- | --- |
| GCP project | `ingka-dp-sap-dev` (`europe-west1`) |
| Cloud SQL instance | `staging-database` (PostgreSQL 16) |
| Rotated users → secrets | `postgres` → `postgres_pwd`, `int_mdm_012` → `int_mdm_012_pwd`, `int_mdm_013` → `int_mdm_013_pwd`, `int_mdm_016` → `int_mdm_016_pwd` |
| Previous passwords (for ops) | `postgres_oldpwd`, `int_mdm_012_oldpwd`, `int_mdm_013_oldpwd`, `int_mdm_016_oldpwd` |
| Versions kept per secret | 2: the current one (enabled) and the one before it (disabled); older versions are destroyed |
| Cloud Run Job | `postgres-password-rotator-dev` |
| Schedule | `0 0 1 */3 *` UTC (1 Jan, 1 Apr, 1 Jul, 1 Oct) |
| Image | `europe-west1-docker.pkg.dev/ingka-dp-sap-dev/rotator-repo/rotator` |

See [ARCHITECTURE.md](ARCHITECTURE.md) for how the pieces fit together.

## Tech stack

- **Python 3.11**: `rotator.py`, a single script, using
  [pg8000](https://github.com/tlocke/pg8000) (pure-Python PostgreSQL driver)
  and `google-cloud-secret-manager`.
- **Docker**: `python:3.11-slim` image, runs as a non-root user.
- **Terraform** (`hashicorp/google ~> 5.0`): all GCP infrastructure, state in
  GCS bucket `mdm-postgrespwd-tfstate-dev`.
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
git clone https://github.com/ingka-group-digital/mdm-postgrespwd-rotator.git
cd mdm-postgrespwd-rotator

python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Running locally

> **Warning:** the rotator has no dry-run mode. Running it changes real
> passwords and writes real secret versions. Point it at a throwaway user and
> secret, never at the shared mapping below, unless you mean to rotate.

The job connects through the
[Cloud SQL Python Connector](https://github.com/GoogleCloudPlatform/cloud-sql-python-connector)
on the instance's private IP, which isn't reachable from a laptop. Locally, use
the public IP instead (the instance must have one). The connector handles TLS
and client certificates either way:

```sh
gcloud auth application-default login

export PROJECT_ID=ingka-dp-sap-dev
export INSTANCE_CONNECTION_NAME=ingka-dp-sap-dev:europe-west1:staging-database
export DB_IP_TYPE=public
export DB_ADMIN_SECRET=postgres_pwd # password used to connect as postgres
export SECRET_MAPPINGS='{"test_user": "test_user_pwd"}'

python rotator.py
```

Your own gcloud account needs `roles/cloudsql.client` on the instance and
`secretmanager.versions.access`/`add`/`list`/`disable`/`destroy` on the
secrets involved. The full list
of environment variables is in the `rotator.py` module docstring.

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

## Environments

There are four environments, each in its own GCP project with its own
Terraform state. The code is the same everywhere; only
`terraform/envs/<env>.tfvars` and `terraform/envs/<env>.backend.hcl` differ.

| Env | GCP project | Deploy |
| --- | --- | --- |
| dev | `ingka-dp-sap-dev` | Automatic on every merge to `main`, or a PR preview |
| test | `ingka-dp-sap-test` | Approved promotion PR, same image as dev |
| stage | `ingka-dp-sap-stage` | Approved promotion PR, same image as test |
| prod | `ingka-dp-sap-prod` | Approved promotion PR (being set up) |

`main` is the only long-lived code branch, with short-lived `feature/*` and
`fix/*` branches merged through PRs. The image is built once per merge, and
each higher environment gets that exact image through its own promotion PR.
The `prod` branch is the confirmed production copy. See [CICD.md](CICD.md).

## First-time environment setup

Run once per environment, using a user account with admin access to that
environment's project (the "bootstrap account"). CI can't do this, because it
can't create the identity it signs in with. After this, Terraform and
application deploys both go through CI, and this account is only needed to
repair the pipeline itself.

Below, `<env>` is `dev`, `test`, ... and `<project>` is that environment's
project from the table above.

**1. Log in as the bootstrap account.** Replace `<your-account-email>` with
your own GCP login. Terraform uses Application Default Credentials, so the
`application-default` login is the one that matters:

```sh
gcloud auth login <your-account-email>
gcloud config set account <your-account-email>
gcloud config set project <project>
gcloud auth application-default login
gcloud auth application-default set-quota-project <project>
```

**2. Check the account's access.** It needs `roles/owner` on the project, or
at least: Service Usage Admin, Service Account Admin, Project IAM Admin,
Workload Identity Pool Admin and Storage Admin on the state bucket. No
custom-role permissions are needed.

**3. Create what Terraform expects to already exist:**

```sh
# APIs Terraform needs before it can enable the rest
gcloud services enable cloudresourcemanager.googleapis.com \
  serviceusage.googleapis.com --project=<project>

# State bucket (versioned, private)
gcloud storage buckets create gs://mdm-postgrespwd-tfstate-<env> \
  --project=<project> --location=europe-west1 \
  --uniform-bucket-level-access --public-access-prevention
gcloud storage buckets update gs://mdm-postgrespwd-tfstate-<env> --versioning
```

Also required, and not created by Terraform:

- Cloud SQL instance `staging-database` (same name in every environment) with
  a **private IP** on the `ingka-dp-vpc-1` VPC (Private Services Access set up
  on that network).
- Secrets `postgres_pwd`, `int_mdm_012_pwd`, `int_mdm_013_pwd`,
  `int_mdm_016_pwd`, each holding that user's **current** password.
- Secrets `postgres_oldpwd`, `int_mdm_012_oldpwd`, `int_mdm_013_oldpwd`,
  `int_mdm_016_oldpwd` (region `europe-west1`), for the password each
  rotation replaces. A dummy first value is fine; the first rotation writes
  the real one.
- On PostgreSQL 16, for each `int_mdm_*` user:
  `GRANT <user> TO postgres WITH ADMIN OPTION;`
- An unused `/28` in the VPC for the Serverless VPC Access connector
  (`vpc_connector_cidr` in `envs/<env>.tfvars`). It must not overlap any
  subnet, the Private Services Access range, another connector, or a route
  learned through peering.

**4. Bootstrap the Terraform pipeline** (Cloud Shell works):

```sh
bash terraform/bootstrap.sh <env> <project>
```

It creates the GitHub Workload Identity pool and provider (if missing) and
the pipeline's two service accounts: `sa-terraform` (applies, only from
`main`) and `sa-terraform-plan` (read-only, plans on PRs). It's safe to run
again. It prints the line to add to `.github/terraform-envs.json`.

**5. Create the GitHub Environment.** In the repository, go to Settings ->
Environments -> New environment `<env>`, and add these variables:

| Variable | Value |
| --- | --- |
| `PROJECT_ID` | `<project>` |
| `REGION` | `europe-west1` |
| `WIF_PROVIDER` | `projects/<project-number>/locations/global/workloadIdentityPools/github-actions-pool-<env>/providers/github-provider-<env>` |
| `DEPLOY_SA` | `sa-cicd-deployer@<project>.iam.gserviceaccount.com` |

Set **Deployment branches** to `main` only (dev: no restriction, for PR
previews), and reviewers if the environment needs them: they approve both
deploys and Terraform applies. Use environment *variables*, not secrets. The
other GitHub settings (repository variables, branch protection, labels) are
listed in [CICD.md](CICD.md#github-settings).

**6. Open a PR** adding `terraform/envs/<env>.tfvars`,
`terraform/envs/<env>.backend.hcl`, the environment in
`.github/terraform-envs.json`, and the environment in
`.github/workflows/terraform.yaml`. The PR shows the plan. After merging,
**Actions → Terraform → Run workflow** with the environment creates it. See
[CICD.md](CICD.md#adding-an-environment).

## Deploying

**Application:**

1. Optional: label your PR `deploy-dev` to try it in dev before review.
2. Merge to `main`: builds **build N** once and deploys it to dev.
3. Actions → **Create promotion PR** → pick the environment. Approve and
   merge the PR it opens to deploy that build there.
4. After the prod sanity check: Actions → **Confirm prod stable**.

Details, rollback and disaster restore: [CICD.md](CICD.md). Only `main` of
this repository can authenticate to test, stage and prod; PRs can reach dev
only.

**Infrastructure:** change `terraform/` in a PR. The PR gets a plan comment
per environment; merging applies dev. Test, stage and prod get it with their
next promotion PR (which shows their plan), or with an infrastructure-only
PR from the same button. See [CICD.md](CICD.md#infrastructure-changes).

**Run a rotation now** (changes real passwords):

```sh
gcloud run jobs execute postgres-password-rotator-<env> \
  --region=europe-west1 --project=<project> --wait
```

**Schedule:** the scheduler trigger is **paused in every environment**
(`schedule_paused = true` in `terraform/envs/<env>.tfvars`), so rotations
only happen when the job is run as above. To turn scheduled rotation on for
an environment, set `schedule_paused = false` in its tfvars in a PR: dev
gets it on merge, the others with their next promotion (or "Apply
infrastructure changes"). Resuming it by hand in the console works too, but
the next Terraform apply pauses it again.

Logs are in Cloud Logging under resource type `cloud_run_job`, one JSON entry
per step, with fields `db_user`, `secret_id` and `step`. Passwords are never
logged.

## Adding a user to rotation

1. Create the secret in Secret Manager with the user's current password, and
   its `<user>_oldpwd` secret (a dummy value is fine).
2. Add the `user = "secret_id"` pairs to `user_secret_mappings` and
   `user_old_secret_mappings` in `terraform/envs/<env>.tfvars`, for each
   environment that has the user.
3. Make sure `postgres` can change that user's password (PostgreSQL 16:
   `GRANT <user> TO postgres WITH ADMIN OPTION;`).
4. Merge the PR; the Terraform pipeline applies it (see Deploying).
