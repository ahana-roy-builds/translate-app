import { createHash, X509Certificate } from "node:crypto";
import { AsyncLocalStorage } from "node:async_hooks";
import { URLSearchParams } from "node:url";
import fetch, { type Response as NodeFetchResponse } from "node-fetch";
import {
  AppStoreServerAPIClient,
  Environment,
  InAppOwnershipType,
  SignedDataVerifier,
  Status,
  Type,
  VerificationException,
  VerificationStatus,
  type JWSTransactionDecodedPayload,
  type JWSRenewalInfoDecodedPayload,
  type ResponseBodyV2DecodedPayload,
  type StatusResponse
} from "@apple/app-store-server-library";
import { ApiError } from "./errors.js";
import type { EntitlementEvidence, StoreKitNotificationEvent, StoreKitService, VerifiedEntitlement } from "./contracts.js";

interface Options {
  bundleID: string;
  appAppleID: number;
  environment: "Production" | "Sandbox";
  allowedProductIDs: readonly string[];
  rootCertificatesPEM: readonly string[];
  signingKey: string;
  keyID: string;
  issuerID: string;
}

interface AppleSignedDataVerifier {
  verifyAndDecodeTransaction(value: string): Promise<JWSTransactionDecodedPayload>;
  verifyAndDecodeRenewalInfo(value: string): Promise<JWSRenewalInfoDecodedPayload>;
  verifyAndDecodeNotification(value: string): Promise<ResponseBodyV2DecodedPayload>;
}

interface AppleStatusClient {
  getAllSubscriptionStatuses(transactionID: string, status?: Status[], signal?: AbortSignal): Promise<StatusResponse>;
}

interface Dependencies {
  verifier?: AppleSignedDataVerifier;
  statusClient?: AppleStatusClient;
  now?: () => number;
}

const CLOCK_SKEW_MS = 60_000;

class BoundedAppStoreServerAPIClient extends AppStoreServerAPIClient {
  private readonly requestSignals = new AsyncLocalStorage<AbortSignal | undefined>();

  override async getAllSubscriptionStatuses(transactionID: string, status?: Status[], signal?: AbortSignal): Promise<StatusResponse> {
    return this.requestSignals.run(signal, () => super.getAllSubscriptionStatuses(transactionID, status));
  }

  protected override async makeFetchRequest(
    path: string,
    parsedQueryParameters: URLSearchParams,
    method: string,
    requestBody: string | Buffer | undefined,
    headers: Record<string, string>
  ): Promise<NodeFetchResponse> {
    // Apple's client intentionally leaves transport customization to this
    // protected seam. Bound both time and bytes below the request/LB budgets.
    const urlBase = (this as unknown as { urlBase: string }).urlBase;
    const callerSignal = this.requestSignals.getStore();
    return fetch(`${urlBase}${path}?${parsedQueryParameters}`, {
      method,
      body: requestBody,
      headers,
      timeout: 8_000,
      size: 256 * 1024,
      signal: callerSignal ? AbortSignal.any([callerSignal, AbortSignal.timeout(8_000)]) as never : AbortSignal.timeout(8_000) as never
    });
  }
}

function credentialError(): ApiError {
  return new ApiError(402, "SUBSCRIPTION_REQUIRED", "An active Pro subscription is required");
}

function verificationUnavailable(): ApiError {
  return new ApiError(503, "STOREKIT_VERIFICATION_UNAVAILABLE", "Subscription verification is temporarily unavailable");
}

function safeTimestamp(value: unknown, now: number): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0 && value <= now + CLOCK_SKEW_MS;
}

function appleEnvironment(value: Options["environment"]): Environment {
  return value === "Production" ? Environment.PRODUCTION : Environment.SANDBOX;
}

/**
 * Apple omits appAppleId from Sandbox/TestFlight notification data. Production
 * notifications must contain the configured numeric identifier; Sandbox
 * accepts the documented omission, while still rejecting a conflicting value.
 */
export function notificationAppIdentityMatches(
  data: Record<string, unknown>,
  bundleID: string,
  appAppleID: number,
  environment: "Production" | "Sandbox"
): boolean {
  if (data.bundleId !== bundleID || data.environment !== environment) return false;
  if (environment === "Production") return typeof data.appAppleId === "number" && data.appAppleId === appAppleID;
  return data.appAppleId === undefined || (typeof data.appAppleId === "number" && data.appAppleId === appAppleID);
}

export function notificationRevokesAccess(notificationType: unknown): boolean {
  // CONSUMPTION_REQUEST is only a refund-information request. Access changes
  // when Apple later sends REFUND (or another terminal subscription event).
  return new Set(["EXPIRED", "GRACE_PERIOD_EXPIRED", "REFUND", "REVOKE"]).has(String(notificationType));
}

