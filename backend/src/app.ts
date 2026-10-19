import { createHash, randomBytes, randomUUID } from "node:crypto";
import { TextDecoder } from "node:util";
import Fastify, { type FastifyInstance, type FastifyRequest } from "fastify";
import type { AppAttestService, ChallengePurpose, SecurityStore, StoreKitNotificationEvent, StoreKitService, SupportedLocale, TranslationProvider } from "./contracts.js";
import { SUPPORTED_LOCALES } from "./contracts.js";
import type { Config } from "./config.js";
import { ApiError, asApiError } from "./errors.js";
import { canonicalRequestDigest, sha256Base64URL } from "./protocol.js";
import { FixedWindowRateLimiter } from "./rate-limit.js";
import { parseCanonicalPCM16Wav } from "./wav.js";
import { appAttestKeyIDHash, decodeCanonicalAppAttestKeyID } from "./app-attest-key.js";

export { canonicalRequestDigest } from "./protocol.js";

export interface AppDependencies {
  config: Config;
  provider: TranslationProvider;
  appAttest: AppAttestService;
  storeKit: StoreKitService;
  store: SecurityStore;
  logRequests?: boolean;
}

const utf8 = new TextDecoder("utf-8", { fatal: true });

function bufferBody(request: FastifyRequest): Buffer {
  if (!Buffer.isBuffer(request.body)) throw new ApiError(400, "INVALID_BODY", "Request body is invalid");
  return request.body;
}

function jsonObject(request: FastifyRequest, maximumBytes: number): { raw: Buffer; value: Record<string, unknown> } {
  const raw = bufferBody(request);
  if (raw.length === 0 || raw.length > maximumBytes) throw new ApiError(raw.length > maximumBytes ? 413 : 400, raw.length > maximumBytes ? "PAYLOAD_TOO_LARGE" : "INVALID_JSON", "JSON request body is invalid");
  let value: unknown;
  try { value = JSON.parse(utf8.decode(raw)); } catch { throw new ApiError(400, "INVALID_JSON", "JSON request body is invalid"); }
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new ApiError(400, "INVALID_JSON", "JSON request body must be an object");
  return { raw, value: value as Record<string, unknown> };
}

function exactKeys(value: Record<string, unknown>, expected: readonly string[]): void {
  const keys = Object.keys(value).sort(), allowed = [...expected].sort();
  if (keys.length !== allowed.length || keys.some((key, index) => key !== allowed[index])) throw new ApiError(400, "INVALID_FIELDS", "Request contains missing or unknown fields");
}

function requiredString(value: unknown, name: string, maximum: number): string {
  if (typeof value !== "string" || !value.trim() || Buffer.byteLength(value, "utf8") > maximum) throw new ApiError(400, "INVALID_FIELD", `${name} is invalid`);
  return value;
}

function keyID(value: unknown): string {
  const result = requiredString(value, "keyID", 256);
  try { decodeCanonicalAppAttestKeyID(result); }
  catch { throw new ApiError(400, "INVALID_APP_ATTEST_KEY_ID", "App Attest key ID is invalid"); }
  return result;
}

function locale(value: unknown, name: string): SupportedLocale {
  if (typeof value !== "string" || !(SUPPORTED_LOCALES as readonly string[]).includes(value)) throw new ApiError(400, "UNSUPPORTED_LOCALE", `${name} is unsupported`);
  return value as SupportedLocale;
}

function languagePair(request: FastifyRequest): { sourceLocale: SupportedLocale; targetLocale: SupportedLocale } {
  const sourceLocale = locale(request.headers["x-source-locale"], "sourceLocale");
  const targetLocale = locale(request.headers["x-target-locale"], "targetLocale");
  if (sourceLocale === targetLocale) throw new ApiError(400, "INVALID_LANGUAGE_PAIR", "Source and target locales must differ");
  return { sourceLocale, targetLocale };
}

