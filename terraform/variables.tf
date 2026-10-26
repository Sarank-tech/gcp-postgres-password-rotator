###############################################################################
# Core project settings
###############################################################################

variable "project_id" {
  description = "GCP project ID that hosts the rotator."
  type        = string
  default     = "ingka-dp-sap-dev"
}

variable "region" {
  description = "Region for Cloud Run, Cloud Scheduler and the VPC connector."
  type        = string
  default     = "europe-west1"
}

variable "environment" {
  description = "Environment suffix appended to resource names."
  type        = string
  default     = "dev"
}

###############################################################################
# Cloud SQL target & secrets
###############################################################################

variable "sql_instance_name" {
  description = "Name of the existing Cloud SQL for PostgreSQL instance whose users are rotated."
  type        = string
  default     = "staging-database"
}

variable "user_secret_mappings" {
  description = "Map of PostgreSQL user name => existing Secret Manager secret ID holding that user's password."
  type        = map(string)
  default = {
    "postgres"    = "postgres_pwd"
    "int_mdm_012" = "int_mdm_012_pwd"
    "int_mdm_013" = "int_mdm_013_pwd"
    "int_mdm_016" = "int_mdm_016_pwd"
  }
}

###############################################################################
# GitHub / Workload Identity Federation
###############################################################################

variable "github_repository" {
  description = "GitHub repository (\"<org>/<repo>\") allowed to impersonate the CI/CD service account."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must be in the form \"<org>/<repo>\", e.g. \"ingka-group-digital/p2p-postgrespwd-ratator\"."
  }
}

variable "github_allowed_ref" {
  description = "Only GitHub tokens for this git ref may authenticate (trunk-based: main only)."
  type        = string
  default     = "refs/heads/main"
}

variable "wif_pool_id" {
  description = "Workload Identity Pool ID."
  type        = string
  default     = "github-actions-pool-dev"
}

variable "wif_provider_id" {
  description = "Workload Identity Pool Provider ID for GitHub Actions."
  type        = string
  default     = "github-provider-dev"
}

variable "tfstate_bucket" {
  description = "GCS bucket holding Terraform state (CI/CD SA gets object access on it)."
  type        = string
  default     = "p2p-postgrespwd-tfstate-dev"
}

variable "cicd_project_roles" {
  description = "Project-level roles granted to the CI/CD deployer SA (deploy Cloud Run / Functions, push images, manage schedules)."
  type        = list(string)
  default = [
    "roles/run.admin",
    "roles/cloudfunctions.developer",
    "roles/artifactregistry.writer",
    "roles/cloudbuild.builds.editor",
    "roles/cloudscheduler.admin",
    "roles/vpcaccess.user",
    "roles/serviceusage.serviceUsageConsumer",
  ]
}

###############################################################################
# Networking
###############################################################################

variable "vpc_network" {
  description = "VPC network the Cloud SQL private IP lives on."
  type        = string
  default     = "default"
}

variable "vpc_connector_cidr" {
  description = "Unused /28 range in the VPC reserved for the Serverless VPC Access connector."
  type        = string
  default     = "10.8.0.0/28"
}

variable "vpc_connector_machine_type" {
  description = "Machine type for connector instances."
  type        = string
  default     = "e2-micro"
}

###############################################################################
# Cloud Run Job & Scheduler
###############################################################################

variable "job_image" {
  description = <<-EOT
    Container image for the rotator job. Defaults to Google's public sample job
    image so the first apply succeeds before CI has pushed the real image; CI
    then updates the image (Terraform ignores subsequent image changes).
  EOT
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/job:latest"
}

variable "job_timeout" {
  description = "Max run time of a single job task."
  type        = string
  default     = "600s"
}

variable "job_max_retries" {
  description = "Retries per failed task. Keep low: the rotator must be idempotent if > 0."
  type        = number
  default     = 1
}

variable "schedule_cron" {
  description = "Cron for the rotation trigger. Default runs 00:00 on the 1st of Jan/May/Sep (~every 120 days)."
  type        = string
  default     = "0 0 1 */4 *"
}

variable "schedule_time_zone" {
  description = "Time zone for the scheduler cron."
  type        = string
  default     = "Etc/UTC"
}
