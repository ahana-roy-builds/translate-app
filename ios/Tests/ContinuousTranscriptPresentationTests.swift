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

    func testRibbonShowsSpeechOverPendingWorkAndStopsOnPause() {
        XCTAssertEqual(TalkWavePhase(state: .listening, speaking: false, replaying: false), .quiet)
        XCTAssertEqual(TalkWavePhase(state: .catchingUp(pendingTurns: 1), speaking: true, replaying: false), .speaking)
        XCTAssertEqual(TalkWavePhase(state: .catchingUp(pendingTurns: 1), speaking: false, replaying: false), .resolving)
        XCTAssertEqual(TalkWavePhase(state: .pausedForPlayback, speaking: true, replaying: false), .playback)
        XCTAssertEqual(TalkWavePhase(state: .ended, speaking: false, replaying: true), .playback)
        XCTAssertEqual(TalkWavePhase(state: .paused(.user), speaking: true, replaying: false), .quiet)
    }

    func testInterruptedActionAndParticipantLabels() {
        XCTAssertEqual(ContinuousTalkPresentation.primaryAction(for: .interrupted), .resume)
        XCTAssertEqual(ParticipantLabels(.spanishSpain).checkLanguage, "Revisa el idioma detectado")
        XCTAssertEqual(ParticipantLabels(.spanishSpain).swapLanguage, "Cambiar el idioma detectado")
    }

    func testTalkLayoutMigratesIndependentlyOfManualLayout() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"layout":"heldPhone"}"#.utf8))
        XCTAssertEqual(old.talkLayout, .faceToFace)
        XCTAssertEqual(old.layout, .heldPhone)
        var saved = old
        saved.talkLayout = .heldPhone
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(restored.talkLayout, .heldPhone)
    }

    @MainActor
    func testWaveRibbonExchangeAtPhoneSize() async throws {
        let first = turn(sequence: 0, sourceText: "Where is the station?", translatedText: "¿Dónde está la estación?")
        let early = ContinuousDraft(language: .englishUS, text: "Where is the", confidence: 0.9, score: 0.9)
        let reply = ContinuousDraft(language: .spanishSpain, text: "A cinco minutos a pie.", confidence: 0.9, score: 0.9)
        let longTurn = turn(sequence: 1, speaker: .local, sourceLocale: "es-ES", targetLocale: "en-US",
                            sourceText: "Está a cinco minutos a pie. Siga por esta calle y gire a la derecha después de la biblioteca.",
                            translatedText: "It’s a five-minute walk. Follow this street and turn right after the library.")

        func capture(_ name: String, _ turns: [ConversationTurn], _ pending: [Int: ContinuousDraft],
                     _ live: ContinuousDraft?, _ phase: TalkWavePhase, dark: Bool = false, large: Bool = false) async throws {
            func panel(_ side: SpeakerSide) -> some View {
                TalkParticipantPanel(side: side, language: LanguagePair().source(for: side), turns: turns,
                                     pending: pending, live: live,
                                     allowsCorrection: false, playbackID: nil, canReplay: { _ in true },
                                     correct: { _ in }, replay: { _ in })
            }
            let split = VStack(spacing: 0) {
                panel(.local).rotationEffect(.degrees(180))
                TalkWaveRibbon(phase: phase)
                panel(.traveler)
            }
            .environment(\.dynamicTypeSize, large ? .accessibility2 : .large)
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: 390, height: 570)
            let controller = UIHostingController(rootView: split)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 570)
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            window.rootViewController = controller
            window.isHidden = false
            defer { window.isHidden = true }
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            let bounds = controller.view.bounds
            let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in
                XCTAssertTrue(controller.view.drawHierarchy(in: bounds, afterScreenUpdates: true))
            }
            attach(image, name: name)
        }
        try await capture("First words", [], [:], early, .speaking)
        try await capture("Waiting for translation", [], [0: early], nil, .resolving)
        try await capture("First translation", [first], [:], nil, .quiet)
        try await capture("Partner replies", [first], [:], reply, .speaking, dark: true)
        let shortReply = turn(sequence: 1, speaker: .local, sourceLocale: "es-ES", targetLocale: "en-US",
                              sourceText: "Está cerca.", translatedText: "It’s nearby.")
        try await capture("Relay conversation history", [first, shortReply], [:], nil, .quiet)
        try await capture("Long reply at accessibility size", [first, longTurn], [:], nil, .quiet, large: true)
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
