variable "project_id" {
  description = "Google Cloud project ID for one isolated environment."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid Google Cloud project ID."
  }
}

variable "region" {
  description = "US region used by Artifact Registry and the backend."
  type        = string
  default     = "us-central1"

  validation {
    condition     = var.region == "us-central1"
    error_message = "The reviewed bootstrap contract requires us-central1."
  }
}

variable "firestore_location" {
  description = "Regional Firestore location for security state."
  type        = string
  default     = "us-central1"

  validation {
    condition     = var.firestore_location == "us-central1"
    error_message = "The reviewed Firestore contract requires us-central1."
  }
}

variable "environment" {
  description = "Isolated deployment environment."
  type        = string
  default     = "development"

  validation {
    condition     = contains(["development", "staging", "testflight", "production"], var.environment)
    error_message = "environment must be development, staging, testflight, or production."
  }
}

variable "service_name" {
  description = "Cloud Run service name used to derive the runtime identity."
  type        = string
  default     = "locallingo-api"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,61}[a-z0-9]$", var.service_name))
    error_message = "service_name must be a valid Cloud Run service name."
  }
}

variable "artifact_repository_id" {
  description = "Artifact Registry Docker repository ID."
  type        = string
  default     = "locallingo"
}

variable "secret_ids" {
  description = "Exact reviewed runtime secret metadata. Secret values and versions are populated out of band."
  type        = set(string)
  default = [
    "apple-app-attest-root-ca-pem",
    "apple-iap-signing-key-p8",
    "apple-storekit-root-ca-pems",
  ]

  validation {
    condition = var.secret_ids == toset([
      "apple-app-attest-root-ca-pem",
      "apple-iap-signing-key-p8",
      "apple-storekit-root-ca-pems",
    ])
    error_message = "secret_ids must equal the exact three reviewed LocalLingo runtime secret IDs."
  }
}

variable "deletion_protection" {
  description = "Protect Firestore, secrets, and Artifact Registry from accidental deletion."
  type        = bool
  default     = false
}

variable "labels" {
  description = "Additional resource labels."
  type        = map(string)
  default     = {}
}
