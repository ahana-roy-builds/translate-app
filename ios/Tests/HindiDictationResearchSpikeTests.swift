import AVFoundation
import CryptoKit
import Foundation
import Network
import Speech
import XCTest
@testable import LocalLingo

/// Explicitly gated, file-only research for Apple's Hindi dictation model.
///
/// These tests are inert during normal test runs. They never open the
/// microphone. The installation test is the only code here that can request a
/// model download, and it requires its exact opt-in action value.
@MainActor
final class HindiDictationResearchSpikeTests: XCTestCase {
    func testInventoryHindiDictationConfigurationsWithoutInstalling() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Apple speech assets must be inventoried on a physical iPhone.")
#else
        let requestedHindi = Locale(identifier: "hi-IN")
        guard let hindi = await DictationTranscriber.supportedLocale(
            equivalentTo: requestedHindi
        ) else {
            XCTFail("DictationTranscriber does not expose an equivalent Hindi locale.")
            return
        }

        let presetModules: [(String, DictationTranscriber)] = [
            ("phrase", DictationTranscriber(locale: hindi, preset: .phrase)),
            ("shortDictation", DictationTranscriber(locale: hindi, preset: .shortDictation)),
            (
                "progressiveShortDictation",
                DictationTranscriber(locale: hindi, preset: .progressiveShortDictation)
            ),
            ("longDictation", DictationTranscriber(locale: hindi, preset: .longDictation)),
            (
                "progressiveLongDictation",
                DictationTranscriber(locale: hindi, preset: .progressiveLongDictation)
            ),
            (
                "timeIndexedLongDictation",
                DictationTranscriber(locale: hindi, preset: .timeIndexedLongDictation)
            )
        ]
        var configurations: [SpeechConfigurationStatus] = []
        for (name, module) in presetModules {
            configurations.append(SpeechConfigurationStatus(
                name: "hindi-preset-\(name)",
                status: Self.statusName(await AssetInventory.status(forModules: [module]))
            ))
        }

        let hindiLive = Self.makeHindiLiveModule(locale: hindi)
        let hindiFinal = Self.makeHindiFinalModule(locale: hindi)
        configurations.append(SpeechConfigurationStatus(
            name: "hindi-exact-live",
            status: Self.statusName(await AssetInventory.status(forModules: [hindiLive]))
        ))
        configurations.append(SpeechConfigurationStatus(
            name: "hindi-exact-final",
            status: Self.statusName(await AssetInventory.status(forModules: [hindiFinal]))
        ))
        configurations.append(SpeechConfigurationStatus(
            name: "hindi-exact-live-plus-final",
            status: Self.statusName(
                await AssetInventory.status(forModules: [hindiLive, hindiFinal])
            )
        ))

        let requestedEnglish = Locale(identifier: "en-US")
        let hybridAggregateStatus: String
        let resolvedEnglishSpeech: String?
        if let english = await SpeechTranscriber.supportedLocale(
            equivalentTo: requestedEnglish
        ) {
            resolvedEnglishSpeech = english.identifier
            let englishLive = Self.makeSpeechLiveModule(locale: english)
            let englishFinal = Self.makeSpeechFinalModule(locale: english)
            configurations.append(SpeechConfigurationStatus(
                name: "english-speech-exact-live",
                status: Self.statusName(
                    await AssetInventory.status(forModules: [englishLive])
                )
            ))
            configurations.append(SpeechConfigurationStatus(
                name: "english-speech-exact-final",
                status: Self.statusName(
                    await AssetInventory.status(forModules: [englishFinal])
                )
            ))
            hybridAggregateStatus = Self.statusName(
                await AssetInventory.status(
                    forModules: [englishLive, englishFinal, hindiLive, hindiFinal]
                )
            )
        } else {
            resolvedEnglishSpeech = nil
            hybridAggregateStatus = "english-speech-transcriber-unsupported"
        }
        configurations.append(SpeechConfigurationStatus(
            name: "english-speech-live-final-plus-hindi-dictation-live-final",
            status: hybridAggregateStatus
        ))

