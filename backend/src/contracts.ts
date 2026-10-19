export const SUPPORTED_LOCALES = ["en-US", "es-ES", "ja-JP"] as const;
export type SupportedLocale = (typeof SUPPORTED_LOCALES)[number];
export type ChallengePurpose = "register" | "session-establishment" | "session-request";

export interface AssertionChallenge {
  challenge: string;
  challengeToken: string;
  expiresAt: string;
}

export interface TranslateTurnInput {
  audio: Buffer;
  sourceLocale: SupportedLocale;
  targetLocale: SupportedLocale;
  durationMs: number;
  signal: AbortSignal;
}

export interface TranslateTextInput {
  sourceLocale: SupportedLocale;
  targetLocale: SupportedLocale;
  text: string;
  signal: AbortSignal;
}

export interface ProviderTimings {
  speechRecognition?: number;
  translation: number;
}

export interface TranslateTurnResult {
  sourceText: string;
  translatedText: string;
  recognitionConfidence: number | null;
  engine: "google";
  warnings: string[];
  timingsMs: ProviderTimings;
}

export interface TranslateTextResult {
  sourceText: string;
  translatedText: string;
  engine: "google";
  warnings: string[];
  timingsMs: ProviderTimings;
}

export interface TranslationProvider {
  translateTurn(input: TranslateTurnInput): Promise<TranslateTurnResult>;
  translateText(input: TranslateTextInput): Promise<TranslateTextResult>;
  ready(): Promise<boolean>;
}

export interface AttestationRegistrationInput {
  keyID: string;
  attestationObject: Buffer;
  clientDataHash: Buffer;
}

export interface AttestationRegistration {
  keyIDHash: string;
  publicKeyPem: string;
  counter: number;
  environment: "development" | "production";
  validationCategory?: number;
  bundleVersion?: string;
}

export interface AppAttestService {
  register(input: AttestationRegistrationInput): Promise<AttestationRegistration>;
  verifyAssertion(publicKeyPem: string, assertion: Buffer, clientDataHash: Buffer, previousCounter: number): Promise<number>;
}

export interface VerifiedEntitlement {
  originalTransactionIDHash: string;
  productID: string;
  expiresAt: number;
  signedAt: number;
  /** Time current status was verified with Apple, or the signed event time. */
  verifiedAt: number;
  status: "active" | "grace-period" | "expired";
}

/**
 * Evidence from a live status request spans the entire request. Apple server
 * notifications are point-in-time events. Keeping these clocks distinct is
 * what prevents a delayed ACTIVE response from overwriting a refund that
 * happened while that response was in flight.
 */
export type EntitlementEvidence =
  | (VerifiedEntitlement & {
      kind: "live-status";
      startedAt: number;
      completedAt: number;
    })
  | (VerifiedEntitlement & {
      kind: "server-notification";
      eventAt: number;
    });

export interface StoreKitNotificationEvent {
  notificationID: string;
  signedAt: number;
  evidence?: EntitlementEvidence;
}

export interface StoreKitService {
  verifyTransaction(signedTransaction: string, signal?: AbortSignal): Promise<EntitlementEvidence>;
  processNotification(signedPayload: string, signal?: AbortSignal): Promise<StoreKitNotificationEvent>;
}

export interface RegisteredKey {
  keyIDHash: string;
  publicKeyPem: string;
  counter: number;
  environment: "development" | "production";
  validationCategory?: number;
  bundleVersion?: string;
  createdAt: number;
  updatedAt: number;
}

export interface StoredEntitlement extends VerifiedEntitlement {
  schemaVersion: 2;
  evidenceKind: EntitlementEvidence["kind"];
  evidenceFrom: number;
  evidenceTo: number;
  /** Operational write time only; never used to order entitlement evidence. */
  updatedAt: number;
}

export interface StoredSession {
  tokenHash: string;
  keyIDHash: string;
  originalTransactionIDHash: string;
  expiresAt: number;
  createdAt: number;
}

export interface ConsumeQuotaInput {
  keyIDHash: string;
  originalTransactionIDHash: string;
  now: number;
  installationPerMinute: number;
  entitlementPerMinute: number;
  entitlementPerDay: number;
}

export interface EstablishSessionInput {
  keyIDHash: string;
  originalTransactionIDHash: string;
  evidence: EntitlementEvidence;
  now: number;
  maximumDevices: number;
  inactiveAfterMs: number;
  challengeCount: number;
  challengeTtlMs: number;
  maximumPoolsPerMinute: number;
  session: StoredSession;
}

export interface EstablishSessionResult {
  authorized: boolean;
  challenges: AssertionChallenge[];
}

export interface ReplaceInstallationInput {
  originalTransactionIDHash: string;
  keyIDHash: string;
  evidence: EntitlementEvidence;
  now: number;
  maximumDevices: number;
  inactiveAfterMs: number;
}

export interface ApplyNotificationInput {
  notificationID: string;
  payloadHash: string;
  signedAt: number;
  receivedAt: number;
  evidence?: EntitlementEvidence;
}

export interface SecurityStore {
  ready(signal?: AbortSignal): Promise<boolean>;
  createChallenge(purpose: ChallengePurpose, keyIDHash: string, ttlMs: number, signal?: AbortSignal): Promise<AssertionChallenge>;
  createSessionChallengePool(keyIDHash: string, count: number, ttlMs: number, now: number, maximumPoolsPerMinute: number, signal?: AbortSignal): Promise<AssertionChallenge[]>;
  establishSessionWithEvidence(input: EstablishSessionInput, signal?: AbortSignal): Promise<EstablishSessionResult>;
  consumeChallenge(token: string, purpose: ChallengePurpose, keyIDHash: string, now: number, signal?: AbortSignal): Promise<string>;
  putRegisteredKey(key: RegisteredKey, signal?: AbortSignal): Promise<void>;
  getRegisteredKey(keyIDHash: string, signal?: AbortSignal): Promise<RegisteredKey | undefined>;
  advanceCounter(keyIDHash: string, previousCounter: number, nextCounter: number, now: number, signal?: AbortSignal): Promise<void>;
  getEntitlement(originalTransactionIDHash: string, signal?: AbortSignal): Promise<StoredEntitlement | undefined>;
  replaceOldestInstallationWithEvidence(input: ReplaceInstallationInput, signal?: AbortSignal): Promise<boolean>;
  removeInstallation(originalTransactionIDHash: string, keyIDHash: string, now: number, signal?: AbortSignal): Promise<void>;
  getSession(tokenHash: string, now: number, signal?: AbortSignal): Promise<StoredSession | undefined>;
  consumeQuota(input: ConsumeQuotaInput, signal?: AbortSignal): Promise<void>;
  consumeSessionAttempt(keyIDHash: string, now: number, maximumPerMinute: number, signal?: AbortSignal): Promise<void>;
  applyNotification(input: ApplyNotificationInput, signal?: AbortSignal): Promise<boolean>;
}
