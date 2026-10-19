variable "project_id" {
  description = "Google Cloud project ID initialized by the bootstrap stack."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid Google Cloud project ID."
  }
}

variable "region" {
  description = "US Cloud Run region."
  type        = string
  default     = "us-central1"

  validation {
    condition     = var.region == "us-central1"
    error_message = "The reviewed service contract requires us-central1."
  }
}

variable "environment" {
  description = "Deployment environment."
  type        = string
  default     = "staging"

  validation {
    condition     = contains(["staging", "testflight", "production"], var.environment)
    error_message = "The remotely reachable service supports only fail-closed staging, TestFlight, or production; local development fakes are never deployed."
  }
}

variable "service_name" {
  description = "Cloud Run service name."
  type        = string
  default     = "locallingo-api"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,61}[a-z0-9]$", var.service_name))
    error_message = "service_name must be a valid Cloud Run service name."
  }
}

variable "runtime_service_account_email" {
  description = "Runtime identity created by the bootstrap stack."
  type        = string

  validation {
    condition = (
      can(regex("^[^@]+@[^@]+\\.iam\\.gserviceaccount\\.com$", var.runtime_service_account_email)) &&
      endswith(var.runtime_service_account_email, "@${var.project_id}.iam.gserviceaccount.com")
    )
    error_message = "runtime_service_account_email must be a service account owned by project_id."
  }
}

variable "runtime_service_account_unique_id" {
  description = "Immutable unique ID emitted by the bootstrap stack for the runtime identity."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{10,30}$", var.runtime_service_account_unique_id))
    error_message = "runtime_service_account_unique_id must be the numeric bootstrap output."
  }
}

variable "artifact_repository_id" {
  description = "Exact Artifact Registry repository created by bootstrap."
  type        = string
  default     = "locallingo"

  validation {
    condition     = var.artifact_repository_id == "locallingo"
    error_message = "The reviewed release repository ID is exactly locallingo."
  }
}

variable "container_image" {
  description = "Immutable backend image. Production requires a sha256 digest."
  type        = string

  validation {
    condition = (
      startswith(var.container_image, "${var.region}-docker.pkg.dev/${var.project_id}/${var.artifact_repository_id}/") &&
      can(regex("/[a-z][a-z0-9._/-]*@sha256:[a-f0-9]{64}$", var.container_image))
    )
    error_message = "container_image must be a digest-pinned image in the reviewed project/region/locallingo repository."
  }
}

variable "release_build_id" {
  description = "Immutable release-candidate build ID returned by /v2/availability."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{15,127}$", var.release_build_id))
    error_message = "release_build_id must be 16-128 URL-safe identifier characters."
  }
}

variable "api_domain" {
  description = "Public DNS name whose A record points to the load-balancer address."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])$", var.api_domain))
    error_message = "api_domain must be a DNS host name without a URL scheme or path."
  }
}

variable "firestore_database" {
  description = "Firestore database name created by bootstrap."
  type        = string
  default     = "(default)"
}

variable "non_sensitive_env" {
  description = "Explicit non-secret backend environment."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for name in keys(var.non_sensitive_env) : can(regex("^[A-Z_][A-Z0-9_]*$", name))])
    error_message = "Environment names must use uppercase letters, digits, and underscores."
  }
}

variable "secret_env" {
  description = "Environment name to existing Secret Manager ID and immutable numeric version."
  type = map(object({
    secret_id = string
    version   = string
  }))
  default = {}

  validation {
    condition = alltrue([
      for name, binding in var.secret_env :
      can(regex("^[A-Z_][A-Z0-9_]*$", name)) && can(regex("^[1-9][0-9]*$", binding.version))
    ])
    error_message = "Secret names must be valid environment names and versions must be immutable positive integers, never latest."
  }
}

variable "min_instances" {
  description = "Minimum warm instances; production requires at least one."
  type        = number
  default     = 0

  validation {
    condition     = var.min_instances >= 0
    error_message = "min_instances cannot be negative."
  }
}

variable "max_instances" {
  description = "Hard cost and abuse guardrail."
  type        = number
  default     = 3

  validation {
    condition     = var.max_instances >= 1 && var.max_instances <= 3
    error_message = "max_instances must be from one through three."
  }
}

variable "ip_registration_requests_per_minute" {
  description = "Cloud Armor per-IP registration/challenge threshold before a temporary ban."
  type        = number
  default     = 60

  validation {
    condition     = var.ip_registration_requests_per_minute >= 1 && var.ip_registration_requests_per_minute <= 10000
    error_message = "ip_registration_requests_per_minute must be from one through 10000."
  }
}

variable "ip_shared_nat_requests_per_minute" {
  description = "High shared-NAT throttle for all allowlisted routes; attested subject quotas remain authoritative."
  type        = number
  default     = 600

  validation {
    condition     = var.ip_shared_nat_requests_per_minute >= 60 && var.ip_shared_nat_requests_per_minute <= 10000
    error_message = "ip_shared_nat_requests_per_minute must be from 60 through 10000."
  }
}

variable "notification_channels" {
  description = "Existing Monitoring notification-channel resource names."
  type        = list(string)
  default     = []

  validation {
    condition = length(var.notification_channels) <= 5 && alltrue([
      for channel in var.notification_channels :
      can(regex("^projects/[^/]+/notificationChannels/[^/]+$", channel))
    ])
    error_message = "Provide at most five full Monitoring notification-channel resource names."
  }
}

variable "billing_account_id" {
  description = "Billing account ID used for a project budget; omit only outside production."
  type        = string
  default     = ""
}

variable "monthly_budget_usd" {
  description = "Monthly project budget in USD."
  type        = number
  default     = 100

  validation {
    condition     = var.monthly_budget_usd > 0
    error_message = "monthly_budget_usd must be positive."
  }
}

variable "deletion_protection" {
  description = "Protect the Cloud Run service from accidental deletion."
  type        = bool
  default     = false
}

variable "labels" {
  description = "Additional resource labels."
  type        = map(string)
  default     = {}
}
