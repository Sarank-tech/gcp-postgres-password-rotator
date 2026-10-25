###############################################################################
# Terraform settings & remote backend
#
# State lives in GCS. Backend blocks cannot use variables, so the bucket and
# prefix are hard-coded here.
###############################################################################

terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }

  backend "gcs" {
    bucket = "shriramblue-tfstate-dev"
    prefix = "postgres-password-rotator/dev"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

data "google_project" "this" {}

locals {
  job_name = "postgres-password-rotator-${var.environment}"

  required_apis = [
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "run.googleapis.com",
    "cloudscheduler.googleapis.com",
    "vpcaccess.googleapis.com",
    "compute.googleapis.com",
    "secretmanager.googleapis.com",
    "sqladmin.googleapis.com",
    "artifactregistry.googleapis.com",
  ]
}

###############################################################################
# 0. Required APIs
###############################################################################

resource "google_project_service" "apis" {
  for_each = toset(local.required_apis)

  service            = each.value
  disable_on_destroy = false
}

###############################################################################
# 1. Workload Identity Federation for GitHub Actions
#
# GitHub's OIDC tokens are exchanged for short-lived GCP credentials, so no
# service account keys are ever created. Only workflows from the configured
# repository can authenticate (enforced by attribute_condition AND by the
# principalSet binding below).
###############################################################################

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = var.wif_pool_id
  display_name              = "GitHub Actions (${var.environment})"
  description               = "Federates GitHub Actions OIDC tokens for ${var.github_repository}"

  depends_on = [google_project_service.apis]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = var.wif_provider_id
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # Reject tokens from any other repository, and (trunk-based) from any branch
  # other than main, so a workflow edited on a feature branch can't deploy.
  attribute_condition = "assertion.repository == \"${var.github_repository}\" && assertion.ref == \"${var.github_allowed_ref}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

###############################################################################
# 2. CI/CD deployer service account
#
# Impersonated by GitHub Actions via WIF. Gets the roles needed to build and
# deploy Cloud Run / Cloud Functions, plus read/write on the Terraform state
# bucket.
###############################################################################

resource "google_service_account" "cicd_deployer" {
  account_id   = "sa-cicd-deployer"
  display_name = "CI/CD deployer (GitHub Actions)"
}

resource "google_project_iam_member" "cicd_roles" {
  for_each = toset(var.cicd_project_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.cicd_deployer.email}"
}

# State management: scoped to the state bucket only, not project-wide.
resource "google_storage_bucket_iam_member" "cicd_tfstate" {
  bucket = var.tfstate_bucket
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.cicd_deployer.email}"
}

# Lets CI deploy the job "as" the runtime SA (actAs), scoped to that SA only.
resource "google_service_account_iam_member" "cicd_act_as_rotator" {
  service_account_id = google_service_account.db_rotator.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.cicd_deployer.email}"
}

# Allow identities from the GitHub repository to impersonate the deployer SA.
resource "google_service_account_iam_member" "cicd_wif_binding" {
  service_account_id = google_service_account.cicd_deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}

###############################################################################
# 3. Runtime service account & custom role
#
# The Cloud Run Job runs as sa-db-rotator-dev with a minimal custom role:
# update Cloud SQL user passwords and read/write the password secrets.
###############################################################################

resource "google_service_account" "db_rotator" {
  account_id   = "sa-db-rotator-${var.environment}"
  display_name = "PostgreSQL password rotator runtime (${var.environment})"
}

# Custom roles live under projects/<id>/roles/<role_id>; the "roles/" prefix is
# reserved for predefined roles. Note: a deleted custom role ID cannot be
# reused for ~37 days.
resource "google_project_iam_custom_role" "postgres_rotator" {
  role_id     = "CustomPostgresRotator${title(var.environment)}"
  title       = "Postgres Password Rotator (${var.environment})"
  description = "Minimal permissions to rotate Cloud SQL user passwords and store them in Secret Manager."

  permissions = [
    "cloudsql.users.update",
    "cloudsql.instances.get",
    "secretmanager.versions.add",
    "secretmanager.versions.access",
    "secretmanager.secrets.get",
  ]
}

resource "google_project_iam_member" "db_rotator_custom_role" {
  project = var.project_id
  role    = google_project_iam_custom_role.postgres_rotator.id
  member  = "serviceAccount:${google_service_account.db_rotator.email}"
}

# Fail fast at plan time if any mapped secret does not exist.
data "google_secret_manager_secret" "mapped" {
  for_each  = var.user_secret_mappings
  secret_id = each.value
}

# Fail fast if the target instance does not exist; also exposes its private IP.
data "google_sql_database_instance" "target" {
  name = var.sql_instance_name
}

