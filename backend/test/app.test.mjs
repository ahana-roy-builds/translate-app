import assert from "node:assert/strict";
import { createHash, generateKeyPairSync } from "node:crypto";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { VerificationException, VerificationStatus } from "@apple/app-store-server-library";
import { buildApp, SettlingSemaphore, StoreKitNotificationCache } from "../dist/app.js";
import { authenticatorData, nonceFromExtensionValue, x963PublicKeyIdentifierFromJWK } from "../dist/app-attest.js";
import { appAttestKeyIDHash, decodeCanonicalAppAttestKeyID } from "../dist/app-attest-key.js";
import { readConfig, readTestConfig } from "../dist/config.js";
import { canonicalRequestDigest } from "../dist/protocol.js";
import { FirestoreSecurityStore, InMemorySecurityStore, MetadataTokenProvider, mergeEntitlementEvidence, normalizeStoredEntitlement } from "../dist/state-store.js";
import { DevelopmentAppAttestService, ProductionAppAttestService } from "../dist/app-attest.js";
import { DevelopmentStoreKitService, ProductionStoreKitService, notificationAppIdentityMatches, notificationRevokesAccess } from "../dist/storekit.js";
import { parseCanonicalPCM16Wav } from "../dist/wav.js";
import { GoogleTranslationProvider, MetadataAccessTokenProvider, translationEndpoint } from "../dist/google-provider.js";
import { ApiError } from "../dist/errors.js";

const ASSERTION = Buffer.alloc(64, 3).toString("base64");
const TEST_BUILD_IDENTITY_HEADERS = {
  "x-locallingo-release-build-id": "development",
  "x-locallingo-backend-oci-digest": `sha256:${"0".repeat(64)}`,
  "x-locallingo-runtime-environment": "test",
  "x-locallingo-cloud-run-revision": "local"
};

function buildIdentityHeaders(config) {
  return {
    "x-locallingo-release-build-id": config.releaseBuildID,
    "x-locallingo-backend-oci-digest": config.backendOCIDigest,
    "x-locallingo-runtime-environment": config.runtimeMode,
    "x-locallingo-cloud-run-revision": config.cloudRunRevision
  };
}

function liveEvidence(id, from, to, status = "active", expiresAt = to + 86_400_000) {
  return { originalTransactionIDHash: id, productID: "pro.monthly", expiresAt: status === "expired" ? 0 : expiresAt, signedAt: from, verifiedAt: to, status, kind: "live-status", startedAt: from, completedAt: to };
}

function notificationEvidence(id, eventAt, status = "expired", expiresAt = eventAt + 86_400_000) {
  return { originalTransactionIDHash: id, productID: "pro.monthly", expiresAt: status === "expired" ? 0 : expiresAt, signedAt: eventAt, verifiedAt: eventAt, status, kind: "server-notification", eventAt };
}

class FakeProvider {
  turnCalls = [];
  textCalls = [];
  available = true;
  delayMs = 0;
  async ready() { return this.available; }
  async translateTurn(input) {
    this.turnCalls.push(input);
    return { sourceText: "Hello", translatedText: "Hola", recognitionConfidence: 0.91, engine: "google", warnings: [], timingsMs: { speechRecognition: 1, translation: 2 } };
  }
  async translateText(input) {
    if (this.delayMs) await new Promise((resolve) => setTimeout(resolve, this.delayMs));
    this.textCalls.push(input);
    return { sourceText: input.text, translatedText: "¿Dónde?", engine: "google", warnings: [], timingsMs: { translation: 2 } };
  }
}

function wav(milliseconds = 1_000) {
  const dataBytes = milliseconds * 32;
  const value = Buffer.alloc(44 + dataBytes);
  value.write("RIFF", 0); value.writeUInt32LE(value.length - 8, 4); value.write("WAVE", 8);
  value.write("fmt ", 12); value.writeUInt32LE(16, 16); value.writeUInt16LE(1, 20); value.writeUInt16LE(1, 22);
  value.writeUInt32LE(16_000, 24); value.writeUInt32LE(32_000, 28); value.writeUInt16LE(2, 32); value.writeUInt16LE(16, 34);
  value.write("data", 36); value.writeUInt32LE(dataBytes, 40);
  return value;
}

async function fixture(overrides = {}, injected = {}) {
  const provider = injected.provider ?? new FakeProvider(), store = injected.store ?? new InMemorySecurityStore();
  const config = { ...readTestConfig({ GOOGLE_CLOUD_PROJECT: "test" }), ...overrides };
  const storeKit = injected.storeKit ?? new DevelopmentStoreKitService();
  const app = await buildApp({ config, provider, store, appAttest: injected.appAttest ?? new DevelopmentAppAttestService(), storeKit });
  return { app, provider, store, storeKit, config };
}

async function challenge(app, keyID, purpose) {
  const response = await app.inject({ method: "POST", url: "/v2/app-attest/challenge", payload: { purpose, keyID } });
  assert.equal(response.statusCode, 200, response.body);
  return response.json();
}

async function register(app, seed = 7) {
  const keyID = Buffer.alloc(32, seed).toString("base64");
  const pending = await challenge(app, keyID, "register");
  const response = await app.inject({ method: "POST", url: "/v2/app-attest/register", payload: { keyID, attestationObject: Buffer.alloc(128, seed).toString("base64"), challengeToken: pending.challengeToken } });
  assert.equal(response.statusCode, 201, response.body);
  return keyID;
}

function attestHeaders(keyID, pending, token, identity = TEST_BUILD_IDENTITY_HEADERS) {
  return {
    ...identity,
    ...(token ? { authorization: `Bearer ${token}` } : {}),
    "x-app-attest-key-id": keyID,
    "x-app-attest-assertion": ASSERTION,
    "x-app-attest-challenge-token": pending.challengeToken
  };
}

async function session(app, keyID, signedTransaction = "sandbox-transaction", identity = TEST_BUILD_IDENTITY_HEADERS) {
  const pending = await challenge(app, keyID, "session");
  const response = await app.inject({ method: "POST", url: "/v2/session", headers: attestHeaders(keyID, pending, undefined, identity), payload: { signedTransaction } });
  assert.equal(response.statusCode, 200, response.body);
  assert.equal(response.json().challenges.length, 8);
  return response.json();
}

test("liveness, readiness and content-free availability are separate", async (t) => {
  const { app, provider } = await fixture(); t.after(() => app.close());
  assert.equal((await app.inject({ method: "GET", url: "/livez" })).statusCode, 200);
  assert.deepEqual((await app.inject({ method: "GET", url: "/v2/availability" })).json(), { available: true, buildIdentity: { releaseBuildID: "development", ociDigest: `sha256:${"0".repeat(64)}`, environment: "test", revision: "local", assurance: "self-reported-diagnostic" } });
  provider.available = false;
  assert.equal((await app.inject({ method: "GET", url: "/readyz" })).statusCode, 503);
  // Public availability is deliberately cached to prevent unauthenticated dependency-read amplification.
  assert.equal((await app.inject({ method: "GET", url: "/v2/availability" })).json().available, true);
});

test("attested routes require exact canonical build identity header values", async (t) => {
  const { app } = await fixture(); t.after(() => app.close());
  const send = (headers) => app.inject({ method: "POST", url: "/v2/session", headers, payload: { signedTransaction: "sandbox-transaction" } });
  const missing = { ...TEST_BUILD_IDENTITY_HEADERS }; delete missing["x-locallingo-release-build-id"];
  const invalid = [
    missing,
    { ...TEST_BUILD_IDENTITY_HEADERS, "x-locallingo-release-build-id": "a".repeat(129) },
    { ...TEST_BUILD_IDENTITY_HEADERS, "x-locallingo-backend-oci-digest": `sha256:${"a".repeat(63)}` },
    { ...TEST_BUILD_IDENTITY_HEADERS, "x-locallingo-runtime-environment": "developmentx" },
    { ...TEST_BUILD_IDENTITY_HEADERS, "x-locallingo-cloud-run-revision": "a".repeat(64) }
  ];
  for (const headers of invalid) {
    const response = await send(headers);
    assert.equal(response.statusCode, 400); assert.equal(response.json().error.code, "INVALID_BUILD_IDENTITY_HEADER");
  }
  const mismatches = [
    { "x-locallingo-release-build-id": "another-release" },
    { "x-locallingo-backend-oci-digest": `sha256:${"a".repeat(64)}` },
    { "x-locallingo-runtime-environment": "production" },
    { "x-locallingo-cloud-run-revision": "another-revision" }
  ];
  for (const mutation of mismatches) {
    const response = await send({ ...TEST_BUILD_IDENTITY_HEADERS, ...mutation });
    assert.equal(response.statusCode, 409); assert.equal(response.json().error.code, "BUILD_IDENTITY_MISMATCH");
    assert.equal(response.body.includes(Object.values(mutation)[0]), false, "identity errors must not echo supplied header values");
  }
  const acceptedIdentity = await send(TEST_BUILD_IDENTITY_HEADERS);
  assert.notEqual(acceptedIdentity.json().error.code, "INVALID_BUILD_IDENTITY_HEADER");
  assert.notEqual(acceptedIdentity.json().error.code, "BUILD_IDENTITY_MISMATCH");
});

test("an identity mismatch happens before challenge consumption or StoreKit work", async (t) => {
  class CountingStoreKit extends DevelopmentStoreKitService {
    calls = 0;
    async verifyTransaction(...arguments_) { this.calls += 1; return super.verifyTransaction(...arguments_); }
  }
  const storeKit = new CountingStoreKit();
  const { app } = await fixture({}, { storeKit }); t.after(() => app.close());
  const keyID = await register(app, 93), pending = await challenge(app, keyID, "session");
  const staleIdentity = { ...TEST_BUILD_IDENTITY_HEADERS, "x-locallingo-cloud-run-revision": "stale-revision" };
  const stale = await app.inject({ method: "POST", url: "/v2/session", headers: attestHeaders(keyID, pending, undefined, staleIdentity), payload: { signedTransaction: "identity-retry-subscription" } });
  assert.equal(stale.statusCode, 409); assert.equal(stale.json().error.code, "BUILD_IDENTITY_MISMATCH"); assert.equal(storeKit.calls, 0);
  const retried = await app.inject({ method: "POST", url: "/v2/session", headers: attestHeaders(keyID, pending), payload: { signedTransaction: "identity-retry-subscription" } });
  assert.equal(retried.statusCode, 200, retried.body); assert.equal(storeKit.calls, 1);
});

