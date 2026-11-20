import AVFoundation
import Foundation
import NaturalLanguage
import Speech

@MainActor
final class AppleSpeechRecognitionEngine: SpeechRecognitionEngine, SpeechAssetManaging {
    private var transcriptionModule: AppleSpeechTranscriptionModule?
    private var analyzer: SpeechAnalyzer?
    private var converter: SpeechAnalyzerInputConverter?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisTask: Task<CMTime?, Error>?
    private var resultsTask: Task<Transcript, Error>?
    private var operationGeneration = RecognitionOperationGeneration()

    func assetReadiness(locale: Locale) async -> ComponentReadiness {
        guard let plan = try? await AppleSpeechModulePlan.resolve(for: locale) else {
            return .unavailable
        }
        let modules = plan.makeAssetModules().map { $0.analyzerModule }
        let status = await AssetInventory.status(forModules: modules)
        return Self.readiness(for: status)
    }

    func continuousAssetReadiness(pair: LanguagePair) async -> ComponentReadiness {
        guard let modules = try? await continuousAssetModules(for: pair) else {
            return .unavailable
        }
        let status = await AssetInventory.status(forModules: modules)
        guard status == .installed else { return Self.readiness(for: status) }
        return await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) == nil
            ? .unavailable
            : .ready
    }

    func inventorySnapshot() async -> SpeechAssetInventorySnapshot {
        SpeechAssetInventorySnapshot(
            maximumReservedLocales: AssetInventory.maximumReservedLocales,
            reservedLocales: await AssetInventory.reservedLocales
        )
    }

    func reserveAssets(locale: Locale) async throws {
        let plan = try await AppleSpeechModulePlan.resolve(for: locale)
        _ = try await AssetInventory.reserve(locale: plan.supportedLocale)
        try Task.checkCancellation()
    }

    func releaseAssets(reservedLocale: Locale) async -> Bool {
        await AssetInventory.release(reservedLocale: reservedLocale)
    }

    func prepare(locale: Locale) async throws {
        let plan = try await AppleSpeechModulePlan.resolve(for: locale)
        let modules = plan.makeAssetModules().map { $0.analyzerModule }
        let status = await AssetInventory.status(forModules: modules)
        try Task.checkCancellation()
        guard status == .installed else {
            throw PipelineError.assetsUnavailable(Self.assetStatusMessage(status, locale: locale))
        }
    }

    func installAssets(
        locale: Locale,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let plan = try await AppleSpeechModulePlan.resolve(for: locale)
        let modules = plan.makeAssetModules().map { $0.analyzerModule }
        let initialStatus = await AssetInventory.status(forModules: modules)
        try Task.checkCancellation()
        if initialStatus == .installed {
            onProgress(1)
            return
        }
        guard initialStatus != .unsupported else {
            throw PipelineError.assetsUnavailable(Self.assetStatusMessage(initialStatus, locale: locale))
        }

        guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
            let status = await AssetInventory.status(forModules: modules)
            guard status == .installed else {
                throw PipelineError.assetsUnavailable(Self.assetStatusMessage(status, locale: locale))
            }
            onProgress(1)
            return
        }
        try Task.checkCancellation()

        let progressTask = Task { @MainActor in
            while !Task.isCancelled {
                onProgress(Self.normalizedProgress(request.progress.fractionCompleted))
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
            }
        }
        defer { progressTask.cancel() }
        onProgress(Self.normalizedProgress(request.progress.fractionCompleted))
        try await withTaskCancellationHandler {
            try await request.downloadAndInstall()
        } onCancel: {
            request.progress.cancel()
        }
        try Task.checkCancellation()

        let finalStatus = await AssetInventory.status(forModules: modules)
        guard finalStatus == .installed else {
            throw PipelineError.assetsUnavailable(Self.assetStatusMessage(finalStatus, locale: locale))
        }
        onProgress(1)
    }

    func installContinuousAssets(
        pair: LanguagePair,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let modules = try await continuousAssetModules(for: pair)
        let initialStatus = await AssetInventory.status(forModules: modules)
        try Task.checkCancellation()
        if initialStatus == .installed {
            try await requireContinuousAudioFormat(modules, pair: pair)
            onProgress(1)
            return
        }
        guard initialStatus != .unsupported else {
            throw PipelineError.assetsUnavailable(
                Self.continuousAssetStatusMessage(initialStatus, pair: pair)
            )
        }

        guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
            let status = await AssetInventory.status(forModules: modules)
            try Task.checkCancellation()
            guard status == .installed else {
                throw PipelineError.assetsUnavailable(
                    Self.continuousAssetStatusMessage(status, pair: pair)
                )
            }
            try await requireContinuousAudioFormat(modules, pair: pair)
            onProgress(1)
            return
        }
        try Task.checkCancellation()

        let progressTask = Task { @MainActor in
            while !Task.isCancelled {
                onProgress(Self.normalizedProgress(request.progress.fractionCompleted))
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
            }
        }
        defer { progressTask.cancel() }
        onProgress(Self.normalizedProgress(request.progress.fractionCompleted))
        try await withTaskCancellationHandler {
            try await request.downloadAndInstall()
        } onCancel: {
            request.progress.cancel()
        }
        try Task.checkCancellation()

        let finalStatus = await AssetInventory.status(forModules: modules)
        try Task.checkCancellation()
        guard finalStatus == .installed else {
            throw PipelineError.assetsUnavailable(
                Self.continuousAssetStatusMessage(finalStatus, pair: pair)
            )
        }
        try await requireContinuousAudioFormat(modules, pair: pair)
        onProgress(1)
    }

    func start(locale: Locale, onPartial: @escaping @MainActor (Transcript) -> Void) async throws {
        cancel()
        let generation = operationGeneration.begin()
        do {
            let plan = try await AppleSpeechModulePlan.resolve(for: locale)
            let transcriptionModule = plan.makeModule(for: .manual)
            let analyzerModule = transcriptionModule.analyzerModule
            try requireCurrent(generation)
            let status = await AssetInventory.status(forModules: [analyzerModule])
            try requireCurrent(generation)
            guard status == .installed else {
                throw PipelineError.assetsUnavailable(Self.assetStatusMessage(status, locale: locale))
            }
            let bestFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [analyzerModule]
            )
            try requireCurrent(generation)
            guard let audioFormat = bestFormat else {
                throw PipelineError.assetsUnavailable("No compatible microphone format")
            }

            let analyzer = SpeechAnalyzer(modules: [analyzerModule])
            let converter = SpeechAnalyzerInputConverter(analyzerFormat: audioFormat)
            let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
            self.transcriptionModule = transcriptionModule
            self.analyzer = analyzer
            self.converter = converter
            inputContinuation = continuation

            let expectedLanguage = locale.language.languageCode?.identifier
            resultsTask = Task { @MainActor in
                var segments: [RecognizedSegment] = []
                for try await result in transcriptionModule.normalizedResults() {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard TurnTextPolicy.isFinalTextWithinLimit(text) else {
                        throw PipelineError.server("The speech result is too long. Please split the turn and try again.")
                    }
                    let confidence = Self.confidenceSummary(result.text)
                    guard SpeechSegmentAccumulator.apply(
                        range: result.range,
                        text: text,
                        isFinal: result.isFinal,
                        confidence: confidence.mean,
                        lowConfidenceFraction: confidence.lowFraction,
                        to: &segments
                    ) else {
                        throw PipelineError.server("The speech result was too complex. Please split the turn and try again.")
                    }
                    guard segments.reduce(0, { $0 + $1.text.utf8.count + 1 }) <= TurnTextPolicy.maximumFinalUTF8Bytes else {
                        throw PipelineError.server("The speech result is too long. Please split the turn and try again.")
                    }
                    let partial = Self.combinedTranscript(segments: segments, expectedLanguage: expectedLanguage)
                    onPartial(Transcript(text: TurnTextPolicy.clampedPartial(partial.text), isFinal: result.isFinal, confidence: partial.confidence, lowConfidenceFraction: partial.lowConfidenceFraction, languageMatchesExpectation: partial.languageMatchesExpectation))
                }
                let completedSegments = segments.filter(\.isFinal)
                let completed = Self.combinedTranscript(segments: completedSegments.isEmpty ? segments : completedSegments, expectedLanguage: expectedLanguage)
                guard !completed.text.isEmpty else { throw PipelineError.noSpeech }
                let bounded = try TurnTextPolicy.validatedFinal(completed.text, field: "speech")
                return Transcript(text: bounded, isFinal: true, confidence: completed.confidence, lowConfidenceFraction: completed.lowConfidenceFraction, languageMatchesExpectation: completed.languageMatchesExpectation)
            }
            analysisTask = Task {
                let lastTime = try await analyzer.analyzeSequence(stream)
                if let lastTime { try await analyzer.finalizeAndFinish(through: lastTime) }
                else { await analyzer.cancelAndFinishNow() }
                return lastTime
            }
        } catch {
            if operationGeneration.invalidateIfCurrent(generation) { clearReferences() }
            throw error
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        guard let converter, let inputContinuation else { return }
        for input in try converter.convert(buffer, at: nil) { inputContinuation.yield(input) }
    }

    func finish() async throws -> Transcript {
        guard let generation = operationGeneration.active,
              let converter, let inputContinuation, let analysisTask, let resultsTask else { throw PipelineError.noSpeech }
        try requireCurrent(generation)
        for input in try converter.flush() { inputContinuation.yield(input) }
        inputContinuation.finish()
        _ = try await analysisTask.value
        try requireCurrent(generation)
        let result = try await resultsTask.value
        try requireCurrent(generation)
        guard operationGeneration.invalidateIfCurrent(generation) else { throw CancellationError() }
        clearReferences()
        return result
    }

    func cancel() {
        operationGeneration.invalidate()
        inputContinuation?.finish()
        analysisTask?.cancel(); resultsTask?.cancel()
        let canceledAnalyzer = analyzer
        clearReferences()
        if let canceledAnalyzer { Task { await canceledAnalyzer.cancelAndFinishNow() } }
    }

    private func requireCurrent(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard operationGeneration.isCurrent(generation) else { throw CancellationError() }
    }

    private func clearReferences() {
        transcriptionModule = nil; analyzer = nil; converter = nil
        inputContinuation = nil; analysisTask = nil; resultsTask = nil
    }

    private func continuousAssetModules(
        for pair: LanguagePair
    ) async throws -> [any SpeechModule] {
        guard ContinuousModePolicy.supports(pair) else {
            throw PipelineError.assetsUnavailable(
                "Continuous listening is unavailable for \(pair.traveler.displayName) and \(pair.local.displayName)."
            )
        }
        let travelerPlan = try await AppleSpeechModulePlan.resolve(for: pair.traveler.locale)
        let localPlan = try await AppleSpeechModulePlan.resolve(for: pair.local.locale)
        try Task.checkCancellation()
        return AppleSpeechModulePlan.continuousRoles(for: pair).flatMap { role in
            [travelerPlan, localPlan].map { $0.makeModule(for: role).analyzerModule }
        }
    }

    private func requireContinuousAudioFormat(
        _ modules: [any SpeechModule],
        pair: LanguagePair
    ) async throws {
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
        try Task.checkCancellation()
        guard format != nil else {
            throw PipelineError.assetsUnavailable(
                "The installed Listen models for \(pair.traveler.displayName) and \(pair.local.displayName) cannot run together on this iPhone."
            )
        }
    }

    nonisolated static func readiness(for status: AssetInventory.Status) -> ComponentReadiness {
        switch status {
        case .unsupported: .unavailable
        case .supported: .downloadRequired
        case .downloading: .downloading
        case .installed: .ready
        @unknown default: .unknown
        }
    }

    nonisolated private static func normalizedProgress(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    nonisolated private static func assetStatusMessage(_ status: AssetInventory.Status, locale: Locale) -> String {
        let language = locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        return switch status {
        case .unsupported:
            "Listen recognition is not supported for \(language) on this iPhone."
        case .supported:
            "The Listen recognition model for \(language) is not installed."
        case .downloading:
            "The Listen recognition model for \(language) is downloading or waiting for iOS to continue."
        case .installed:
            "The Listen recognition model for \(language) is installed."
        @unknown default:
            "The Listen recognition model for \(language) has an unknown status."
        }
    }

    nonisolated private static func continuousAssetStatusMessage(
        _ status: AssetInventory.Status,
        pair: LanguagePair
    ) -> String {
        let languages = "\(pair.traveler.displayName) and \(pair.local.displayName)"
        return switch status {
        case .unsupported:
            "Continuous Listen recognition is not supported for \(languages) on this iPhone."
        case .supported:
            "The continuous Listen models for \(languages) are not installed."
        case .downloading:
            "The continuous Listen models for \(languages) are downloading or waiting for iOS to continue."
        case .installed:
            "The continuous Listen models for \(languages) are installed."
        @unknown default:
            "The continuous Listen models for \(languages) have an unknown status."
        }
    }

    private static func confidenceSummary(_ text: AttributedString) -> (mean: Double?, lowFraction: Double) {
        var weightedTotal = 0.0
        var attributedCharacters = 0
        var lowCharacters = 0
        for run in text.runs {
            let count = text[run.range].characters.count
            guard count > 0,
                  let value = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] else { continue }
            let confidence = Double(value)
            weightedTotal += confidence * Double(count)
            attributedCharacters += count
            if confidence < 0.45 { lowCharacters += count }
        }
        guard attributedCharacters > 0 else { return (nil, 1) }
        return (weightedTotal / Double(attributedCharacters), Double(lowCharacters) / Double(attributedCharacters))
    }

    private static func combinedTranscript(segments: [RecognizedSegment], expectedLanguage: String?) -> Transcript {
        let text = segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let characterCount = segments.reduce(0) { $0 + $1.text.count }
        let hasMissingConfidence = segments.contains { $0.confidence == nil }
        let confidence: Double? = hasMissingConfidence || characterCount == 0 ? nil : segments.reduce(0) { partial, segment in
            partial + (segment.confidence ?? 0) * Double(segment.text.count)
        } / Double(characterCount)
        let lowFraction = characterCount == 0 ? 1 : segments.reduce(0) { partial, segment in
            partial + segment.lowConfidenceFraction * Double(segment.text.count)
        } / Double(characterCount)
        return Transcript(
            text: text,
            isFinal: segments.allSatisfy(\.isFinal),
            confidence: confidence,
            lowConfidenceFraction: lowFraction,
            languageMatchesExpectation: languageMatch(text: text, expectedLanguage: expectedLanguage)
        )
    }

    private static func languageMatch(text: String, expectedLanguage: String?) -> Bool? {
        guard text.filter(\.isLetter).count >= 8, let expectedLanguage else { return nil }
        guard let detected = NLLanguageRecognizer.dominantLanguage(for: text), detected != .undetermined else { return nil }
        return detected.rawValue == expectedLanguage
    }
}

