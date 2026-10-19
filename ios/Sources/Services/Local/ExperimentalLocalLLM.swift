import CryptoKit
import Foundation

#if LOCAL_LLM_EXPERIMENT && canImport(MLXLLM)
import MLXLLM
#endif

struct ExperimentalModelManifest: Codable, Equatable, Sendable {
    let modelID: String
    let version: String
    let artifactURL: URL
    let byteCount: Int64
    let sha256: String
    let signature: String

    var isApprovedQwenArtifact: Bool {
        modelID == "Qwen3-4B-Instruct-2507-4bit" && artifactURL.scheme == "https" && artifactURL.host != "huggingface.co"
    }
}

struct ExperimentalTranslationConfiguration: Equatable, Sendable {
    let temperature: Double = 0
    let seed: UInt64 = 0
    let maximumInputTokens = 256
    let maximumOutputTokens = 384
}

enum ExperimentalLocalLLMEligibility {
    static func failureReason(processInfo: ProcessInfo = .processInfo, freeDiskBytes: Int64?) -> String? {
        guard processInfo.physicalMemory >= 8 * 1_024 * 1_024 * 1_024 else { return "This experiment requires at least 8 GB of memory." }
        guard let freeDiskBytes, freeDiskBytes >= 6 * 1_024 * 1_024 * 1_024 else { return "This experiment requires 6 GB of free storage." }
        guard processInfo.thermalState == .nominal || processInfo.thermalState == .fair else { return "The device must cool down before loading the model." }
        return nil
    }
}

enum ExperimentalManifestVerifier {
    static func verify(_ manifest: ExperimentalModelManifest, artifactURL: URL, publicKey: Curve25519.Signing.PublicKey) -> Bool {
        guard manifest.isApprovedQwenArtifact,
              manifest.byteCount > 0,
              manifest.byteCount <= 6 * 1_024 * 1_024 * 1_024,
              let artifactDigest = try? sha256AndSize(of: artifactURL),
              artifactDigest.size == manifest.byteCount,
              artifactDigest.digest == manifest.sha256.lowercased(),
              let signatureData = Data(base64Encoded: manifest.signature),
              let signedPayload = try? canonicalPayload(manifest) else { return false }
        return publicKey.isValidSignature(signatureData, for: signedPayload)
    }

    private static func canonicalPayload(_ manifest: ExperimentalModelManifest) throws -> Data {
        let unsigned = UnsignedManifest(modelID: manifest.modelID, version: manifest.version, artifactURL: manifest.artifactURL, byteCount: manifest.byteCount, sha256: manifest.sha256.lowercased())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(unsigned)
    }

    private struct UnsignedManifest: Encodable {
        let modelID: String
        let version: String
        let artifactURL: URL
        let byteCount: Int64
        let sha256: String
    }

    private static func sha256AndSize(of url: URL) throws -> (digest: String, size: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            size += Int64(chunk.count)
            guard size <= 6 * 1_024 * 1_024 * 1_024 else { throw PipelineError.server("Experimental artifact exceeds its size limit.") }
            hasher.update(data: chunk)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }
}

/// Research-only seam for an MLX adapter. App Store builds compile the fail-
/// closed implementation below and cannot select this engine.
@MainActor
final class ExperimentalLocalLLMTranslationEngine: TranslationEngine {
    typealias Translator = @MainActor (_ text: String, _ source: Locale.Language, _ target: Locale.Language, _ configuration: ExperimentalTranslationConfiguration) async throws -> String
    private let translator: Translator?

    #if LOCAL_LLM_EXPERIMENT && canImport(MLXLLM)
    init(translator: @escaping Translator) { self.translator = translator }
    #else
    init() { translator = nil }
    #endif

    func availability(source: Locale.Language, target: Locale.Language) async -> ComponentReadiness {
        translator == nil ? .unavailable : .ready
    }

    func prepare(source: Locale.Language, target: Locale.Language) async throws {
        guard translator != nil else { throw PipelineError.assetsUnavailable("The experimental local LLM is not included in this build.") }
    }

    func translate(_ text: String, source: Locale.Language, target: Locale.Language) async throws -> String {
        guard let translator else { throw PipelineError.assetsUnavailable("The experimental local LLM is not included in this build.") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Until the pinned MLX tokenizer is connected, a UTF-8 cap is the only
        // language-independent fail-closed approximation of the 256-token limit.
        guard !trimmed.isEmpty, trimmed.utf8.count <= 1_024 else { throw PipelineError.server("Experimental model input is outside its safety limit.") }
        let result = try await translator(trimmed, source, target, ExperimentalTranslationConfiguration())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, !result.contains("<tool"), !result.contains("```"), result.count <= 2_048 else {
            throw PipelineError.server("The experimental model produced an invalid translation-only response.")
        }
        return try TurnTextPolicy.validatedFinal(result, field: "translation")
    }

    func cancel() {}
}
