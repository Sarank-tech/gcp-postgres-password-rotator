#!/usr/bin/env bash
# One-time setup of an environment for the Terraform pipeline. Run it once
# per environment (Cloud Shell works), by someone allowed to manage IAM,
# service accounts and Workload Identity pools in the project:
#
#   bash terraform/bootstrap.sh <env> <project-id>
#   e.g. bash terraform/bootstrap.sh stage ingka-dp-sap-stage
#
# The pipeline can't create the identity it signs in with, so this script
# does, before Terraform ever runs there:
#   - the APIs needed to sign in through Workload Identity Federation,
#   - the GitHub pool and provider, if missing (Terraform adopts them later),
#   - sa-terraform: plans and applies on main (GitHub environment <env>),
#   - sa-terraform-plan: read-only, plans on pull requests.
# The state bucket must already exist (see README). Safe to run again.
set -euo pipefail

ENV="${1:?usage: bootstrap.sh <env> <project-id>}"
PROJECT="${2:?usage: bootstrap.sh <env> <project-id>}"
REPO="ingka-group-digital/mdm-postgrespwd-rotator"
MAIN_REF="refs/heads/main"

POOL="github-actions-pool-${ENV}"
PROVIDER="github-provider-${ENV}"
BUCKET="mdm-postgrespwd-tfstate-${ENV}"
APPLY_SA="sa-terraform@${PROJECT}.iam.gserviceaccount.com"
PLAN_SA="sa-terraform-plan@${PROJECT}.iam.gserviceaccount.com"

# What Terraform manages: IAM, service accounts, the WIF pool, APIs, the job,
# its schedule and VPC connector, secret access, and (dev) the registry.
APPLY_ROLES=(
  roles/resourcemanager.projectIamAdmin
  roles/iam.serviceAccountAdmin
  roles/iam.serviceAccountUser
  roles/iam.workloadIdentityPoolAdmin
  roles/serviceusage.serviceUsageAdmin
  roles/run.admin
  roles/cloudscheduler.admin
  roles/vpcaccess.admin
  roles/compute.networkViewer
  roles/secretmanager.admin
  roles/cloudsql.viewer
)
[ "${ENV}" = "dev" ] && APPLY_ROLES+=(roles/artifactregistry.admin)

PLAN_ROLES=(
  roles/viewer
  roles/iam.securityReviewer
)

gcloud projects describe "${PROJECT}" > /dev/null
NUMBER="$(gcloud projects describe "${PROJECT}" --format='value(projectNumber)')"
gcloud storage buckets describe "gs://${BUCKET}" --project="${PROJECT}" > /dev/null \
  || { echo "State bucket gs://${BUCKET} is missing; create it first (README)." >&2; exit 1; }

echo "== APIs"
gcloud services enable iam.googleapis.com iamcredentials.googleapis.com \
  sts.googleapis.com cloudresourcemanager.googleapis.com \
  serviceusage.googleapis.com --project="${PROJECT}"

echo "== Workload Identity pool and provider"
# Same settings as terraform/main.tf, so adopting them changes nothing.
if ! gcloud iam workload-identity-pools describe "${POOL}" \
     --project="${PROJECT}" --location=global > /dev/null 2>&1; then
  gcloud iam workload-identity-pools create "${POOL}" \
    --project="${PROJECT}" --location=global \
    --display-name="GitHub Actions (${ENV})" \
    --description="Federates GitHub Actions OIDC tokens for ${REPO}"
fi
if ! gcloud iam workload-identity-pools providers describe "${PROVIDER}" \
     --project="${PROJECT}" --location=global \
     --workload-identity-pool="${POOL}" > /dev/null 2>&1; then
  gcloud iam workload-identity-pools providers create-oidc "${PROVIDER}" \
    --project="${PROJECT}" --location=global \
    --workload-identity-pool="${POOL}" \
    --display-name="GitHub OIDC" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository,attribute.ref=assertion.ref" \
    --attribute-condition="assertion.repository == \"${REPO}\" && (assertion.ref == \"${MAIN_REF}\" || assertion.ref.startsWith(\"refs/pull/\"))"
fi
POOL_NAME="projects/${NUMBER}/locations/global/workloadIdentityPools/${POOL}"

echo "== Service accounts"
for sa in sa-terraform sa-terraform-plan; do
  if ! gcloud iam service-accounts describe "${sa}@${PROJECT}.iam.gserviceaccount.com" \
       --project="${PROJECT}" > /dev/null 2>&1; then
    case "${sa}" in
      sa-terraform) name="Terraform pipeline (apply)" ;;
      *) name="Terraform pipeline (plan, read-only)" ;;
    esac
    gcloud iam service-accounts create "${sa}" --project="${PROJECT}" \
      --display-name="${name}"
    created=yes
  fi
done
# A new service account takes a few seconds before it can be granted roles.
[ -z "${created:-}" ] || sleep 15

echo "== Project roles"
# --condition=None: the project already has conditional bindings, and
# without it gcloud stops to ask.
for role in "${APPLY_ROLES[@]}"; do
  gcloud projects add-iam-policy-binding "${PROJECT}" --condition=None \
    --member="serviceAccount:${APPLY_SA}" --role="${role}" > /dev/null
  echo "  sa-terraform       ${role}"
done
for role in "${PLAN_ROLES[@]}"; do
  gcloud projects add-iam-policy-binding "${PROJECT}" --condition=None \
    --member="serviceAccount:${PLAN_SA}" --role="${role}" > /dev/null
  echo "  sa-terraform-plan  ${role}"
done

echo "== State bucket"
# Apply also manages the deployer's access to the bucket (storage.admin);
# plan only reads the state (it runs with -lock=false).
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member="serviceAccount:${APPLY_SA}" --role=roles/storage.admin > /dev/null
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member="serviceAccount:${PLAN_SA}" --role=roles/storage.objectViewer > /dev/null

echo "== Who may sign in as them"
# Apply: runs on main only. Plan: any run of the repository the pool accepts
# (main and pull requests).
gcloud iam service-accounts add-iam-policy-binding "${APPLY_SA}" \
  --project="${PROJECT}" --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/${POOL_NAME}/attribute.ref/${MAIN_REF}" > /dev/null
gcloud iam service-accounts add-iam-policy-binding "${PLAN_SA}" \
  --project="${PROJECT}" --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/${POOL_NAME}/attribute.repository/${REPO}" > /dev/null

echo
echo "Done. Values for .github/terraform-envs.json:"
echo "  \"${ENV}\": { \"project_id\": \"${PROJECT}\", \"project_number\": \"${NUMBER}\" }"