        let allDictationAggregateStatus: String
        let resolvedEnglishDictation: String?
        if let english = await DictationTranscriber.supportedLocale(
            equivalentTo: requestedEnglish
        ) {
            resolvedEnglishDictation = english.identifier
            let englishLive = Self.makeHindiLiveModule(locale: english)
            let englishFinal = Self.makeHindiFinalModule(locale: english)
            configurations.append(SpeechConfigurationStatus(
                name: "english-dictation-exact-live",
                status: Self.statusName(
                    await AssetInventory.status(forModules: [englishLive])
                )
            ))
            configurations.append(SpeechConfigurationStatus(
                name: "english-dictation-exact-final",
                status: Self.statusName(
                    await AssetInventory.status(forModules: [englishFinal])
                )
            ))
            allDictationAggregateStatus = Self.statusName(
                await AssetInventory.status(
                    forModules: [englishLive, englishFinal, hindiLive, hindiFinal]
                )
            )
        } else {
            resolvedEnglishDictation = nil
            allDictationAggregateStatus = "english-dictation-transcriber-unsupported"
        }
        configurations.append(SpeechConfigurationStatus(
            name: "english-dictation-live-final-plus-hindi-dictation-live-final",
            status: allDictationAggregateStatus
        ))

        let allDictationLocales = await DictationTranscriber.supportedLocales
        let allSpeechLocales = await SpeechTranscriber.supportedLocales
        let dictationHindiLocales = allDictationLocales
            .filter(Self.isHindi)
            .map(Self.localeIdentifierReport)
            .sorted { $0.bcp47 < $1.bcp47 }
        let speechHindiLocales = allSpeechLocales
            .filter(Self.isHindi)
            .map(Self.localeIdentifierReport)
            .sorted { $0.bcp47 < $1.bcp47 }
        var localeProbes: [HindiLocaleConfigurationProbe] = []
        for identifier in ["hi-IN", "hi-Latn", "hi-IN-translit"] {
            let requested = Locale(identifier: identifier)
            let requestedBCP47 = requested.identifier(.bcp47)
            let dictationEquivalent = await DictationTranscriber.supportedLocale(
                equivalentTo: requested
            )
            let speechEquivalent = await SpeechTranscriber.supportedLocale(
                equivalentTo: requested
            )
            let dictationStatus: String
            if let dictationEquivalent {
                dictationStatus = Self.statusName(
                    await AssetInventory.status(
                        forModules: [Self.makeHindiFinalModule(locale: dictationEquivalent)]
                    )
                )
            } else {
                dictationStatus = "not-queried-unsupported-locale"
            }
            let speechStatus: String
            if let speechEquivalent {
                speechStatus = Self.statusName(
                    await AssetInventory.status(
                        forModules: [Self.makeSpeechFinalModule(locale: speechEquivalent)]
                    )
                )
            } else {
                speechStatus = "not-queried-unsupported-locale"
            }
            localeProbes.append(HindiLocaleConfigurationProbe(
                requestedLocale: identifier,
                requestedBCP47: requestedBCP47,
                dictationEquivalent: dictationEquivalent?.identifier,
                dictationEquivalentBCP47: dictationEquivalent?.identifier(.bcp47),
                dictationExactSupportedLocale: allDictationLocales.contains {
                    $0.identifier(.bcp47).caseInsensitiveCompare(requestedBCP47) == .orderedSame
                },
                dictationStatus: dictationStatus,
                speechEquivalent: speechEquivalent?.identifier,
                speechEquivalentBCP47: speechEquivalent?.identifier(.bcp47),
                speechExactSupportedLocale: allSpeechLocales.contains {
                    $0.identifier(.bcp47).caseInsensitiveCompare(requestedBCP47) == .orderedSame
                },
                speechStatus: speechStatus
            ))
        }

