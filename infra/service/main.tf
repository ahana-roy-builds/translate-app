locals {
  fixed_limits = {
    CHALLENGE_POOL_SIZE                       = "8"
    CHALLENGE_POOL_REQUESTS_PER_MINUTE        = "4"
    CHALLENGE_TTL_MS                          = "120000"
    ENTITLEMENT_RATE_PER_DAY                  = "500"
    ENTITLEMENT_RATE_PER_MINUTE               = "60"
    INACTIVE_DEVICE_AFTER_MS                  = "2592000000"
    INSTALLATION_RATE_PER_MINUTE              = "30"
    MAXIMUM_SUBSCRIPTION_DEVICES              = "3"
    MAX_AUDIO_BYTES                           = "960044"
    MAX_TEXT_BYTES                            = "8192"
    REQUEST_DEADLINE_MS                       = "18000"
    SESSION_ATTEMPTS_PER_MINUTE               = "6"
    SESSION_TTL_MS                            = "900000"
    SPEECH_TIMEOUT_MS                         = "10000"
    STOREKIT_NOTIFICATION_CONCURRENCY         = "1"
    STOREKIT_NOTIFICATION_MAXIMUM_OUTSTANDING = "2"
    STOREKIT_SESSION_CONCURRENCY              = "2"
    STOREKIT_SESSION_MAXIMUM_OUTSTANDING      = "6"
    TRANSLATION_TIMEOUT_MS                    = "5000"
  }

  required_env = setunion(toset([
    "ALLOWED_APP_BUNDLE_VERSIONS",
    "ALLOWED_PRODUCT_IDS",
    "APPLE_APP_ID_PREFIX",
    "APPLE_APP_STORE_ID",
    "APPLE_BUNDLE_ID",
    "APPLE_IAP_ISSUER_ID",
    "APPLE_IAP_KEY_ID",
    "APPLE_STOREKIT_ENVIRONMENT",
    "APP_ATTEST_ENVIRONMENT",
    "APPLE_TEAM_ID",
    "FIRESTORE_DATABASE",
    "FIRESTORE_PROJECT",
    "GOOGLE_CLOUD_PROJECT",
    "GOOGLE_STT_LOCATION",
    "GOOGLE_TRANSLATION_LOCATION",
    "ONLINE_ENABLED",
    "RUNTIME_MODE",
  ]), toset(keys(local.fixed_limits)))

  required_secret_env = toset([
    "APPLE_APP_ATTEST_ROOT_CA_PEM",
    "APPLE_IAP_SIGNING_KEY_P8",
    "APPLE_STOREKIT_ROOT_CA_PEMS",
  ])

  required_secret_bindings = {
    APPLE_APP_ATTEST_ROOT_CA_PEM = "apple-app-attest-root-ca-pem"
    APPLE_IAP_SIGNING_KEY_P8     = "apple-iap-signing-key-p8"
    APPLE_STOREKIT_ROOT_CA_PEMS  = "apple-storekit-root-ca-pems"
  }

  common_labels = merge(var.labels, {
    application = "locallingo"
    environment = var.environment
    managed_by  = "terraform"
  })

  container_digest = try(split("@", var.container_image)[1], "")
}

data "google_project" "current" {
  project_id = var.project_id
}

data "google_service_account" "runtime" {
  project    = var.project_id
  account_id = var.runtime_service_account_email
}

data "google_secret_manager_secret" "runtime" {
  for_each = var.secret_env

  project   = var.project_id
  secret_id = each.value.secret_id
}

