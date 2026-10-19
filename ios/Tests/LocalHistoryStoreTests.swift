import Foundation
import XCTest
@testable import LocalLingo

@MainActor
final class LocalHistoryStoreTests: XCTestCase {
    func testOnDeviceRoundTripAndDeleteAll() throws {
        let store = LocalHistoryStore(inMemory: true)
        let now = Date()
        let turn = ConversationTurn(
            id: UUID(), sequence: 0, speaker: .traveler,
            sourceLocale: "en-US", targetLocale: "es-ES",
            sourceText: "Where is the station?", translatedText: "¿Dónde está la estación?",
            userEdited: false, createdAt: now, entities: [], route: .local, recognitionConfidence: 0.92
        )
        let record = ConversationRecord(
            id: UUID(), createdAt: now, updatedAt: now,
            languageA: "en-US", languageB: "es-ES", title: "Test", turns: [turn]
        )
        try store.save(record, enabled: true)
        XCTAssertEqual(try store.load(enabled: true), [record])
        try store.deleteAll()
        XCTAssertTrue(try store.load(enabled: true).isEmpty)
    }

    func testDisabledConsentWritesNothing() throws {
        let store = LocalHistoryStore(inMemory: true)
        let now = Date()
        let record = ConversationRecord(id: UUID(), createdAt: now, updatedAt: now, languageA: "en-US", languageB: "ja-JP", title: "Disabled", turns: [])
        try store.save(record, enabled: false)
        XCTAssertTrue(try store.load(enabled: true).isEmpty)
        XCTAssertNil(store.storageDirectoryURL)
    }

    func testHistoryLoadsInBoundedPages() throws {
        let store = LocalHistoryStore(inMemory: true)
        let base = Date()
        for index in 0..<(LocalHistoryPolicy.pageSize + 1) {
            try store.save(makeRecord(updatedAt: base.addingTimeInterval(Double(index))), enabled: true)
        }

        let first = try store.loadPage(enabled: true, offset: 0)
        XCTAssertEqual(first.records.count, LocalHistoryPolicy.pageSize)
        XCTAssertTrue(first.hasMore)
        let second = try store.loadPage(enabled: true, offset: first.nextOffset)
        XCTAssertEqual(second.records.count, 1)
        XCTAssertFalse(second.hasMore)
    }

    func testInvalidConfidenceIsRejectedBeforePersistence() throws {
        let store = LocalHistoryStore(inMemory: true)
        let now = Date()
        let invalidTurn = ConversationTurn(
            id: UUID(), sequence: 0, speaker: .traveler,
            sourceLocale: "en-US", targetLocale: "es-ES",
            sourceText: "Hello", translatedText: "Hola", userEdited: false,
            createdAt: now, entities: [], route: .local, recognitionConfidence: .infinity
        )
        let invalid = ConversationRecord(
            id: UUID(), createdAt: now, updatedAt: now,
            languageA: "en-US", languageB: "es-ES", title: "Invalid", turns: [invalidTurn]
        )

        XCTAssertThrowsError(try store.save(invalid, enabled: true)) { error in
            XCTAssertEqual(error as? LocalHistoryError, .invalidRecord)
        }
        XCTAssertTrue(try store.load(enabled: true).isEmpty)
    }

    func testContinuousReviewMetadataRoundTrips() throws {
        let store = LocalHistoryStore(inMemory: true)
        let now = Date()
        let turn = ConversationTurn(
            id: UUID(), sequence: 0, speaker: .traveler,
            sourceLocale: "en-US", targetLocale: "es-ES",
            sourceText: "Where is the station?", translatedText: "¿Dónde está la estación?",
            userEdited: false, createdAt: now, entities: [], route: .local,
            recognitionConfidence: 0.72, warnings: [.uncertainRecognition],
            languageReviewStatus: .needsReview,
            alternateTranscript: AlternateTranscript(
                locale: "es-ES",
                text: "¿Dónde está la estación?",
                recognitionConfidence: 0.65
            )
        )
        let record = ConversationRecord(
            id: UUID(), createdAt: now, updatedAt: now,
            languageA: "en-US", languageB: "es-ES", title: "Continuous", turns: [turn]
        )

        try store.save(record, enabled: true)

        XCTAssertEqual(try store.load(enabled: true), [record])
    }

    func testHindiConversationRoundTripsWithoutLosingScriptOrLocale() throws {
        let store = LocalHistoryStore(inMemory: true)
        let now = Date()
        let turn = ConversationTurn(
            id: UUID(), sequence: 0, speaker: .local,
            sourceLocale: "hi-IN", targetLocale: "en-US",
            sourceText: "रेलवे स्टेशन कहाँ है?",
            translatedText: "Where is the railway station?",
            userEdited: false, createdAt: now, entities: [], route: .local,
            recognitionConfidence: 0.84
        )
        let record = ConversationRecord(
            id: UUID(), createdAt: now, updatedAt: now,
            languageA: "en-US", languageB: "hi-IN", title: "हिन्दी", turns: [turn]
        )

        try store.save(record, enabled: true)

        XCTAssertEqual(try store.load(enabled: true), [record])
    }

    func testAlternateTranscriptMustUseOppositeLocale() throws {
        let store = LocalHistoryStore(inMemory: true)
        let now = Date()
        let turn = ConversationTurn(
            id: UUID(), sequence: 0, speaker: .traveler,
            sourceLocale: "en-US", targetLocale: "es-ES",
            sourceText: "Hello", translatedText: "Hola",
            userEdited: false, createdAt: now, entities: [], route: .local,
            recognitionConfidence: 0.8,
            alternateTranscript: AlternateTranscript(
                locale: "en-US",
                text: "Hello",
                recognitionConfidence: 0.7
            )
        )
        let record = ConversationRecord(
            id: UUID(), createdAt: now, updatedAt: now,
            languageA: "en-US", languageB: "es-ES", title: "Invalid", turns: [turn]
        )

        XCTAssertThrowsError(try store.save(record, enabled: true)) { error in
            XCTAssertEqual(error as? LocalHistoryError, .invalidRecord)
        }
    }

    func testTooManyEntitiesAreRejectedBeforeEncoding() throws {
        let store = LocalHistoryStore(inMemory: true)
        let now = Date()
        let entities = (0...ConversationContentPolicy.maximumSafetyEntities).map {
            CriticalEntity(kind: .number, value: String($0))
        }
        let invalidTurn = ConversationTurn(
            id: UUID(), sequence: 0, speaker: .traveler,
            sourceLocale: "en-US", targetLocale: "ja-JP",
            sourceText: "Hello", translatedText: "こんにちは", userEdited: false,
            createdAt: now, entities: entities, route: .local, recognitionConfidence: 0.9
        )
        let invalid = ConversationRecord(
            id: UUID(), createdAt: now, updatedAt: now,
            languageA: "en-US", languageB: "ja-JP", title: "Invalid", turns: [invalidTurn]
        )

        XCTAssertThrowsError(try store.save(invalid, enabled: true))
    }

    private func makeRecord(updatedAt: Date) -> ConversationRecord {
        let turn = ConversationTurn(
            id: UUID(), sequence: 0, speaker: .traveler,
            sourceLocale: "en-US", targetLocale: "es-ES",
            sourceText: "Where is the station?", translatedText: "¿Dónde está la estación?",
            userEdited: false, createdAt: updatedAt, entities: [], route: .local, recognitionConfidence: 0.92
        )
        return ConversationRecord(
            id: UUID(), createdAt: updatedAt, updatedAt: updatedAt,
            languageA: "en-US", languageB: "es-ES", title: "Test", turns: [turn]
        )
    }
}