        let report = HindiDictationConfigurationReport(
            requestedHindiLocale: requestedHindi.identifier,
            resolvedHindiLocale: hindi.identifier,
            requestedEnglishLocale: requestedEnglish.identifier,
            resolvedEnglishSpeechLocale: resolvedEnglishSpeech,
            resolvedEnglishDictationLocale: resolvedEnglishDictation,
            dictationHindiSupportedLocales: dictationHindiLocales,
            speechHindiSupportedLocales: speechHindiLocales,
            localeProbes: localeProbes,
            maximumReservedLocales: AssetInventory.maximumReservedLocales,
            reservedLocales: await AssetInventory.reservedLocales.map(\.identifier).sorted(),
            configurations: configurations,
            readOnly: true,
            requestedInstallation: false,
            queriedCompatibleAudioFormat: false
        )
        let reportData = try JSONEncoder.researchEncoder.encode(report)
        let reportJSON = try XCTUnwrap(String(data: reportData, encoding: .utf8))
        print("\n=== LOCALLINGO HINDI DICTATION CONFIGURATION BEGIN ===")
        print(reportJSON)
        print("=== LOCALLINGO HINDI DICTATION CONFIGURATION END ===\n")

        let attachment = XCTAttachment(string: reportJSON)
        attachment.name = "HindiDictationConfiguration.json"
        attachment.lifetime = .keepAlways
        add(attachment)
#endif
    }

    func testInstallAppleHindiDictationAssetWithExplicitOptIn() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Apple speech assets must be tested on a physical iPhone.")
#else
        try requireAction(.installAsset)

        let locale = try await supportedHindiLocale()
        let modules = [
            Self.makeHindiLiveModule(locale: locale),
            Self.makeHindiFinalModule(locale: locale)
        ]
        let initialStatus = await AssetInventory.status(forModules: modules)
        var requestedInstallation = false
        if initialStatus == .supported {
            guard let request = try await AssetInventory.assetInstallationRequest(
                supporting: modules
            ) else {
                XCTFail("iOS returned no installation request for a supported, uninstalled asset.")
                return
            }
            requestedInstallation = true
            print("Beginning explicitly authorized Apple Hindi dictation asset installation.")
            try await request.downloadAndInstall()
        } else if initialStatus != .installed {
            XCTFail("Unexpected pre-install asset status: \(Self.statusName(initialStatus))")
            return
        }

        let finalStatus = await AssetInventory.status(forModules: modules)
        XCTAssertEqual(finalStatus, .installed)
        guard finalStatus == .installed else { return }

        let requestedBCP47 = Locale(identifier: "hi-IN").identifier(.bcp47)
        let installedLocale = await DictationTranscriber.installedLocales.first {
            $0.identifier(.bcp47).caseInsensitiveCompare(requestedBCP47) == .orderedSame
        }
        XCTAssertNotNil(
            installedLocale,
            "DictationTranscriber.installedLocales does not contain exact hi-IN."
        )
        guard let installedLocale else { return }

        let compatibleFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules
        )
        XCTAssertNotNil(
            compatibleFormat,
            "Installed Hindi live/final modules have no compatible audio format."
        )
        guard let compatibleFormat else { return }

        let report = HindiDictationInstallationReport(
            initialStatus: Self.statusName(initialStatus),
            finalStatus: Self.statusName(finalStatus),
            requestedInstallation: requestedInstallation,
            installedLocale: installedLocale.identifier,
            installedLocaleBCP47: installedLocale.identifier(.bcp47),
            sampleRate: compatibleFormat.sampleRate,
            channelCount: compatibleFormat.channelCount,
            commonFormat: String(describing: compatibleFormat.commonFormat)
        )
        let reportData = try JSONEncoder.researchEncoder.encode(report)
        let reportJSON = try XCTUnwrap(String(data: reportData, encoding: .utf8))
        print("\n=== LOCALLINGO HINDI DICTATION INSTALLATION BEGIN ===")
        print(reportJSON)
        print("=== LOCALLINGO HINDI DICTATION INSTALLATION END ===\n")

        let attachment = XCTAttachment(string: reportJSON)
        attachment.name = "HindiDictationInstallation.json"
        attachment.lifetime = .keepAlways
        add(attachment)
