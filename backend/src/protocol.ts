import { createHash } from "node:crypto";

export interface CanonicalRequestInput {
  method: string;
  path: string;
  challenge: string;
  keyID: string;
  releaseBuildID: string;
  backendOCIDigest: string;
  runtimeEnvironment: string;
  cloudRunRevision: string;
  sessionToken?: string;
  sourceLocale?: string;
  targetLocale?: string;
  body: Buffer;
}

export function sha256Base64URL(value: string | Buffer): string {
  return createHash("sha256").update(value).digest("base64url");
}

/**
 * This exact 32-byte value is passed to DCAppAttestService.generateAssertion.
 * The body is hashed independently so binary and JSON requests share one contract.
 */
export function canonicalRequestDigest(input: CanonicalRequestInput): Buffer {
  const sessionHash = input.sessionToken ? sha256Base64URL(Buffer.from(input.sessionToken, "utf8")) : "";
  const prefix = Buffer.from(
    `locallingo-request-v3\n${input.method.toUpperCase()}\n${input.path}\n${input.challenge}\n${input.keyID}\n${sessionHash}\n${input.sourceLocale ?? ""}\n${input.targetLocale ?? ""}\n${input.releaseBuildID}\n${input.backendOCIDigest}\n${input.runtimeEnvironment}\n${input.cloudRunRevision}\n`,
    "utf8"
  );
  const bodyHash = createHash("sha256").update(input.body).digest();
  return createHash("sha256").update(prefix).update(bodyHash).digest();
}
