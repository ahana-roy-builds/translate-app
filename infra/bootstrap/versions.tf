terraform {
  required_version = "= 1.15.7"

  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "= 7.34.0"
    }
  }
}