#endif
    }

    func testReportInstalledBilingualCompatibilityWithoutChangingDeviceState() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Apple speech modules must be inspected on a physical iPhone.")
#else
        let hindi = try await supportedHindiLocale()
        let requestedEnglish = Locale(identifier: "en-US")

        var configurations: [BilingualSpeechCompatibility] = []
        if let englishSpeech = await SpeechTranscriber.supportedLocale(
            equivalentTo: requestedEnglish
        ) {
            let modules: [any SpeechModule] = [
                Self.makeSpeechLiveModule(locale: englishSpeech),
                Self.makeSpeechFinalModule(locale: englishSpeech),
                Self.makeHindiLiveModule(locale: hindi),
                Self.makeHindiFinalModule(locale: hindi)
            ]
            configurations.append(await Self.compatibility(
                name: "english-speech-plus-hindi-dictation",
                modules: modules
            ))
        } else {
            configurations.append(BilingualSpeechCompatibility(
                name: "english-speech-plus-hindi-dictation",
                status: "english-speech-transcriber-unsupported",
                compatibleFormatQueried: false,
                sampleRate: nil,
                channelCount: nil,
                commonFormat: nil
            ))
        }

        if let englishDictation = await DictationTranscriber.supportedLocale(
            equivalentTo: requestedEnglish
        ) {
            let modules: [any SpeechModule] = [
                Self.makeHindiLiveModule(locale: englishDictation),
                Self.makeHindiFinalModule(locale: englishDictation),
                Self.makeHindiLiveModule(locale: hindi),
                Self.makeHindiFinalModule(locale: hindi)
            ]
            configurations.append(await Self.compatibility(
                name: "english-dictation-plus-hindi-dictation",
                modules: modules
            ))
        } else {
            configurations.append(BilingualSpeechCompatibility(
                name: "english-dictation-plus-hindi-dictation",
                status: "english-dictation-transcriber-unsupported",
                compatibleFormatQueried: false,
                sampleRate: nil,
                channelCount: nil,
                commonFormat: nil
            ))
        }

        let report = HindiBilingualCompatibilityReport(
            requestedPair: ["en-US", "hi-IN"],
            configurations: configurations,
            readOnly: true,
            requestedInstallation: false,
            submittedAudio: false
        )
        let reportData = try JSONEncoder.researchEncoder.encode(report)
        let reportJSON = try XCTUnwrap(String(data: reportData, encoding: .utf8))
        print("\n=== LOCALLINGO HINDI BILINGUAL COMPATIBILITY BEGIN ===")
        print(reportJSON)
        print("=== LOCALLINGO HINDI BILINGUAL COMPATIBILITY END ===\n")

        let attachment = XCTAttachment(string: reportJSON)
        attachment.name = "HindiBilingualCompatibility.json"
        attachment.lifetime = .keepAlways
        add(attachment)
#endif
    }

    func testTranscribePinnedHindiFixtureWhileOffline() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Hindi dictation inference must be tested on a physical iPhone.")
