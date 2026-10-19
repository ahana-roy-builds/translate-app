output "api_ip_address" {
  description = "Create an A record for api_domain with this address."
  value       = google_compute_global_address.api.address
}

output "api_url" {
  description = "Public API URL through the protected load balancer."
  value       = "https://${var.api_domain}"
}

output "cloud_run_uri" {
  description = "Diagnostic URI only; ingress policy prevents internet bypass."
  value       = google_cloud_run_v2_service.api.uri
}

output "release_build_id" {
  description = "Build identity returned by the backend availability contract."
  value       = var.release_build_id
}

output "backend_oci_digest" {
  description = "Immutable OCI subject returned by the backend availability contract."
  value       = local.container_digest
}

output "cloud_run_service" {
  description = "Service name bound into deployment receipts."
  value       = google_cloud_run_v2_service.api.name
}

output "runtime_service_account_unique_id" {
  description = "Immutable runtime identity checked against bootstrap."
  value       = data.google_service_account.runtime.unique_id
}

output "security_policy" {
  value = google_compute_security_policy.api.name
}