function strictBase64(value: unknown, name: string, maximumBytes: number): Buffer {
  if (typeof value !== "string" || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) throw new ApiError(400, "INVALID_BASE64", `${name} must be padded standard base64`);
  const result = Buffer.from(value, "base64");
  if (result.length === 0 || result.length > maximumBytes) throw new ApiError(400, "INVALID_BASE64", `${name} has an invalid size`);
  return result;
}

function bearer(request: FastifyRequest): string {
  const match = /^Bearer ([A-Za-z0-9_-]{43})$/.exec(request.headers.authorization ?? "");
  if (!match) throw new ApiError(401, "SESSION_REQUIRED", "A valid online session is required");
  return match[1]!;
}

function attestationHeaders(request: FastifyRequest): { keyID: string; assertion: Buffer; challengeToken: string } {
  const rawKey = request.headers["x-app-attest-key-id"];
  const rawAssertion = request.headers["x-app-attest-assertion"];
  const rawChallenge = request.headers["x-app-attest-challenge-token"];
  return {
    keyID: keyID(rawKey),
    assertion: strictBase64(rawAssertion, "X-App-Attest-Assertion", 4_096),
    challengeToken: requiredString(rawChallenge, "X-App-Attest-Challenge-Token", 256)
  };
}

function emptyBody(request: FastifyRequest): Buffer {
  if (request.body === undefined || request.body === null) return Buffer.alloc(0);
  const body = bufferBody(request);
  if (body.length !== 0) throw new ApiError(400, "BODY_NOT_ALLOWED", "This request must have an empty body");
  return body;
}

interface RequestOperation { signal: AbortSignal; disconnected: AbortSignal; cleanup: () => void; }

interface BoundBuildIdentity {
  releaseBuildID: string;
  backendOCIDigest: string;
  runtimeEnvironment: string;
  cloudRunRevision: string;
}

function buildIdentityHeaders(request: FastifyRequest, config: Config): BoundBuildIdentity {
  const releaseBuildID = request.headers["x-locallingo-release-build-id"];
  const backendOCIDigest = request.headers["x-locallingo-backend-oci-digest"];
  const runtimeEnvironment = request.headers["x-locallingo-runtime-environment"];
  const cloudRunRevision = request.headers["x-locallingo-cloud-run-revision"];
  if (
    typeof releaseBuildID !== "string" || Buffer.byteLength(releaseBuildID, "utf8") > 128 || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(releaseBuildID) ||
    typeof backendOCIDigest !== "string" || Buffer.byteLength(backendOCIDigest, "utf8") !== 71 || !/^sha256:[0-9a-f]{64}$/.test(backendOCIDigest) ||
    typeof runtimeEnvironment !== "string" || Buffer.byteLength(runtimeEnvironment, "utf8") > 11 || !/^(?:production|testflight|staging|development|test)$/.test(runtimeEnvironment) ||
    typeof cloudRunRevision !== "string" || Buffer.byteLength(cloudRunRevision, "utf8") > 63 || !/^[a-z][a-z0-9-]{0,62}$/.test(cloudRunRevision)
  ) throw new ApiError(400, "INVALID_BUILD_IDENTITY_HEADER", "Build identity headers are missing or invalid");
  if (
    releaseBuildID !== config.releaseBuildID ||
    backendOCIDigest !== config.backendOCIDigest ||
    runtimeEnvironment !== config.runtimeMode ||
    cloudRunRevision !== config.cloudRunRevision
  ) throw new ApiError(409, "BUILD_IDENTITY_MISMATCH", "The app and backend build identities do not match");
  return { releaseBuildID, backendOCIDigest, runtimeEnvironment, cloudRunRevision };
}

export class SettlingSemaphore {
  private active = 0;
  private readonly waiting: Array<{ signal: AbortSignal; start: () => void; cancel: () => void }> = [];
  constructor(private readonly maximum: number, private readonly maximumOutstanding = Number.MAX_SAFE_INTEGER) {
    if (!Number.isInteger(maximum) || maximum < 1) throw new Error("Semaphore maximum must be positive");
    if (!Number.isInteger(maximumOutstanding) || maximumOutstanding < maximum) throw new Error("Semaphore outstanding limit must be at least its concurrency");
  }
  get activeCount(): number { return this.active; }
  get queuedCount(): number { return this.waiting.length; }

