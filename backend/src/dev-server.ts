import { buildApp } from "./app.js";
import { DevelopmentAppAttestService } from "./app-attest.js";
import { readDevelopmentConfig } from "./config.js";
import { GoogleTranslationProvider } from "./google-provider.js";
import { InMemorySecurityStore } from "./state-store.js";
import { DevelopmentStoreKitService } from "./storekit.js";

async function main(): Promise<void> {
  const config = readDevelopmentConfig();
  const provider = new GoogleTranslationProvider({ projectID: config.googleCloudProject, sttLocation: config.googleSttLocation, translationLocation: config.googleTranslationLocation, speechTimeoutMs: config.speechTimeoutMs, translationTimeoutMs: config.translationTimeoutMs });
  const app = await buildApp({ config, provider, appAttest: new DevelopmentAppAttestService(), storeKit: new DevelopmentStoreKitService(), store: new InMemorySecurityStore(), logRequests: true });
  // Development fakes are reachable only from the local machine.
  await app.listen({ host: "127.0.0.1", port: config.port });
}

main().catch(() => {
  process.stderr.write(`${JSON.stringify({ severity: "CRITICAL", event: "development_startup_failed", errorCode: "STARTUP_CONFIGURATION_OR_DEPENDENCY_FAILURE" })}\n`);
  process.exitCode = 1;
});