test("maximum canonical build identity header lengths are accepted", async (t) => {
  const releaseBuildID = "r".repeat(128), cloudRunRevision = "r".repeat(63);
  const { app, config } = await fixture({ runtimeMode: "development", releaseBuildID, cloudRunRevision }); t.after(() => app.close());
  const keyID = await register(app, 91);
  const established = await session(app, keyID, "boundary-subscription", buildIdentityHeaders(config));
  assert.equal(established.challenges.length, 8);
});

test("health, availability, bootstrap, and Apple notification routes do not require app build headers", async (t) => {
  const { app } = await fixture(); t.after(() => app.close());
  assert.equal((await app.inject({ method: "GET", url: "/livez" })).statusCode, 200);
  assert.equal((await app.inject({ method: "GET", url: "/v2/availability" })).statusCode, 200);
  assert.equal((await challenge(app, Buffer.alloc(32, 92).toString("base64"), "register")).challenge.length > 0, true);
  assert.equal((await app.inject({ method: "POST", url: "/v2/storekit/notifications", payload: { signedPayload: "notification-without-app-identity" } })).statusCode, 200);
});

test("registration challenge is one-use and registers a key", async (t) => {
  const { app } = await fixture(); t.after(() => app.close());
  const keyID = Buffer.alloc(32, 5).toString("base64"), pending = await challenge(app, keyID, "register");
  const payload = { keyID, attestationObject: Buffer.alloc(128, 1).toString("base64"), challengeToken: pending.challengeToken };
  assert.equal((await app.inject({ method: "POST", url: "/v2/app-attest/register", payload })).statusCode, 201);
  const replay = await app.inject({ method: "POST", url: "/v2/app-attest/register", payload });
  assert.equal(replay.statusCode, 409); assert.equal(replay.json().error.code, "CHALLENGE_REPLAYED");
});

test("session and raw WAV turn use attestation, subscription and derived duration", async (t) => {
  const { app, provider } = await fixture(); t.after(() => app.close());
  const keyID = await register(app), established = await session(app, keyID), audio = wav(1_234);
  const response = await app.inject({
    method: "POST", url: "/v2/translate-turn",
    headers: { ...attestHeaders(keyID, established.challenges[0], established.token), "content-type": "audio/wav", "x-source-locale": "en-US", "x-target-locale": "es-ES" },
    payload: audio
  });
  assert.equal(response.statusCode, 200, response.body);
  assert.equal(response.json().recognitionConfidence, 0.91);
  assert.equal(provider.turnCalls.length, 1); assert.equal(provider.turnCalls[0].durationMs, 1_234);
});

test("online text correction binds locale headers to the exact JSON", async (t) => {
  const { app, provider } = await fixture(); t.after(() => app.close());
  const keyID = await register(app), established = await session(app, keyID);
  const response = await app.inject({
    method: "POST", url: "/v2/translate-text",
    headers: { ...attestHeaders(keyID, established.challenges[0], established.token), "x-source-locale": "en-US", "x-target-locale": "ja-JP" },
    payload: { sourceLocale: "en-US", targetLocale: "ja-JP", text: "Where is the station?" }
  });
  assert.equal(response.statusCode, 200, response.body); assert.equal(provider.textCalls.length, 1);

  const mismatch = await app.inject({
    method: "POST", url: "/v2/translate-text",
    headers: { ...attestHeaders(keyID, established.challenges[1], established.token), "x-source-locale": "en-US", "x-target-locale": "es-ES" },
    payload: { sourceLocale: "en-US", targetLocale: "ja-JP", text: "Where?" }
  });
  assert.equal(mismatch.statusCode, 400); assert.equal(mismatch.json().error.code, "LOCALE_HEADER_MISMATCH");
});

test("strict WAV parser derives duration and rejects spoofable/noncanonical formats", () => {
  assert.deepEqual(parseCanonicalPCM16Wav(wav(30_000)), { durationMs: 30_000, pcmBytes: 960_000 });
  const stereo = wav(); stereo.writeUInt16LE(2, 22);
  assert.throws(() => parseCanonicalPCM16Wav(stereo), (error) => error.code === "UNSUPPORTED_WAV_FORMAT");
  const lied = wav(); lied.writeUInt32LE(4, 40);
  assert.throws(() => parseCanonicalPCM16Wav(lied), (error) => error.code === "INVALID_WAV");
  assert.throws(() => parseCanonicalPCM16Wav(wav(30_001)), (error) => error.statusCode === 413);
});

test("one assertion challenge cannot be consumed concurrently", async (t) => {
  const { app } = await fixture(); t.after(() => app.close());
  const keyID = await register(app), established = await session(app, keyID), body = { sourceLocale: "en-US", targetLocale: "es-ES", text: "Hello" };
  const request = () => app.inject({ method: "POST", url: "/v2/translate-text", headers: { ...attestHeaders(keyID, established.challenges[0], established.token), "x-source-locale": "en-US", "x-target-locale": "es-ES" }, payload: body });
  const responses = await Promise.all([request(), request()]);
  assert.deepEqual(responses.map((item) => item.statusCode).sort(), [200, 409]);
});

test("shared subscription enforces three active installations", async (t) => {
  const { app } = await fixture(); t.after(() => app.close());
  for (let seed = 1; seed <= 3; seed += 1) await session(app, await register(app, seed), "same-subscription");
  const fourth = await register(app, 4), pending = await challenge(app, fourth, "session");
  const response = await app.inject({ method: "POST", url: "/v2/session", headers: attestHeaders(fourth, pending), payload: { signedTransaction: "same-subscription" } });
  assert.equal(response.statusCode, 409); assert.equal(response.json().error.code, "DEVICE_LIMIT_REACHED");
});

test("distributed quota interface rejects the second per-installation turn", async (t) => {
  const { app } = await fixture({ installationRatePerMinute: 1 }); t.after(() => app.close());
  const keyID = await register(app), established = await session(app, keyID);
  const send = (pending) => app.inject({ method: "POST", url: "/v2/translate-text", headers: { ...attestHeaders(keyID, pending, established.token), "x-source-locale": "en-US", "x-target-locale": "es-ES" }, payload: { sourceLocale: "en-US", targetLocale: "es-ES", text: "Hello" } });
  assert.equal((await send(established.challenges[0])).statusCode, 200);
  const response = await send(established.challenges[1]); assert.equal(response.statusCode, 429); assert.equal(response.json().error.code, "QUOTA_EXCEEDED");
});

test("challenge-pool issuance is bounded per attested key", async (t) => {
  const { app, store } = await fixture({ challengePoolRequestsPerMinute: 1 }); t.after(() => app.close());
  const keyID = await register(app), established = await session(app, keyID);
  const response = await app.inject({ method: "POST", url: "/v2/session/challenges", headers: attestHeaders(keyID, established.challenges[0], established.token) });
  assert.equal(response.statusCode, 429); assert.equal(response.json().error.code, "CHALLENGE_POOL_QUOTA_EXCEEDED");
  const pending = await challenge(app, keyID, "session");
  const secondSession = await app.inject({ method: "POST", url: "/v2/session", headers: attestHeaders(keyID, pending), payload: { signedTransaction: "sandbox-transaction" } });
  assert.equal(secondSession.statusCode, 429);
  assert.equal(store.sessions.size, 1, "a failed challenge-pool reservation must not orphan a session");
});

test("public establishment challenges cannot bypass request challenge pools", async (t) => {
  const { app } = await fixture(); t.after(() => app.close());
  const keyID = await register(app), established = await session(app, keyID);
  const publicChallenge = await challenge(app, keyID, "session");
  const translation = await app.inject({
    method: "POST", url: "/v2/translate-text",
    headers: { ...attestHeaders(keyID, publicChallenge, established.token), "x-source-locale": "en-US", "x-target-locale": "es-ES" },
    payload: { sourceLocale: "en-US", targetLocale: "es-ES", text: "Hello" }
  });
  assert.equal(translation.statusCode, 401); assert.equal(translation.json().error.code, "INVALID_CHALLENGE");

  const wrongSession = await app.inject({ method: "POST", url: "/v2/session", headers: attestHeaders(keyID, established.challenges[0]), payload: { signedTransaction: "sandbox-transaction" } });
  assert.equal(wrongSession.statusCode, 401); assert.equal(wrongSession.json().error.code, "INVALID_CHALLENGE");
});

test("distributed session-attempt quota rejects before StoreKit work", async (t) => {
  class CountingStoreKit extends DevelopmentStoreKitService {
    calls = 0;
    async verifyTransaction(value) { this.calls += 1; return super.verifyTransaction(value); }
  }
  const storeKit = new CountingStoreKit();
  const { app } = await fixture({ sessionAttemptsPerMinute: 1 }, { storeKit }); t.after(() => app.close());
  const keyID = await register(app);
  await session(app, keyID);
  const pending = await challenge(app, keyID, "session");
  const limited = await app.inject({ method: "POST", url: "/v2/session", headers: attestHeaders(keyID, pending), payload: { signedTransaction: "sandbox-transaction" } });
  assert.equal(limited.statusCode, 429); assert.equal(limited.json().error.code, "SESSION_ATTEMPT_QUOTA_EXCEEDED");
  assert.equal(storeKit.calls, 1, "quota rejection must happen before StoreKit verification");
});