export class ProductionStoreKitService implements StoreKitService {
  private readonly options: Options;
  private readonly verifier: AppleSignedDataVerifier;
  private readonly statusClient: AppleStatusClient;
  private readonly now: () => number;
  private retryableVerificationFailures = 0;
  private verificationCircuitUntil = 0;

  constructor(options: Options, dependencies: Dependencies = {}) {
    this.options = options;
    this.now = dependencies.now ?? Date.now;
    const environment = appleEnvironment(options.environment);
    if (dependencies.verifier) {
      this.verifier = dependencies.verifier;
    } else {
      if (options.rootCertificatesPEM.length === 0) throw new Error("At least one StoreKit root certificate is required");
      const roots = options.rootCertificatesPEM.map((pem) => new X509Certificate(pem).raw);
      this.verifier = new SignedDataVerifier(roots, true, environment, options.bundleID, options.environment === "Production" ? options.appAppleID : undefined);
    }
    if (dependencies.statusClient) {
      this.statusClient = dependencies.statusClient;
    } else {
      if (!options.signingKey.trim() || !options.keyID.trim() || !options.issuerID.trim()) throw new Error("App Store Server API credentials are required");
      this.statusClient = new BoundedAppStoreServerAPIClient(options.signingKey, options.keyID, options.issuerID, options.bundleID, environment);
    }
  }

  private ensureVerifierAvailable(signal?: AbortSignal): void {
    if (signal?.aborted) throw new ApiError(504, "REQUEST_DEADLINE_EXCEEDED", "The request deadline was exceeded");
    if (this.verificationCircuitUntil > this.now()) throw verificationUnavailable();
  }

  private verifierSucceeded(): void { this.retryableVerificationFailures = 0; }

  private verifierFailed(error: unknown): never {
    if (error instanceof VerificationException && error.status === VerificationStatus.RETRYABLE_VERIFICATION_FAILURE) {
      this.retryableVerificationFailures += 1;
      if (this.retryableVerificationFailures >= 2) this.verificationCircuitUntil = this.now() + 30_000;
      throw verificationUnavailable();
    }
    throw credentialError();
  }

  private async verifyTransactionJWS(value: string, signal?: AbortSignal): Promise<JWSTransactionDecodedPayload> {
    this.ensureVerifierAvailable(signal);
    try {
      const result = await this.verifier.verifyAndDecodeTransaction(value);
      this.ensureVerifierAvailable(signal);
      this.verifierSucceeded();
      return result;
    } catch (error) {
      if (error instanceof ApiError) throw error;
      return this.verifierFailed(error);
    }
  }

  private async verifyRenewalJWS(value: string, signal?: AbortSignal): Promise<JWSRenewalInfoDecodedPayload> {
    this.ensureVerifierAvailable(signal);
    try {
      const result = await this.verifier.verifyAndDecodeRenewalInfo(value);
      this.ensureVerifierAvailable(signal);
      this.verifierSucceeded();
      return result;
    } catch (error) {
      if (error instanceof ApiError) throw error;
      return this.verifierFailed(error);
    }
  }

  private transactionEntitlement(payload: JWSTransactionDecodedPayload, permitInactive: boolean, permitFamilyShared = false): VerifiedEntitlement {
    const now = this.now();
    const productID = typeof payload.productId === "string" ? payload.productId : "";
    const originalID = typeof payload.originalTransactionId === "string" ? payload.originalTransactionId : "";
    const expiresAt = payload.expiresDate;
    const signedAt = payload.signedDate;
    const revoked = payload.revocationDate !== undefined;
    if (
      payload.bundleId !== this.options.bundleID ||
      payload.environment !== this.options.environment ||
      payload.type !== Type.AUTO_RENEWABLE_SUBSCRIPTION ||
      payload.inAppOwnershipType !== InAppOwnershipType.PURCHASED && !(permitFamilyShared && payload.inAppOwnershipType === InAppOwnershipType.FAMILY_SHARED) ||
      !this.options.allowedProductIDs.includes(productID) ||
      !originalID || originalID.length > 256 ||
      !safeTimestamp(expiresAt, Number.MAX_SAFE_INTEGER - CLOCK_SKEW_MS) ||
      !safeTimestamp(signedAt, now) ||
      (payload.revocationDate !== undefined && !safeTimestamp(payload.revocationDate, now)) ||
      payload.isUpgraded === true
    ) throw credentialError();
    if (!permitInactive && (expiresAt <= now || revoked)) throw credentialError();
    return {
      originalTransactionIDHash: createHash("sha256").update(originalID, "utf8").digest("base64url"),
      productID,
      expiresAt: revoked ? 0 : expiresAt,
      signedAt,
      verifiedAt: now,
      status: expiresAt > now && !revoked ? "active" : "expired"
    };
  }

