import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";

const target = new URL("../node_modules/@apple/app-store-server-library/dist/jws_verification.js", import.meta.url);
const originalHash = "2ab29caa890958dcfc6dc4789fd5a500e8249102e037045525d35e5c15541bf1";
const legacyPatchedHash = "80562b93d89da11c691cdb8810a83484a078c3f60bc984f1be2ba177f30ec4a5";
const patchedHash = "a2cd5257b500600fa804bf4ab39658e7b3d6c722c8405497d2372addb23183bc";
const legacyPatchedText = "timeout: 6000,\n                size: 64 * 1024";
const originalTimeoutText = "timeout: 30000";
const originalText = `        let response;
        try {
            response = await (0, node_fetch_1.default)(matchResult[1], {
                headers: headers,
                method: 'POST',
                body: Buffer.from(request.getEncodedHex(), 'hex'),
                timeout: 30000
            });
            if (!response.ok) {
                throw new VerificationException(VerificationStatus.RETRYABLE_VERIFICATION_FAILURE);
            }
        }
        catch (error) {
            if (error instanceof VerificationException) {
                throw error;
            }
            // Network errors
            throw new VerificationException(VerificationStatus.RETRYABLE_VERIFICATION_FAILURE, error instanceof Error ? error : undefined);
        }
        const responseBuffer = await response.buffer();`;
const patchedText = `        let response;
        let responseBuffer;
        const deadline = AbortSignal.timeout(6000);
        try {
            response = await (0, node_fetch_1.default)(matchResult[1], {
                headers: headers,
                method: 'POST',
                body: Buffer.from(request.getEncodedHex(), 'hex'),
                timeout: 6000,
                size: 64 * 1024,
                redirect: 'follow',
                follow: 1,
                signal: deadline
            });
            if (!response.ok) {
                throw new VerificationException(VerificationStatus.RETRYABLE_VERIFICATION_FAILURE);
            }
            responseBuffer = await response.buffer();
        }
        catch (error) {
            if (error instanceof VerificationException) {
                throw error;
            }
            // Network errors
            throw new VerificationException(VerificationStatus.RETRYABLE_VERIFICATION_FAILURE, error instanceof Error ? error : undefined);
        }`;

function digest(value) {
  return createHash("sha256").update(value).digest("hex");
}

const current = await readFile(target);
const currentHash = digest(current);
if (currentHash === patchedHash) process.exit(0);
let source = current.toString("utf8");
if (currentHash === legacyPatchedHash) {
  if (source.split(legacyPatchedText).length !== 2) throw new Error("Legacy Apple OCSP patch bytes do not match the reviewed seam");
  source = source.replace(legacyPatchedText, originalTimeoutText);
  if (digest(Buffer.from(source, "utf8")) !== originalHash) throw new Error("Legacy Apple OCSP patch does not reconstruct the reviewed upstream artifact");
} else if (currentHash !== originalHash) {
  throw new Error(`Refusing to patch unexpected App Store library bytes (${currentHash})`);
}
if (source.split(originalText).length !== 2) throw new Error("Expected exactly one Apple OCSP timeout seam");
const patched = Buffer.from(source.replace(originalText, patchedText), "utf8");
if (digest(patched) !== patchedHash) throw new Error(`Patched App Store library hash does not match the reviewed artifact (${digest(patched)})`);
await writeFile(target, patched);