  run<T>(signal: AbortSignal, operation: () => Promise<T>, abortedError: () => Error): Promise<T> {
    if (this.active + this.waiting.length >= this.maximumOutstanding) {
      return Promise.reject(new ApiError(503, "STOREKIT_BUSY", "Subscription verification is busy; retry shortly"));
    }
    return new Promise<T>((resolve, reject) => {
      let entry: { signal: AbortSignal; start: () => void; cancel: () => void };
      const release = () => { this.active -= 1; this.drain(); };
      const start = () => {
        signal.removeEventListener("abort", entry.cancel);
        if (signal.aborted) { reject(abortedError()); this.drain(); return; }
        this.active += 1;
        let underlying: Promise<T>;
        try { underlying = operation(); }
        catch (error) { release(); reject(error); return; }
        void underlying.then(
          (value) => { release(); resolve(value); },
          (error: unknown) => { release(); reject(error); }
        );
      };
      const cancel = () => {
        const index = this.waiting.indexOf(entry);
        if (index >= 0) this.waiting.splice(index, 1);
        signal.removeEventListener("abort", cancel);
        reject(abortedError());
        this.drain();
      };
      entry = { signal, start, cancel };
      if (signal.aborted) { reject(abortedError()); return; }
      if (this.active < this.maximum) start();
      else { this.waiting.push(entry); signal.addEventListener("abort", cancel, { once: true }); }
    });
  }

  private drain(): void {
    while (this.active < this.maximum && this.waiting.length > 0) this.waiting.shift()!.start();
  }
}

/** Content-free, bounded cache for successfully verified notification payload hashes. */
export class StoreKitNotificationCache {
  private readonly successful = new Map<string, { event: StoreKitNotificationEvent; expiresAt: number }>();
  private readonly inFlight = new Map<string, Promise<StoreKitNotificationEvent>>();
  constructor(private readonly maximum = 512, private readonly ttlMs = 24 * 60 * 60 * 1_000) {}

  async verify(payloadHash: string, now: number, work: () => Promise<StoreKitNotificationEvent>): Promise<StoreKitNotificationEvent> {
    const cached = this.successful.get(payloadHash);
    if (cached && cached.expiresAt > now) {
      this.successful.delete(payloadHash);
      this.successful.set(payloadHash, cached);
      return cached.event;
    }
    if (cached) this.successful.delete(payloadHash);
    const running = this.inFlight.get(payloadHash);
    if (running) return running;
    const promise = work().then((event) => {
      this.successful.set(payloadHash, { event, expiresAt: now + this.ttlMs });
      while (this.successful.size > this.maximum) this.successful.delete(this.successful.keys().next().value!);
      return event;
    }).finally(() => this.inFlight.delete(payloadHash));
    this.inFlight.set(payloadHash, promise);
    return promise;
  }
}

function requestAbort(request: FastifyRequest, deadlineMs: number): RequestOperation {
  const deadline = AbortSignal.timeout(deadlineMs);
  const disconnected = new AbortController();
  const listener = () => disconnected.abort();
  request.raw.once("aborted", listener);
  request.raw.socket?.once("close", listener);
  return { signal: AbortSignal.any([deadline, disconnected.signal]), disconnected: disconnected.signal, cleanup: () => { request.raw.off("aborted", listener); request.raw.socket?.off("close", listener); } };
}

