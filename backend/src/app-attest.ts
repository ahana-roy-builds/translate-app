import { createHash, verify, X509Certificate } from "node:crypto";
import { ApiError } from "./errors.js";
import { appAttestKeyIDHash, decodeCanonicalAppAttestKeyID } from "./app-attest-key.js";
import { cborMap, decodeCBOR, decodeCBORPrefix } from "./cbor.js";
import type { AppAttestService, AttestationRegistration, AttestationRegistrationInput } from "./contracts.js";

interface Options {
  appIDPrefix: string;
  bundleID: string;
  environment: "development" | "production";
  rootCertificatePEM: string;
  allowedBundleVersions: readonly string[];
  allowedValidationCategories: readonly number[];
}

const NONCE_EXTENSION_OID_VALUE = Buffer.from("2a864886f763640802", "hex");
const DEV_AAGUID = Buffer.from("appattestdevelop", "ascii");
const PROD_AAGUID = Buffer.concat([Buffer.from("appattest", "ascii"), Buffer.alloc(7)]);

function invalid(code = "INVALID_APP_ATTEST"): ApiError {
  return new ApiError(401, code, "App Attest credential is invalid");
}

function certificateChain(rawChain: unknown, root: X509Certificate): X509Certificate[] {
  if (!Array.isArray(rawChain) || rawChain.length !== 2 || rawChain.some((item) => !Buffer.isBuffer(item))) throw invalid();
  let certificates: X509Certificate[];
  try { certificates = rawChain.map((item) => new X509Certificate(item as Buffer)); } catch { throw invalid(); }
  const now = Date.now();
  for (const certificate of [...certificates, root]) {
    if (Date.parse(certificate.validFrom) > now || Date.parse(certificate.validTo) <= now) throw invalid("EXPIRED_APP_ATTEST_CERTIFICATE");
  }
  const [leaf, intermediate] = certificates as [X509Certificate, X509Certificate];
  if (leaf.ca || !intermediate.ca || leaf.issuer !== intermediate.subject || !leaf.verify(intermediate.publicKey)) throw invalid();
  if (intermediate.issuer !== root.subject || !intermediate.verify(root.publicKey)) throw invalid("UNTRUSTED_APP_ATTEST_CERTIFICATE");
  return certificates;
}

interface AuthenticatorExtensions { validationCategory: number; bundleVersion: string; }

function extensions(value: unknown): AuthenticatorExtensions {
  const map = cborMap(value, "INVALID_APP_ATTEST_EXTENSIONS");
  const category = map.get("apple_validation_category_01");
  const bundleVersion = map.get("apple_bundle_version_01");
  if (!Buffer.isBuffer(category) || category.length !== 4 || typeof bundleVersion !== "string" || !bundleVersion || bundleVersion.length > 64) throw invalid("INVALID_APP_ATTEST_EXTENSIONS");
  return { validationCategory: category.readUInt32LE(0), bundleVersion };
}

function cosePublicKeyIdentifier(value: unknown): Buffer {
  const map = cborMap(value, "INVALID_APP_ATTEST_PUBLIC_KEY");
  const x = map.get(-2), y = map.get(-3);
  if (map.get(1) !== 2 || map.get(3) !== -7 || map.get(-1) !== 1 || !Buffer.isBuffer(x) || x.length !== 32 || !Buffer.isBuffer(y) || y.length !== 32) throw invalid("INVALID_APP_ATTEST_PUBLIC_KEY");
  return createHash("sha256").update(Buffer.concat([Buffer.from([0x04]), x, y])).digest();
}

export function authenticatorData(value: unknown, rpIDHash: Buffer, requireCredential: boolean): { bytes: Buffer; counter: number; credentialID?: Buffer; publicKeyIdentifier?: Buffer; extensions?: AuthenticatorExtensions } {
  if (!Buffer.isBuffer(value) || value.length < (requireCredential ? 55 : 37)) throw invalid();
  if (!value.subarray(0, 32).equals(rpIDHash)) throw invalid("INVALID_APP_ID");
  const flags = value[32]!;
  // App Attest does not represent a user-presence ceremony. Only attested credential
  // data (AT) is required during registration; assertions legitimately omit UP.
  if (requireCredential && (flags & 0x40) === 0) throw invalid();
  const counter = value.readUInt32BE(33);
  if (!requireCredential) {
    if ((flags & 0x40) !== 0) throw invalid();
    if ((flags & 0x80) === 0) {
      if (value.length !== 37) throw invalid();
      return { bytes: value, counter };
    }
    const decoded = decodeCBORPrefix(value, 37);
    if (decoded.nextOffset !== value.length) throw invalid("INVALID_APP_ATTEST_EXTENSIONS");
    return { bytes: value, counter, extensions: extensions(decoded.value) };
  }
  const credentialLength = value.readUInt16BE(53);
  if (credentialLength < 16 || 55 + credentialLength > value.length) throw invalid();
  const credentialID = value.subarray(55, 55 + credentialLength);
  const publicKey = decodeCBORPrefix(value, 55 + credentialLength);
  let parsedExtensions: AuthenticatorExtensions | undefined;
  if ((flags & 0x80) !== 0) {
    const decodedExtensions = decodeCBORPrefix(value, publicKey.nextOffset);
    if (decodedExtensions.nextOffset !== value.length) throw invalid("INVALID_APP_ATTEST_EXTENSIONS");
    parsedExtensions = extensions(decodedExtensions.value);
  } else if (publicKey.nextOffset !== value.length) {
    throw invalid();
  }
  return { bytes: value, counter, credentialID, publicKeyIdentifier: cosePublicKeyIdentifier(publicKey.value), ...(parsedExtensions ? { extensions: parsedExtensions } : {}) };
}