#else
        try requireAction(.offlineFixtureInference)

        let network = try await Self.currentNetworkSnapshot()
        guard network.status == "unsatisfied" else {
            XCTFail(
                "Disable Wi-Fi and cellular data before this test. "
                    + "NWPath status was \(network.status)."
            )
            return
        }

        let fixture = try fixtureURL()
        let fixtureDigest = try Self.sha256(of: fixture)
        guard fixtureDigest == Self.approvedFixtureSHA256 else {
            XCTFail("The bundled audio fixture differs from the reviewed research input.")
            return
        }

        let locale = try await supportedHindiLocale()
        let module = Self.makeHindiFinalModule(locale: locale)
        let statusBefore = await AssetInventory.status(forModules: [module])
        guard statusBefore == .installed else {
            XCTFail(
                "Install the Hindi DictationTranscriber asset online first. "
                    + "Current status: \(Self.statusName(statusBefore))."
            )
            return
        }

        let inferenceTask = Task { @MainActor [self] in
            try await transcribeFile(fixture, using: module)
        }
        let result = try await Self.value(
            from: inferenceTask,
            timeout: .seconds(Self.fixtureInferenceTimeoutSeconds)
        )
        let normalizedActual = Self.normalized(result.text)
        let normalizedExpected = Self.normalized(Self.approvedExpectedText)
        XCTAssertEqual(normalizedActual, normalizedExpected)
        XCTAssertFalse(result.text.isEmpty)
        XCTAssertGreaterThan(result.finalResultCount, 0)
        XCTAssertEqual(result.volatileResultCount, 0)

        let statusAfter = await AssetInventory.status(forModules: [module])
        XCTAssertEqual(statusAfter, .installed)
        let networkAfter = try await Self.currentNetworkSnapshot()
        XCTAssertEqual(networkAfter.status, "unsatisfied")

        let report = HindiDictationInferenceReport(
            locale: locale.identifier,
            fixtureName: fixture.lastPathComponent,
            fixtureSHA256: fixtureDigest,
            networkPathStatusBefore: network.status,
            networkPathStatusAfter: networkAfter.status,
            usedCellularPathBefore: network.usesCellular,
            usedCellularPathAfter: networkAfter.usesCellular,
            usedWiFiPathBefore: network.usesWiFi,
            usedWiFiPathAfter: networkAfter.usesWiFi,
            assetStatusBefore: Self.statusName(statusBefore),
            assetStatusAfter: Self.statusName(statusAfter),
            transcript: result.text,
            finalResultCount: result.finalResultCount,
            volatileResultCount: result.volatileResultCount
        )
        let reportData = try JSONEncoder.researchEncoder.encode(report)
        let reportJSON = try XCTUnwrap(String(data: reportData, encoding: .utf8))
        print("\n=== LOCALLINGO HINDI DICTATION INFERENCE BEGIN ===")
        print(reportJSON)
        print("=== LOCALLINGO HINDI DICTATION INFERENCE END ===\n")

        let attachment = XCTAttachment(string: reportJSON)
        attachment.name = "HindiDictationInference.json"
        attachment.lifetime = .keepAlways
        add(attachment)
