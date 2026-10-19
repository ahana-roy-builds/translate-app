import { randomBytes } from "node:crypto";
import { ApiError } from "./errors.js";
import { discardResponseBody, readBoundedResponseJSON } from "./fetch-body.js";
import { sha256Base64URL } from "./protocol.js";
import type {
  ApplyNotificationInput,
  AssertionChallenge,
  ChallengePurpose,
  ConsumeQuotaInput,
  EntitlementEvidence,
  EstablishSessionInput,
  EstablishSessionResult,
  RegisteredKey,
  ReplaceInstallationInput,
  SecurityStore,
  StoredEntitlement,
  StoredSession
} from "./contracts.js";

interface ChallengeRecord {
  purpose: ChallengePurpose;
  keyIDHash: string;
  challenge: string;
  expiresAt: number;
  consumed: boolean;
}

interface BindingRecord { bindings: Record<string, number>; }
interface CounterRecord { count: number; expiresAt: number; }
interface RevocationRecord { revokedAt: number; }
interface NotificationRecord {
  notificationID: string;
  payloadHash: string;
  signedAt: number;
  receivedAt: number;
  expiresAt: number;
}

function challengeRecords(keyIDHash: string, count: number, ttlMs: number, now: number) {
  return Array.from({ length: count }, () => {
    const challenge = randomBytes(32).toString("base64url");
    const challengeToken = randomBytes(32).toString("base64url");
    const expiresAt = now + ttlMs;
    return {
      response: { challenge, challengeToken, expiresAt: new Date(expiresAt).toISOString() },
      id: sha256Base64URL(challengeToken),
      record: { purpose: "session-request" as const, keyIDHash, challenge, expiresAt, consumed: false }
    };
  });
}

function activeBindings(existing: BindingRecord | undefined, now: number, inactiveAfterMs: number): Record<string, number> {
  const bindings = { ...(existing?.bindings ?? {}) };
  for (const [key, activeAt] of Object.entries(bindings)) if (activeAt <= now - inactiveAfterMs) delete bindings[key];
  return bindings;
}

function sessionAfterRevocation(session: StoredSession, revocation: RevocationRecord | undefined): StoredSession {
  return { ...session, createdAt: revocation ? Math.max(session.createdAt, revocation.revokedAt + 1) : session.createdAt };
}

