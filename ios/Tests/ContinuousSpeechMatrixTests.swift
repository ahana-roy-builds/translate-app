import AVFoundation
import Combine
import CoreMedia
import Translation
import XCTest

@testable import LocalLingo

@MainActor
private final class RecordingTranslationTrace: ContinuousBidirectionalTranslating {
    let engine = ContinuousBidirectionalTranslationEngine()
    var last: [String: String] = [:]
    func prepare(pair: LanguagePair, strategy: OnDeviceTranslationStrategy) async throws {
        try await engine.prepare(pair: pair, strategy: strategy)
    }
    func translate(_ text: String, speaker: SpeakerSide, pair: LanguagePair) async throws -> String {
        last = [
            "source": pair.source(for: speaker).code, "target": pair.target(for: speaker).code,
            "asr": text,
        ]
        do {
            let output = try await engine.translate(text, speaker: speaker, pair: pair)
            last["output"] = output
            return output
        } catch {
            last["error"] = (error as NSError).description
            throw error
        }
    }
    func cancel() { engine.cancel() }
}

final class ContinuousSpeechMatrixTests: XCTestCase {
    @MainActor
    private func record(_ kind: String, _ data: [String: String]) {
        var value = data
        value["kind"] = kind
        if let d = try? JSONEncoder().encode(value) {
            print("MATRIX " + String(decoding: d, as: UTF8.self))
        }
    }