struct RecognitionOperationGeneration {
    private(set) var active: UUID?

    mutating func begin() -> UUID {
        let generation = UUID()
        active = generation
        return generation
    }

    func isCurrent(_ generation: UUID) -> Bool { active == generation }

    mutating func invalidateIfCurrent(_ generation: UUID) -> Bool {
        guard active == generation else { return false }
        active = nil
        return true
    }

    mutating func invalidate() { active = nil }
}

struct RecognizedSegment {
    let range: CMTimeRange
    let text: String
    let isFinal: Bool
    let confidence: Double?
    let lowConfidenceFraction: Double
}

/// Applies Apple's volatile revisions by time range. An empty result is a real
/// retraction, so overlap removal must happen before deciding whether there is
/// replacement text to append.
enum SpeechSegmentAccumulator {
    @discardableResult
    static func apply(
        range: CMTimeRange,
        text: String,
        isFinal: Bool,
        confidence: Double?,
        lowConfidenceFraction: Double,
        to segments: inout [RecognizedSegment]
    ) -> Bool {
        segments.removeAll { segment in
            let segmentStart = CMTimeGetSeconds(segment.range.start)
            let segmentEnd = CMTimeGetSeconds(CMTimeRangeGetEnd(segment.range))
            let revisionStart = CMTimeGetSeconds(range.start)
            let revisionEnd = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
            let overlapStart = max(segmentStart, revisionStart)
            let overlapEnd = min(segmentEnd, revisionEnd)
            let pointRevisionInsideSegment = revisionEnd - revisionStart < 0.01
                && revisionStart >= segmentStart - 0.01
                && revisionStart <= segmentEnd + 0.01
            return overlapEnd - overlapStart >= 0.01
                || abs(segmentStart - revisionStart) < 0.01
                || pointRevisionInsideSegment
        }

        let replacement = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replacement.isEmpty else { return true }
        guard segments.count < ConversationContentPolicy.maximumSpeechSegments else { return false }
        segments.append(RecognizedSegment(
            range: range,
            text: replacement,
            isFinal: isFinal,
            confidence: confidence,
            lowConfidenceFraction: lowConfidenceFraction
        ))
        segments.sort { CMTimeCompare($0.range.start, $1.range.start) < 0 }
        return true
    }
}