#endif
    }

    private func supportedHindiLocale() async throws -> Locale {
        let requested = Locale(identifier: "hi-IN")
        guard let supported = await DictationTranscriber.supportedLocale(
            equivalentTo: requested
        ) else {
            XCTFail("DictationTranscriber does not expose an equivalent Hindi locale.")
            throw HindiDictationResearchError.unsupportedHindi
        }
        return supported
    }

    private func transcribeFile(
        _ url: URL,
        using module: DictationTranscriber
    ) async throws -> FileTranscriptionResult {
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [module]
        ) else {
            throw HindiDictationResearchError.noCompatibleAudioFormat
        }

        let analyzer = SpeechAnalyzer(modules: [module])
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        let converter = SpeechAnalyzerInputConverter(analyzerFormat: analyzerFormat)
        let (stream, continuation) = AsyncStream.makeStream(
            of: AnalyzerInput.self,
            bufferingPolicy: .bufferingOldest(128)
        )

        let resultTask = Task {
            var finalTexts: [String] = []
            var volatileCount = 0
            for try await result in module.results {
                let text = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if result.isFinal {
                    if !text.isEmpty { finalTexts.append(text) }
                } else {
                    volatileCount += 1
                }
            }
            return FileTranscriptionResult(
                text: finalTexts.joined(separator: " "),
                finalResultCount: finalTexts.count,
                volatileResultCount: volatileCount
            )
        }
        let analysisTask = Task {
            try await analyzer.analyzeSequence(stream)
        }

        return try await withTaskCancellationHandler {
            do {
                let file = try AVAudioFile(forReading: url)
                while file.framePosition < file.length {
                    try Task.checkCancellation()
                    let remaining = file.length - file.framePosition
                    let frameCount = AVAudioFrameCount(min(Int64(4_096), remaining))
                    guard let buffer = AVAudioPCMBuffer(
                        pcmFormat: file.processingFormat,
                        frameCapacity: frameCount
                    ) else {
                        throw HindiDictationResearchError.audioBufferAllocationFailed
                    }
                    try file.read(into: buffer, frameCount: frameCount)
                    for input in try converter.convert(buffer, at: nil) {
                        continuation.yield(input)
                    }
                }
                for input in try converter.flush() { continuation.yield(input) }
                continuation.finish()

                if let lastTime = try await analysisTask.value {
                    try await analyzer.finalizeAndFinish(through: lastTime)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                return try await resultTask.value
            } catch {
                continuation.finish()
                analysisTask.cancel()
                resultTask.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            continuation.finish()
            analysisTask.cancel()
            resultTask.cancel()
            Task {
                await analyzer.cancelAndFinishNow()
            }
        }
    }

    private func fixtureURL() throws -> URL {
        guard let url = Bundle(for: Self.self).url(
            forResource: "hindi-dictation-fixture",
            withExtension: "wav"
        ) else {
            throw HindiDictationResearchError.missingFixture
        }
        return url
    }

    private func requireAction(_ action: ResearchAction) throws {
        let supplied = ProcessInfo.processInfo.environment[Self.actionKey]
        guard supplied == action.rawValue else {
            throw XCTSkip(
                "Research test is inert. Set \(Self.actionKey)=\(action.rawValue) "
                    + "only for this single test."
            )
        }
    }

    private enum ResearchAction: String {
        case installAsset = "INSTALL_APPLE_HINDI_DICTATION_ASSET"
        case offlineFixtureInference = "TRANSCRIBE_PINNED_FIXTURE_OFFLINE"
    }

    private static let actionKey = "LOCALLINGO_HINDI_DICTATION_RESEARCH_ACTION"
    private static let fixtureInferenceTimeoutSeconds = 90
    private static let networkSnapshotTimeoutSeconds = 5
    private static let approvedFixtureSHA256 =
        "9e34c3ddde1a12e9b4925ac1f8621018a4ab21096c870c18b55fab06f132e552"
    private static let approvedExpectedText =
        "पुलिस ने कहा कि शव लगभग एक दिन पुराना है"

    nonisolated private static func currentNetworkSnapshot() async throws -> NetworkSnapshot {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "LocalLingo.HindiDictationResearch.NWPath")
        let stream = AsyncStream<NetworkSnapshot> { continuation in
            monitor.pathUpdateHandler = { path in
                continuation.yield(NetworkSnapshot(
                    status: Self.networkStatusName(path.status),
                    usesCellular: path.usesInterfaceType(.cellular),
                    usesWiFi: path.usesInterfaceType(.wifi)
                ))
                continuation.finish()
                monitor.cancel()
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: queue)
        }
        let snapshotTask = Task {
            guard let snapshot = await stream.first(where: { _ in true }) else {
                throw HindiDictationResearchError.noNetworkSnapshot
            }
            return snapshot
        }
        return try await value(
            from: snapshotTask,
            timeout: .seconds(networkSnapshotTimeoutSeconds),
            timeoutError: .networkSnapshotTimedOut
        )
    }

    nonisolated private static func value<Value: Sendable>(
        from operationTask: Task<Value, Error>,
        timeout: Duration,
        timeoutError: HindiDictationResearchError = .inferenceTimedOut
    ) async throws -> Value {
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: Value.self,
            throwing: Error.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let forwardingTask = Task {
            do {
                let value = try await operationTask.value
                try Task.checkCancellation()
                continuation.yield(value)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            operationTask.cancel()
            continuation.finish(throwing: timeoutError)
        }
        continuation.onTermination = { @Sendable _ in
            operationTask.cancel()
            forwardingTask.cancel()
            timeoutTask.cancel()
        }
        defer {
            operationTask.cancel()
            forwardingTask.cancel()
            timeoutTask.cancel()
            continuation.finish()
        }

        guard let value = try await stream.first(where: { _ in true }) else {
            throw CancellationError()
        }
        return value
    }

    private static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalized(_ text: String) -> String {
        text
            .precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "hi-IN"))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func statusName(_ status: AssetInventory.Status) -> String {
        switch status {
        case .unsupported: "unsupported"
        case .supported: "supported-not-installed"
        case .downloading: "downloading"
        case .installed: "installed"
        @unknown default: "unknown"
        }
    }

    nonisolated private static func networkStatusName(_ status: NWPath.Status) -> String {
        switch status {
        case .satisfied: "satisfied"
        case .unsatisfied: "unsatisfied"
        case .requiresConnection: "requires-connection"
        @unknown default: "unknown"
        }
    }

    private static func isHindi(_ locale: Locale) -> Bool {
        locale.language.languageCode?.identifier.lowercased() == "hi"
    }

    private static func localeIdentifierReport(_ locale: Locale) -> LocaleIdentifierReport {
        LocaleIdentifierReport(
            identifier: locale.identifier,
            bcp47: locale.identifier(.bcp47)
        )
    }

    private static func makeHindiLiveModule(locale: Locale) -> DictationTranscriber {
        let preset = DictationTranscriber.Preset.progressiveLongDictation
        return DictationTranscriber(
            locale: locale,
            contentHints: preset.contentHints,
            transcriptionOptions: preset.transcriptionOptions,
            reportingOptions: preset.reportingOptions,
            attributeOptions: preset.attributeOptions.union([
                .audioTimeRange,
                .transcriptionConfidence
            ])
        )
    }

    private static func makeHindiFinalModule(locale: Locale) -> DictationTranscriber {
        let preset = DictationTranscriber.Preset.longDictation
        return DictationTranscriber(
            locale: locale,
            contentHints: preset.contentHints,
            transcriptionOptions: preset.transcriptionOptions,
            reportingOptions: preset.reportingOptions,
            attributeOptions: preset.attributeOptions.union([
                .audioTimeRange,
                .transcriptionConfidence
            ])
        )
    }

    private static func makeSpeechLiveModule(locale: Locale) -> SpeechTranscriber {
        let preset = SpeechTranscriber.Preset.transcription
        return SpeechTranscriber(
            locale: locale,
            transcriptionOptions: preset.transcriptionOptions,
            reportingOptions: preset.reportingOptions.union([
                .volatileResults,
                .fastResults
            ]),
            attributeOptions: preset.attributeOptions.union([
                .audioTimeRange,
                .transcriptionConfidence
            ])
        )
    }

    private static func makeSpeechFinalModule(locale: Locale) -> SpeechTranscriber {
        let preset = SpeechTranscriber.Preset.transcription
        return SpeechTranscriber(
            locale: locale,
            transcriptionOptions: preset.transcriptionOptions,
            reportingOptions: preset.reportingOptions.subtracting([
                .volatileResults,
                .fastResults
            ]),
            attributeOptions: preset.attributeOptions.union([
                .audioTimeRange,
                .transcriptionConfidence
            ])
        )
    }

    private static func compatibility(
        name: String,
        modules: [any SpeechModule]
    ) async -> BilingualSpeechCompatibility {
        let status = await AssetInventory.status(forModules: modules)
        guard status == .installed else {
            return BilingualSpeechCompatibility(
                name: name,
                status: statusName(status),
                compatibleFormatQueried: false,
                sampleRate: nil,
                channelCount: nil,
                commonFormat: nil
            )
        }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
        return BilingualSpeechCompatibility(
            name: name,
            status: statusName(status),
            compatibleFormatQueried: true,
            sampleRate: format?.sampleRate,
            channelCount: format?.channelCount,
            commonFormat: format.map { String(describing: $0.commonFormat) }
        )
    }
}