###############################################################################
# 4. Serverless VPC Access connector
#
# Gives the Cloud Run Job a path into the VPC so it can reach Cloud SQL on its
# private IP. The CIDR must be an unused /28 in the network.
###############################################################################

resource "google_vpc_access_connector" "rotator" {
  name          = "pg-rotator-conn-${var.environment}" # max 25 chars
  region        = var.region
  network       = var.vpc_network
  ip_cidr_range = var.vpc_connector_cidr
  machine_type  = var.vpc_connector_machine_type
  min_instances = 2
  max_instances = 3

  depends_on = [google_project_service.apis]
}

###############################################################################
# 4b. Artifact Registry
#
# Holds the rotator image. CI pushes a tag per commit SHA plus "latest"; the
# cleanup policy keeps the 10 newest versions and deletes anything older than
# 30 days beyond that.
###############################################################################

resource "google_artifact_registry_repository" "rotator" {
  repository_id = "rotator-repo"
  location      = var.region
  format        = "DOCKER"
  description   = "Images for ${local.job_name}"

  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }

  cleanup_policies {
    id     = "delete-old"
    action = "DELETE"
    condition {
      older_than = "2592000s" # 30 days
    }
  }

  depends_on = [google_project_service.apis]
}

###############################################################################
# 5a. Cloud Run Job
#
# Runs to completion and exits. Mappings are passed as JSON so the app can
# iterate users without code changes when users are added.
###############################################################################

resource "google_cloud_run_v2_job" "rotator" {
  name     = local.job_name
  location = var.region

  template {
    task_count  = 1
    parallelism = 1

    template {
      service_account = google_service_account.db_rotator.email
      timeout         = var.job_timeout
      max_retries     = var.job_max_retries

      vpc_access {
        connector = google_vpc_access_connector.rotator.id
        egress    = "PRIVATE_RANGES_ONLY"
      }

      containers {
        image = var.job_image

        env {
          name  = "PROJECT_ID"
          value = var.project_id
        }
        env {
          name  = "REGION"
          value = var.region
        }
        env {
          name  = "INSTANCE_NAME"
          value = var.sql_instance_name
        }
        env {
          name  = "INSTANCE_CONNECTION_NAME"
          value = data.google_sql_database_instance.target.connection_name
        }
        env {
          name  = "DB_PRIVATE_IP"
          value = data.google_sql_database_instance.target.private_ip_address
        }
        env {
          name  = "SECRET_MAPPINGS"
          value = jsonencode(var.user_secret_mappings)
        }

        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }
      }
    }
  }

  lifecycle {
    # The job connects over the VPC connector, so the instance must have a
    # private IP; fail the plan instead of deploying with DB_PRIVATE_IP="".
    precondition {
      condition     = data.google_sql_database_instance.target.private_ip_address != ""
      error_message = "Cloud SQL instance ${var.sql_instance_name} has no private IP. Enable private IP on network ${var.vpc_network} first."
    }

    # CI/CD owns the image after the first apply; don't roll it back.
    ignore_changes = [
      template[0].template[0].containers[0].image,
      client,
      client_version,
    ]
  }

  depends_on = [
    google_project_service.apis,
    google_project_iam_member.db_rotator_custom_role,
  ]
}

###############################################################################
# 5b. Cloud Scheduler trigger
#
# Calls the Cloud Run Admin API ":run" endpoint. Google APIs (*.googleapis.com)
# only accept OAuth access tokens, so oauth_token is used here (OIDC tokens are
# for calling your own Cloud Run services/functions and would be rejected).
# A dedicated SA with run.invoker on just this job is used as the caller.
###############################################################################

resource "google_service_account" "scheduler" {
  account_id   = "sa-rotator-scheduler-${var.environment}"
  display_name = "Scheduler trigger for ${local.job_name}"
}

resource "google_cloud_run_v2_job_iam_member" "scheduler_invoker" {
  name     = google_cloud_run_v2_job.rotator.name
  location = google_cloud_run_v2_job.rotator.location
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.scheduler.email}"
}

resource "google_cloud_scheduler_job" "rotator_trigger" {
  name        = "${local.job_name}-trigger"
  region      = var.region
  description = "Triggers ${local.job_name} (~every 120 days)"
  schedule    = var.schedule_cron
  time_zone   = var.schedule_time_zone

  retry_config {
    retry_count = 1
  }

  http_target {
    http_method = "POST"
    uri         = "https://run.googleapis.com/v2/projects/${var.project_id}/locations/${var.region}/jobs/${google_cloud_run_v2_job.rotator.name}:run"

    oauth_token {
      service_account_email = google_service_account.scheduler.email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [google_cloud_run_v2_job_iam_member.scheduler_invoker]
}