interface TLV { tag: number; contentStart: number; contentEnd: number; next: number; }
function tlv(buffer: Buffer, offset: number, limit = buffer.length): TLV | undefined {
  if (offset + 2 > limit) return undefined;
  const tag = buffer[offset]!, firstLength = buffer[offset + 1]!;
  let cursor = offset + 2, length = firstLength;
  if ((firstLength & 0x80) !== 0) {
    const bytes = firstLength & 0x7f;
    if (bytes < 1 || bytes > 4 || cursor + bytes > limit) return undefined;
    length = 0;
    for (let index = 0; index < bytes; index += 1) length = length * 256 + buffer[cursor++]!;
  }
  if (cursor + length > limit) return undefined;
  return { tag, contentStart: cursor, contentEnd: cursor + length, next: cursor + length };
}

export function nonceFromExtensionValue(value: Buffer): Buffer | undefined {
  const sequence = tlv(value, 0);
  if (!sequence || sequence.tag !== 0x30 || sequence.next !== value.length) return undefined;
  const explicit = tlv(value, sequence.contentStart, sequence.contentEnd);
  if (!explicit || explicit.tag !== 0xa1 || explicit.next !== sequence.contentEnd) return undefined;
  const octet = tlv(value, explicit.contentStart, explicit.contentEnd);
  if (!octet || octet.tag !== 0x04 || octet.next !== explicit.contentEnd || octet.contentEnd - octet.contentStart !== 32) return undefined;
  return value.subarray(octet.contentStart, octet.contentEnd);
}

function findNonceExtension(buffer: Buffer, start: number, end: number, depth = 0): Buffer | undefined {
  if (depth > 12) return undefined;
  let cursor = start;
  while (cursor < end) {
    const node = tlv(buffer, cursor, end);
    if (!node) return undefined;
    if (node.tag === 0x30) {
      const oid = tlv(buffer, node.contentStart, node.contentEnd);
      if (oid?.tag === 0x06 && buffer.subarray(oid.contentStart, oid.contentEnd).equals(NONCE_EXTENSION_OID_VALUE)) {
        let next = tlv(buffer, oid.next, node.contentEnd);
        if (next?.tag === 0x01) next = tlv(buffer, next.next, node.contentEnd);
        if (!next || next.tag !== 0x04 || next.next !== node.contentEnd) return undefined;
        return nonceFromExtensionValue(buffer.subarray(next.contentStart, next.contentEnd));
      }
    }
    if ((node.tag & 0x20) !== 0) {
      const found = findNonceExtension(buffer, node.contentStart, node.contentEnd, depth + 1);
      if (found) return found;
    }
    cursor = node.next;
  }
  return undefined;
}

function containsNonceExtension(certificate: X509Certificate, nonce: Buffer): boolean {
  return findNonceExtension(certificate.raw, 0, certificate.raw.length)?.equals(nonce) === true;
}

export function x963PublicKeyIdentifierFromJWK(jwk: JsonWebKey): Buffer {
  if (jwk.kty !== "EC" || jwk.crv !== "P-256" || !jwk.x || !jwk.y) throw invalid();
  const x = Buffer.from(jwk.x, "base64url"), y = Buffer.from(jwk.y, "base64url");
  if (x.length !== 32 || y.length !== 32) throw invalid();
  return createHash("sha256").update(Buffer.concat([Buffer.from([0x04]), x, y])).digest();
}

export function x963PublicKeyIdentifier(certificate: X509Certificate): Buffer {
  return x963PublicKeyIdentifierFromJWK(certificate.publicKey.export({ format: "jwk" }));
}

function strictKeyID(value: string): Buffer {
  try { return decodeCanonicalAppAttestKeyID(value); }
  catch { throw invalid("INVALID_APP_ATTEST_KEY_ID"); }
}