test("a live expired StoreKit result cannot authorize from newer cached active state", async (t) => {
  const now = Date.now(), entitlementID = "live-expired-entitlement", store = new InMemorySecurityStore();
  await store.applyNotification({ notificationID: "future-active", payloadHash: "future-active-hash", signedAt: now + 60_000, receivedAt: now, evidence: notificationEvidence(entitlementID, now + 60_000, "active", now + 86_400_000) });
  const storeKit = {
    async verifyTransaction() {
      return liveEvidence(entitlementID, now - 1_000, now, "expired");
    },
    async processNotification() { throw new Error("unused"); }
  };
  const { app } = await fixture({}, { store, storeKit }); t.after(() => app.close());
  const keyID = await register(app, 33), pending = await challenge(app, keyID, "session");
  const response = await app.inject({ method: "POST", url: "/v2/session", headers: attestHeaders(keyID, pending), payload: { signedTransaction: "revoked-transaction" } });
  assert.equal(response.statusCode, 402); assert.equal(response.json().error.code, "SUBSCRIPTION_REQUIRED");
  assert.equal((await store.getEntitlement(entitlementID)).status, "active", "both the current check and merged state must authorize");
});

test("failed atomic session establishment does not leave a device binding", async (t) => {
  class FailOnceSessionStore extends InMemorySecurityStore {
    failed = false;
    async establishSessionWithEvidence(input, signal) {
      if (!this.failed) { this.failed = true; throw new ApiError(503, "STATE_STORE_UNAVAILABLE", "Security state is temporarily unavailable"); }
      return super.establishSessionWithEvidence(input, signal);
    }
  }
  const store = new FailOnceSessionStore();
  const { app } = await fixture({ maximumSubscriptionDevices: 1 }, { store }); t.after(() => app.close());
  const first = await register(app, 31), firstChallenge = await challenge(app, first, "session");
  const failed = await app.inject({ method: "POST", url: "/v2/session", headers: attestHeaders(first, firstChallenge), payload: { signedTransaction: "shared" } });
  assert.equal(failed.statusCode, 503);
  const second = await register(app, 32);
  const established = await session(app, second, "shared");
  assert.equal(established.challenges.length, 8, "the failed key must not consume the only device slot");
});

test("StoreKit semaphore removes canceled queue entries and holds running permits until settlement", async () => {
  const limiter = new SettlingSemaphore(1);
  let resolveFirst;
  const firstController = new AbortController();
  const first = limiter.run(firstController.signal, () => new Promise((resolve) => { resolveFirst = resolve; }), () => new Error("aborted"));
  assert.equal(limiter.activeCount, 1);

  let canceledStarted = false;
  const canceledController = new AbortController();
  const canceled = limiter.run(canceledController.signal, async () => { canceledStarted = true; }, () => new Error("aborted"));
  canceledController.abort();
  await assert.rejects(canceled, /aborted/);
  assert.equal(canceledStarted, false); assert.equal(limiter.queuedCount, 0);

  let thirdStarted = false;
  const third = limiter.run(new AbortController().signal, async () => { thirdStarted = true; return "third"; }, () => new Error("aborted"));
  firstController.abort();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(thirdStarted, false); assert.equal(limiter.activeCount, 1, "an aborted running call retains its permit");
  resolveFirst("first");
  assert.equal(await first, "first"); assert.equal(await third, "third");
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(limiter.activeCount, 0);
});

test("StoreKit lanes bound outstanding work and notification pressure cannot consume session capacity", async (t) => {
  let releaseNotifications;
  const notificationGate = new Promise((resolve) => { releaseNotifications = resolve; });
  let notificationCalls = 0;
  const storeKit = {
    async verifyTransaction(value) { const now = Date.now(); return liveEvidence(createHash("sha256").update(value).digest("base64url"), now, now, "active", now + 86_400_000); },
    async processNotification(value) { notificationCalls += 1; await notificationGate; return { notificationID: value, signedAt: Date.now() }; }
  };
  const { app } = await fixture({ storeKitNotificationConcurrency: 1, storeKitNotificationMaximumOutstanding: 2 }, { storeKit });
  t.after(() => app.close());
  const first = app.inject({ method: "POST", url: "/v2/storekit/notifications", payload: { signedPayload: "notification-one" } });
  await new Promise((resolve) => setImmediate(resolve));
  const second = app.inject({ method: "POST", url: "/v2/storekit/notifications", payload: { signedPayload: "notification-two" } });
  await new Promise((resolve) => setImmediate(resolve));
  const overflow = await app.inject({ method: "POST", url: "/v2/storekit/notifications", payload: { signedPayload: "notification-three" } });
  assert.equal(overflow.statusCode, 503); assert.equal(overflow.json().error.code, "STOREKIT_BUSY"); assert.equal(overflow.headers["retry-after"], "5");

  const keyID = await register(app, 71);
  assert.equal((await session(app, keyID, "lane-subscription")).challenges.length, 8, "session verification uses its reserved lane");
  releaseNotifications();
  assert.equal((await first).statusCode, 200); assert.equal((await second).statusCode, 200); assert.equal(notificationCalls, 2);
});

test("verified notification cache coalesces successes but never caches failures", async () => {
  const cache = new StoreKitNotificationCache(2, 1_000);
  let calls = 0, resolve;
  const gate = new Promise((done) => { resolve = done; });
  const work = async () => { calls += 1; await gate; return { notificationID: "id", signedAt: 100 }; };
  const first = cache.verify("hash", 100, work), second = cache.verify("hash", 100, work);
  resolve();
  assert.deepEqual(await first, await second); assert.equal(calls, 1);
  await cache.verify("hash", 200, work); assert.equal(calls, 1);
  await assert.rejects(cache.verify("bad", 200, async () => { calls += 1; throw new Error("invalid"); }), /invalid/);
  await assert.rejects(cache.verify("bad", 201, async () => { calls += 1; throw new Error("invalid"); }), /invalid/);
  assert.equal(calls, 3);
});

test("notification UUID replay is idempotent and a different payload hash conflicts", async (t) => {
  let calls = 0;
  const storeKit = {
    async verifyTransaction() { throw new Error("unused"); },
    async processNotification() { calls += 1; return { notificationID: "fixed-notification-id", signedAt: Date.now() }; }
  };
  const { app } = await fixture({}, { storeKit }); t.after(() => app.close());
  const send = (signedPayload) => app.inject({ method: "POST", url: "/v2/storekit/notifications", payload: { signedPayload } });
  assert.equal((await send("same-payload")).statusCode, 200);
  assert.equal((await send("same-payload")).statusCode, 200); assert.equal(calls, 1, "successful payload verification is cached");
  const conflict = await send("different-payload");
  assert.equal(conflict.statusCode, 409); assert.equal(conflict.json().error.code, "STOREKIT_NOTIFICATION_CONFLICT"); assert.equal(calls, 2);
});

test("registration limit is keyed by the requested key, not spoofable forwarding headers", async (t) => {
  const { app } = await fixture(); t.after(() => app.close());
  const keyID = Buffer.alloc(32, 44).toString("base64");
  for (let index = 0; index < 20; index += 1) {
    const response = await app.inject({ method: "POST", url: "/v2/app-attest/challenge", headers: { "x-forwarded-for": `198.51.100.${index}` }, payload: { purpose: "register", keyID } });
    assert.equal(response.statusCode, 200);
  }
  const limited = await app.inject({ method: "POST", url: "/v2/app-attest/challenge", headers: { "x-forwarded-for": "203.0.113.1" }, payload: { purpose: "register", keyID } });
  assert.equal(limited.statusCode, 429);
});

test("the whole request deadline includes provider work", async (t) => {
  const { app, provider } = await fixture({ requestDeadlineMs: 40 }); t.after(() => app.close());
  const keyID = await register(app), established = await session(app, keyID);
  provider.delayMs = 100;
  const response = await app.inject({ method: "POST", url: "/v2/translate-text", headers: { ...attestHeaders(keyID, established.challenges[0], established.token), "x-source-locale": "en-US", "x-target-locale": "es-ES" }, payload: { sourceLocale: "en-US", targetLocale: "es-ES", text: "Hello" } });
  assert.equal(response.statusCode, 504); assert.equal(response.json().error.code, "REQUEST_DEADLINE_EXCEEDED");
});

test("deleting current device invalidates its issued session", async (t) => {
  const { app } = await fixture(); t.after(() => app.close());
  const keyID = await register(app), established = await session(app, keyID);
  const deletion = await app.inject({ method: "DELETE", url: "/v2/devices/current", headers: attestHeaders(keyID, established.challenges[0], established.token) });
  assert.equal(deletion.statusCode, 204, deletion.body);
  const response = await app.inject({ method: "POST", url: "/v2/translate-text", headers: { ...attestHeaders(keyID, established.challenges[1], established.token), "x-source-locale": "en-US", "x-target-locale": "es-ES" }, payload: { sourceLocale: "en-US", targetLocale: "es-ES", text: "Hello" } });
  assert.equal(response.statusCode, 401); assert.equal(response.json().error.code, "INVALID_SESSION");
});

test("stale revocation writes cannot revive a session or regress binding activity", async () => {
  const store = new InMemorySecurityStore();
  const minute = Math.floor(Date.now() / 60_000) * 60_000, createdAt = minute + 1_000;
  const input = {
    keyIDHash: "monotonic-key",
    originalTransactionIDHash: "monotonic-entitlement",
    evidence: liveEvidence("monotonic-entitlement", createdAt, createdAt, "active", createdAt + 10_000),
    now: createdAt,
    maximumDevices: 3,
    inactiveAfterMs: 30 * 86_400_000,
    challengeCount: 1,
    challengeTtlMs: 120_000,
    maximumPoolsPerMinute: 4,
    session: { tokenHash: "monotonic-token", keyIDHash: "monotonic-key", originalTransactionIDHash: "monotonic-entitlement", createdAt, expiresAt: createdAt + 10_000 }
  };
  await store.establishSessionWithEvidence(input);
  await store.establishSessionWithEvidence({ ...input, evidence: liveEvidence("monotonic-entitlement", createdAt - 100, createdAt - 100, "active", createdAt + 10_000), now: createdAt - 100, session: { ...input.session, tokenHash: "stale-refresh-token" } });
  assert.equal(store.bindings.get("monotonic-entitlement").bindings["monotonic-key"], createdAt);

  await store.removeInstallation("monotonic-entitlement", "monotonic-key", createdAt + 200);
  assert.equal(await store.getSession("monotonic-token", createdAt + 300), undefined);
  await store.removeInstallation("monotonic-entitlement", "monotonic-key", createdAt + 100);
  assert.equal(await store.getSession("monotonic-token", createdAt + 300), undefined, "an older retry must not lower the revocation tombstone");
});

