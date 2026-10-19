# Security Policy

Please report vulnerabilities privately to the security contact configured on
the App Store product page. Do not include real conversation recordings,
transcripts, Apple credentials, subscription receipts, or Google Cloud secrets
in an issue.

## Sensitive data rules

- Never commit `.env`, App Store private keys, provisioning profiles, service
  account keys, or production service identifiers. LocalLingo v1 has no
  iCloud/CloudKit entitlement or container.
- Never add audio, transcripts, or translations to logs, crash breadcrumbs,
  analytics properties, fixtures, or screenshots without explicit informed
  consent and a documented retention period.
- Use synthetic text and generated tones for automated tests.
- Treat App Attest assertions and StoreKit transaction JWS values as secrets in
  diagnostics even though they are short-lived or signed.

The production backend verifies App Attest and StoreKit evidence in process,
uses Firestore transactions for replay/counter/session/quota state, and fails
closed when trust roots, subscription state, or regional Google configuration
is unavailable. Production has no remotely reachable development bypass.

Cloud Run is reachable only through the external HTTPS load balancer and Cloud
Armor. The default Cloud Run URL must remain blocked by ingress. A valid
attestation is not an authorization to exceed per-installation, subscription,
IP, or daily cost limits.

Release reports, App Attest objects, StoreKit JWS values, and Terraform plans
belong in access-controlled artifact storage. The repository may contain only
their SHA-256 references and synthetic evaluation fixtures.