private struct FileTranscriptionResult: Sendable {
    let text: String
    let finalResultCount: Int
    let volatileResultCount: Int
}

private struct NetworkSnapshot: Sendable {
    let status: String
    let usesCellular: Bool
    let usesWiFi: Bool
}

private struct HindiDictationInferenceReport: Encodable {
    let locale: String
    let fixtureName: String
    let fixtureSHA256: String
    let networkPathStatusBefore: String
    let networkPathStatusAfter: String
    let usedCellularPathBefore: Bool
    let usedCellularPathAfter: Bool
    let usedWiFiPathBefore: Bool
    let usedWiFiPathAfter: Bool
    let assetStatusBefore: String
    let assetStatusAfter: String
    let transcript: String
    let finalResultCount: Int
    let volatileResultCount: Int
}

private struct HindiDictationInstallationReport: Encodable {
    let initialStatus: String
    let finalStatus: String
    let requestedInstallation: Bool
    let installedLocale: String
    let installedLocaleBCP47: String
    let sampleRate: Double
    let channelCount: AVAudioChannelCount
    let commonFormat: String
}

private struct HindiBilingualCompatibilityReport: Encodable {
    let requestedPair: [String]
    let configurations: [BilingualSpeechCompatibility]
    let readOnly: Bool
    let requestedInstallation: Bool
    let submittedAudio: Bool
}