test("device removal is atomic when its state transaction fails", async (t) => {
  class FailingRemovalStore extends InMemorySecurityStore {
    async removeInstallation() { throw new ApiError(503, "STATE_STORE_UNAVAILABLE", "Security state is temporarily unavailable"); }
  }
  const { app } = await fixture({}, { store: new FailingRemovalStore() }); t.after(() => app.close());
  const keyID = await register(app), established = await session(app, keyID);
  const deletion = await app.inject({ method: "DELETE", url: "/v2/devices/current", headers: attestHeaders(keyID, established.challenges[0], established.token) });
  assert.equal(deletion.statusCode, 503);
  const translation = await app.inject({
    method: "POST", url: "/v2/translate-text",
    headers: { ...attestHeaders(keyID, established.challenges[1], established.token), "x-source-locale": "en-US", "x-target-locale": "es-ES" },
    payload: { sourceLocale: "en-US", targetLocale: "es-ES", text: "Hello" }
  });
  assert.equal(translation.statusCode, 200, "a failed atomic removal must not partially revoke the session");
});

test("replace-oldest recovery evicts the LRU device and lets the new device establish a session", async (t) => {
  const { app } = await fixture(); t.after(() => app.close());
  const active = [];
  for (let seed = 51; seed <= 53; seed += 1) {
    const keyID = await register(app, seed);
    active.push({ keyID, established: await session(app, keyID, "replacement-subscription") });
    await new Promise((resolve) => setTimeout(resolve, 2));
  }
  const replacementKey = await register(app, 54);
  let pending = await challenge(app, replacementKey, "session");
  const full = await app.inject({ method: "POST", url: "/v2/session", headers: attestHeaders(replacementKey, pending), payload: { signedTransaction: "replacement-subscription" } });
  assert.equal(full.statusCode, 409); assert.equal(full.json().error.code, "DEVICE_LIMIT_REACHED");

  pending = await challenge(app, replacementKey, "session");
  const replaced = await app.inject({ method: "POST", url: "/v2/devices/replace-oldest", headers: attestHeaders(replacementKey, pending), payload: { signedTransaction: "replacement-subscription" } });
  assert.equal(replaced.statusCode, 200, replaced.body); assert.deepEqual(replaced.json(), { replaced: true });

  pending = await challenge(app, replacementKey, "session");
  const replacement = await app.inject({ method: "POST", url: "/v2/session", headers: attestHeaders(replacementKey, pending), payload: { signedTransaction: "replacement-subscription" } });
  assert.equal(replacement.statusCode, 200, replacement.body);

  const evicted = active[0];
  const oldSession = await app.inject({
    method: "POST", url: "/v2/translate-text",
    headers: { ...attestHeaders(evicted.keyID, evicted.established.challenges[0], evicted.established.token), "x-source-locale": "en-US", "x-target-locale": "es-ES" },
    payload: { sourceLocale: "en-US", targetLocale: "es-ES", text: "Hello" }
  });
  assert.equal(oldSession.statusCode, 401); assert.equal(oldSession.json().error.code, "INVALID_SESSION");
});

test("replace-oldest requires exact fields and an establishment-scoped assertion", async (t) => {
  const { app } = await fixture(); t.after(() => app.close());
  const keyID = await register(app), established = await session(app, keyID);
  const wrongScope = await app.inject({ method: "POST", url: "/v2/devices/replace-oldest", headers: attestHeaders(keyID, established.challenges[0]), payload: { signedTransaction: "sandbox-transaction" } });
  assert.equal(wrongScope.statusCode, 401); assert.equal(wrongScope.json().error.code, "INVALID_CHALLENGE");
  const pending = await challenge(app, keyID, "session");
  const extra = await app.inject({ method: "POST", url: "/v2/devices/replace-oldest", headers: attestHeaders(keyID, pending), payload: { signedTransaction: "sandbox-transaction", unexpected: true } });
  assert.equal(extra.statusCode, 400); assert.equal(extra.json().error.code, "INVALID_FIELDS");
});

test("canonical digest fixture is stable across iOS and backend", () => {
  const body = Buffer.from('{"sourceLocale":"en-US","targetLocale":"es-ES","text":"Where is the station?"}');
  const base = { method: "POST", path: "/v2/translate-text", challenge: "fixture-challenge", keyID: "fixture-key-id", sessionToken: "fixture-session-token", sourceLocale: "en-US", targetLocale: "es-ES", releaseBuildID: "candidate-release-1", backendOCIDigest: `sha256:${"a".repeat(64)}`, runtimeEnvironment: "production", cloudRunRevision: "locallingo-api-00001", body };
  const digest = canonicalRequestDigest(base);
  assert.equal(digest.toString("hex"), "905db59ebea299d5d3c76c201c146d420c0735eba7af74ea8ab0d0c32350c4b6");
  const mutations = [
    { method: "PUT" }, { path: "/v2/translate-turn" }, { challenge: "other" }, { keyID: "other-key" },
    { sessionToken: "other-session" }, { sourceLocale: "ja-JP" }, { targetLocale: "ja-JP" },
    { releaseBuildID: "candidate-release-2" }, { backendOCIDigest: `sha256:${"b".repeat(64)}` },
    { runtimeEnvironment: "testflight" }, { cloudRunRevision: "locallingo-api-00002" }, { body: Buffer.from("different") }
  ];
  for (const mutation of mutations) assert.notDeepEqual(canonicalRequestDigest({ ...base, ...mutation }), digest);
});

test("App Attest authenticator data does not incorrectly require user-presence", () => {
  const rp = createHash("sha256").update("PREFIX.bundle").digest(), assertion = Buffer.alloc(37);
  rp.copy(assertion); assertion[32] = 0; assertion.writeUInt32BE(4, 33);
  assert.equal(authenticatorData(assertion, rp, false).counter, 4);
  const cose = Buffer.concat([
    Buffer.from([0xa5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20]), Buffer.alloc(32, 1),
    Buffer.from([0x22, 0x58, 0x20]), Buffer.alloc(32, 2)
  ]);
  const registration = Buffer.alloc(55 + 32 + cose.length); rp.copy(registration); registration[32] = 0x40; registration.writeUInt16BE(32, 53); cose.copy(registration, 87);
  assert.equal(authenticatorData(registration, rp, true).credentialID.length, 32);
});

test("App Attest parses the documented validation-category and bundle-version extensions", () => {
  const rp = createHash("sha256").update("PREFIX.bundle").digest();
  const key1 = Buffer.from("apple_bundle_version_01"), key2 = Buffer.from("apple_validation_category_01");
  const extension = Buffer.concat([
    Buffer.from([0xa2, 0x60 + key1.length]), key1, Buffer.from([0x61, 0x31, 0x78, key2.length]), key2,
    Buffer.from([0x44, 0x04, 0x00, 0x00, 0x00])
  ]);
  const assertion = Buffer.concat([Buffer.alloc(37), extension]);
  rp.copy(assertion); assertion[32] = 0x80; assertion.writeUInt32BE(8, 33);
  assert.deepEqual(authenticatorData(assertion, rp, false).extensions, { validationCategory: 4, bundleVersion: "1" });
});

test("App Attest key ID hashes the uncompressed X9.62 point rather than SPKI", () => {
  const { publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const jwk = publicKey.export({ format: "jwk" });
  const expected = createHash("sha256").update(Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x, "base64url"), Buffer.from(jwk.y, "base64url")])).digest();
  assert.deepEqual(x963PublicKeyIdentifierFromJWK(jwk), expected);
  assert.notDeepEqual(expected, createHash("sha256").update(publicKey.export({ format: "der", type: "spki" })).digest());
});

test("App Attest key identity accepts only canonical standard or base64url encodings", async (t) => {
  const bytes = Buffer.alloc(32, 62), standard = bytes.toString("base64"), url = bytes.toString("base64url");
  assert.deepEqual(decodeCanonicalAppAttestKeyID(standard), bytes);
  assert.deepEqual(decodeCanonicalAppAttestKeyID(url), bytes);
  assert.equal(appAttestKeyIDHash(standard), appAttestKeyIDHash(url));
  const noncanonical = `${standard.slice(0, -2)}B=`;
  assert.throws(() => decodeCanonicalAppAttestKeyID(noncanonical));

  const { app } = await fixture(); t.after(() => app.close());
  await register(app, 62);
  const alias = await app.inject({ method: "POST", url: "/v2/app-attest/challenge", payload: { purpose: "register", keyID: url } });
  assert.equal(alias.statusCode, 409); assert.equal(alias.json().error.code, "KEY_ALREADY_REGISTERED");
  const malformed = await app.inject({ method: "POST", url: "/v2/app-attest/challenge", payload: { purpose: "register", keyID: noncanonical } });
  assert.equal(malformed.statusCode, 400); assert.equal(malformed.json().error.code, "INVALID_APP_ATTEST_KEY_ID");
});

test("App Attest nonce extension accepts only the exact Apple DER shape", () => {
  const nonce = Buffer.alloc(32, 9);
  const value = Buffer.concat([Buffer.from([0x30, 0x24, 0xa1, 0x22, 0x04, 0x20]), nonce]);
  assert.deepEqual(nonceFromExtensionValue(value), nonce);
  assert.equal(nonceFromExtensionValue(Buffer.concat([value, Buffer.from([0])])), undefined);
  const wrongTag = Buffer.from(value); wrongTag[4] = 0x05;
  assert.equal(nonceFromExtensionValue(wrongTag), undefined);
});

test("App Attest rejects a malformed trust root during startup", () => {
  assert.throws(() => new ProductionAppAttestService({ appIDPrefix: "ABCDE12345", bundleID: "com.example.LocalLingo", environment: "production", rootCertificatePEM: "-----BEGIN CERTIFICATE-----\ninvalid\n-----END CERTIFICATE-----", allowedBundleVersions: ["1"], allowedValidationCategories: [4] }), /valid certificate/);
});