export async function buildApp(dependencies: AppDependencies): Promise<FastifyInstance> {
  const { config } = dependencies;
  const app = Fastify({ logger: false, trustProxy: false, bodyLimit: config.maxAudioBytes, genReqId: () => randomUUID() });
  const registrationLimiter = new FixedWindowRateLimiter(20, 60_000, 20_000);
  const storeKitSessionLimiter = new SettlingSemaphore(config.storeKitSessionConcurrency, config.storeKitSessionMaximumOutstanding);
  const storeKitNotificationLimiter = new SettlingSemaphore(config.storeKitNotificationConcurrency, config.storeKitNotificationMaximumOutstanding);
  const storeKitNotificationCache = new StoreKitNotificationCache();
  let availabilityCache: { available: boolean; expiresAt: number } | undefined;
  const operations = new WeakMap<FastifyRequest, RequestOperation>();
  const boundBuildIdentities = new WeakMap<FastifyRequest, BoundBuildIdentity>();
  const errorCodes = new WeakMap<FastifyRequest, string>();
  app.removeContentTypeParser("application/json");
  app.addContentTypeParser("application/json", { parseAs: "buffer" }, (_request, body, done) => done(null, body));
  app.addContentTypeParser("audio/wav", { parseAs: "buffer" }, (_request, body, done) => done(null, body));
  app.addHook("onRequest", async (request) => {
    operations.set(request, requestAbort(request, config.requestDeadlineMs));
    if (request.url.includes("?")) throw new ApiError(400, "QUERY_NOT_ALLOWED", "Query parameters are not accepted");
    const path = request.url;
    const attested = path === "/v2/session" || path === "/v2/devices/replace-oldest" || path === "/v2/session/challenges" || path === "/v2/translate-turn" || path === "/v2/translate-text" || path === "/v2/devices/current";
    if (attested) {
      boundBuildIdentities.set(request, buildIdentityHeaders(request, config));
      requireOnline();
      attestationHeaders(request);
      if (path !== "/v2/session" && path !== "/v2/devices/replace-oldest") bearer(request);
    }
    if (path === "/v2/translate-turn") {
      if ((request.headers["content-type"] ?? "").toLowerCase() !== "audio/wav") throw new ApiError(415, "UNSUPPORTED_MEDIA_TYPE", "Content-Type must be audio/wav");
      const declared = request.headers["content-length"];
      if (typeof declared !== "string") throw new ApiError(411, "CONTENT_LENGTH_REQUIRED", "Content-Length is required");
      if (!/^\d+$/.test(declared)) throw new ApiError(400, "INVALID_CONTENT_LENGTH", "Content-Length is invalid");
      if (Number(declared) > config.maxAudioBytes) throw new ApiError(413, "PAYLOAD_TOO_LARGE", "Audio exceeds the upload limit");
    }
  });
  app.addHook("onResponse", async (request) => operations.get(request)?.cleanup());
  app.addHook("onSend", async (request, reply, payload) => {
    reply.header("cache-control", "no-store");
    reply.header("x-content-type-options", "nosniff");
    reply.header("x-request-id", request.id);
    return payload;
  });

  function requireOnline(): void {
    if (!config.onlineEnabled) throw new ApiError(503, "ONLINE_DISABLED", "Online translation is temporarily unavailable");
  }

  function operation(request: FastifyRequest): RequestOperation {
    const value = operations.get(request);
    if (!value) throw new ApiError(500, "REQUEST_CONTEXT_MISSING", "Request context is unavailable");
    if (value.signal.aborted) {
      throw value.disconnected.aborted
        ? new ApiError(499, "CLIENT_CLOSED_REQUEST", "The client closed the request")
        : new ApiError(504, "REQUEST_DEADLINE_EXCEEDED", "The request deadline was exceeded");
    }
    return value;
  }

  function abortedError(current: RequestOperation): ApiError {
    return current.disconnected.aborted
      ? new ApiError(499, "CLIENT_CLOSED_REQUEST", "The client closed the request")
      : new ApiError(504, "REQUEST_DEADLINE_EXCEEDED", "The request deadline was exceeded");
  }

  async function withinRequest<T>(request: FastifyRequest, promise: Promise<T>): Promise<T> {
    const current = operation(request);
    return new Promise<T>((resolve, reject) => {
      const aborted = () => reject(abortedError(current));
      current.signal.addEventListener("abort", aborted, { once: true });
      promise.then(
        (value) => { current.signal.removeEventListener("abort", aborted); resolve(value); },
        (error: unknown) => { current.signal.removeEventListener("abort", aborted); reject(error); }
      );
    });
  }

  async function withinStoreKit<T>(request: FastifyRequest, lane: "session" | "notification", work: () => Promise<T>): Promise<T> {
    const current = operation(request);
    const limiter = lane === "session" ? storeKitSessionLimiter : storeKitNotificationLimiter;
    return withinRequest(request, limiter.run(current.signal, work, () => abortedError(current)));
  }

  async function issueChallenges(request: FastifyRequest, keyHash: string): Promise<Awaited<ReturnType<SecurityStore["createChallenge"]>>[]> {
    const signal = operation(request).signal;
    return withinRequest(request, dependencies.store.createSessionChallengePool(keyHash, config.challengePoolSize, config.challengeTtlMs, Date.now(), config.challengePoolRequestsPerMinute, signal));
  }

  async function verifyAttested(
    request: FastifyRequest,
    rawBody: Buffer,
    sourceLocale?: SupportedLocale,
    targetLocale?: SupportedLocale,
    requireSession = true
  ) {
    const signal = operation(request).signal;
    const headers = attestationHeaders(request), keyHash = appAttestKeyIDHash(headers.keyID);
    const sessionToken = requireSession ? bearer(request) : undefined;
    const session = sessionToken ? await withinRequest(request, dependencies.store.getSession(sha256Base64URL(sessionToken), Date.now(), signal)) : undefined;
    if (requireSession && (!session || session.keyIDHash !== keyHash)) throw new ApiError(401, "INVALID_SESSION", "Online session is invalid or expired");
    const challengePurpose: ChallengePurpose = requireSession ? "session-request" : "session-establishment";
    const challenge = await withinRequest(request, dependencies.store.consumeChallenge(headers.challengeToken, challengePurpose, keyHash, Date.now(), signal));
    const buildIdentity = boundBuildIdentities.get(request);
    if (!buildIdentity) throw new ApiError(500, "REQUEST_CONTEXT_MISSING", "Request context is unavailable");
    const digest = canonicalRequestDigest({ method: request.method, path: request.routeOptions.url ?? request.url, challenge, keyID: headers.keyID, ...buildIdentity, ...(sessionToken ? { sessionToken } : {}), ...(sourceLocale ? { sourceLocale } : {}), ...(targetLocale ? { targetLocale } : {}), body: rawBody });
    const registered = await withinRequest(request, dependencies.store.getRegisteredKey(keyHash, signal));
    if (!registered) throw new ApiError(401, "APP_ATTEST_KEY_NOT_REGISTERED", "App Attest key is not registered");
    if (registered.environment !== config.appAttestEnvironment) throw new ApiError(401, "APP_ATTEST_ENVIRONMENT_MISMATCH", "App Attest key environment is invalid");
    const nextCounter = await withinRequest(request, dependencies.appAttest.verifyAssertion(registered.publicKeyPem, headers.assertion, digest, registered.counter));
    await withinRequest(request, dependencies.store.advanceCounter(keyHash, registered.counter, nextCounter, Date.now(), signal));
    if (session) {
      const entitlement = await withinRequest(request, dependencies.store.getEntitlement(session.originalTransactionIDHash, signal));
      if (!entitlement || entitlement.expiresAt <= Date.now() || (entitlement.status !== "active" && entitlement.status !== "grace-period")) throw new ApiError(402, "SUBSCRIPTION_REQUIRED", "An active Pro subscription is required");
      return { keyHash, session, entitlement };
    }
    return { keyHash };
  }

  async function verifyCurrentEntitlement(request: FastifyRequest, keyHash: string, signedTransaction: string) {
    const signal = operation(request).signal;
    await withinRequest(request, dependencies.store.consumeSessionAttempt(keyHash, Date.now(), config.sessionAttemptsPerMinute, signal));
    return withinStoreKit(request, "session", () => dependencies.storeKit.verifyTransaction(signedTransaction, signal));
  }

  app.get("/livez", async (_request, reply) => reply.code(200).send({ status: "ok" }));
  app.get("/readyz", async (_request, reply) => {
    const [storeReady, providerReady] = await withinRequest(_request, Promise.all([dependencies.store.ready(operation(_request).signal), dependencies.provider.ready()]));
    return storeReady && providerReady ? reply.code(200).send({ status: "ready" }) : reply.code(503).send({ status: "unavailable" });
  });
  app.get("/v2/availability", async (request, reply) => {
    // These values are deployment-injected and therefore useful for routing
    // diagnostics, but a process cannot independently attest the image that is
    // running it. Trusted image/revision binding belongs to signed release
    // evidence built from the control plane, never this self-reported response.
    const buildIdentity = { releaseBuildID: config.releaseBuildID, ociDigest: config.backendOCIDigest, environment: config.runtimeMode, revision: config.cloudRunRevision, assurance: "self-reported-diagnostic" };
    if (!config.onlineEnabled) return { available: false, buildIdentity };
    if (availabilityCache && availabilityCache.expiresAt > Date.now()) return { available: availabilityCache.available, buildIdentity };
    const [storeReady, providerReady] = await withinRequest(request, Promise.all([dependencies.store.ready(operation(request).signal), dependencies.provider.ready()]));
    availabilityCache = { available: storeReady && providerReady, expiresAt: Date.now() + 30_000 };
    return { available: availabilityCache.available, buildIdentity };
  });

  app.post("/v2/app-attest/challenge", async (request, reply) => {
    const { value } = jsonObject(request, 1_024); exactKeys(value, ["purpose", "keyID"]);
    const purpose = value.purpose;
    if (purpose !== "register" && purpose !== "session") throw new ApiError(400, "INVALID_CHALLENGE_PURPOSE", "Challenge purpose is invalid");
    const rawKey = keyID(value.keyID), keyHash = appAttestKeyIDHash(rawKey);
    registrationLimiter.consume(keyHash);
    if (purpose === "session") requireOnline();
    const signal = operation(request).signal;
    const existing = await withinRequest(request, dependencies.store.getRegisteredKey(keyHash, signal));
    if (purpose === "register" && existing) throw new ApiError(409, "KEY_ALREADY_REGISTERED", "App Attest key is already registered");
    if (purpose === "session" && !existing) throw new ApiError(401, "APP_ATTEST_KEY_NOT_REGISTERED", "App Attest key is not registered");
    reply.header("cache-control", "no-store");
    const storedPurpose: ChallengePurpose = purpose === "register" ? "register" : "session-establishment";
    return reply.code(200).send(await withinRequest(request, dependencies.store.createChallenge(storedPurpose, keyHash, config.challengeTtlMs, signal)));
  });

  app.post("/v2/app-attest/register", async (request, reply) => {
    const { value } = jsonObject(request, 512 * 1024); exactKeys(value, ["keyID", "attestationObject", "challengeToken"]);
    const rawKey = keyID(value.keyID), keyHash = appAttestKeyIDHash(rawKey);
    registrationLimiter.consume(keyHash);
    const challengeToken = requiredString(value.challengeToken, "challengeToken", 256);
    const signal = operation(request).signal;
    const challenge = await withinRequest(request, dependencies.store.consumeChallenge(challengeToken, "register", keyHash, Date.now(), signal));
    const attestationObject = strictBase64(value.attestationObject, "attestationObject", 512 * 1024);
    const clientDataHash = createHash("sha256").update(Buffer.from(challenge, "base64url")).digest();
    const registration = await withinRequest(request, dependencies.appAttest.register({ keyID: rawKey, attestationObject, clientDataHash }));
    if (registration.keyIDHash !== keyHash || registration.environment !== config.appAttestEnvironment) throw new ApiError(401, "INVALID_APP_ATTEST", "App Attest credential is invalid");
    const now = Date.now();
    await withinRequest(request, dependencies.store.putRegisteredKey({ ...registration, createdAt: now, updatedAt: now }, signal));
    reply.header("cache-control", "no-store");
    return reply.code(201).send({ registered: true });
  });

  app.post("/v2/session", async (request, reply) => {
    requireOnline();
    const { raw, value } = jsonObject(request, 64 * 1024); exactKeys(value, ["signedTransaction"]);
    const security = await verifyAttested(request, raw, undefined, undefined, false);
    const signal = operation(request).signal;
    const evidence = await verifyCurrentEntitlement(request, security.keyHash, requiredString(value.signedTransaction, "signedTransaction", 64 * 1024));
    const token = randomBytes(32).toString("base64url"), now = Date.now(), expiresAt = now + config.sessionTtlMs;
    const session = { tokenHash: sha256Base64URL(token), keyIDHash: security.keyHash, originalTransactionIDHash: evidence.originalTransactionIDHash, createdAt: now, expiresAt };
    const established = await withinRequest(request, dependencies.store.establishSessionWithEvidence({
      keyIDHash: security.keyHash,
      originalTransactionIDHash: evidence.originalTransactionIDHash,
      evidence,
      now,
      maximumDevices: config.maximumSubscriptionDevices,
      inactiveAfterMs: config.inactiveDeviceAfterMs,
      challengeCount: config.challengePoolSize,
      challengeTtlMs: config.challengeTtlMs,
      maximumPoolsPerMinute: config.challengePoolRequestsPerMinute,
      session
    }, signal));
    if (!established.authorized) throw new ApiError(402, "SUBSCRIPTION_REQUIRED", "An active Pro subscription is required");
    reply.header("cache-control", "no-store");
    return reply.code(200).send({ token, expiresAt: new Date(expiresAt).toISOString(), challenges: established.challenges });
  });

  app.post("/v2/devices/replace-oldest", async (request, reply) => {
    requireOnline();
    const { raw, value } = jsonObject(request, 64 * 1024); exactKeys(value, ["signedTransaction"]);
    const security = await verifyAttested(request, raw, undefined, undefined, false);
    const evidence = await verifyCurrentEntitlement(request, security.keyHash, requiredString(value.signedTransaction, "signedTransaction", 64 * 1024));
    const signal = operation(request).signal;
    const authorized = await withinRequest(request, dependencies.store.replaceOldestInstallationWithEvidence({ originalTransactionIDHash: evidence.originalTransactionIDHash, keyIDHash: security.keyHash, evidence, now: Date.now(), maximumDevices: config.maximumSubscriptionDevices, inactiveAfterMs: config.inactiveDeviceAfterMs }, signal));
    if (!authorized) throw new ApiError(402, "SUBSCRIPTION_REQUIRED", "An active Pro subscription is required");
    return reply.code(200).send({ replaced: true });
  });

  app.post("/v2/session/challenges", async (request, reply) => {
    requireOnline();
    const raw = emptyBody(request), security = await verifyAttested(request, raw);
    reply.header("cache-control", "no-store");
    return reply.code(200).send({ challenges: await issueChallenges(request, security.keyHash) });
  });

  app.post("/v2/translate-turn", async (request, reply) => {
    requireOnline();
    if ((request.headers["content-type"] ?? "").toLowerCase() !== "audio/wav") throw new ApiError(415, "UNSUPPORTED_MEDIA_TYPE", "Content-Type must be audio/wav");
    const audio = bufferBody(request), declared = request.headers["content-length"];
    if (typeof declared !== "string") throw new ApiError(411, "CONTENT_LENGTH_REQUIRED", "Content-Length is required");
    if (!/^\d+$/.test(declared) || Number(declared) !== audio.length) throw new ApiError(400, "CONTENT_LENGTH_MISMATCH", "Content-Length must exactly match the WAV body");
    const pair = languagePair(request), wav = parseCanonicalPCM16Wav(audio, config.maxAudioBytes);
    const security = await verifyAttested(request, audio, pair.sourceLocale, pair.targetLocale);
    const signal = operation(request).signal;
    await withinRequest(request, dependencies.store.consumeQuota({ keyIDHash: security.keyHash, originalTransactionIDHash: security.session!.originalTransactionIDHash, now: Date.now(), installationPerMinute: config.installationRatePerMinute, entitlementPerMinute: config.entitlementRatePerMinute, entitlementPerDay: config.entitlementRatePerDay }, signal));
    return reply.code(200).send(await withinRequest(request, dependencies.provider.translateTurn({ audio, ...pair, durationMs: wav.durationMs, signal })));
  });

  app.post("/v2/translate-text", async (request, reply) => {
    requireOnline();
    const { raw, value } = jsonObject(request, config.maxTextBytes); exactKeys(value, ["sourceLocale", "targetLocale", "text"]);
    const pair = languagePair(request);
    if (value.sourceLocale !== pair.sourceLocale || value.targetLocale !== pair.targetLocale) throw new ApiError(400, "LOCALE_HEADER_MISMATCH", "Locale headers must match the JSON body");
    const text = requiredString(value.text, "text", config.maxTextBytes).trim();
    const security = await verifyAttested(request, raw, pair.sourceLocale, pair.targetLocale);
    const signal = operation(request).signal;
    await withinRequest(request, dependencies.store.consumeQuota({ keyIDHash: security.keyHash, originalTransactionIDHash: security.session!.originalTransactionIDHash, now: Date.now(), installationPerMinute: config.installationRatePerMinute, entitlementPerMinute: config.entitlementRatePerMinute, entitlementPerDay: config.entitlementRatePerDay }, signal));
    return reply.code(200).send(await withinRequest(request, dependencies.provider.translateText({ ...pair, text, signal })));
  });

  app.delete("/v2/devices/current", async (request, reply) => {
    const raw = emptyBody(request), security = await verifyAttested(request, raw);
    const signal = operation(request).signal;
    await withinRequest(request, dependencies.store.removeInstallation(security.session!.originalTransactionIDHash, security.keyHash, Date.now(), signal));
    return reply.code(204).send();
  });

  app.post("/v2/storekit/notifications", async (request, reply) => {
    const { value } = jsonObject(request, 128 * 1024); exactKeys(value, ["signedPayload"]);
    const signal = operation(request).signal;
    const signedPayload = requiredString(value.signedPayload, "signedPayload", 128 * 1024);
    const payloadHash = sha256Base64URL(Buffer.from(signedPayload, "utf8"));
    const event = await withinStoreKit(request, "notification", () => storeKitNotificationCache.verify(payloadHash, Date.now(), () => dependencies.storeKit.processNotification(signedPayload, signal)));
    await withinRequest(request, dependencies.store.applyNotification({ notificationID: event.notificationID, payloadHash, signedAt: event.signedAt, receivedAt: Date.now(), ...(event.evidence ? { evidence: event.evidence } : {}) }, signal));
    return reply.code(200).send({ accepted: true });
  });

  app.setNotFoundHandler(async (request, reply) => {
    errorCodes.set(request, "NOT_FOUND");
    return reply.code(404).send({ error: { code: "NOT_FOUND", message: "Route not found", requestId: request.id } });
  });
  app.setErrorHandler(async (error, request, reply) => {
    const normalized = asApiError(error);
    errorCodes.set(request, normalized.code);
    if (normalized.statusCode === 429) reply.header("retry-after", "60");
    if (normalized.code === "STOREKIT_BUSY") reply.header("retry-after", "5");
    return reply.code(normalized.statusCode).send({ error: { code: normalized.code, message: normalized.message, requestId: request.id } });
  });
  if (dependencies.logRequests) app.addHook("onResponse", async (request, reply) => {
    process.stdout.write(`${JSON.stringify({ severity: reply.statusCode >= 500 ? "ERROR" : reply.statusCode >= 400 ? "WARNING" : "INFO", event: "request_completed", requestId: request.id, method: request.method, route: request.routeOptions.url ?? "unmatched", statusCode: reply.statusCode, errorCode: errorCodes.get(request) ?? "NONE", elapsedMs: Math.round(reply.elapsedTime) })}\n`);
  });
  return app;
}
