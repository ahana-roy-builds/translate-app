import XCTest
@testable import LocalLingo

@MainActor
final class OnlineTypedTranslationTests: XCTestCase {
    func testAlteredBackendSourceEchoIsRejected() async {
        let client = MockOnlineTranslationClient(response: response(source: "I need ibuprofen"))
        let pipeline = OnlineConversationPipeline(client: client) { "signed-transaction" }

        do {
            _ = try await pipeline.translateText("I need warfarin", source: .englishUS, target: .spanishSpain)
            XCTFail("An altered typed-source echo must fail closed")
        } catch PipelineError.malformedResponse {
            // Expected: backend text cannot replace the user's typed source.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testValidatedRequestTextRemainsAuthoritativeSource() async throws {
        let client = MockOnlineTranslationClient(response: response(source: "I need warfarin"))
        let pipeline = OnlineConversationPipeline(client: client) { "signed-transaction" }

        let result = try await pipeline.translateText("  I need warfarin  ", source: .englishUS, target: .spanishSpain)

        XCTAssertEqual(client.lastTypedRequest, "I need warfarin")
        XCTAssertEqual(result.sourceText, "I need warfarin")
        XCTAssertEqual(result.translatedText, "Necesito warfarina")
    }

    private func response(source: String) -> OnlineTurnResponse {
        OnlineTurnResponse(
            sourceText: source,
            translatedText: "Necesito warfarina",
            recognitionConfidence: nil,
            engine: "mock",
            warnings: [],
            timingsMs: ["translation": 1]
        )
    }
}

@MainActor
private final class MockOnlineTranslationClient: OnlineTranslationClient {
    let response: OnlineTurnResponse
    private(set) var lastTypedRequest: String?

    init(response: OnlineTurnResponse) { self.response = response }

    func prepareSecurity(signedTransaction: String) async throws {}

    func translateTurn(
        audio: AudioTurn,
        source: AppLanguage,
        target: AppLanguage,
        signedTransaction: String
    ) async throws -> OnlineTurnResponse { response }

    func translateText(
        _ text: String,
        source: AppLanguage,
        target: AppLanguage,
        signedTransaction: String
    ) async throws -> OnlineTurnResponse {
        lastTypedRequest = text
        return response
    }

    func cancel() {}
}
