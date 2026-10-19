import { createHash } from "node:crypto";

/**
 * App Attest key identifiers are SHA-256 public-key digests. Accept either of
 * the two canonical encodings Apple clients use, but never mixed alphabets or
 * non-zero base64 pad bits.
 */
export function decodeCanonicalAppAttestKeyID(value: string): Buffer {
  if (typeof value !== "string" || value.length > 64) throw new Error("invalid App Attest key identifier");
  if (!/^[A-Za-z0-9+/]{43}=$/.test(value) && !/^[A-Za-z0-9_-]{43}$/.test(value)) {
    throw new Error("invalid App Attest key identifier");
  }
  const decoded = Buffer.from(value, value.endsWith("=") ? "base64" : "base64url");
  if (decoded.length !== 32 || (value !== decoded.toString("base64") && value !== decoded.toString("base64url"))) {
    throw new Error("invalid App Attest key identifier");
  }
  return decoded;
}

export function appAttestKeyIDHash(value: string): string {
  return createHash("sha256").update(decodeCanonicalAppAttestKeyID(value)).digest("base64url");
}
