locals {
  required_services = toset([
    "artifactregistry.googleapis.com",
    "billingbudgets.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "containeranalysis.googleapis.com",
    "containerscanning.googleapis.com",
    "firestore.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "serviceusage.googleapis.com",
    "speech.googleapis.com",
    "translate.googleapis.com",
  ])

  runtime_project_roles = toset([
    "roles/cloudtranslate.user",
    "roles/datastore.user",
    "roles/serviceusage.serviceUsageConsumer",
    "roles/speech.client",
  ])

  ttl_fields = toset([
    "app_attest_challenges",
    "app_attest_session_challenges",
    "challenge_pool_quotas",
    "online_quotas",
    "online_sessions",
    "session_attempt_quotas",
    "storekit_notification_deduplication",
  ])

  common_labels = merge(var.labels, {
    application = "locallingo"
    environment = var.environment
    managed_by  = "terraform"
  })
}

data "google_project" "current" {
  project_id = var.project_id
}

resource "google_project_service" "required" {
  for_each = local.required_services

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_artifact_registry_repository" "containers" {
  project       = var.project_id
  location      = var.region
  repository_id = var.artifact_repository_id
  description   = "Immutable LocalLingo backend images"
  format        = "DOCKER"
  labels        = local.common_labels

  cleanup_policy_dry_run = false
  deletion_policy        = var.deletion_protection ? "PREVENT" : "DELETE"

  docker_config {
    immutable_tags = true
  }

  vulnerability_scanning_config {
    enablement_config = "INHERITED"
  }

  cleanup_policies {
    id     = "delete-untagged"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "2592000s"
    }
  }

  lifecycle {
    precondition {
      condition     = !contains(["production", "testflight"], var.environment) || var.deletion_protection
      error_message = "Production and TestFlight bootstrap resources require deletion_protection=true."
    }
  }

  depends_on = [google_project_service.required]
}

resource "google_service_account" "cloud_run" {
  project      = var.project_id
  account_id   = trim(substr("${var.service_name}-runtime", 0, 30), "-")
  display_name = "${var.service_name} runtime"
  description  = "Least-privilege identity for the LocalLingo backend"

  depends_on = [google_project_service.required]
}

resource "google_project_iam_member" "runtime_api_access" {
  for_each = local.runtime_project_roles

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.cloud_run.email}"
}

resource "google_firestore_database" "security_state" {
  project                     = var.project_id
  name                        = "(default)"
  location_id                 = var.firestore_location
  type                        = "FIRESTORE_NATIVE"
  concurrency_mode            = "PESSIMISTIC"
  app_engine_integration_mode = "DISABLED"
  delete_protection_state     = var.deletion_protection ? "DELETE_PROTECTION_ENABLED" : "DELETE_PROTECTION_DISABLED"
  deletion_policy             = var.deletion_protection ? "ABANDON" : "DELETE"

  depends_on = [google_project_service.required]
}

resource "google_firestore_field" "ttl" {
  for_each = local.ttl_fields

  project         = var.project_id
  database        = google_firestore_database.security_state.name
  collection      = each.value
  field           = "expiresAt"
  deletion_policy = var.deletion_protection ? "PREVENT" : "DELETE"

  ttl_config {}
}

resource "google_project_iam_audit_config" "secret_manager_data_access" {
  project = var.project_id
  service = "secretmanager.googleapis.com"

  audit_log_config {
    log_type = "DATA_READ"
  }
}

resource "google_secret_manager_secret" "runtime" {
  for_each = var.secret_ids

  project             = var.project_id
  secret_id           = each.value
  deletion_protection = var.deletion_protection
  labels              = local.common_labels

  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret_iam_member" "runtime_access" {
  for_each = var.secret_ids

  project   = var.project_id
  secret_id = google_secret_manager_secret.runtime[each.value].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.cloud_run.email}"
}