    @MainActor
    func testRecordedConversations() async throws {
        guard ProcessInfo.processInfo.environment["SPEECH_MATRIX"] == "1" else {
            throw XCTSkip("Opt-in physical iPhone speech matrix")
        }
        let languages = AppLanguage.conversationLanguages
        let root = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "continuous-speech", withExtension: nil))
        for language in languages {
            for index in Self.references(language).indices {
                let clip = root.appendingPathComponent("\(language.code)-\(index).wav")
                XCTAssertGreaterThan(try AVAudioFile(forReading: clip).length, 0)
            }
        }
        let bridge = ProcessInfo.processInfo.environment["SPEECH_BRIDGE"] == "1"
        func reference(_ source: AppLanguage, _ index: Int) -> String {
            if bridge && source == .spanishSpain && index == 0 { return "La estación está cerca del puente." }
            return Self.references(source)[index]
        }
        func clip(_ source: AppLanguage, _ index: Int) -> URL {
            let name = bridge && source == .spanishSpain && index == 0 ? "bridge-es-ES" : "\(source.code)-\(index)"
            return root.appendingPathComponent(name + ".wav")
        }
        let filter = ProcessInfo.processInfo.environment["SPEECH_PAIRS"]?.split(separator: ",").map(
            String.init)
        let speech = AppleSpeechRecognitionEngine()
        let baseline = await speech.inventorySnapshot()
        let protected = Set(baseline.reservedLocales.map(\.identifier))
        var lastFailures = Set<AppLanguage>()
        var manualDone = Set<AppLanguage>()
        var checkedVoice = Set<AppLanguage>()
        func keepSpace(for pair: LanguagePair) async {
            let snap = await speech.inventorySnapshot()
            if snap.reservedCount < snap.maximumReservedLocales { return }
            for locale in snap.reservedLocales
            where !protected.contains(locale.identifier)
                && locale != snap.reservedLocale(matching: pair.traveler)
                && locale != snap.reservedLocale(matching: pair.local)
            {
                if await speech.releaseAssets(reservedLocale: locale) { break }
            }
        }
        var pairs = [LanguagePair]()
        for (i, a) in languages.enumerated() {
            for b in languages.dropFirst(i + 1)
            where ContinuousModePolicy.supports(.init(traveler: a, local: b)) {
                pairs.append(.init(traveler: a, local: b))
            }
        }
        pairs.sort { ($0.isEnglishHindi ? 0 : 1) < ($1.isEnglishHindi ? 0 : 1) }
        if let filter {
            XCTAssertTrue(
                Set(filter).isSubset(of: Set(pairs.map { $0.traveler.code + "_" + $0.local.code })),
                "Unknown language pair")
        }
        for canonical in pairs {
            if let filter, !filter.contains(canonical.traveler.code + "_" + canonical.local.code) { continue }
            let pair =
                ProcessInfo.processInfo.environment["SPEECH_REVERSE_PRIMARY"] == "1"
                ? LanguagePair(traveler: canonical.local, local: canonical.traveler) : canonical
            let key = pair.traveler.code + "_" + pair.local.code
            print("MATRIX_PAIR", key)
            for source in [pair.traveler, pair.local] {
                let target = source == pair.traveler ? pair.local : pair.traveler
                let refs = Self.references(source).indices.map { reference(source, $0) }
                let engine = AppleTranslationEngine(strategy: .lowLatency)
                for (idx, ref) in refs.enumerated() {
                    var d = ["expected": source.code, "target": target.code, "idx": String(idx), "ref": ref]
                    do {
                        d["out"] = try await engine.translate(
                            ref, source: source.language, target: target.language)
                    } catch TranslationError.notInstalled { d["error"] = "notInstalled" } catch {
                        d["error"] = (error as NSError).description
                    }
                    record("reference", d)
                    if d["error"] != nil { break }
                }
                engine.cancel()
                if checkedVoice.insert(source).inserted {
                    let synth = RecordingPlaybackTrace()
                    do {
                        try await PlaybackService(synthesis: synth).speak(
                            refs[0], locale: source.locale, slower: false)
                        record("voice", ["src": source.code, "actual": synth.completed.last ?? "none"])
                    } catch { record("voice", ["src": source.code, "error": error.localizedDescription]) }
                }
                if await speech.assetReadiness(locale: source.locale) != .ready
                    && !lastFailures.contains(source)
                {
                    await keepSpace(for: pair)
                    do {
                        print("MATRIX_LISTEN DOWNLOAD", source.code)
                        try await speech.installAssets(locale: source.locale) { _ in }
                    } catch {
                        lastFailures.insert(source)
                        record("install", ["src": source.code, "error": (error as NSError).description])
                    }
                }
                if !manualDone.contains(source),
                    await speech.assetReadiness(locale: source.locale) == .ready
                {
                    manualDone.insert(source)
                    for idx in 0..<3 {
                        var d = ["src": source.code, "idx": String(idx), "ref": refs[idx]]
                        do {
                            try await speech.start(locale: source.locale) { _ in }
                            let file = try AVAudioFile(
                                forReading: clip(source, idx))
                            while file.framePosition < file.length {
                                let b = try XCTUnwrap(
                                    AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024))
                                try file.read(into: b)
                                try speech.append(b)
                                try await Task.sleep(for: .seconds(Double(b.frameLength) / 16000))
                            }
                            d["asr"] = try await speech.finish().text
                        } catch { d["error"] = (error as NSError).description }
                        speech.cancel()
                        record("manual", d)
                    }
                }
            }
            let readiness = await speech.continuousAssetReadiness(pair: pair)
            guard readiness == .ready else {
                XCTFail("Blocked pair \(key)")
                record("blocked", ["pair": key, "reason": readiness.rawValue])
                continue
            }
            let playback = RecordingPlaybackTrace()
            let traced = ComparisonRecognitionTrace()
            let trans = RecordingTranslationTrace()
            let capture = FakeContinuousCapture()
            let settings = SettingsStore(
                defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
            settings.value.autoSpeak = ProcessInfo.processInfo.environment["SPEECH_AUTO_PLAY"] == "1"
            let history = HistoryStore(local: LocalHistoryStore(inMemory: true))
            let talk = ContinuousConversationCoordinator(
                capture: capture, voiceActivity: SileroVoiceActivityDetector(), recognition: traced,
                translation: trans, playback: PlaybackService(synthesis: playback), settings: settings,
                history: history, access: TestTranslationAuthorization())
            talk.speakTranslations = settings.value.autoSpeak
            talk.start(pair: pair)
            defer { talk.cancelSession() }
            func wait(_ seconds: Int, _ condition: () -> Bool) async throws {
                let end = ContinuousClock.now.advanced(by: .seconds(seconds))
                while !condition() {
                    guard ContinuousClock.now < end else {
                        throw PipelineError.server("timeout in " + String(describing: talk.state))
                    }
                    try await Task.sleep(for: .milliseconds(40))
                }
            }
            do {
                try await wait(12) { talk.state == .listening || talk.errorMessage != nil }
                if let m = talk.errorMessage { throw PipelineError.server(m) }
            } catch {
                XCTFail("Blocked pair \(key)")
                record("blocked", ["pair": key, "reason": error.localizedDescription])
                continue
            }
            var sample: AVAudioFramePosition = 0
            if ProcessInfo.processInfo.environment["SPEECH_LIFECYCLE"] == "1" {
                var sawBoundary = false
                traced.trace = { kind, _ in if kind == "speechBoundary" { sawBoundary = true } }
                func feed(_ source: AppLanguage, untilBoundary: Bool) async throws {
                    let recording = try AVAudioFile(forReading: clip(source, 0))
                    var silence = 0
                    while recording.framePosition < recording.length || (untilBoundary && !sawBoundary && silence < 40)
                    {
                        let buffer = try XCTUnwrap(
                            AVAudioPCMBuffer(pcmFormat: recording.processingFormat, frameCapacity: 1024))
                        if recording.framePosition < recording.length {
                            try recording.read(into: buffer)
                        } else {
                            buffer.frameLength = 1024
                            buffer.floatChannelData![0].initialize(repeating: 0, count: 1024)
                            silence += 1
                        }
                        _ = try await capture.emit(buffer, at: AVAudioTime(sampleTime: sample, atRate: 16_000))
                        sample += Int64(buffer.frameLength)
                        try await Task.sleep(for: .seconds(Double(buffer.frameLength) / 16_000))
                    }
                }
                try await feed(pair.traveler, untilBoundary: true)
                XCTAssertTrue(sawBoundary)
                let committedBeforeReply = talk.turns.count
                try await feed(pair.local, untilBoundary: false)
                talk.pauseSession()
                try await wait(12) { talk.state == .paused(.user) }
                XCTAssertEqual(talk.turns.map(\.sourceLocale), [pair.traveler.code, pair.local.code])
                talk.resumeSession()
                try await wait(12) { talk.state == .listening && capture.isActive }
                sample = 0
                try await feed(pair.traveler, untilBoundary: false)
                talk.endSession()
                try await wait(12) { talk.state == .ended }
                XCTAssertEqual(
                    talk.turns.map(\.sourceLocale), [pair.traveler.code, pair.local.code, pair.traveler.code])
                XCTAssertEqual(Set(talk.turns.map(\.id)).count, 3)
                for turn in talk.turns {
                    XCTAssertFalse(turn.translatedText.isEmpty)
                    record(
                        "lifecycle",
                        [
                            "pair": key, "sequence": String(turn.sequence), "asr": turn.sourceText,
                            "output": turn.translatedText, "source": turn.sourceLocale, "target": turn.targetLocale,
                            "committedBeforeFirstReply": String(committedBeforeReply),
                        ])
                }
                continue
            }
            var replays = [(ConversationTurn, AppLanguage, Int)]()
            for idx in 0..<3 {
                for source in [pair.traveler, pair.local] {
                    let target = source == pair.traveler ? pair.local : pair.traveler
                    var d = [
                        "pair": key, "expected": source.code, "intended": target.code, "idx": String(idx),
                        "ref": reference(source, idx),
                    ]
                    let before = talk.turns.count
                    let synthesesBefore = playback.completed.count
                    trans.last = [:]
                    var boundaryInstant: Date?
                    var onset: Date?
                    var lastAudibleBuffer: Date?
                    var firstCommit: Date?
                    let commits = talk.$turns.sink { turns in
                        if turns.count > before && firstCommit == nil { firstCommit = Date() }
                    }
                    defer { commits.cancel() }
                    traced.engine.observeFixtureDiagnostic = { kind, fields in
                        self.record(
                            kind,
                            fields.merging(["pair": key, "expected": source.code, "idx": String(idx)]) { value, _ in
                                value
                            })
                    }
                    traced.trace = { kind, values in
                        if kind == "speechStarted" { onset = Date() }
                        if kind == "firstDraft", d["draftMs"] == nil, let onset {
                            d["draftMs"] = String(Int(-onset.timeIntervalSinceNow * 1000))
                        }
                        if kind == "speechBoundary" {
                            boundaryInstant = Date()
                            d.merge(values) { _, new in new }
                        }
                        if kind == "decision" { d.merge(values) { _, new in new } }
                        if kind == "decision" {
                            d["winner"] = values["selected"]
                            d["finalText"] = values[(values["selected"] ?? "") + "Text"]
                            d["alt"] =
                                values[(values["selected"] == source.code ? target.code : source.code) + "Text"]
                        }
                        if kind == "finalizationError" { d["finalizationError"] = values["error"] }
                    }
                    do {
                        let f = try AVAudioFile(
                            forReading: clip(source, idx))
                        var leading = 4
                        var trailing = 0
                        while f.framePosition < f.length || trailing < 64 {
                            let b = try XCTUnwrap(
                                AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 1024))
                            if leading > 0 || f.framePosition == f.length {
                                b.frameLength = 1024
                                b.floatChannelData![0].initialize(repeating: 0, count: 1024)
                                if leading > 0 { leading -= 1 } else { trailing += 1 }
                            } else {
                                try f.read(into: b)
                                if let samples = b.floatChannelData?[0],
                                    UnsafeBufferPointer(start: samples, count: Int(b.frameLength)).contains(where: {
                                        abs($0) > 0.006
                                    })
                                {
                                    lastAudibleBuffer = Date()
                                }
                            }
                            let stamp = AVAudioTime(sampleTime: sample, atRate: 16000)
                            sample += Int64(b.frameLength)
                            // Auto Speak closes the microphone at the detected boundary.
                            // The real input tap stops delivering silence while the turn drains.
                            if settings.value.autoSpeak && boundaryInstant != nil && !capture.isActive { break }
                            _ = try await capture.emit(b, at: stamp)
                            try await Task.sleep(for: .seconds(Double(b.frameLength) / 16000))
                            if trailing >= 5
                                && (talk.turns.count > before || trans.last["error"] != nil
                                    || d["finalizationError"] != nil)
                            {
                                break
                            }
                        }
                        try await wait(5) {
                            talk.turns.count > before || trans.last["error"] != nil
                                || d["finalizationError"] != nil
                        }
                    } catch { d["harnessError"] = error.localizedDescription }
                    if let firstCommit, let boundaryInstant {
                        d["endpointMs"] = String(Int(firstCommit.timeIntervalSince(boundaryInstant) * 1000))
                    }
                    if let firstCommit, let lastAudibleBuffer {
                        d["pauseMs"] = String(Int(firstCommit.timeIntervalSince(lastAudibleBuffer) * 1000))
                    }
                    d.merge(trans.last) { _, new in new }
                    let result = Array(talk.turns.dropFirst(before))
                    d["count"] = String(result.count)
                    if let turn = result.first {
                        d["savedSource"] = turn.sourceLocale
                        d["savedTarget"] = turn.targetLocale
                        d["side"] = turn.speaker.rawValue
                        d["asr"] = turn.sourceText
                        d["output"] = turn.translatedText
                        d["review"] = turn.languageReviewStatus.rawValue
                        if idx == 0 || (idx == 1 && source == pair.traveler) {
                            replays.append((turn, source, idx))
                        }
                    }
                    XCTAssertEqual(
                        result.count, 1, "Expected one turn for \(key) fixture \(idx) spoken by \(source.code)")
                    if settings.value.autoSpeak {
                        try await wait(20) { talk.state == .listening && capture.isActive }
                        d["autoVoice"] = playback.completed.count > synthesesBefore ? playback.completed.last : nil
                        d["lastSynthesizedText"] = playback.completed.count > synthesesBefore ? playback.lastText : nil
                        if let turn = result.first {
                            let shouldSpeak = !turn.warnings.contains(.unresolvedSpeaker)
                            XCTAssertEqual(playback.completed.count - synthesesBefore, shouldSpeak ? 1 : 0)
                            if shouldSpeak {
                                XCTAssertEqual(d["autoVoice"]?.replacingOccurrences(of: "_", with: "-"), target.code)
                                XCTAssertEqual(d["lastSynthesizedText"], turn.translatedText)
                            }
                        }
                    }
                    record("spoken", d)
                }
            }
            talk.handleSceneActivity(isActive: false)
            talk.handleSceneActivity(isActive: true)
            for (turn, source, idx) in replays {
                var d = [
                    "pair": key, "expected": source.code, "idx": String(idx), "target": turn.targetLocale,
                    "unresolvedSpeaker": String(turn.warnings.contains(.unresolvedSpeaker)),
                ]
                if talk.canReplayTranslation(for: turn) {
                    let before = playback.completed.count
                    talk.replayTranslation(for: turn.id)
                    do {
                        try await wait(16) { !talk.isReviewedPlaybackActive }
                        if playback.completed.count == before + 1 {
                            d["voice"] = playback.completed.last
                            d["sameText"] = String(playback.lastText == turn.translatedText)
                        } else {
                            d["error"] = talk.errorMessage ?? "no synthesis"
                        }
                    } catch { d["error"] = error.localizedDescription }
                } else {
                    d["error"] = "ineligible"
                }
                record("replay", d)
            }
        }
        let current = await speech.inventorySnapshot()
        for locale in current.reservedLocales where !protected.contains(locale.identifier) {
            _ = await speech.releaseAssets(reservedLocale: locale)
        }
        print("MATRIX_END", await speech.inventorySnapshot())
    }
}
@MainActor
private final class RecordingPlaybackTrace: SpeechSynthesisEngine {
    let engine = AppleSpeechSynthesisEngine()
    var completed: [String] = []
    var lastText = ""
    func isVoiceAvailable(locale: Locale) -> Bool { engine.isVoiceAvailable(locale: locale) }
    func speak(_ text: String, locale: Locale, rate: Float) async throws {
        try await engine.speak(text, locale: locale, rate: rate)
        completed.append(locale.identifier)
        lastText = text
    }
    func play(data: Data, format: String?) async throws {
        try await engine.play(data: data, format: format)
    }
    func cancel() { engine.cancel() }
}