  private async entitlementForStatus(
    status: Status | number | undefined,
    transaction: JWSTransactionDecodedPayload,
    signedRenewalInfo: string | undefined,
    observedAt: number,
    permitFamilyShared = false,
    signal?: AbortSignal
  ): Promise<VerifiedEntitlement> {
    const base = this.transactionEntitlement(transaction, true, permitFamilyShared);
    if (status === Status.ACTIVE) {
      if (base.status !== "active") throw credentialError();
      return { ...base, verifiedAt: observedAt };
    }
    if (status === Status.BILLING_GRACE_PERIOD) {
      // Grace can extend an ordinarily expired renewal, but it must never
      // resurrect a transaction that Apple has explicitly refunded or
      // revoked. Treat an internally inconsistent status response as invalid.
      if (transaction.revocationDate !== undefined) throw credentialError();
      if (!signedRenewalInfo) throw credentialError();
      const renewal = await this.verifyRenewalJWS(signedRenewalInfo, signal);
      const graceExpiry = renewal.gracePeriodExpiresDate;
      if (
        renewal.environment !== this.options.environment ||
        renewal.originalTransactionId !== transaction.originalTransactionId ||
        renewal.productId !== transaction.productId ||
        !safeTimestamp(renewal.signedDate, this.now()) ||
        !safeTimestamp(graceExpiry, Number.MAX_SAFE_INTEGER - CLOCK_SKEW_MS) ||
        graceExpiry <= this.now()
      ) throw credentialError();
      return { ...base, expiresAt: graceExpiry, signedAt: Math.max(base.signedAt, renewal.signedDate), verifiedAt: observedAt, status: "grace-period" };
    }
    if (status === Status.EXPIRED || status === Status.BILLING_RETRY || status === Status.REVOKED) {
      return { ...base, expiresAt: 0, verifiedAt: observedAt, status: "expired" };
    }
    throw credentialError();
  }

  async verifyTransaction(signedTransaction: string, signal?: AbortSignal): Promise<EntitlementEvidence> {
    if (!signedTransaction || signedTransaction.length > 64 * 1024) throw credentialError();
    this.ensureVerifierAvailable(signal);
    // Do not coalesce live checks by client JWS. Each admitted request owns its
    // cancellation signal and its StoreKit-lane permit until Apple settles.
    // Sharing work here lets one disconnected caller abort another caller's
    // verification and makes limiter accounting diverge from actual work.
    return this.verifyTransactionOnce(signedTransaction, signal);
  }

  private async verifyTransactionOnce(signedTransaction: string, signal?: AbortSignal): Promise<EntitlementEvidence> {
    const startedAt = this.now();
    const clientTransaction = await this.verifyTransactionJWS(signedTransaction, signal);
    const clientEntitlement = this.transactionEntitlement(clientTransaction, true);
    const transactionID = typeof clientTransaction.transactionId === "string" && clientTransaction.transactionId
      ? clientTransaction.transactionId
      : clientTransaction.originalTransactionId;
    if (!transactionID) throw credentialError();
    let response: StatusResponse;
    try {
      response = await this.statusClient.getAllSubscriptionStatuses(transactionID, undefined, signal);
    } catch {
      if (signal?.aborted) throw new ApiError(504, "REQUEST_DEADLINE_EXCEEDED", "The request deadline was exceeded");
      throw verificationUnavailable();
    }
    // Order live observations by when Apple answered, not when this request
    // started. Otherwise a slower, newer REVOKED response can lose to an
    // ACTIVE response from a request that started a little later.
    const observedAt = this.now();
    if (!notificationAppIdentityMatches(response as Record<string, unknown>, this.options.bundleID, this.options.appAppleID, this.options.environment)) throw credentialError();

    const candidates: VerifiedEntitlement[] = [];
    for (const group of response.data ?? []) {
      for (const item of group.lastTransactions ?? []) {
        if (item.originalTransactionId && item.originalTransactionId !== clientTransaction.originalTransactionId) continue;
        if (!item.signedTransactionInfo) throw credentialError();
        const transaction = await this.verifyTransactionJWS(item.signedTransactionInfo, signal);
        if (transaction.isUpgraded === true) continue;
        const entitlement = this.transactionEntitlement(transaction, true);
        if (entitlement.originalTransactionIDHash !== clientEntitlement.originalTransactionIDHash) continue;
        candidates.push(await this.entitlementForStatus(item.status, transaction, item.signedRenewalInfo, observedAt, false, signal));
      }
    }
    const selected = candidates.length === 0 ? { ...clientEntitlement, expiresAt: 0, verifiedAt: observedAt, status: "expired" as const } : candidates.sort((left, right) => {
      const rank = { active: 3, "grace-period": 2, expired: 1 } as const;
      return rank[right.status] - rank[left.status] || right.signedAt - left.signedAt;
    })[0]!;
    const completedAt = this.now();
    if (completedAt < startedAt) throw verificationUnavailable();
    return { ...selected, verifiedAt: completedAt, kind: "live-status", startedAt, completedAt };
  }

