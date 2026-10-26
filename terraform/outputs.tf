output "wif_provider_name" {
  description = "Full WIF provider resource name; use as `workload_identity_provider` in google-github-actions/auth."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "wif_pool_name" {
  description = "Full Workload Identity Pool resource name."
  value       = google_iam_workload_identity_pool.github.name
}

output "cicd_service_account_email" {
  description = "CI/CD deployer SA; use as `service_account` in google-github-actions/auth."
  value       = google_service_account.cicd_deployer.email
}

output "rotator_service_account_email" {
  description = "Runtime SA used by the Cloud Run Job."
  value       = google_service_account.db_rotator.email
}

output "scheduler_service_account_email" {
  description = "SA Cloud Scheduler uses to trigger the job."
  value       = google_service_account.scheduler.email
}

output "cloud_run_job_name" {
  description = "Cloud Run Job name."
  value       = google_cloud_run_v2_job.rotator.name
}

output "artifact_registry_repository_url" {
  description = "Docker repository URL to push rotator images to."
  value       = "${google_artifact_registry_repository.rotator.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.rotator.repository_id}"
}

output "vpc_connector_id" {
  description = "Serverless VPC Access connector ID."
  value       = google_vpc_access_connector.rotator.id
}