private struct BilingualSpeechCompatibility: Encodable {
    let name: String
    let status: String
    let compatibleFormatQueried: Bool
    let sampleRate: Double?
    let channelCount: AVAudioChannelCount?
    let commonFormat: String?
}

private struct HindiDictationConfigurationReport: Encodable {
    let requestedHindiLocale: String
    let resolvedHindiLocale: String
    let requestedEnglishLocale: String
    let resolvedEnglishSpeechLocale: String?
    let resolvedEnglishDictationLocale: String?
    let dictationHindiSupportedLocales: [LocaleIdentifierReport]
    let speechHindiSupportedLocales: [LocaleIdentifierReport]
    let localeProbes: [HindiLocaleConfigurationProbe]
    let maximumReservedLocales: Int
    let reservedLocales: [String]
    let configurations: [SpeechConfigurationStatus]
    let readOnly: Bool
    let requestedInstallation: Bool
    let queriedCompatibleAudioFormat: Bool
}

private struct HindiLocaleConfigurationProbe: Encodable {
    let requestedLocale: String
    let requestedBCP47: String
    let dictationEquivalent: String?
    let dictationEquivalentBCP47: String?
    let dictationExactSupportedLocale: Bool
    let dictationStatus: String
    let speechEquivalent: String?
    let speechEquivalentBCP47: String?
    let speechExactSupportedLocale: Bool
    let speechStatus: String
}

private struct LocaleIdentifierReport: Encodable {
    let identifier: String
    let bcp47: String
}

private struct SpeechConfigurationStatus: Encodable {
    let name: String
    let status: String
}

private enum HindiDictationResearchError: Error {
    case unsupportedHindi
    case noCompatibleAudioFormat
    case audioBufferAllocationFailed
    case missingFixture
    case noNetworkSnapshot
    case networkSnapshotTimedOut
    case inferenceTimedOut
}

private extension JSONEncoder {
    static var researchEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
