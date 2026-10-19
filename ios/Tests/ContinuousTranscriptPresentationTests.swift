import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import LocalLingo

final class ContinuousTranscriptPresentationTests: XCTestCase {
    func testNewestTurnUsesHighestSequenceRegardlessOfArrayOrder() {
        let first = turn(sequence: 2)
        let newest = turn(sequence: 9)
        let middle = turn(sequence: 5)

        XCTAssertEqual(
            ContinuousTranscriptPresentation.newestTurnID(
                in: [newest, first, middle]
            ),
            newest.id
        )
    }

    func testNewestTurnIsNilForEmptyTranscript() {
        XCTAssertNil(ContinuousTranscriptPresentation.newestTurnID(in: []))
    }

    func testNewestTurnScalesToMaximumTranscriptLength() {
        let turns = (0..<500).reversed().map { turn(sequence: $0) }

        XCTAssertEqual(
            ContinuousTranscriptPresentation.newestTurnID(in: turns),
            turns.first?.id
        )
    }

    func testPlaybackPresentationKeepsStableSafetyAndActivityStates() {
        XCTAssertEqual(
            ContinuousTurnPlaybackPresentation.resolve(
                isActive: false,
                canReplay: true,
                isSafetyBlocked: false
            ),
            .ready
        )
        XCTAssertEqual(
            ContinuousTurnPlaybackPresentation.resolve(
                isActive: true,
                canReplay: false,
                isSafetyBlocked: false
            ),
            .playing
        )
        XCTAssertEqual(
            ContinuousTurnPlaybackPresentation.resolve(
                isActive: false,
                canReplay: false,
                isSafetyBlocked: false
            ),
            .temporarilyUnavailable
        )
        XCTAssertEqual(
            ContinuousTurnPlaybackPresentation.resolve(
                isActive: true,
                canReplay: true,
                isSafetyBlocked: true
            ),
            .safetyBlocked
        )
    }

    func testOnlyReadyPlaybackPresentationIsEnabled() {
        XCTAssertTrue(ContinuousTurnPlaybackPresentation.ready.isEnabled)
        XCTAssertFalse(ContinuousTurnPlaybackPresentation.playing.isEnabled)
        XCTAssertFalse(
            ContinuousTurnPlaybackPresentation.temporarilyUnavailable.isEnabled
        )
        XCTAssertFalse(ContinuousTurnPlaybackPresentation.safetyBlocked.isEnabled)
        XCTAssertEqual(
            ContinuousTurnPlaybackPresentation.playing.systemImage,
            "speaker.wave.2.fill"
        )
        XCTAssertEqual(
            ContinuousTurnPlaybackPresentation.safetyBlocked.systemImage,
            "speaker.slash.fill"
        )
    }

    @MainActor
    func testTurnRowsRenderAtDefaultAndAccessibilityTextSizes() throws {
        let older = turn(
            sequence: 2,
            sourceText: "Where is the nearest train station?",
            translatedText: "¿Dónde está la estación de tren más cercana?"
        )
        let newest = turn(
            sequence: 9,
            speaker: .local,
            sourceLocale: AppLanguage.spanishSpain.code,
            targetLocale: AppLanguage.englishUS.code,
            sourceText: "Está a dos calles, junto al hotel.",
            translatedText: "It is two blocks away, next to the hotel."
        )

        let standard = try renderFixture(older: older, newest: newest)
        let accessibility = try renderFixture(
            older: older,
            newest: newest,
            dynamicTypeSize: .accessibility3
        )

        XCTAssertGreaterThan(standard.size.height, 200)
        XCTAssertGreaterThan(accessibility.size.height, standard.size.height)
        attach(standard, name: "continuous-transcript-standard")
        attach(accessibility, name: "continuous-transcript-accessibility")
    }

    @MainActor
    private func renderFixture(
        older: ConversationTurn,
        newest: ConversationTurn,
        dynamicTypeSize: DynamicTypeSize = .large
    ) throws -> UIImage {
        let content = VStack(spacing: 0) {
            row(older, isNewest: false)
            row(newest, isNewest: true)
        }
        .frame(width: 390)
        .padding(.vertical, 12)
        .background(Color(uiColor: .systemBackground))
        .environment(\.dynamicTypeSize, dynamicTypeSize)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.uiImage else {
            throw XCTSkip("SwiftUI could not render the transcript fixture.")
        }
        return image
    }

    @MainActor
    private func row(_ turn: ConversationTurn, isNewest: Bool) -> some View {
        ContinuousTurnRow(
            turn: turn,
            isNewest: isNewest,
            allowsLanguageCorrection: true,
            isReviewedPlaybackActive: false,
            canReplayTranslation: true,
            onSwapLanguage: {},
            onReplayTranslation: {}
        )
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func turn(
        sequence: Int,
        speaker: SpeakerSide = .traveler,
        sourceLocale: String = AppLanguage.englishUS.code,
        targetLocale: String = AppLanguage.spanishSpain.code,
        sourceText: String = "Hello",
        translatedText: String = "Hola"
    ) -> ConversationTurn {
        ConversationTurn(
            id: UUID(),
            sequence: sequence,
            speaker: speaker,
            sourceLocale: sourceLocale,
            targetLocale: targetLocale,
            sourceText: sourceText,
            translatedText: translatedText,
            userEdited: false,
            createdAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
            entities: [],
            route: .local,
            recognitionConfidence: 0.95
        )
    }
}