resource "google_cloud_run_v2_service" "api" {
  project             = var.project_id
  location            = var.region
  name                = var.service_name
  description         = "App-Attested Online Quality speech translation API"
  ingress             = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  deletion_protection = var.deletion_protection
  labels              = local.common_labels

  template {
    service_account                  = var.runtime_service_account_email
    timeout                          = "20s"
    max_instance_request_concurrency = 8

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    containers {
      image = var.container_image

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "1Gi"
        }
        cpu_idle = true
      }

      startup_probe {
        initial_delay_seconds = 1
        timeout_seconds       = 2
        period_seconds        = 2
        failure_threshold     = 10
        http_get {
          path = "/livez"
          port = 8080
        }
      }

      liveness_probe {
        timeout_seconds   = 2
        period_seconds    = 10
        failure_threshold = 3
        http_get {
          path = "/livez"
          port = 8080
        }
      }

      dynamic "env" {
        for_each = var.non_sensitive_env
        content {
          name  = env.key
          value = env.value
        }
      }

      # These values are derived from reviewed deployment inputs instead of
      # accepting caller-supplied duplicates. K_REVISION is reserved and is
      # injected by Cloud Run at runtime.
      env {
        name  = "RELEASE_BUILD_ID"
        value = var.release_build_id
      }

      env {
        name  = "BACKEND_OCI_DIGEST"
        value = local.container_digest
      }

      dynamic "env" {
        for_each = var.secret_env
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = data.google_secret_manager_secret.runtime[env.key].secret_id
              version = env.value.version
            }
          }
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition     = var.max_instances >= var.min_instances && var.max_instances <= 3
      error_message = "max_instances must be at least min_instances and no greater than the initial hard cap of three."
    }
    precondition {
      condition     = var.environment != "production" || var.min_instances >= 1
      error_message = "Production requires at least one warm instance."
    }
    precondition {
      condition     = var.environment == "staging" || var.deletion_protection
      error_message = "Production and TestFlight require deletion protection."
    }
    precondition {
      condition     = can(regex("@sha256:[a-f0-9]{64}$", var.container_image))
      error_message = "Every remotely reachable container_image must use an immutable sha256 digest."
    }
    precondition {
      condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{15,127}$", var.release_build_id))
      error_message = "release_build_id must be the immutable candidate build identifier."
    }
    precondition {
      condition     = length(setintersection(toset(keys(var.non_sensitive_env)), toset(keys(var.secret_env)))) == 0
      error_message = "An environment variable cannot be both secret and non-secret."
    }
    precondition {
      condition     = toset(keys(var.secret_env)) == local.required_secret_env
      error_message = "Only the reviewed Apple trust roots and App Store Server API signing key may be exposed to the runtime."
    }
    precondition {
      condition = alltrue([
        for name, secret_id in local.required_secret_bindings :
        try(var.secret_env[name].secret_id, "") == secret_id
      ])
      error_message = "Runtime secret environment must use the reviewed Apple trust-root and App Store key containers."
    }
    precondition {
      condition     = data.google_service_account.runtime.unique_id == var.runtime_service_account_unique_id
      error_message = "Runtime service-account unique ID differs from the bootstrapped identity."
    }
    precondition {
      condition     = alltrue([for name in local.required_env : contains(keys(var.non_sensitive_env), name)])
      error_message = "All documented fail-closed environment variables must be explicit."
    }
    precondition {
      condition     = length(setsubtract(toset(keys(var.non_sensitive_env)), local.required_env)) == 0
      error_message = "Unknown non-sensitive environment variables are rejected until reviewed and declared."
    }
    precondition {
      condition = alltrue([
        for name, expected in local.fixed_limits :
        lookup(var.non_sensitive_env, name, "") == expected
      ])
      error_message = "Request, timeout, quota, session, and device limits must match the reviewed initial production policy."
    }
    precondition {
      condition     = lookup(var.non_sensitive_env, "GOOGLE_CLOUD_PROJECT", "") == var.project_id
      error_message = "GOOGLE_CLOUD_PROJECT must equal project_id."
    }
    precondition {
      condition     = lookup(var.non_sensitive_env, "FIRESTORE_DATABASE", "") == var.firestore_database
      error_message = "FIRESTORE_DATABASE must equal the bootstrapped database."
    }
    precondition {
      condition = (
        lookup(var.non_sensitive_env, "GOOGLE_STT_LOCATION", "") == "us" &&
        lookup(var.non_sensitive_env, "GOOGLE_TRANSLATION_LOCATION", "") == "us-central1"
      )
      error_message = "Speech and Translation locations must be exactly us and us-central1."
    }
    precondition {
      condition     = lookup(var.non_sensitive_env, "FIRESTORE_PROJECT", "") == var.project_id
      error_message = "FIRESTORE_PROJECT must equal project_id."
    }
    precondition {
      condition     = lookup(var.non_sensitive_env, "RUNTIME_MODE", "") == var.environment
      error_message = "RUNTIME_MODE must match the fail-closed staging or production Terraform environment."
    }
    precondition {
      condition = lookup(var.non_sensitive_env, "APP_ATTEST_ENVIRONMENT", "") == (
        var.environment == "staging" ? "development" : "production"
      )
      error_message = "Production and TestFlight use production App Attest; staging uses real verification with the development AAGUID."
    }
    precondition {
      condition = (
        can(regex("^[A-Z0-9]{10}$", lookup(var.non_sensitive_env, "APPLE_TEAM_ID", ""))) &&
        can(regex("^[A-Z0-9]{10}$", lookup(var.non_sensitive_env, "APPLE_APP_ID_PREFIX", ""))) &&
        can(regex("^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+$", lookup(var.non_sensitive_env, "APPLE_BUNDLE_ID", "")))
      )
      error_message = "Deployment requires concrete Apple Team, App ID prefix, and bundle identifiers."
    }
    precondition {
      condition = (
        lookup(var.non_sensitive_env, "APPLE_STOREKIT_ENVIRONMENT", "") == (var.environment == "production" ? "Production" : "Sandbox") &&
        can(regex("^[1-9][0-9]*$", lookup(var.non_sensitive_env, "APPLE_APP_STORE_ID", "")))
      )
      error_message = "The StoreKit environment must match deployment and Apple App Store ID must be numeric."
    }
    precondition {
      condition = (
        can(regex("^[A-Z0-9]{10}$", lookup(var.non_sensitive_env, "APPLE_IAP_KEY_ID", ""))) &&
        can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", lookup(var.non_sensitive_env, "APPLE_IAP_ISSUER_ID", ""))) &&
        can(regex("^[1-9][0-9]*(,[1-9][0-9]*)*$", lookup(var.non_sensitive_env, "ALLOWED_APP_BUNDLE_VERSIONS", "")))
      )
      error_message = "App Store API key/issuer IDs and the comma-separated app build allowlist must use reviewed formats."
    }
    precondition {
      condition     = var.environment == "staging" || (length(var.notification_channels) > 0 && var.billing_account_id != "")
      error_message = "Production and TestFlight require alert routing and a billing-account budget."
    }
    precondition {
      condition = alltrue([
        for value in concat(
          [var.api_domain],
          values(var.non_sensitive_env),
          [for binding in values(var.secret_env) : binding.secret_id],
        ) :
        !strcontains(lower(value), "example") && !strcontains(lower(value), "replace") && !strcontains(lower(value), ".invalid")
      ])
      error_message = "Deployable configuration contains placeholder values."
    }
  }
}