@MainActor
private final class ComparisonRecognitionTrace: ContinuousSpeechRecognizing {
    let engine = AppleContinuousSpeechRecognizer(
        usesSharedAnalyzer: ProcessInfo.processInfo.environment["SPEECH_ANALYZER"] == "shared")
    var trace: ((String, [String: String]) -> Void)?
    func start(
        pair: LanguagePair, onDraft: @escaping @MainActor (ContinuousDraft?) -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) async throws {
        try await engine.start(
            pair: pair,
            onDraft: { [weak self] draft in
                if draft != nil { self?.trace?("firstDraft", [:]) }
                onDraft(draft)
            }, onFailure: onFailure)
    }
    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) throws {
        try engine.append(buffer, at: time)
    }
    func beginUtterance(at start: CMTime) {
        trace?("speechStarted", ["at": String(start.seconds)])
        engine.beginUtterance(at: start)
    }
    func takeDraft(in range: CMTimeRange, onRevision: @escaping @MainActor (ContinuousDraft?) -> Void)
        -> ContinuousDraft?
    {
        trace?(
            "speechBoundary", ["start": String(range.start.seconds), "end": String(range.end.seconds)])
        return engine.takeDraft(in: range, onRevision: onRevision)
    }
    func finishInput() throws -> CMTime? { try engine.finishInput() }
    func finalizeUtterance(in range: CMTimeRange) async throws -> LanguageDecision {
        do {
            let decision = try await engine.finalizeUtterance(in: range)
            let candidates = [decision.selected, decision.alternate].compactMap { $0 }
            let rankedOnly = ContinuousLanguageDecisionPolicy.decide(candidates: candidates, pair: nil)
            var values = [
                "reviewReasons": decision.reviewReasons.map(\.rawValue).sorted().joined(separator: ","),
                "selected": decision.selected.language.code,
                "byScore": rankedOnly?.selected.language.code ?? "",
            ]
            for c in candidates {
                values[c.language.code + "Text"] = c.text
                values[c.language.code + "Score"] = String(c.score)
                values[c.language.code + "Confidence"] = c.confidence.map { String($0) } ?? "unreported"
                values[c.language.code + "LangProbability"] =
                    c.constrainedLanguageProbability.map { String($0) } ?? "unreported"
            }
            trace?("decision", values)
            return decision
        } catch {
            trace?("finalizationError", ["error": error.localizedDescription])
            throw error
        }
    }
    func cancelAnalysis(before time: CMTime) { engine.cancelAnalysis(before: time) }
    func stop() { engine.stop() }
}