test("causal entitlement merge is commutative, terminal on overlap, and permits later recovery", () => {
  const active = liveEvidence("transaction", 100, 300, "active", 10_000);
  const revoked = notificationEvidence("transaction", 200, "expired");
  const left = mergeEntitlementEvidence(mergeEntitlementEvidence(undefined, active, 300), revoked, 400);
  const right = mergeEntitlementEvidence(mergeEntitlementEvidence(undefined, revoked, 400), active, 300);
  assert.equal(left.status, "expired"); assert.equal(right.status, "expired");
  assert.deepEqual({ ...left, updatedAt: 0 }, { ...right, updatedAt: 0 });

  const recovered = mergeEntitlementEvidence(left, liveEvidence("transaction", 201, 500, "active", 20_000), 500);
  assert.equal(recovered.status, "active", "only a live request beginning strictly after the terminal event may recover");

  const grace = mergeEntitlementEvidence(undefined, notificationEvidence("transaction", 600, "grace-period", 30_000), 600);
  const samePointActive = mergeEntitlementEvidence(grace, notificationEvidence("transaction", 600, "active", 40_000), 601);
  assert.equal(samePointActive.status, "grace-period");
});

test("atomic establishment persists terminal evidence without creating session or binding state", async () => {
  const store = new InMemorySecurityStore(), id = "atomic-entitlement", now = Date.now();
  await store.applyNotification({ notificationID: "revocation", payloadHash: "revocation-hash", signedAt: now, receivedAt: now, evidence: notificationEvidence(id, now, "expired") });
  const result = await store.establishSessionWithEvidence({
    keyIDHash: "key", originalTransactionIDHash: id, evidence: liveEvidence(id, now - 1_000, now + 1_000, "active", now + 86_400_000), now: now + 1_000,
    maximumDevices: 3, inactiveAfterMs: 30 * 86_400_000, challengeCount: 8, challengeTtlMs: 120_000, maximumPoolsPerMinute: 4,
    session: { tokenHash: "must-not-exist", keyIDHash: "key", originalTransactionIDHash: id, createdAt: now + 1_000, expiresAt: now + 10_000 }
  });
  assert.deepEqual(result, { authorized: false, challenges: [] });
  assert.equal((await store.getEntitlement(id)).status, "expired");
  assert.equal(store.sessions.has("must-not-exist"), false); assert.equal(store.bindings.has(id), false);
});

test("legacy entitlement documents normalize to v2 point evidence and fail closed when malformed", () => {
  const legacy = { originalTransactionIDHash: "legacy", productID: "pro", expiresAt: 500, signedAt: 100, verifiedAt: 200, status: "active", updatedAt: 200 };
  assert.deepEqual(normalizeStoredEntitlement(legacy), { ...legacy, schemaVersion: 2, evidenceKind: "server-notification", evidenceFrom: 200, evidenceTo: 200 });
  assert.equal(normalizeStoredEntitlement({ ...legacy, updatedAt: "invalid" }), undefined);
});

test("StoreKit notification identity follows Sandbox and Production rules", () => {
  const sandbox = { bundleId: "com.example.LocalLingo", environment: "Sandbox" };
  assert.equal(notificationAppIdentityMatches(sandbox, "com.example.LocalLingo", 123, "Sandbox"), true);
  assert.equal(notificationAppIdentityMatches({ ...sandbox, appAppleId: 999 }, "com.example.LocalLingo", 123, "Sandbox"), false);
  assert.equal(notificationAppIdentityMatches({ bundleId: "com.example.LocalLingo", environment: "Production" }, "com.example.LocalLingo", 123, "Production"), false);
  assert.equal(notificationAppIdentityMatches({ bundleId: "com.example.LocalLingo", environment: "Production", appAppleId: 123 }, "com.example.LocalLingo", 123, "Production"), true);
});

test("a StoreKit consumption request does not revoke subscription access", () => {
  assert.equal(notificationRevokesAccess("CONSUMPTION_REQUEST"), false);
  assert.equal(notificationRevokesAccess("REFUND"), true);
  assert.equal(notificationRevokesAccess("GRACE_PERIOD_EXPIRED"), true);
});

test("StoreKit live status refresh authorizes active and grace but denies billing retry or revoked grace", async () => {
  const now = 2_000_000_000_000;
  const base = {
    transactionId: "tx", originalTransactionId: "original", bundleId: "com.example.LocalLingo", productId: "pro.monthly",
    type: "Auto-Renewable Subscription", inAppOwnershipType: "PURCHASED", environment: "Sandbox", expiresDate: now + 60_000, signedDate: now - 1_000
  };
  const values = new Map([["client", base], ["current", base]]);
  const verifier = {
    async verifyAndDecodeTransaction(value) { return values.get(value); },
    async verifyAndDecodeRenewalInfo() { return { environment: "Sandbox", originalTransactionId: "original", productId: "pro.monthly", gracePeriodExpiresDate: now + 120_000, signedDate: now - 500 }; },
    async verifyAndDecodeNotification() { throw new Error("unused"); }
  };
  let status = 1;
  const statusClient = { async getAllSubscriptionStatuses() { return { environment: "Sandbox", bundleId: "com.example.LocalLingo", data: [{ lastTransactions: [{ status, originalTransactionId: "original", signedTransactionInfo: "current", signedRenewalInfo: "renewal" }] }] }; } };
  const service = new ProductionStoreKitService({ bundleID: "com.example.LocalLingo", appAppleID: 123, environment: "Sandbox", allowedProductIDs: ["pro.monthly", "pro.annual"], rootCertificatesPEM: [], signingKey: "", keyID: "", issuerID: "" }, { verifier, statusClient, now: () => now });
  assert.equal((await service.verifyTransaction("client")).status, "active");
  status = 4;
  assert.equal((await service.verifyTransaction("client")).status, "grace-period");
  status = 3;
  assert.equal((await service.verifyTransaction("client")).status, "expired");
  values.set("current", { ...base, revocationDate: now - 250 });
  status = 4;
  await assert.rejects(service.verifyTransaction("client"), (error) => error.code === "SUBSCRIPTION_REQUIRED", "grace must not resurrect an explicitly revoked transaction");
});

test("StoreKit orders concurrent live status observations by response time", async () => {
  const baseTime = 2_000_000_000_000;
  let clock = baseTime;
  const base = { originalTransactionId: "original", bundleId: "com.example.LocalLingo", productId: "pro.monthly", type: "Auto-Renewable Subscription", inAppOwnershipType: "PURCHASED", environment: "Sandbox", expiresDate: baseTime + 86_400_000, signedDate: baseTime - 1_000 };
  const transactions = new Map([
    ["slow-client", { ...base, transactionId: "slow" }],
    ["fast-client", { ...base, transactionId: "fast" }],
    ["active-current", { ...base, transactionId: "active-current" }],
    ["revoked-current", { ...base, transactionId: "revoked-current", revocationDate: baseTime + 25 }]
  ]);
  const verifier = {
    async verifyAndDecodeTransaction(value) { return transactions.get(value); },
    async verifyAndDecodeRenewalInfo() { throw new Error("unused"); },
    async verifyAndDecodeNotification() { throw new Error("unused"); }
  };
  const pending = new Map();
  const statusClient = { async getAllSubscriptionStatuses(transactionID) {
    return new Promise((resolve) => pending.set(transactionID, resolve));
  } };
  const service = new ProductionStoreKitService({ bundleID: "com.example.LocalLingo", appAppleID: 123, environment: "Sandbox", allowedProductIDs: ["pro.monthly", "pro.annual"], rootCertificatesPEM: [], signingKey: "", keyID: "", issuerID: "" }, { verifier, statusClient, now: () => clock });

  const slowPromise = service.verifyTransaction("slow-client");
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(pending.has("slow"), true);
  clock = baseTime + 10;
  const fastPromise = service.verifyTransaction("fast-client");
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(pending.has("fast"), true);

  clock = baseTime + 20;
  pending.get("fast")({ environment: "Sandbox", bundleId: "com.example.LocalLingo", data: [{ lastTransactions: [{ status: 1, originalTransactionId: "original", signedTransactionInfo: "active-current" }] }] });
  const fast = await fastPromise;
  clock = baseTime + 30;
  pending.get("slow")({ environment: "Sandbox", bundleId: "com.example.LocalLingo", data: [{ lastTransactions: [{ status: 5, originalTransactionId: "original", signedTransactionInfo: "revoked-current" }] }] });
  const slow = await slowPromise;
  assert.equal(fast.verifiedAt, baseTime + 20); assert.equal(slow.verifiedAt, baseTime + 30);

  const merged = mergeEntitlementEvidence(mergeEntitlementEvidence(undefined, fast, fast.verifiedAt), slow, slow.verifiedAt);
  assert.equal(merged.status, "expired", "overlapping live observations fail closed even when ACTIVE returns first");
});

test("StoreKit accepts Apple's shortened TEST notification data", async () => {
  const now = 2_000_000_000_000;
  const verifier = {
    async verifyAndDecodeTransaction() { throw new Error("unused"); },
    async verifyAndDecodeRenewalInfo() { throw new Error("unused"); },
    async verifyAndDecodeNotification() { return { notificationType: "TEST", notificationUUID: "test-notification", signedDate: now, data: { environment: "Sandbox", bundleId: "com.example.LocalLingo" } }; }
  };
  const statusClient = { async getAllSubscriptionStatuses() { throw new Error("unused"); } };
  const service = new ProductionStoreKitService({ bundleID: "com.example.LocalLingo", appAppleID: 123, environment: "Sandbox", allowedProductIDs: ["pro.monthly", "pro.annual"], rootCertificatesPEM: [], signingKey: "", keyID: "", issuerID: "" }, { verifier, statusClient, now: () => now });
  assert.deepEqual(await service.processNotification("signed-test"), { notificationID: "test-notification", signedAt: now });
});

