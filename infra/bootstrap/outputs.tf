output "artifact_repository" {
  description = "Artifact Registry repository prefix."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.containers.repository_id}"
}

output "runtime_service_account_email" {
  description = "Pass this value to the service stack."
  value       = google_service_account.cloud_run.email
}

output "runtime_service_account_unique_id" {
  description = "Bind this immutable identity into the service stack and deployment policy."
  value       = google_service_account.cloud_run.unique_id
}

output "project_number" {
  description = "Bind this immutable project identity into the environment policy."
  value       = data.google_project.current.number
}

output "region" {
  value = var.region
}

output "firestore_location" {
  value = var.firestore_location
}

output "firestore_database" {
  description = "Pass this value to the service stack."
  value       = google_firestore_database.security_state.name
}

output "secret_resource_names" {
  description = "Secret containers awaiting independently managed versions."
  value       = { for id, secret in google_secret_manager_secret.runtime : id => secret.name }
}
