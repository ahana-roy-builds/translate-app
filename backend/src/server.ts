import { buildApp } from "./app.js";
import { ProductionAppAttestService } from "./app-attest.js";
import { readConfig } from "./config.js";
import { GoogleTranslationProvider } from "./google-provider.js";
import { FirestoreSecurityStore } from "./state-store.js";
import { ProductionStoreKitService } from "./storekit.js";

async function main(): Promise<void> {
  const config = readConfig();
  const provider = new GoogleTranslationProvider({
    projectID: config.googleCloudProject,
    sttLocation: config.googleSttLocation,
    translationLocation: config.googleTranslationLocation,
    speechTimeoutMs: config.speechTimeoutMs,
    translationTimeoutMs: config.translationTimeoutMs
  });
  const store = new FirestoreSecurityStore({ projectID: config.firestoreProject, database: config.firestoreDatabase });
  const appAttest = new ProductionAppAttestService({
    appIDPrefix: config.appleAppIDPrefix,
    bundleID: config.appleBundleID,
    environment: config.appAttestEnvironment,
    rootCertificatePEM: config.appAttestRootCertificatePEM,
    allowedBundleVersions: config.allowedAppBundleVersions,
    allowedValidationCategories: config.allowedAppAttestValidationCategories
  });
  const storeKit = new ProductionStoreKitService({
    bundleID: config.appleBundleID,
    appAppleID: config.appleAppStoreID,
    environment: config.storeKitEnvironment,
    allowedProductIDs: config.allowedProductIDs,
    rootCertificatesPEM: config.storeKitRootCertificatesPEM,
    signingKey: config.appleIAPSigningKey,
    keyID: config.appleIAPKeyID,
    issuerID: config.appleIAPIssuerID
  });
  const app = await buildApp({ config, provider, appAttest, storeKit, store, logRequests: true });
  await app.listen({ host: "0.0.0.0", port: config.port });
}

main().catch(() => {
  process.stderr.write(`${JSON.stringify({ severity: "CRITICAL", event: "startup_failed", errorCode: "STARTUP_CONFIGURATION_OR_DEPENDENCY_FAILURE" })}\n`);
  process.exitCode = 1;
});