  async processNotification(signedPayload: string, signal?: AbortSignal): Promise<StoreKitNotificationEvent> {
    if (!signedPayload || signedPayload.length > 128 * 1024) throw credentialError();
    this.ensureVerifierAvailable(signal);
    let outer: ResponseBodyV2DecodedPayload;
    try {
      outer = await this.verifier.verifyAndDecodeNotification(signedPayload);
      this.ensureVerifierAvailable(signal);
      this.verifierSucceeded();
    } catch (error) {
      if (error instanceof ApiError) throw error;
      return this.verifierFailed(error);
    }
    const notificationID = typeof outer.notificationUUID === "string" ? outer.notificationUUID : "";
    const signedAt = outer.signedDate;
    if (!notificationID || notificationID.length > 128 || !safeTimestamp(signedAt, this.now())) throw credentialError();
    const data = outer.data;
    if (!data) {
      const noDataTypes = new Set(["TEST", "RENEWAL_EXTENSION", "EXTERNAL_PURCHASE_TOKEN", "RESCIND_CONSENT"]);
      if (!noDataTypes.has(String(outer.notificationType))) throw credentialError();
      return { notificationID, signedAt };
    }
    if (!notificationAppIdentityMatches(data as Record<string, unknown>, this.options.bundleID, this.options.appAppleID, this.options.environment)) throw credentialError();
    if (outer.notificationType === "TEST") return { notificationID, signedAt };
    if (!data.signedTransactionInfo) throw credentialError();
    const transaction = await this.verifyTransactionJWS(data.signedTransactionInfo, signal);
    const permitFamilyShared = outer.notificationType === "REVOKE";
    const base = this.transactionEntitlement(transaction, true, permitFamilyShared);

    if (outer.notificationType === "CONSUMPTION_REQUEST") return { notificationID, signedAt };
    if (notificationRevokesAccess(outer.notificationType)) {
      return { notificationID, signedAt, evidence: { ...base, expiresAt: 0, verifiedAt: signedAt, status: "expired", kind: "server-notification", eventAt: signedAt } };
    }
    if (data.status !== undefined) {
      const entitlement = await this.entitlementForStatus(data.status, transaction, data.signedRenewalInfo, signedAt, permitFamilyShared, signal);
      return { notificationID, signedAt, evidence: { ...entitlement, verifiedAt: signedAt, kind: "server-notification", eventAt: signedAt } };
    }
    if (base.status === "expired") {
      return { notificationID, signedAt, evidence: { ...base, expiresAt: 0, verifiedAt: signedAt, status: "expired", kind: "server-notification", eventAt: signedAt } };
    }
    const grantingTypes = new Set(["SUBSCRIBED", "DID_RENEW", "DID_RECOVER", "INTERACTIVE_RENEWAL", "OFFER_REDEEMED", "REFUND_REVERSED"]);
    if (grantingTypes.has(String(outer.notificationType))) {
      if (base.status !== "active") throw credentialError();
      return { notificationID, signedAt, evidence: { ...base, verifiedAt: signedAt, kind: "server-notification", eventAt: signedAt } };
    }
    const informationalTypes = new Set(["DID_CHANGE_RENEWAL_PREF", "DID_CHANGE_RENEWAL_STATUS", "PRICE_INCREASE"]);
    if (informationalTypes.has(String(outer.notificationType))) return { notificationID, signedAt };
    throw credentialError();
  }
}

export class DevelopmentStoreKitService implements StoreKitService {
  async verifyTransaction(signedTransaction: string, signal?: AbortSignal): Promise<EntitlementEvidence> {
    if (!signedTransaction) throw credentialError();
    if (signal?.aborted) throw new ApiError(504, "REQUEST_DEADLINE_EXCEEDED", "The request deadline was exceeded");
    const now = Date.now();
    return { originalTransactionIDHash: createHash("sha256").update(signedTransaction).digest("base64url"), productID: "development.pro", expiresAt: now + 86_400_000, signedAt: now, verifiedAt: now, status: "active", kind: "live-status", startedAt: now, completedAt: now };
  }
  async processNotification(signedPayload: string, signal?: AbortSignal): Promise<StoreKitNotificationEvent> {
    if (signal?.aborted) throw new ApiError(504, "REQUEST_DEADLINE_EXCEEDED", "The request deadline was exceeded");
    return { notificationID: createHash("sha256").update(signedPayload).digest("base64url"), signedAt: Date.now() };
  }
}