resource "google_cloud_run_v2_service_iam_member" "public_edge" {
  project  = var.project_id
  location = google_cloud_run_v2_service.api.location
  name     = google_cloud_run_v2_service.api.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_compute_region_network_endpoint_group" "api" {
  project               = var.project_id
  name                  = "${var.service_name}-neg"
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = google_cloud_run_v2_service.api.name
  }
}

resource "google_compute_security_policy" "api" {
  project     = var.project_id
  name        = "${var.service_name}-edge"
  description = "Deny malformed traffic and apply route-aware shared-NAT abuse controls before Cloud Run"
  type        = "CLOUD_ARMOR"

  rule {
    action      = "deny(400)"
    priority    = 100
    description = "Reject query strings before application routing; API inputs belong in bounded bodies and headers"
    match {
      expr {
        expression = "request.query != ''"
      }
    }
  }

  rule {
    action      = "deny(404)"
    priority    = 200
    description = "Reject unknown paths at the edge"
    match {
      expr {
        expression = "!(request.path == '/livez' || request.path == '/readyz' || request.path == '/v2/availability' || request.path == '/v2/app-attest/challenge' || request.path == '/v2/app-attest/register' || request.path == '/v2/session' || request.path == '/v2/session/challenges' || request.path == '/v2/translate-turn' || request.path == '/v2/translate-text' || request.path == '/v2/devices/current' || request.path == '/v2/devices/replace-oldest' || request.path == '/v2/storekit/notifications')"
      }
    }
  }

  rule {
    action   = "rate_based_ban"
    priority = 1000
    match {
      expr {
        expression = "request.path == '/v2/app-attest/challenge' || request.path == '/v2/app-attest/register'"
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
      rate_limit_threshold {
        count        = var.ip_registration_requests_per_minute
        interval_sec = 60
      }
      ban_duration_sec = 600
      ban_threshold {
        count        = var.ip_registration_requests_per_minute * 2
        interval_sec = 60
      }
    }
  }

  rule {
    action      = "throttle"
    priority    = 2000
    description = "Shared-NAT safety valve; device and entitlement quotas enforce authenticated use"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
      rate_limit_threshold {
        count        = var.ip_shared_nat_requests_per_minute
        interval_sec = 60
      }
    }
  }

  rule {
    action      = "allow"
    priority    = 2147483647
    description = "Default allow after edge validation; application attestation and distributed quotas remain mandatory"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
  }
}