extension ContinuousSpeechMatrixTests {
    static func references(_ language: AppLanguage) -> [String] {
        switch language {
        case .englishUS:
            [
                "Where is the train station?", "Two tickets cost thirty euros.",
                "The train leaves at nine, not ten.",
            ]
        case .spanishSpain:
            [
                "¿Dónde está la estación de tren?", "Dos billetes cuestan treinta euros.",
                "El tren sale a las nueve, no a las diez.",
            ]
        case .frenchFrance:
            [
                "Où est la gare ?", "Deux billets coûtent trente euros.",
                "Le train part à neuf heures, pas à dix heures.",
            ]
        case .germanGermany:
            [
                "Wo ist der Bahnhof?", "Zwei Fahrkarten kosten dreißig Euro.",
                "Der Zug fährt um neun Uhr ab, nicht um zehn.",
            ]
        case .italianItaly:
            [
                "Dov’è la stazione ferroviaria?", "Due biglietti costano trenta euro.",
                "Il treno parte alle nove, non alle dieci.",
            ]
        case .portugueseBrazil:
            [
                "Onde fica a estação de trem?", "Duas passagens custam trinta euros.",
                "O trem sai às nove, não às dez.",
            ]
        case .japaneseJapan: ["駅はどこですか？", "切符は二枚で三十ユーロです。", "電車は十時ではなく九時に出発します。"]
        case .koreanSouthKorea: ["기차역이 어디에 있나요?", "표 두 장은 삼십 유로예요.", "기차는 열 시가 아니라 아홉 시에 출발해요."]
        case .hindiIndia: ["रेलवे स्टेशन कहाँ है?", "दो टिकटों की कीमत तीस यूरो है।", "ट्रेन नौ बजे चलती है, दस बजे नहीं।"]
        }
    }
}