test("StoreKit status refresh skips an obsolete upgraded transaction", async () => {
  const now = 2_000_000_000_000;
  const current = { transactionId: "new", originalTransactionId: "original", bundleId: "com.example.LocalLingo", productId: "pro.annual", type: "Auto-Renewable Subscription", inAppOwnershipType: "PURCHASED", environment: "Sandbox", expiresDate: now + 60_000, signedDate: now - 500 };
  const upgraded = { ...current, transactionId: "old", productId: "pro.monthly", signedDate: now - 1_000, isUpgraded: true };
  const values = new Map([["client", current], ["current", current], ["upgraded", upgraded]]);
  const verifier = { async verifyAndDecodeTransaction(value) { return values.get(value); }, async verifyAndDecodeRenewalInfo() { throw new Error("unused"); }, async verifyAndDecodeNotification() { throw new Error("unused"); } };
  const statusClient = { async getAllSubscriptionStatuses() { return { environment: "Sandbox", bundleId: "com.example.LocalLingo", data: [{ lastTransactions: [
    { status: 2, originalTransactionId: "original", signedTransactionInfo: "upgraded" },
    { status: 1, originalTransactionId: "original", signedTransactionInfo: "current" }
  ] }] }; } };
  const service = new ProductionStoreKitService({ bundleID: "com.example.LocalLingo", appAppleID: 123, environment: "Sandbox", allowedProductIDs: ["pro.monthly", "pro.annual"], rootCertificatesPEM: [], signingKey: "", keyID: "", issuerID: "" }, { verifier, statusClient, now: () => now });
  assert.equal((await service.verifyTransaction("client")).status, "active");
});

test("StoreKit forwards cancellation to live status and opens a short circuit after retryable verifier failures", async () => {
  const now = 2_000_000_000_000;
  const transaction = { transactionId: "tx", originalTransactionId: "original", bundleId: "com.example.LocalLingo", productId: "pro.monthly", type: "Auto-Renewable Subscription", inAppOwnershipType: "PURCHASED", environment: "Sandbox", expiresDate: now + 60_000, signedDate: now - 1_000 };
  const controller = new AbortController();
  let observedSignal;
  const verifier = { async verifyAndDecodeTransaction() { return transaction; }, async verifyAndDecodeRenewalInfo() { throw new Error("unused"); }, async verifyAndDecodeNotification() { throw new Error("unused"); } };
  const statusClient = { async getAllSubscriptionStatuses(_id, _statuses, signal) { observedSignal = signal; return { environment: "Sandbox", bundleId: "com.example.LocalLingo", data: [{ lastTransactions: [{ status: 1, originalTransactionId: "original", signedTransactionInfo: "current" }] }] }; } };
  const service = new ProductionStoreKitService({ bundleID: "com.example.LocalLingo", appAppleID: 123, environment: "Sandbox", allowedProductIDs: ["pro.monthly", "pro.annual"], rootCertificatesPEM: [], signingKey: "", keyID: "", issuerID: "" }, { verifier, statusClient, now: () => now });
  await service.verifyTransaction("client", controller.signal); assert.equal(observedSignal, controller.signal);
  controller.abort();
  await assert.rejects(service.verifyTransaction("client", controller.signal), (error) => error.code === "REQUEST_DEADLINE_EXCEEDED");

  let failures = 0;
  const failingVerifier = { async verifyAndDecodeTransaction() { failures += 1; throw new VerificationException(VerificationStatus.RETRYABLE_VERIFICATION_FAILURE); }, async verifyAndDecodeRenewalInfo() { throw new Error("unused"); }, async verifyAndDecodeNotification() { throw new Error("unused"); } };
  const circuit = new ProductionStoreKitService({ bundleID: "com.example.LocalLingo", appAppleID: 123, environment: "Sandbox", allowedProductIDs: ["pro.monthly", "pro.annual"], rootCertificatesPEM: [], signingKey: "", keyID: "", issuerID: "" }, { verifier: failingVerifier, statusClient, now: () => now });
  await assert.rejects(circuit.verifyTransaction("first"), (error) => error.code === "STOREKIT_VERIFICATION_UNAVAILABLE");
  await assert.rejects(circuit.verifyTransaction("second"), (error) => error.code === "STOREKIT_VERIFICATION_UNAVAILABLE");
  await assert.rejects(circuit.verifyTransaction("third"), (error) => error.code === "STOREKIT_VERIFICATION_UNAVAILABLE");
  assert.equal(failures, 2, "the third call must fail before entering the verifier");
});

test("identical in-flight StoreKit checks keep cancellation and work ownership independent", async () => {
  const now = 2_000_000_000_000;
  const transaction = { transactionId: "tx", originalTransactionId: "original", bundleId: "com.example.LocalLingo", productId: "pro.monthly", type: "Auto-Renewable Subscription", inAppOwnershipType: "PURCHASED", environment: "Sandbox", expiresDate: now + 60_000, signedDate: now - 1_000 };
  const verifier = { async verifyAndDecodeTransaction() { return transaction; }, async verifyAndDecodeRenewalInfo() { throw new Error("unused"); }, async verifyAndDecodeNotification() { throw new Error("unused"); } };
  const pending = [];
  const statusClient = { async getAllSubscriptionStatuses(_id, _statuses, signal) {
    return new Promise((resolve, reject) => {
      const abort = () => reject(new Error("aborted"));
      signal?.addEventListener("abort", abort, { once: true });
      pending.push({ resolve, signal });
    });
  } };
  const service = new ProductionStoreKitService({ bundleID: "com.example.LocalLingo", appAppleID: 123, environment: "Sandbox", allowedProductIDs: ["pro.monthly", "pro.annual"], rootCertificatesPEM: [], signingKey: "", keyID: "", issuerID: "" }, { verifier, statusClient, now: () => now });
  const firstController = new AbortController(), secondController = new AbortController();
  const first = service.verifyTransaction("same-client-jws", firstController.signal);
  const second = service.verifyTransaction("same-client-jws", secondController.signal);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(pending.length, 2); assert.notEqual(pending[0].signal, pending[1].signal);
  firstController.abort();
  await assert.rejects(first, (error) => error.code === "REQUEST_DEADLINE_EXCEEDED");
  pending[1].resolve({ environment: "Sandbox", bundleId: "com.example.LocalLingo", data: [{ lastTransactions: [{ status: 1, originalTransactionId: "original", signedTransactionInfo: "current" }] }] });
  assert.equal((await second).status, "active", "one caller's cancellation must not affect another caller's live check");
});

test("reviewed StoreKit 3.1.0 OCSP patch is hash locked", () => {
  const bytes = readFileSync(new URL("../node_modules/@apple/app-store-server-library/dist/jws_verification.js", import.meta.url));
  assert.equal(createHash("sha256").update(bytes).digest("hex"), "a2cd5257b500600fa804bf4ab39658e7b3d6c722c8405497d2372addb23183bc");
  const source = bytes.toString("utf8");
  assert.match(source, /const deadline = AbortSignal\.timeout\(6000\)/);
  assert.match(source, /timeout: 6000,\s+size: 64 \* 1024,\s+redirect: 'follow',\s+follow: 1,\s+signal: deadline/);
  assert.match(source, /responseBuffer = await response\.buffer\(\);\s+}\s+catch/);
});

test("StoreKit notifications apply status, grace, consumption, and Family revoke policy", async () => {
  const now = 2_000_000_000_000;
  let outer;
  const purchased = { transactionId: "tx", originalTransactionId: "original", bundleId: "com.example.LocalLingo", productId: "pro.monthly", type: "Auto-Renewable Subscription", inAppOwnershipType: "PURCHASED", environment: "Sandbox", expiresDate: now + 60_000, signedDate: now - 1_000 };
  const verifier = {
    async verifyAndDecodeTransaction() { return outer.notificationType === "REVOKE" ? { ...purchased, inAppOwnershipType: "FAMILY_SHARED" } : purchased; },
    async verifyAndDecodeRenewalInfo() { return { environment: "Sandbox", originalTransactionId: "original", productId: "pro.monthly", gracePeriodExpiresDate: now + 120_000, signedDate: now - 500 }; },
    async verifyAndDecodeNotification() { return outer; }
  };
  const statusClient = { async getAllSubscriptionStatuses() { throw new Error("unused"); } };
  const service = new ProductionStoreKitService({ bundleID: "com.example.LocalLingo", appAppleID: 123, environment: "Sandbox", allowedProductIDs: ["pro.monthly", "pro.annual"], rootCertificatesPEM: [], signingKey: "", keyID: "", issuerID: "" }, { verifier, statusClient, now: () => now });
  const data = { environment: "Sandbox", bundleId: "com.example.LocalLingo", signedTransactionInfo: "transaction" };
  outer = { notificationType: "DID_RENEW", notificationUUID: "active", signedDate: now, data: { ...data, status: 1 } };
  assert.equal((await service.processNotification("payload")).evidence.status, "active");
  outer = { notificationType: "DID_FAIL_TO_RENEW", notificationUUID: "grace", signedDate: now, data: { ...data, status: 4, signedRenewalInfo: "renewal" } };
  assert.equal((await service.processNotification("payload")).evidence.status, "grace-period");
  outer = { notificationType: "DID_FAIL_TO_RENEW", notificationUUID: "retry", signedDate: now, data: { ...data, status: 3 } };
  assert.equal((await service.processNotification("payload")).evidence.status, "expired");
  outer = { notificationType: "CONSUMPTION_REQUEST", notificationUUID: "consumption", signedDate: now, data };
  assert.deepEqual(await service.processNotification("payload"), { notificationID: "consumption", signedAt: now });
  outer = { notificationType: "REVOKE", notificationUUID: "family", signedDate: now, data: { ...data, status: 5 } };
  assert.equal((await service.processNotification("payload")).evidence.status, "expired");
  outer = { notificationType: "REFUND", notificationUUID: "inconsistent-terminal", signedDate: now, data: { ...data, status: 1 } };
  assert.equal((await service.processNotification("payload")).evidence.status, "expired", "terminal notification type wins over contradictory status");
});