resource "google_compute_backend_service" "api" {
  project               = var.project_id
  name                  = "${var.service_name}-backend"
  protocol              = "HTTP"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  security_policy       = google_compute_security_policy.api.id
  timeout_sec           = 20

  backend {
    group = google_compute_region_network_endpoint_group.api.id
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

resource "google_compute_url_map" "api" {
  project         = var.project_id
  name            = "${var.service_name}-https"
  default_service = google_compute_backend_service.api.id
}

resource "google_compute_managed_ssl_certificate" "api" {
  project = var.project_id
  name    = "${var.service_name}-certificate"

  managed {
    domains = [var.api_domain]
  }
}

resource "google_compute_ssl_policy" "api" {
  project         = var.project_id
  name            = "${var.service_name}-modern-tls"
  profile         = "MODERN"
  min_tls_version = "TLS_1_2"
}

resource "google_compute_target_https_proxy" "api" {
  project          = var.project_id
  name             = "${var.service_name}-https"
  url_map          = google_compute_url_map.api.id
  ssl_certificates = [google_compute_managed_ssl_certificate.api.id]
  ssl_policy       = google_compute_ssl_policy.api.id
}

resource "google_compute_global_address" "api" {
  project = var.project_id
  name    = "${var.service_name}-address"
}

resource "google_compute_global_forwarding_rule" "https" {
  project               = var.project_id
  name                  = "${var.service_name}-https"
  ip_address            = google_compute_global_address.api.address
  port_range            = "443"
  target                = google_compute_target_https_proxy.api.id
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

resource "google_compute_url_map" "redirect" {
  project = var.project_id
  name    = "${var.service_name}-http-redirect"

  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = true
  }
}

resource "google_compute_target_http_proxy" "redirect" {
  project = var.project_id
  name    = "${var.service_name}-http-redirect"
  url_map = google_compute_url_map.redirect.id
}

resource "google_compute_global_forwarding_rule" "http" {
  project               = var.project_id
  name                  = "${var.service_name}-http"
  ip_address            = google_compute_global_address.api.address
  port_range            = "80"
  target                = google_compute_target_http_proxy.redirect.id
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

resource "google_logging_project_bucket_config" "default" {
  project        = var.project_id
  location       = "global"
  bucket_id      = "_Default"
  retention_days = 30
}

resource "google_logging_metric" "edge_query_rejections" {
  project     = var.project_id
  name        = "${var.service_name}-edge-query-rejections"
  description = "Cloud Armor requests rejected by the no-query rule; URL contents are excluded from storage below"
  filter      = "resource.type=\"http_load_balancer\" AND jsonPayload.enforcedSecurityPolicy.priority=100"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_project_exclusion" "query_strings" {
  project     = var.project_id
  name        = "${var.service_name}-drop-query-bearing-request-logs"
  description = "Prevent attacker- or client-supplied query text from entering the default log bucket"
  filter      = "httpRequest.requestUrl =~ \"[?].+\""
}

resource "google_logging_metric" "security_rejections" {
  project     = var.project_id
  name        = "${var.service_name}-security-rejections"
  description = "Content-free backend request completions rejected by attestation, session, entitlement, replay, or quota policy"
  filter      = "resource.type=\"cloud_run_revision\" AND jsonPayload.event=\"request_completed\" AND jsonPayload.errorCode=~\"^(.*APP_ATTEST.*|INVALID_ASSERTION_COUNTER|.*CHALLENGE.*|INVALID_SESSION|SUBSCRIPTION_REQUIRED|.*QUOTA.*)$\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "unexpected_secret_access" {
  project     = var.project_id
  name        = "${var.service_name}-unexpected-secret-access"
  description = "Secret Manager data access by identities other than the Cloud Run runtime"
  filter      = "protoPayload.serviceName=\"secretmanager.googleapis.com\" AND protoPayload.methodName:\"AccessSecretVersion\" AND protoPayload.authenticationInfo.principalEmail!=\"${var.runtime_service_account_email}\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "iam_changes" {
  project     = var.project_id
  name        = "${var.service_name}-iam-changes"
  description = "Project IAM policy changes"
  filter      = "protoPayload.methodName=(\"SetIamPolicy\" OR \"google.iam.admin.v1.CreateServiceAccount\" OR \"google.iam.admin.v1.DeleteServiceAccount\")"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

locals {
  security_log_metrics = {
    edge_query_rejections = {
      metric        = google_logging_metric.edge_query_rejections.name
      resource_type = "http_load_balancer"
      threshold     = 10
    }
    security_rejections = {
      metric        = google_logging_metric.security_rejections.name
      resource_type = "cloud_run_revision"
      threshold     = 10
    }
    unexpected_secret_access = {
      metric        = google_logging_metric.unexpected_secret_access.name
      resource_type = "audited_resource"
      threshold     = 0
    }
    iam_changes = {
      metric        = google_logging_metric.iam_changes.name
      resource_type = "audited_resource"
      threshold     = 0
    }
  }
}

resource "google_monitoring_alert_policy" "security_events" {
  for_each = local.security_log_metrics

  project      = var.project_id
  display_name = "${var.service_name}: ${replace(each.key, "_", " ")}"
  combiner     = "OR"

  conditions {
    display_name = "${replace(each.key, "_", " ")} exceeded reviewed threshold"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${each.value.metric}\" AND resource.type=\"${each.value.resource_type}\""
      comparison      = "COMPARISON_GT"
      threshold_value = each.value.threshold
      duration        = "0s"
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  notification_channels = var.notification_channels
}

resource "google_monitoring_uptime_check_config" "ready" {
  project      = var.project_id
  display_name = "${var.service_name} readiness"
  timeout      = "10s"
  period       = "60s"

  http_check {
    path         = "/readyz"
    port         = 443
    use_ssl      = true
    validate_ssl = true
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      host       = var.api_domain
      project_id = var.project_id
    }
  }
}

resource "google_monitoring_alert_policy" "uptime" {
  project      = var.project_id
  display_name = "${var.service_name}: readiness unavailable"
  combiner     = "OR"

  conditions {
    display_name = "Readiness probe failed"
    condition_threshold {
      filter          = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND resource.type=\"uptime_url\" AND metric.label.check_id=\"${google_monitoring_uptime_check_config.ready.uptime_check_id}\""
      comparison      = "COMPARISON_LT"
      threshold_value = 1
      duration        = "120s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_NEXT_OLDER"
      }
    }
  }

  notification_channels = var.notification_channels
}

resource "google_monitoring_alert_policy" "server_errors" {
  project      = var.project_id
  display_name = "${var.service_name}: elevated server errors"
  combiner     = "OR"

  conditions {
    display_name = "5xx response rate"
    condition_threshold {
      filter          = "resource.type=\"cloud_run_revision\" AND resource.label.service_name=\"${var.service_name}\" AND metric.type=\"run.googleapis.com/request_count\" AND metric.label.response_code_class=\"5xx\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.1
      duration        = "300s"
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_RATE"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  notification_channels = var.notification_channels
}

resource "google_monitoring_alert_policy" "latency" {
  project      = var.project_id
  display_name = "${var.service_name}: high request latency"
  combiner     = "OR"

  conditions {
    display_name = "p95 latency exceeds 18 seconds"
    condition_threshold {
      filter          = "resource.type=\"cloud_run_revision\" AND resource.label.service_name=\"${var.service_name}\" AND metric.type=\"run.googleapis.com/request_latencies\""
      comparison      = "COMPARISON_GT"
      threshold_value = 18000
      duration        = "300s"
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_PERCENTILE_95"
        cross_series_reducer = "REDUCE_MAX"
      }
    }
  }

  notification_channels = var.notification_channels
}

resource "google_monitoring_alert_policy" "memory" {
  project      = var.project_id
  display_name = "${var.service_name}: high memory utilization"
  combiner     = "OR"

  conditions {
    display_name = "p95 memory utilization exceeds 85 percent"
    condition_threshold {
      filter          = "resource.type=\"cloud_run_revision\" AND resource.label.service_name=\"${var.service_name}\" AND metric.type=\"run.googleapis.com/container/memory/utilizations\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.85
      duration        = "300s"
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_PERCENTILE_95"
        cross_series_reducer = "REDUCE_MAX"
      }
    }
  }

  notification_channels = var.notification_channels
}

resource "google_monitoring_alert_policy" "instance_saturation" {
  project      = var.project_id
  display_name = "${var.service_name}: instance cap saturation"
  combiner     = "OR"

  conditions {
    display_name = "Active instances reached configured cap"
    condition_threshold {
      filter          = "resource.type=\"cloud_run_revision\" AND resource.label.service_name=\"${var.service_name}\" AND metric.type=\"run.googleapis.com/container/instance_count\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.max_instances - 0.5
      duration        = "300s"
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_MAX"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  notification_channels = var.notification_channels
}

resource "google_billing_budget" "project" {
  count = var.billing_account_id == "" ? 0 : 1

  billing_account = var.billing_account_id
  display_name    = "${var.project_id} monthly guardrail"

  budget_filter {
    projects = ["projects/${data.google_project.current.number}"]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(floor(var.monthly_budget_usd))
      nanos         = floor((var.monthly_budget_usd - floor(var.monthly_budget_usd)) * 1000000000)
    }
  }

  threshold_rules {
    threshold_percent = 0.5
  }
  threshold_rules {
    threshold_percent = 0.9
  }
  threshold_rules {
    threshold_percent = 1.0
  }

  all_updates_rule {
    monitoring_notification_channels = var.notification_channels
    disable_default_iam_recipients   = false
  }
}