function validTime(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

function isAccessActive(value: Pick<StoredEntitlement, "status" | "expiresAt">, now: number): boolean {
  return (value.status === "active" || value.status === "grace-period") && value.expiresAt > now;
}

export function entitlementFromEvidence(evidence: EntitlementEvidence, updatedAt: number): StoredEntitlement {
  const evidenceFrom = evidence.kind === "live-status" ? evidence.startedAt : evidence.eventAt;
  const evidenceTo = evidence.kind === "live-status" ? evidence.completedAt : evidence.eventAt;
  if (
    typeof evidence.originalTransactionIDHash !== "string" || !evidence.originalTransactionIDHash ||
    typeof evidence.productID !== "string" ||
    !validTime(evidence.expiresAt) || !validTime(evidence.signedAt) || !validTime(evidence.verifiedAt) ||
    (evidence.status !== "active" && evidence.status !== "grace-period" && evidence.status !== "expired") ||
    (evidence.status === "expired" ? evidence.expiresAt !== 0 : evidence.expiresAt === 0) ||
    !validTime(evidenceFrom) || !validTime(evidenceTo) || evidenceTo < evidenceFrom ||
    evidence.verifiedAt !== evidenceTo || !validTime(updatedAt)
  ) {
    throw new ApiError(503, "INVALID_ENTITLEMENT_EVIDENCE", "Subscription evidence is invalid");
  }
  return {
    originalTransactionIDHash: evidence.originalTransactionIDHash,
    productID: evidence.productID,
    expiresAt: evidence.expiresAt,
    signedAt: evidence.signedAt,
    verifiedAt: evidence.verifiedAt,
    status: evidence.status,
    schemaVersion: 2,
    evidenceKind: evidence.kind,
    evidenceFrom,
    evidenceTo,
    updatedAt
  };
}

/** Decode v1 timestamp records as point evidence. They are rewritten as v2 on the next merge. */
export function normalizeStoredEntitlement(value: unknown): StoredEntitlement | undefined {
  if (!value || typeof value !== "object") return undefined;
  const item = value as Partial<StoredEntitlement> & { updatedAt?: unknown };
  if (
    typeof item.originalTransactionIDHash !== "string" ||
    typeof item.productID !== "string" ||
    !validTime(item.expiresAt) || !validTime(item.signedAt) || !validTime(item.verifiedAt) ||
    (item.status !== "active" && item.status !== "grace-period" && item.status !== "expired") ||
    (item.status === "expired" ? item.expiresAt !== 0 : item.expiresAt === 0) ||
    !validTime(item.updatedAt)
  ) return undefined;
  if (item.schemaVersion === 2) {
    if (
      (item.evidenceKind !== "live-status" && item.evidenceKind !== "server-notification") ||
      !validTime(item.evidenceFrom) || !validTime(item.evidenceTo) || item.evidenceTo < item.evidenceFrom || item.verifiedAt !== item.evidenceTo
    ) return undefined;
    return item as StoredEntitlement;
  }
  return {
    originalTransactionIDHash: item.originalTransactionIDHash,
    productID: item.productID,
    expiresAt: item.expiresAt,
    signedAt: item.signedAt,
    verifiedAt: item.updatedAt,
    status: item.status,
    schemaVersion: 2,
    evidenceKind: "server-notification",
    evidenceFrom: item.updatedAt,
    evidenceTo: item.updatedAt,
    updatedAt: item.updatedAt
  };
}

function compareTieBreak(left: StoredEntitlement, right: StoredEntitlement): number {
  const numbers: Array<[number, number]> = [
    [left.evidenceTo, right.evidenceTo],
    [left.evidenceFrom, right.evidenceFrom],
    [left.signedAt, right.signedAt],
    [left.expiresAt, right.expiresAt]
  ];
  for (const [a, b] of numbers) if (a !== b) return a > b ? 1 : -1;
  const leftKey = `${left.evidenceKind}\u0000${left.productID}\u0000${left.originalTransactionIDHash}`;
  const rightKey = `${right.evidenceKind}\u0000${right.productID}\u0000${right.originalTransactionIDHash}`;
  return leftKey.localeCompare(rightKey);
}

/**
 * Commutative causal merge. Non-overlapping evidence follows time; overlapping
 * evidence is conservative so a response that straddles a terminal event can
 * never revive access.
 */
export function mergeEntitlementEvidence(existingValue: unknown, evidence: EntitlementEvidence, updatedAt: number): StoredEntitlement {
  const incoming = entitlementFromEvidence(evidence, updatedAt);
  const existing = normalizeStoredEntitlement(existingValue);
  if (existingValue !== undefined && !existing) throw new ApiError(503, "STATE_STORE_INVALID", "Security state is invalid");
  if (!existing) return incoming;
  if (existing.originalTransactionIDHash !== incoming.originalTransactionIDHash) {
    throw new ApiError(503, "INVALID_ENTITLEMENT_EVIDENCE", "Subscription evidence is invalid");
  }
  let winner: StoredEntitlement;
  if (incoming.evidenceFrom > existing.evidenceTo) winner = incoming;
  else if (incoming.evidenceTo < existing.evidenceFrom) winner = existing;
  else {
    const rank = { active: 1, "grace-period": 2, expired: 3 } as const;
    if (rank[incoming.status] !== rank[existing.status]) winner = rank[incoming.status] > rank[existing.status] ? incoming : existing;
    else winner = compareTieBreak(incoming, existing) > 0 ? incoming : existing;
  }
  return { ...winner, updatedAt: Math.max(existing.updatedAt, incoming.updatedAt) };
}

export class InMemorySecurityStore implements SecurityStore {
  private readonly challenges = new Map<string, ChallengeRecord>();
  private readonly keys = new Map<string, RegisteredKey>();
  private readonly entitlements = new Map<string, StoredEntitlement>();
  private readonly bindings = new Map<string, BindingRecord>();
  private readonly sessions = new Map<string, StoredSession>();
  private readonly counters = new Map<string, CounterRecord>();
  private readonly notifications = new Map<string, NotificationRecord>();
  private readonly keyRevocations = new Map<string, RevocationRecord>();

  async ready(): Promise<boolean> { return true; }

  async createChallenge(purpose: ChallengePurpose, keyIDHash: string, ttlMs: number): Promise<AssertionChallenge> {
    const challenge = randomBytes(32).toString("base64url");
    const challengeToken = randomBytes(32).toString("base64url");
    const expiresAt = Date.now() + ttlMs;
    this.challenges.set(sha256Base64URL(challengeToken), { purpose, keyIDHash, challenge, expiresAt, consumed: false });
    return { challenge, challengeToken, expiresAt: new Date(expiresAt).toISOString() };
  }

  async createSessionChallengePool(keyIDHash: string, count: number, ttlMs: number, now: number, maximumPoolsPerMinute: number): Promise<AssertionChallenge[]> {
    const minute = Math.floor(now / 60_000), quotaID = `p:${keyIDHash}:${minute}`;
    const quota = this.counters.get(quotaID) ?? { count: 0, expiresAt: (minute + 1) * 60_000 };
    if (quota.count >= maximumPoolsPerMinute) throw new ApiError(429, "CHALLENGE_POOL_QUOTA_EXCEEDED", "Assertion challenge issuance quota has been reached");
    const records = challengeRecords(keyIDHash, count, ttlMs, now);
    quota.count += 1;
    this.counters.set(quotaID, quota);
    for (const value of records) this.challenges.set(value.id, value.record);
    return records.map((value) => value.response);
  }

  async establishSessionWithEvidence(input: EstablishSessionInput): Promise<EstablishSessionResult> {
    if (input.originalTransactionIDHash !== input.evidence.originalTransactionIDHash || input.evidence.kind !== "live-status") {
      throw new ApiError(503, "INVALID_ENTITLEMENT_EVIDENCE", "Subscription evidence is invalid");
    }
    const merged = mergeEntitlementEvidence(this.entitlements.get(input.originalTransactionIDHash), input.evidence, input.now);
    const authorized = isAccessActive(input.evidence, input.now) && isAccessActive(merged, input.now);
    if (!authorized) {
      this.entitlements.set(input.originalTransactionIDHash, structuredClone(merged));
      return { authorized: false, challenges: [] };
    }
    const minute = Math.floor(input.now / 60_000), quotaID = `p:${input.keyIDHash}:${minute}`;
    const quota = this.counters.get(quotaID) ?? { count: 0, expiresAt: (minute + 1) * 60_000 };
    if (quota.count >= input.maximumPoolsPerMinute) throw new ApiError(429, "CHALLENGE_POOL_QUOTA_EXCEEDED", "Assertion challenge issuance quota has been reached");
    const bindings = activeBindings(this.bindings.get(input.originalTransactionIDHash), input.now, input.inactiveAfterMs);
    if (!(input.keyIDHash in bindings) && Object.keys(bindings).length >= input.maximumDevices) {
      throw new ApiError(409, "DEVICE_LIMIT_REACHED", "This subscription is already active on the maximum number of devices");
    }
    const records = challengeRecords(input.keyIDHash, input.challengeCount, input.challengeTtlMs, input.now);
    quota.count += 1;
    bindings[input.keyIDHash] = Math.max(bindings[input.keyIDHash] ?? 0, input.now);
    this.counters.set(quotaID, quota);
    this.entitlements.set(input.originalTransactionIDHash, structuredClone(merged));
    this.bindings.set(input.originalTransactionIDHash, { bindings });
    for (const value of records) this.challenges.set(value.id, value.record);
    this.sessions.set(input.session.tokenHash, structuredClone(sessionAfterRevocation(input.session, this.keyRevocations.get(input.keyIDHash))));
    return { authorized: true, challenges: records.map((value) => value.response) };
  }

  async consumeChallenge(token: string, purpose: ChallengePurpose, keyIDHash: string, now: number): Promise<string> {
    const id = sha256Base64URL(token);
    const record = this.challenges.get(id);
    if (!record || record.purpose !== purpose || record.keyIDHash !== keyIDHash) {
      throw new ApiError(401, "INVALID_CHALLENGE", "Assertion challenge is invalid");
    }
    if (record.expiresAt <= now) throw new ApiError(410, "CHALLENGE_EXPIRED", "Assertion challenge has expired");
    if (record.consumed) throw new ApiError(409, "CHALLENGE_REPLAYED", "Assertion challenge has already been consumed");
    record.consumed = true;
    return record.challenge;
  }

  async putRegisteredKey(key: RegisteredKey): Promise<void> {
    if (this.keys.has(key.keyIDHash)) throw new ApiError(409, "KEY_ALREADY_REGISTERED", "App Attest key is already registered");
    this.keys.set(key.keyIDHash, structuredClone(key));
  }

  async getRegisteredKey(keyIDHash: string): Promise<RegisteredKey | undefined> {
    const value = this.keys.get(keyIDHash);
    return value ? structuredClone(value) : undefined;
  }

  async advanceCounter(keyIDHash: string, previousCounter: number, nextCounter: number, now: number): Promise<void> {
    const key = this.keys.get(keyIDHash);
    if (!key || key.counter !== previousCounter || nextCounter <= previousCounter) {
      throw new ApiError(401, "INVALID_ASSERTION_COUNTER", "App Attest assertion counter is invalid");
    }
    key.counter = nextCounter;
    key.updatedAt = now;
  }

  async getEntitlement(id: string): Promise<StoredEntitlement | undefined> {
    const raw = this.entitlements.get(id);
    const value = normalizeStoredEntitlement(raw);
    if (raw !== undefined && !value) throw new ApiError(503, "STATE_STORE_INVALID", "Security state is invalid");
    return value ? structuredClone(value) : undefined;
  }

  async replaceOldestInstallationWithEvidence(input: ReplaceInstallationInput): Promise<boolean> {
    const { originalTransactionIDHash: id, keyIDHash, now, maximumDevices, inactiveAfterMs } = input;
    if (id !== input.evidence.originalTransactionIDHash || input.evidence.kind !== "live-status") {
      throw new ApiError(503, "INVALID_ENTITLEMENT_EVIDENCE", "Subscription evidence is invalid");
    }
    const merged = mergeEntitlementEvidence(this.entitlements.get(id), input.evidence, now);
    const authorized = isAccessActive(input.evidence, now) && isAccessActive(merged, now);
    if (!authorized) {
      this.entitlements.set(id, structuredClone(merged));
      return false;
    }
    const bindings = activeBindings(this.bindings.get(id), now, inactiveAfterMs);
    let evicted: string | undefined;
    if (!(keyIDHash in bindings) && Object.keys(bindings).length >= maximumDevices) {
      evicted = Object.entries(bindings).sort(([leftKey, leftAt], [rightKey, rightAt]) => leftAt - rightAt || leftKey.localeCompare(rightKey))[0]?.[0];
      if (evicted) delete bindings[evicted];
    }
    bindings[keyIDHash] = Math.max(bindings[keyIDHash] ?? 0, now);
    this.entitlements.set(id, structuredClone(merged));
    this.bindings.set(id, { bindings });
    if (evicted) {
      const existing = this.keyRevocations.get(evicted);
      this.keyRevocations.set(evicted, { revokedAt: Math.max(existing?.revokedAt ?? 0, now) });
    }
    return true;
  }

  async removeInstallation(id: string, keyIDHash: string, now: number): Promise<void> {
    const record = this.bindings.get(id);
    if (record) delete record.bindings[keyIDHash];
    const existingRevocation = this.keyRevocations.get(keyIDHash);
    this.keyRevocations.set(keyIDHash, { revokedAt: Math.max(existingRevocation?.revokedAt ?? 0, now) });
  }

  async getSession(tokenHash: string, now: number): Promise<StoredSession | undefined> {
    const session = this.sessions.get(tokenHash);
    if (!session || session.expiresAt <= now) return undefined;
    const revocation = this.keyRevocations.get(session.keyIDHash);
    if (revocation && revocation.revokedAt >= session.createdAt) return undefined;
    return structuredClone(session);
  }

  async consumeQuota(input: ConsumeQuotaInput): Promise<void> {
    const minute = Math.floor(input.now / 60_000);
    const day = Math.floor(input.now / 86_400_000);
    this.increment(`i:${input.keyIDHash}:${minute}`, input.installationPerMinute, (minute + 1) * 60_000);
    this.increment(`e:${input.originalTransactionIDHash}:${minute}`, input.entitlementPerMinute, (minute + 1) * 60_000);
    this.increment(`d:${input.originalTransactionIDHash}:${day}`, input.entitlementPerDay, (day + 1) * 86_400_000);
  }

  async consumeSessionAttempt(keyIDHash: string, now: number, maximumPerMinute: number): Promise<void> {
    const minute = Math.floor(now / 60_000), id = `s:${keyIDHash}:${minute}`;
    const existing = this.counters.get(id) ?? { count: 0, expiresAt: (minute + 1) * 60_000 };
    if (existing.count >= maximumPerMinute) throw new ApiError(429, "SESSION_ATTEMPT_QUOTA_EXCEEDED", "Online session verification quota has been reached");
    existing.count += 1;
    this.counters.set(id, existing);
  }

  private increment(id: string, maximum: number, expiresAt: number): void {
    const existing = this.counters.get(id) ?? { count: 0, expiresAt };
    if (existing.count >= maximum) throw new ApiError(429, "QUOTA_EXCEEDED", "Online translation quota has been reached");
    existing.count += 1;
    this.counters.set(id, existing);
  }

  async applyNotification(input: ApplyNotificationInput): Promise<boolean> {
    const id = sha256Base64URL(input.notificationID);
    const existing = this.notifications.get(id);
    if (existing) {
      if (existing.payloadHash !== input.payloadHash) throw new ApiError(409, "STOREKIT_NOTIFICATION_CONFLICT", "StoreKit notification identifier conflicts with an earlier payload");
      return false;
    }
    const merged = input.evidence
      ? mergeEntitlementEvidence(this.entitlements.get(input.evidence.originalTransactionIDHash), input.evidence, input.receivedAt)
      : undefined;
    if (input.evidence && input.evidence.kind !== "server-notification") throw new ApiError(503, "INVALID_ENTITLEMENT_EVIDENCE", "Subscription evidence is invalid");
    this.notifications.set(id, {
      notificationID: input.notificationID,
      payloadHash: input.payloadHash,
      signedAt: input.signedAt,
      receivedAt: input.receivedAt,
      expiresAt: input.receivedAt + 30 * 86_400_000
    });
    if (merged) this.entitlements.set(merged.originalTransactionIDHash, structuredClone(merged));
    return true;
  }
}

interface FirestoreDocument {
  name: string;
  fields?: Record<string, { stringValue?: string; timestampValue?: string }>;
  updateTime?: string;
}

interface FirestoreOptions { projectID: string; database: string; }

export class MetadataTokenProvider {
  private cached?: { token: string; expiresAt: number };
  private inFlight: Promise<string> | undefined;

  private async refresh(): Promise<string> {
    let response: Response;
    try {
      response = await fetch("http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token", {
        headers: { "Metadata-Flavor": "Google" }, signal: AbortSignal.timeout(3_000)
      });
    } catch { throw new ApiError(503, "STATE_STORE_UNAVAILABLE", "Security state is temporarily unavailable"); }
    if (!response.ok) {
      await discardResponseBody(response);
      throw new ApiError(503, "STATE_STORE_UNAVAILABLE", "Security state is temporarily unavailable");
    }
    let body: { access_token?: unknown; expires_in?: unknown };
    try { body = await readBoundedResponseJSON(response, 16 * 1024); }
    catch { throw new ApiError(503, "STATE_STORE_UNAVAILABLE", "Security state is temporarily unavailable"); }
    if (typeof body.access_token !== "string") throw new ApiError(503, "STATE_STORE_UNAVAILABLE", "Security state is temporarily unavailable");
    this.cached = { token: body.access_token, expiresAt: Date.now() + (typeof body.expires_in === "number" ? body.expires_in : 300) * 1_000 };
    return body.access_token;
  }

  async token(signal?: AbortSignal): Promise<string> {
    if (signal?.aborted) throw new ApiError(504, "REQUEST_DEADLINE_EXCEEDED", "The request deadline was exceeded");
    if (this.cached && this.cached.expiresAt > Date.now() + 60_000) return this.waitForCaller(Promise.resolve(this.cached.token), signal);
    if (!this.inFlight) {
      const refresh = this.refresh();
      this.inFlight = refresh;
      void refresh.then(
        () => { if (this.inFlight === refresh) this.inFlight = undefined; },
        () => { if (this.inFlight === refresh) this.inFlight = undefined; }
      );
    }
    return this.waitForCaller(this.inFlight, signal);
  }

  private waitForCaller<T>(promise: Promise<T>, signal?: AbortSignal): Promise<T> {
    if (!signal) return promise;
    if (signal.aborted) return Promise.reject(new ApiError(504, "REQUEST_DEADLINE_EXCEEDED", "The request deadline was exceeded"));
    return new Promise<T>((resolve, reject) => {
      const aborted = () => {
        signal.removeEventListener("abort", aborted);
        reject(new ApiError(504, "REQUEST_DEADLINE_EXCEEDED", "The request deadline was exceeded"));
      };
      signal.addEventListener("abort", aborted, { once: true });
      promise.then(
        (value) => { signal.removeEventListener("abort", aborted); resolve(value); },
        (error: unknown) => { signal.removeEventListener("abort", aborted); reject(error); }
      );
    });
  }
}

/** Firestore REST adapter; every replay/counter/quota mutation uses an optimistic transaction. */
export class FirestoreSecurityStore implements SecurityStore {
  private readonly root: string;
  private readonly tokens: MetadataTokenProvider;
  constructor(options: FirestoreOptions, tokens = new MetadataTokenProvider()) {
    this.root = `https://firestore.googleapis.com/v1/projects/${encodeURIComponent(options.projectID)}/databases/${encodeURIComponent(options.database)}/documents`;
    this.tokens = tokens;
  }

  async ready(signal?: AbortSignal): Promise<boolean> {
    try { await this.getDocument("_health", "readiness", undefined, signal); return true; } catch { return false; }
  }

  async createChallenge(purpose: ChallengePurpose, keyIDHash: string, ttlMs: number, signal?: AbortSignal): Promise<AssertionChallenge> {
    const challenge = randomBytes(32).toString("base64url");
    const token = randomBytes(32).toString("base64url");
    const expiresAt = Date.now() + ttlMs;
    await this.create(this.challengeCollection(purpose), sha256Base64URL(token), { purpose, keyIDHash, challenge, expiresAt, consumed: false }, signal);
    return { challenge, challengeToken: token, expiresAt: new Date(expiresAt).toISOString() };
  }

  async createSessionChallengePool(keyIDHash: string, count: number, ttlMs: number, now: number, maximumPoolsPerMinute: number, signal?: AbortSignal): Promise<AssertionChallenge[]> {
    const minute = Math.floor(now / 60_000), quotaID = `${keyIDHash}-${minute}`, expiresAt = (minute + 1) * 60_000;
    const records = challengeRecords(keyIDHash, count, ttlMs, now);
    return this.transaction(async (transaction) => {
      const quotaDocument = await this.getDocument("challenge_pool_quotas", quotaID, transaction, signal);
      const quota = this.decode<CounterRecord>(quotaDocument);
      if ((quota?.count ?? 0) >= maximumPoolsPerMinute) throw new ApiError(429, "CHALLENGE_POOL_QUOTA_EXCEEDED", "Assertion challenge issuance quota has been reached");
      const writes = [
        this.write("challenge_pool_quotas", quotaID, { count: (quota?.count ?? 0) + 1, expiresAt }, quotaDocument),
        ...records.map((value) => this.write("app_attest_session_challenges", value.id, value.record))
      ];
      return [writes, records.map((value) => value.response)];
    }, signal);
  }

  async establishSessionWithEvidence(input: EstablishSessionInput, signal?: AbortSignal): Promise<EstablishSessionResult> {
    if (input.originalTransactionIDHash !== input.evidence.originalTransactionIDHash || input.evidence.kind !== "live-status") {
      throw new ApiError(503, "INVALID_ENTITLEMENT_EVIDENCE", "Subscription evidence is invalid");
    }
    const minute = Math.floor(input.now / 60_000), quotaID = `${input.keyIDHash}-${minute}`, expiresAt = (minute + 1) * 60_000;
    const records = challengeRecords(input.keyIDHash, input.challengeCount, input.challengeTtlMs, input.now);
    return this.transaction<EstablishSessionResult>(async (transaction) => {
      const [quotaDocument, bindingDocument, revocationDocument, entitlementDocument] = await Promise.all([
        this.getDocument("challenge_pool_quotas", quotaID, transaction, signal),
        this.getDocument("subscription_device_bindings", input.originalTransactionIDHash, transaction, signal),
        this.getDocument("key_revocations", input.keyIDHash, transaction, signal),
        this.getDocument("storekit_entitlements", input.originalTransactionIDHash, transaction, signal)
      ]);
      const existingEntitlement = this.decode<unknown>(entitlementDocument);
      const merged = mergeEntitlementEvidence(existingEntitlement, input.evidence, input.now);
      const authorized = isAccessActive(input.evidence, input.now) && isAccessActive(merged, input.now);
      if (!authorized) {
        return [[this.write("storekit_entitlements", input.originalTransactionIDHash, merged, entitlementDocument)], { authorized: false, challenges: [] }];
      }
      const quota = this.decode<CounterRecord>(quotaDocument);
      if ((quota?.count ?? 0) >= input.maximumPoolsPerMinute) throw new ApiError(429, "CHALLENGE_POOL_QUOTA_EXCEEDED", "Assertion challenge issuance quota has been reached");
      const bindings = activeBindings(this.decode<BindingRecord>(bindingDocument), input.now, input.inactiveAfterMs);
      if (!(input.keyIDHash in bindings) && Object.keys(bindings).length >= input.maximumDevices) {
        throw new ApiError(409, "DEVICE_LIMIT_REACHED", "This subscription is already active on the maximum number of devices");
      }
      bindings[input.keyIDHash] = Math.max(bindings[input.keyIDHash] ?? 0, input.now);
      const writes = [
        this.write("storekit_entitlements", input.originalTransactionIDHash, merged, entitlementDocument),
        this.write("challenge_pool_quotas", quotaID, { count: (quota?.count ?? 0) + 1, expiresAt }, quotaDocument),
        this.write("subscription_device_bindings", input.originalTransactionIDHash, { bindings }, bindingDocument),
        ...records.map((value) => this.write("app_attest_session_challenges", value.id, value.record)),
        this.write("online_sessions", input.session.tokenHash, sessionAfterRevocation(input.session, this.decode<RevocationRecord>(revocationDocument)))
      ];
      return [writes, { authorized: true, challenges: records.map((value) => value.response) }];
    }, signal);
  }

  async consumeChallenge(token: string, purpose: ChallengePurpose, keyIDHash: string, now: number, signal?: AbortSignal): Promise<string> {
    return this.transactOne<ChallengeRecord, string>(this.challengeCollection(purpose), sha256Base64URL(token), (record) => {
      if (!record || record.purpose !== purpose || record.keyIDHash !== keyIDHash) throw new ApiError(401, "INVALID_CHALLENGE", "Assertion challenge is invalid");
      if (record.expiresAt <= now) throw new ApiError(410, "CHALLENGE_EXPIRED", "Assertion challenge has expired");
      if (record.consumed) throw new ApiError(409, "CHALLENGE_REPLAYED", "Assertion challenge has already been consumed");
      return [{ ...record, consumed: true }, record.challenge];
    }, signal);
  }

  async putRegisteredKey(key: RegisteredKey, signal?: AbortSignal): Promise<void> { await this.create("app_attest_keys", key.keyIDHash, key, signal); }
  async getRegisteredKey(id: string, signal?: AbortSignal): Promise<RegisteredKey | undefined> { return this.get<RegisteredKey>("app_attest_keys", id, signal); }

  async advanceCounter(id: string, previous: number, next: number, now: number, signal?: AbortSignal): Promise<void> {
    await this.transactOne<RegisteredKey, undefined>("app_attest_keys", id, (key) => {
      if (!key || key.counter !== previous || next <= previous) throw new ApiError(401, "INVALID_ASSERTION_COUNTER", "App Attest assertion counter is invalid");
      return [{ ...key, counter: next, updatedAt: now }, undefined];
    }, signal);
  }

  async getEntitlement(id: string, signal?: AbortSignal): Promise<StoredEntitlement | undefined> {
    const raw = await this.get<unknown>("storekit_entitlements", id, signal);
    const value = normalizeStoredEntitlement(raw);
    if (raw !== undefined && !value) throw new ApiError(503, "STATE_STORE_INVALID", "Security state is invalid");
    return value;
  }

  async replaceOldestInstallationWithEvidence(input: ReplaceInstallationInput, signal?: AbortSignal): Promise<boolean> {
    const { originalTransactionIDHash: id, keyIDHash, now, maximumDevices: maximum, inactiveAfterMs } = input;
    if (id !== input.evidence.originalTransactionIDHash || input.evidence.kind !== "live-status") {
      throw new ApiError(503, "INVALID_ENTITLEMENT_EVIDENCE", "Subscription evidence is invalid");
    }
    return this.transaction(async (transaction) => {
      const [bindingDocument, entitlementDocument] = await Promise.all([
        this.getDocument("subscription_device_bindings", id, transaction, signal),
        this.getDocument("storekit_entitlements", id, transaction, signal)
      ]);
      const merged = mergeEntitlementEvidence(this.decode<unknown>(entitlementDocument), input.evidence, now);
      const authorized = isAccessActive(input.evidence, now) && isAccessActive(merged, now);
      if (!authorized) return [[this.write("storekit_entitlements", id, merged, entitlementDocument)], false];
      const bindings = activeBindings(this.decode<BindingRecord>(bindingDocument), now, inactiveAfterMs);
      let evicted: string | undefined;
      if (!(keyIDHash in bindings) && Object.keys(bindings).length >= maximum) {
        evicted = Object.entries(bindings).sort(([leftKey, leftAt], [rightKey, rightAt]) => leftAt - rightAt || leftKey.localeCompare(rightKey))[0]?.[0];
        if (evicted) delete bindings[evicted];
      }
      bindings[keyIDHash] = Math.max(bindings[keyIDHash] ?? 0, now);
      const revocationDocument = evicted ? await this.getDocument("key_revocations", evicted, transaction, signal) : undefined;
      const revokedAt = Math.max(this.decode<RevocationRecord>(revocationDocument)?.revokedAt ?? 0, now);
      const writes = [
        this.write("storekit_entitlements", id, merged, entitlementDocument),
        this.write("subscription_device_bindings", id, { bindings }, bindingDocument),
        ...(evicted ? [this.write("key_revocations", evicted, { revokedAt }, revocationDocument)] : [])
      ];
      return [writes, true];
    }, signal);
  }

  async removeInstallation(id: string, keyIDHash: string, now: number, signal?: AbortSignal): Promise<void> {
    await this.transaction(async (transaction) => {
      const [bindingDocument, revocationDocument] = await Promise.all([
        this.getDocument("subscription_device_bindings", id, transaction, signal),
        this.getDocument("key_revocations", keyIDHash, transaction, signal)
      ]);
      const existing = this.decode<BindingRecord>(bindingDocument);
      const bindings = { ...(existing?.bindings ?? {}) };
      delete bindings[keyIDHash];
      const revokedAt = Math.max(this.decode<RevocationRecord>(revocationDocument)?.revokedAt ?? 0, now);
      return [[
        ...(bindingDocument ? [this.write("subscription_device_bindings", id, { bindings }, bindingDocument)] : []),
        this.write("key_revocations", keyIDHash, { revokedAt }, revocationDocument)
      ], undefined];
    }, signal);
  }

  async getSession(id: string, now: number, signal?: AbortSignal): Promise<StoredSession | undefined> {
    const value = await this.get<StoredSession>("online_sessions", id, signal);
    if (!value || value.expiresAt <= now) return undefined;
    const revocation = await this.get<RevocationRecord>("key_revocations", value.keyIDHash, signal);
    return revocation && revocation.revokedAt >= value.createdAt ? undefined : value;
  }

  async consumeQuota(input: ConsumeQuotaInput, signal?: AbortSignal): Promise<void> {
    const minute = Math.floor(input.now / 60_000), day = Math.floor(input.now / 86_400_000);
    const specs = [
      { id: `i-${input.keyIDHash}-${minute}`, max: input.installationPerMinute, expiresAt: (minute + 1) * 60_000 },
      { id: `e-${input.originalTransactionIDHash}-${minute}`, max: input.entitlementPerMinute, expiresAt: (minute + 1) * 60_000 },
      { id: `d-${input.originalTransactionIDHash}-${day}`, max: input.entitlementPerDay, expiresAt: (day + 1) * 86_400_000 }
    ];
    await this.transaction(async (transaction) => {
      const docs = await Promise.all(specs.map((spec) => this.getDocument("online_quotas", spec.id, transaction, signal)));
      const writes = specs.map((spec, index) => {
        const existing = this.decode<CounterRecord>(docs[index]);
        if ((existing?.count ?? 0) >= spec.max) throw new ApiError(429, "QUOTA_EXCEEDED", "Online translation quota has been reached");
        return this.write("online_quotas", spec.id, { count: (existing?.count ?? 0) + 1, expiresAt: spec.expiresAt }, docs[index]);
      });
      return [writes, undefined];
    }, signal);
  }

  async consumeSessionAttempt(keyIDHash: string, now: number, maximumPerMinute: number, signal?: AbortSignal): Promise<void> {
    const minute = Math.floor(now / 60_000), id = `${keyIDHash}-${minute}`, expiresAt = (minute + 1) * 60_000;
    await this.transactOne<CounterRecord, undefined>("session_attempt_quotas", id, (existing) => {
      if ((existing?.count ?? 0) >= maximumPerMinute) throw new ApiError(429, "SESSION_ATTEMPT_QUOTA_EXCEEDED", "Online session verification quota has been reached");
      return [{ count: (existing?.count ?? 0) + 1, expiresAt }, undefined];
    }, signal);
  }

  async applyNotification(input: ApplyNotificationInput, signal?: AbortSignal): Promise<boolean> {
    if (input.evidence && input.evidence.kind !== "server-notification") throw new ApiError(503, "INVALID_ENTITLEMENT_EVIDENCE", "Subscription evidence is invalid");
    const markerID = sha256Base64URL(input.notificationID);
    return this.transaction(async (transaction) => {
      const [markerDocument, entitlementDocument] = await Promise.all([
        this.getDocument("storekit_notification_deduplication", markerID, transaction, signal),
        input.evidence
          ? this.getDocument("storekit_entitlements", input.evidence.originalTransactionIDHash, transaction, signal)
          : Promise.resolve(undefined)
      ]);
      const marker = this.decode<NotificationRecord>(markerDocument);
      if (marker) {
        if (marker.payloadHash !== input.payloadHash) throw new ApiError(409, "STOREKIT_NOTIFICATION_CONFLICT", "StoreKit notification identifier conflicts with an earlier payload");
        return [[], false];
      }
      const notification: NotificationRecord = {
        notificationID: input.notificationID,
        payloadHash: input.payloadHash,
        signedAt: input.signedAt,
        receivedAt: input.receivedAt,
        expiresAt: input.receivedAt + 30 * 86_400_000
      };
      const writes = [this.write("storekit_notification_deduplication", markerID, notification, markerDocument)];
      if (input.evidence) {
        const merged = mergeEntitlementEvidence(this.decode<unknown>(entitlementDocument), input.evidence, input.receivedAt);
        writes.push(this.write("storekit_entitlements", input.evidence.originalTransactionIDHash, merged, entitlementDocument));
      }
      return [writes, true];
    }, signal);
  }

  private async get<T>(collection: string, id: string, signal?: AbortSignal): Promise<T | undefined> { return this.decode<T>(await this.getDocument(collection, id, undefined, signal)); }
  private challengeCollection(purpose: ChallengePurpose): string { return purpose === "register" ? "app_attest_challenges" : "app_attest_session_challenges"; }
  private async create(collection: string, id: string, value: unknown, signal?: AbortSignal): Promise<void> {
    const url = `${this.root}/${encodeURIComponent(collection)}?documentId=${encodeURIComponent(id)}`;
    await discardResponseBody(await this.request(url, { method: "POST", body: JSON.stringify(this.document(value)) }, [200], true, signal));
  }
  private async getDocument(collection: string, id: string, transaction?: string, signal?: AbortSignal): Promise<FirestoreDocument | undefined> {
    const query = transaction ? `?transaction=${encodeURIComponent(transaction)}` : "";
    const response = await this.request(`${this.root}/${encodeURIComponent(collection)}/${encodeURIComponent(id)}${query}`, { method: "GET" }, [200, 404], false, signal);
    if (response.status === 404) { await discardResponseBody(response); return undefined; }
    try { return await readBoundedResponseJSON<FirestoreDocument>(response, 256 * 1024); }
    catch { throw new ApiError(503, "STATE_STORE_UNAVAILABLE", "Security state is temporarily unavailable"); }
  }
  private document(value: unknown): { fields: Record<string, unknown> } {
    const fields: Record<string, unknown> = { payload: { stringValue: JSON.stringify(value) } };
    if (value && typeof value === "object" && "expiresAt" in value && typeof (value as { expiresAt?: unknown }).expiresAt === "number") {
      fields.expiresAt = { timestampValue: new Date((value as { expiresAt: number }).expiresAt).toISOString() };
    }
    return { fields };
  }
  private decode<T>(document: FirestoreDocument | undefined): T | undefined {
    const payload = document?.fields?.payload?.stringValue;
    return payload ? JSON.parse(payload) as T : undefined;
  }
  private write(collection: string, id: string, value: unknown, existing?: FirestoreDocument): object {
    const update = { name: `${this.root.replace("https://firestore.googleapis.com/v1/", "")}/${collection}/${id}`, ...this.document(value) };
    return { update, currentDocument: existing?.updateTime ? { updateTime: existing.updateTime } : { exists: false } };
  }
  private async transactOne<T, R>(collection: string, id: string, mutate: (value: T | undefined) => [T | undefined, R], signal?: AbortSignal): Promise<R> {
    return this.transaction(async (transaction) => {
      const document = await this.getDocument(collection, id, transaction, signal);
      const [next, result] = mutate(this.decode<T>(document));
      return [next === undefined ? [] : [this.write(collection, id, next, document)], result];
    }, signal);
  }
  private async transaction<R>(operation: (transaction: string) => Promise<[object[], R]>, signal?: AbortSignal): Promise<R> {
    for (let attempt = 0; attempt < 3; attempt += 1) {
      if (signal?.aborted) throw new ApiError(504, "REQUEST_DEADLINE_EXCEEDED", "The request deadline was exceeded");
      const start = await this.request(`${this.root}:beginTransaction`, { method: "POST", body: JSON.stringify({ options: { readWrite: {} } }) }, [200], false, signal);
      let transaction: unknown;
      try { ({ transaction } = await readBoundedResponseJSON<{ transaction?: unknown }>(start, 16 * 1024)); }
      catch { throw new ApiError(503, "STATE_STORE_UNAVAILABLE", "Security state is temporarily unavailable"); }
      if (typeof transaction !== "string" || !transaction) throw new ApiError(503, "STATE_STORE_UNAVAILABLE", "Security state is temporarily unavailable");
      let committed = false;
      try {
        const [writes, result] = await operation(transaction);
        await discardResponseBody(await this.request(`${this.root}:commit`, { method: "POST", body: JSON.stringify({ transaction, writes }) }, [200], false, signal));
        committed = true;
        return result;
      } catch (error) {
        if (!committed) {
          try {
            await discardResponseBody(await this.request(`${this.root}:rollback`, { method: "POST", body: JSON.stringify({ transaction }) }, [200], false, AbortSignal.timeout(1_000)));
          } catch { /* Firestore also releases locks when a transaction expires. */ }
        }
        if (error instanceof ApiError && error.code === "TRANSACTION_CONFLICT" && attempt < 2) continue;
        throw error;
      }
    }
    throw new ApiError(503, "STATE_STORE_UNAVAILABLE", "Security state is temporarily unavailable");
  }
  private async request(url: string, init: RequestInit, statuses: number[], creating = false, signal?: AbortSignal): Promise<Response> {
    let response: Response;
    try {
      response = await fetch(url, { ...init, headers: { authorization: `Bearer ${await this.tokens.token(signal)}`, "content-type": "application/json", ...(init.headers ?? {}) }, signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(5_000)]) : AbortSignal.timeout(5_000) });
    } catch {
      if (signal?.aborted) throw new ApiError(504, "REQUEST_DEADLINE_EXCEEDED", "The request deadline was exceeded");
      throw new ApiError(503, "STATE_STORE_UNAVAILABLE", "Security state is temporarily unavailable");
    }
    if (statuses.includes(response.status)) return response;
    const status = response.status;
    await discardResponseBody(response);
    if (creating && status === 409) throw new ApiError(409, "ALREADY_EXISTS", "Security state already exists");
    if (status === 409 || status === 412) throw new ApiError(409, "TRANSACTION_CONFLICT", "Concurrent security state update conflicted");
    throw new ApiError(503, "STATE_STORE_UNAVAILABLE", "Security state is temporarily unavailable");
  }
}