export class ProductionAppAttestService implements AppAttestService {
  private readonly options: Options;
  private readonly rpIDHash: Buffer;
  private readonly root: X509Certificate;
  constructor(options: Options) {
    this.options = options;
    this.rpIDHash = createHash("sha256").update(`${options.appIDPrefix}.${options.bundleID}`, "utf8").digest();
    try {
      this.root = new X509Certificate(options.rootCertificatePEM);
    } catch {
      throw new Error("APPLE_APP_ATTEST_ROOT_CA_PEM is not a valid certificate");
    }
    if (!this.root.ca || !this.root.verify(this.root.publicKey)) throw new Error("APPLE_APP_ATTEST_ROOT_CA_PEM is not a self-signed CA certificate");
  }

  private validateExtensions(value: AuthenticatorExtensions | undefined): void {
    // These fields are emitted on iOS 27 and later. iOS 26 remains supported,
    // so absence is accepted; when present, every value is enforced.
    if (!value) return;
    const categories = new Set(this.options.allowedValidationCategories);
    if (!categories.has(value.validationCategory) || !this.options.allowedBundleVersions.includes(value.bundleVersion)) throw invalid("INVALID_APP_ATTEST_EXTENSIONS");
  }

  async register(input: AttestationRegistrationInput): Promise<AttestationRegistration> {
    const object = cborMap(decodeCBOR(input.attestationObject), "INVALID_ATTESTATION_OBJECT");
    if (object.get("fmt") !== "apple-appattest") throw invalid();
    const statement = cborMap(object.get("attStmt"), "INVALID_ATTESTATION_OBJECT");
    const chain = certificateChain(statement.get("x5c"), this.root);
    if (!Buffer.isBuffer(statement.get("receipt")) || (statement.get("receipt") as Buffer).length < 32) throw invalid();
    const auth = authenticatorData(object.get("authData"), this.rpIDHash, true);
    this.validateExtensions(auth.extensions);
    if (auth.counter !== 0) throw invalid("INVALID_APP_ATTEST_COUNTER");
    const expectedAAGUID = this.options.environment === "development" ? DEV_AAGUID : PROD_AAGUID;
    if (!auth.bytes.subarray(37, 53).equals(expectedAAGUID)) throw invalid("INVALID_APP_ATTEST_ENVIRONMENT");
    const keyID = strictKeyID(input.keyID);
    if (!auth.credentialID?.equals(keyID)) throw invalid("INVALID_APP_ATTEST_KEY_ID");
    const nonce = createHash("sha256").update(auth.bytes).update(input.clientDataHash).digest();
    if (!containsNonceExtension(chain[0]!, nonce)) throw invalid("INVALID_APP_ATTEST_NONCE");
    if (!x963PublicKeyIdentifier(chain[0]!).equals(keyID)) throw invalid("INVALID_APP_ATTEST_KEY_ID");
    if (!auth.publicKeyIdentifier?.equals(keyID)) throw invalid("INVALID_APP_ATTEST_PUBLIC_KEY");
    return {
      keyIDHash: appAttestKeyIDHash(input.keyID),
      publicKeyPem: chain[0]!.publicKey.export({ type: "spki", format: "pem" }).toString(),
      counter: 0,
      environment: this.options.environment,
      ...(auth.extensions ? { validationCategory: auth.extensions.validationCategory, bundleVersion: auth.extensions.bundleVersion } : {})
    };
  }

  async verifyAssertion(publicKeyPem: string, assertion: Buffer, clientDataHash: Buffer, previousCounter: number): Promise<number> {
    const object = cborMap(decodeCBOR(assertion), "INVALID_ASSERTION_OBJECT");
    const signature = object.get("signature");
    const auth = authenticatorData(object.get("authenticatorData"), this.rpIDHash, false);
    this.validateExtensions(auth.extensions);
    if (!Buffer.isBuffer(signature) || signature.length < 64 || signature.length > 80) throw invalid("INVALID_APP_ATTEST_ASSERTION");
    if (auth.counter <= previousCounter) throw invalid("INVALID_APP_ATTEST_COUNTER");
    const valid = verify("sha256", Buffer.concat([auth.bytes, clientDataHash]), publicKeyPem, signature);
    if (!valid) throw invalid("INVALID_APP_ATTEST_ASSERTION");
    return auth.counter;
  }
}

/** Explicitly injectable test/development adapter; never constructed by the production entry point. */
export class DevelopmentAppAttestService implements AppAttestService {
  async register(input: AttestationRegistrationInput): Promise<AttestationRegistration> {
    return { keyIDHash: appAttestKeyIDHash(input.keyID), publicKeyPem: "development", counter: 0, environment: "development" };
  }
  async verifyAssertion(_key: string, _assertion: Buffer, _hash: Buffer, previousCounter: number): Promise<number> { return previousCounter + 1; }
}