test("Google metadata token refresh is shared without sharing caller cancellation", async () => {
  const originalFetch = globalThis.fetch;
  let resolveRefresh, calls = 0, refreshSignal;
  globalThis.fetch = async (_url, init) => {
    calls += 1; refreshSignal = init.signal;
    return new Promise((resolve) => { resolveRefresh = resolve; });
  };
  try {
    const tokens = new MetadataAccessTokenProvider();
    const firstController = new AbortController(), secondController = new AbortController();
    const first = tokens.getToken(firstController.signal), second = tokens.getToken(secondController.signal);
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(calls, 1); assert.notEqual(refreshSignal, firstController.signal); assert.notEqual(refreshSignal, secondController.signal);
    firstController.abort();
    await assert.rejects(first, (error) => error.code === "UPSTREAM_REQUEST_ABORTED");
    resolveRefresh(new Response('{"access_token":"shared-google-token","expires_in":300}', { status: 200 }));
    assert.equal(await second, "shared-google-token");
    assert.equal(await tokens.getToken(), "shared-google-token"); assert.equal(calls, 1);
  } finally { globalThis.fetch = originalFetch; }
});

test("Google translation uses the US multi-region endpoint and opens a stage-specific circuit", async () => {
  assert.equal(translationEndpoint("project-1", "us-central1"), "https://translate-us.googleapis.com/v3/projects/project-1/locations/us-central1:translateText");
  const originalFetch = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async () => { calls += 1; return new Response("{}", { status: 500, headers: { "content-type": "application/json" } }); };
  try {
    const tokens = { async getToken() { return "token"; }, async ready() { return true; } };
    const provider = new GoogleTranslationProvider({ projectID: "project-1", sttLocation: "us", translationLocation: "us-central1", speechTimeoutMs: 1_000, translationTimeoutMs: 1_000 }, tokens);
    const input = { sourceLocale: "en-US", targetLocale: "es-ES", text: "Hello", signal: new AbortController().signal };
    for (let index = 0; index < 3; index += 1) await assert.rejects(provider.translateText(input), (error) => error.code === "PROVIDER_ERROR");
    await assert.rejects(provider.translateText(input), (error) => error.code === "PROVIDER_CIRCUIT_OPEN");
    assert.equal(calls, 3);
    assert.equal(await provider.ready(), false);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("Google semantic failures share circuit state across concurrent HTTP 200 responses", async () => {
  const originalFetch = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async () => { calls += 1; return new Response("{}", { status: 200, headers: { "content-type": "application/json" } }); };
  try {
    const tokens = { async getToken() { return "token"; }, async ready() { return true; } };
    const provider = new GoogleTranslationProvider({ projectID: "project-1", sttLocation: "us", translationLocation: "us-central1", speechTimeoutMs: 1_000, translationTimeoutMs: 1_000 }, tokens);
    const input = { sourceLocale: "en-US", targetLocale: "es-ES", text: "Hello", signal: new AbortController().signal };
    const failures = await Promise.allSettled([provider.translateText(input), provider.translateText(input), provider.translateText(input)]);
    assert.equal(failures.every((value) => value.status === "rejected" && value.reason.code === "PROVIDER_ERROR"), true);
    await assert.rejects(provider.translateText(input), (error) => error.code === "PROVIDER_CIRCUIT_OPEN");
    assert.equal(calls, 3); assert.equal(await provider.ready(), false);
  } finally { globalThis.fetch = originalFetch; }
});

test("a stale successful Google call cannot resurrect a circuit opened by newer failures", async () => {
  const originalFetch = globalThis.fetch;
  const pending = [];
  globalThis.fetch = async () => new Promise((resolve) => pending.push(resolve));
  try {
    const tokens = { async getToken() { return "token"; }, async ready() { return true; } };
    const provider = new GoogleTranslationProvider({ projectID: "project-1", sttLocation: "us", translationLocation: "us-central1", speechTimeoutMs: 1_000, translationTimeoutMs: 1_000 }, tokens);
    const input = { sourceLocale: "en-US", targetLocale: "es-ES", text: "Hello", signal: new AbortController().signal };
    const calls = Array.from({ length: 4 }, () => provider.translateText(input));
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(pending.length, 4);
    for (let index = 0; index < 3; index += 1) pending[index](new Response("{}", { status: 200 }));
    const failures = await Promise.allSettled(calls.slice(0, 3));
    assert.equal(failures.every((value) => value.status === "rejected" && value.reason.code === "PROVIDER_ERROR"), true);

    pending[3](new Response('{"translations":[{"translatedText":"Hola"}]}', { status: 200 }));
    assert.equal((await calls[3]).translatedText, "Hola");
    await assert.rejects(provider.translateText(input), (error) => error.code === "PROVIDER_CIRCUIT_OPEN");
    assert.equal(pending.length, 4, "an open circuit must reject before starting another upstream call");
  } finally { globalThis.fetch = originalFetch; }
});

test("Google non-success response bodies are terminally consumed", async () => {
  const originalFetch = globalThis.fetch;
  let response;
  globalThis.fetch = async () => { response = new Response("provider detail", { status: 500 }); return response; };
  try {
    const tokens = { async getToken() { return "token"; }, async ready() { return true; } };
    const provider = new GoogleTranslationProvider({ projectID: "project-1", sttLocation: "us", translationLocation: "us-central1", speechTimeoutMs: 1_000, translationTimeoutMs: 1_000 }, tokens);
    await assert.rejects(provider.translateText({ sourceLocale: "en-US", targetLocale: "es-ES", text: "Hello", signal: new AbortController().signal }), (error) => error.code === "PROVIDER_ERROR");
    assert.equal(response.bodyUsed, true);
  } finally { globalThis.fetch = originalFetch; }
});

test("caller cancellations do not open the Google provider circuit", async () => {
  const tokens = { async getToken() { return "token"; }, async ready() { return true; } };
  const provider = new GoogleTranslationProvider({ projectID: "project-1", sttLocation: "us", translationLocation: "us-central1", speechTimeoutMs: 1_000, translationTimeoutMs: 1_000 }, tokens);
  for (let index = 0; index < 3; index += 1) {
    const controller = new AbortController(); controller.abort();
    await assert.rejects(provider.translateText({ sourceLocale: "en-US", targetLocale: "es-ES", text: "Hello", signal: controller.signal }), (error) => error.code === "UPSTREAM_REQUEST_ABORTED");
  }
  assert.equal(await provider.ready(), true);
});

test("Google response-stream failures are sanitized provider errors", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response(new ReadableStream({ start(controller) { controller.error(new Error("stream failed")); } }), { status: 200 });
  try {
    const tokens = { async getToken() { return "token"; }, async ready() { return true; } };
    const provider = new GoogleTranslationProvider({ projectID: "project-1", sttLocation: "us", translationLocation: "us-central1", speechTimeoutMs: 1_000, translationTimeoutMs: 1_000 }, tokens);
    await assert.rejects(provider.translateText({ sourceLocale: "en-US", targetLocale: "es-ES", text: "Hello", signal: new AbortController().signal }), (error) => error.code === "PROVIDER_UNAVAILABLE" && !String(error.message).includes("stream failed"));
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("Firestore metadata token refresh is shared without sharing caller cancellation", async () => {
  const originalFetch = globalThis.fetch;
  let resolveRefresh, calls = 0, refreshSignal;
  globalThis.fetch = async (_url, init) => {
    calls += 1; refreshSignal = init.signal;
    return new Promise((resolve) => { resolveRefresh = resolve; });
  };
  try {
    const tokens = new MetadataTokenProvider();
    const firstController = new AbortController(), secondController = new AbortController();
    const first = tokens.token(firstController.signal), second = tokens.token(secondController.signal);
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(calls, 1); assert.notEqual(refreshSignal, firstController.signal); assert.notEqual(refreshSignal, secondController.signal);
    firstController.abort();
    await assert.rejects(first, (error) => error.code === "REQUEST_DEADLINE_EXCEEDED");
    resolveRefresh(new Response('{"access_token":"shared-firestore-token","expires_in":300}', { status: 200 }));
    assert.equal(await second, "shared-firestore-token");
    assert.equal(await tokens.token(), "shared-firestore-token"); assert.equal(calls, 1);
  } finally { globalThis.fetch = originalFetch; }
});

test("Firestore rolls back a rejected pessimistic transaction", async () => {
  const originalFetch = globalThis.fetch, calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), init });
    if (String(url).endsWith(":beginTransaction")) return new Response('{"transaction":"tx-1"}', { status: 200 });
    if (String(url).endsWith(":rollback")) return new Response("{}", { status: 200 });
    if (init.method === "GET" && String(url).includes("online_quotas/i-")) return new Response(JSON.stringify({ name: "quota", updateTime: "2026-01-01T00:00:00Z", fields: { payload: { stringValue: JSON.stringify({ count: 1, expiresAt: Date.now() + 60_000 }) } } }), { status: 200 });
    if (init.method === "GET") return new Response("{}", { status: 404 });
    throw new Error(`unexpected request ${url}`);
  };
  try {
    const store = new FirestoreSecurityStore({ projectID: "project-1", database: "(default)" }, { async token() { return "token"; } });
    await assert.rejects(store.consumeQuota({ keyIDHash: "key", originalTransactionIDHash: "entitlement", now: Date.now(), installationPerMinute: 1, entitlementPerMinute: 2, entitlementPerDay: 3 }), (error) => error.code === "QUOTA_EXCEEDED");
    assert.equal(calls.some((value) => value.url.endsWith(":rollback")), true);
    assert.equal(calls.some((value) => value.url.endsWith(":commit")), false);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("Firestore commits binding, session and challenge pool atomically", async () => {
  const originalFetch = globalThis.fetch;
  let commit;
  const now = Date.now();
  globalThis.fetch = async (url, init) => {
    if (String(url).endsWith(":beginTransaction")) return new Response('{"transaction":"tx-2"}', { status: 200 });
    if (init.method === "GET" && String(url).includes("subscription_device_bindings")) return new Response(JSON.stringify({ updateTime: "2026-01-01T00:00:00Z", fields: { payload: { stringValue: JSON.stringify({ bindings: { key: now + 100 } }) } } }), { status: 200 });
    if (init.method === "GET") return new Response("{}", { status: 404 });
    if (String(url).endsWith(":commit")) { commit = JSON.parse(init.body); return new Response("{}", { status: 200 }); }
    throw new Error(`unexpected request ${url}`);
  };
  try {
    const store = new FirestoreSecurityStore({ projectID: "project-1", database: "(default)" }, { async token() { return "token"; } });
    const sessionRecord = { tokenHash: "token", keyIDHash: "key", originalTransactionIDHash: "entitlement", createdAt: now, expiresAt: now + 900_000 };
    const established = await store.establishSessionWithEvidence({ keyIDHash: "key", originalTransactionIDHash: "entitlement", evidence: liveEvidence("entitlement", now - 100, now, "active", now + 86_400_000), now, maximumDevices: 3, inactiveAfterMs: 30 * 86_400_000, challengeCount: 8, challengeTtlMs: 120_000, maximumPoolsPerMinute: 4, session: sessionRecord });
    assert.equal(established.authorized, true); assert.equal(established.challenges.length, 8);
    assert.equal(commit.writes.length, 12);
    assert.equal(commit.writes.some((write) => write.update.name.includes("/storekit_entitlements/entitlement")), true);
    assert.equal(commit.writes.some((write) => write.update.name.includes("/online_sessions/token")), true);
    const binding = commit.writes.find((write) => write.update.name.includes("/subscription_device_bindings/entitlement"));
    assert.equal(JSON.parse(binding.update.fields.payload.stringValue).bindings.key, now + 100, "a stale retry must not regress binding activity");
    assert.equal(commit.writes.filter((write) => write.update.name.includes("/app_attest_session_challenges/")).length, 8);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("Firestore replacement writes the binding and evicted-key revocation in one commit", async () => {
  const originalFetch = globalThis.fetch;
  let commit;
  const now = Date.now();
  globalThis.fetch = async (url, init) => {
    const value = String(url);
    if (value.endsWith(":beginTransaction")) return new Response('{"transaction":"tx-replace"}', { status: 200 });
    if (init.method === "GET" && value.includes("subscription_device_bindings")) {
      return new Response(JSON.stringify({ updateTime: "2026-01-01T00:00:00Z", fields: { payload: { stringValue: JSON.stringify({ bindings: { oldest: now - 30, middle: now - 20, newest: now - 10 } }) } } }), { status: 200 });
    }
    if (init.method === "GET" && value.includes("key_revocations")) return new Response(JSON.stringify({ updateTime: "2026-01-01T00:00:00Z", fields: { payload: { stringValue: JSON.stringify({ revokedAt: now + 100 }) } } }), { status: 200 });
    if (init.method === "GET") return new Response("{}", { status: 404 });
    if (value.endsWith(":commit")) { commit = JSON.parse(init.body); return new Response("{}", { status: 200 }); }
    throw new Error(`unexpected request ${url}`);
  };
  try {
    const store = new FirestoreSecurityStore({ projectID: "project-1", database: "(default)" }, { async token() { return "token"; } });
    await store.replaceOldestInstallationWithEvidence({ originalTransactionIDHash: "entitlement", keyIDHash: "replacement", evidence: liveEvidence("entitlement", now - 100, now, "active", now + 86_400_000), now, maximumDevices: 3, inactiveAfterMs: 30 * 86_400_000 });
    assert.equal(commit.writes.length, 3);
    const binding = commit.writes.find((write) => write.update.name.includes("subscription_device_bindings"));
    const payload = JSON.parse(binding.update.fields.payload.stringValue);
    assert.deepEqual(Object.keys(payload.bindings).sort(), ["middle", "newest", "replacement"]);
    const revocation = commit.writes.find((write) => write.update.name.includes("/key_revocations/oldest"));
    assert.equal(JSON.parse(revocation.update.fields.payload.stringValue).revokedAt, now + 100, "a stale retry must not lower an existing tombstone");
  } finally { globalThis.fetch = originalFetch; }
});

test("Firestore deduplicates and applies notification evidence in one commit", async () => {
  const originalFetch = globalThis.fetch;
  let commit;
  globalThis.fetch = async (url, init) => {
    const value = String(url);
    if (value.endsWith(":beginTransaction")) return new Response('{"transaction":"tx-notification"}', { status: 200 });
    if (init.method === "GET") return new Response("{}", { status: 404 });
    if (value.endsWith(":commit")) { commit = JSON.parse(init.body); return new Response("{}", { status: 200 }); }
    throw new Error(`unexpected request ${url}`);
  };
  try {
    const store = new FirestoreSecurityStore({ projectID: "project-1", database: "(default)" }, { async token() { return "token"; } });
    const applied = await store.applyNotification({ notificationID: "uuid", payloadHash: "payload-hash", signedAt: 200, receivedAt: 300, evidence: notificationEvidence("entitlement", 200, "expired") });
    assert.equal(applied, true); assert.equal(commit.writes.length, 2);
    assert.equal(commit.writes.some((write) => write.update.name.includes("/storekit_notification_deduplication/")), true);
    const entitlement = commit.writes.find((write) => write.update.name.includes("/storekit_entitlements/entitlement"));
    assert.equal(JSON.parse(entitlement.update.fields.payload.stringValue).status, "expired");
  } finally { globalThis.fetch = originalFetch; }
});

test("Firestore consumes successful and missing-document response bodies", async () => {
  const originalFetch = globalThis.fetch, responses = [];
  globalThis.fetch = async (_url, init) => {
    const response = init.method === "GET" ? new Response('{"error":"missing"}', { status: 404 }) : new Response('{"created":true}', { status: 200 });
    responses.push(response);
    return response;
  };
  try {
    const store = new FirestoreSecurityStore({ projectID: "project-1", database: "(default)" }, { async token() { return "token"; } });
    assert.equal(await store.getRegisteredKey("missing"), undefined);
    await store.putRegisteredKey({ keyIDHash: "key", publicKeyPem: "pem", counter: 0, environment: "development", createdAt: 1, updatedAt: 1 });
    assert.equal(responses.every((response) => response.bodyUsed), true);
  } finally { globalThis.fetch = originalFetch; }
});

test("v1 routes are gone and errors never echo request content", async (t) => {
  const { app } = await fixture(); t.after(() => app.close());
  assert.equal((await app.inject({ method: "POST", url: "/v1/translate-turn" })).statusCode, 404);
  const response = await app.inject({ method: "POST", url: "/v2/app-attest/challenge", payload: { purpose: "register", keyID: "secret phrase" } });
  assert.equal(response.statusCode, 400); assert.doesNotMatch(response.body, /secret phrase/);
});

test("production config defaults fail closed and rejects non-US/provider identities", () => {
  assert.throws(() => readConfig({}), /GOOGLE_CLOUD_PROJECT is required/);
  assert.throws(() => readConfig({ RUNTIME_MODE: "development" }), /deployed server/);
  assert.throws(() => readTestConfig({ GOOGLE_STT_LOCATION: "global" }), /exactly us/);
  assert.throws(() => readTestConfig({ GOOGLE_STT_LOCATION: "us-fake" }), /exactly us/);
  assert.throws(() => readTestConfig({ GOOGLE_TRANSLATION_LOCATION: "us-fake" }), /exactly us-central1/);
  const certificate = "-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----";
  const signingKey = generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey.export({ type: "pkcs8", format: "pem" }).toString();
  const deployed = { RUNTIME_MODE: "staging", GOOGLE_CLOUD_PROJECT: "staging", FIRESTORE_PROJECT: "staging", RELEASE_BUILD_ID: "candidate-1", BACKEND_OCI_DIGEST: `sha256:${"a".repeat(64)}`, K_REVISION: "translator-00001-abc", APPLE_TEAM_ID: "ABCDE12345", APPLE_APP_ID_PREFIX: "ABCDE12345", APPLE_BUNDLE_ID: "com.example.staging", APPLE_APP_STORE_ID: "123", APP_ATTEST_ENVIRONMENT: "development", APPLE_STOREKIT_ENVIRONMENT: "Sandbox", APPLE_APP_ATTEST_ROOT_CA_PEM: certificate, APPLE_STOREKIT_ROOT_CA_PEMS: certificate, APPLE_IAP_SIGNING_KEY_P8: signingKey, APPLE_IAP_KEY_ID: "ABCDEFGHIJ", APPLE_IAP_ISSUER_ID: "00000000-0000-4000-8000-000000000000", ALLOWED_PRODUCT_IDS: "com.example.pro.monthly,com.example.pro.annual", ALLOWED_APP_BUNDLE_VERSIONS: "1" };
  const staging = readConfig(deployed);
  assert.equal(staging.runtimeMode, "staging");
  assert.equal(staging.sessionAttemptsPerMinute, 6); assert.equal(staging.storeKitSessionConcurrency, 2); assert.equal(staging.storeKitNotificationConcurrency, 1);
  assert.throws(() => readTestConfig({ CHALLENGE_TTL_MS: "89999" }), /90000/);
  assert.throws(() => readTestConfig({ SESSION_ATTEMPTS_PER_MINUTE: "0" }), /SESSION_ATTEMPTS_PER_MINUTE/);
  assert.throws(() => readTestConfig({ STOREKIT_SESSION_CONCURRENCY: "9" }), /STOREKIT_SESSION_CONCURRENCY/);
  assert.throws(() => readTestConfig({ STOREKIT_NOTIFICATION_CONCURRENCY: "3", STOREKIT_NOTIFICATION_MAXIMUM_OUTSTANDING: "2" }), /must be at least/);
  const invalidPrivateKey = "-----BEGIN " + "PRIVATE KEY-----\ninvalid\n-----END " + "PRIVATE KEY-----";
  assert.throws(() => readConfig({ ...deployed, APPLE_IAP_SIGNING_KEY_P8: invalidPrivateKey }), /EC P-256/);
  const testflight = readConfig({ ...deployed, RUNTIME_MODE: "testflight", APPLE_BUNDLE_ID: "com.example.beta", APP_ATTEST_ENVIRONMENT: "production" });
  assert.deepEqual(testflight.allowedAppAttestValidationCategories, [2]);
});
