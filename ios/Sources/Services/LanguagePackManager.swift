import Combine
import Foundation
@preconcurrency import Translation

@MainActor
final class LanguagePackManager: ObservableObject {
    @Published private(set) var readiness = TripReadiness()
    @Published private(set) var languageStates: [AppLanguage: LanguageAssetState]
    @Published private(set) var speechInventory = SpeechAssetInventorySnapshot.empty
    @Published private(set) var catalogRevision = 0
    @Published private(set) var isWorking = false
    @Published private(set) var activeOperation: LanguagePackOperationTarget?
    @Published private(set) var progressMessage: String?
    @Published private(set) var installationProgress: Double?
    @Published private(set) var noticeMessage: String?
    @Published var errorMessage: String?
    @Published var translationDownloadConfiguration: TranslationSession.Configuration?

    private let speech: any SpeechAssetManaging
    private let translationForStrategy: (OnDeviceTranslationStrategy) -> any TranslationEngine
    private let preferredStrategy: () -> OnDeviceTranslationStrategy
    private let synthesis: any SpeechSynthesisEngine
    private let defaults: UserDefaults
    private let now: () -> Date
    private var selectedPair: LanguagePair?
    private var operationReadiness = TripReadiness()
    private var pendingInstallation: (pair: LanguagePair, generation: Int)?
    private var pendingDirection: TranslationDirection?
    private var activeTranslationSession: TranslationSession?
    private var checking: (pair: LanguagePair, generation: Int, task: Task<Void, Never>)?
    private var installationDidSucceed: ((TripReadiness) -> Void)?
    private var generation = 0
    private var catalogLoad: Task<Void, Never>?
    private var listenDownload: Task<Void, Never>?
    private var lastUsed: [AppLanguage: Date]

    private static let usageKey = "LocalLingo.LanguagePackUsage.v1"

    private enum TranslationDirection: Equatable {
        case forward
        case reverse
    }

    private struct TranslationPreparationToken {
        let pair: LanguagePair
        let generation: Int
        let direction: TranslationDirection
    }

    init(
        speech: any SpeechAssetManaging,
        translationForStrategy: @escaping (OnDeviceTranslationStrategy) -> any TranslationEngine,
        preferredStrategy: @escaping () -> OnDeviceTranslationStrategy,
        synthesis: any SpeechSynthesisEngine,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.speech = speech
        self.translationForStrategy = translationForStrategy
        self.preferredStrategy = preferredStrategy
        self.synthesis = synthesis
        self.defaults = defaults
        self.now = now
        let usage = Self.loadUsage(defaults: defaults)
        lastUsed = usage
        languageStates = Dictionary(
            uniqueKeysWithValues: AppLanguage.conversationLanguages.map { language in
                (
                    language,
                    LanguageAssetState(
                        language: language,
                        lastUsedAt: usage[language]
                    )
                )
            }
        )
    }

    func state(for language: AppLanguage) -> LanguageAssetState {
        languageStates[language] ?? LanguageAssetState(
            language: language,
            lastUsedAt: lastUsed[language]
        )
    }

    func checkIfNeeded(_ pair: LanguagePair) async {
        guard readiness.pair != pair || readiness.translationStrategy != preferredStrategy()
                || readiness.translateForward == .unknown || readiness.translateReverse == .unknown else { return }
        await check(pair)
    }

    func check(_ pair: LanguagePair) async {
        if let listenDownload, selectedPair != pair {
            // A detail download can continue after the user returns to Talk.
            selectedPair = pair
            await listenDownload.value
            guard selectedPair == pair else { return }
        }
        guard !isWorking else { return }
        let strategy = preferredStrategy()
        if let checking, checking.pair == pair, checking.generation == generation,
           operationReadiness.translationStrategy == strategy {
            await checking.task.value
            return
        }
        selectedPair = pair
        generation += 1
        let current = generation
        clearPendingOperation()
        isWorking = false
        activeOperation = nil
        errorMessage = nil
        noticeMessage = nil
        guard LocalConversationLanguagePolicy.supports(pair) else {
            let message = LocalConversationLanguagePolicy.unsupportedMessage(for: pair)
            operationReadiness = TripReadiness(pair: pair, translationStrategy: strategy, generation: current)
            readiness = operationReadiness
            errorMessage = message
            setPairError(message, pair: pair)
            return
        }
        markUsed(pair.traveler)
        markUsed(pair.local)
        if readiness.pair == pair && readiness.translationStrategy == strategy {
            // Keep the selected pair usable until the new probe finishes.
            operationReadiness = readiness
            operationReadiness.generation = current
        } else {
            operationReadiness = checkingReadiness(pair: pair, generation: current, strategy: strategy)
            publishOperationReadiness()
        }
        setPairError(nil, pair: pair)

        let previousCatalogLoad = catalogLoad
        let probe = Task {
            await previousCatalogLoad?.value
            guard isCurrent(pair, current) else { return }
            let inventory = await speech.inventorySnapshot()
            guard isCurrent(pair, current) else { return }
            updateInventory(inventory)
            await refreshOperationReadiness(pair, generation: current)
        }
        checking = (pair, current, probe)
        await probe.value
        if checking?.generation == current { checking = nil }
    }

    func invalidateCatalog() {
        catalogLoad?.cancel()
        catalogLoad = nil
        catalogRevision += 1
    }

    func loadCatalogIfNeeded() async {
        guard !isWorking else { return }
        if let catalogLoad {
            await catalogLoad.value
            return
        }

        // The list and its details share this read, including while the first
        // screen disappears. An asset change explicitly cancels the old read.
        let previousPairCheck = checking?.task
        let load = Task {
            await previousPairCheck?.value
            guard !Task.isCancelled else { return }
            await readCatalog()
        }
        catalogLoad = load
        await load.value
    }

    private func readCatalog() async {
        let languages = AppLanguage.conversationLanguages
        let inventory = await speech.inventorySnapshot()
        guard !Task.isCancelled else { return }
        let voices = await synthesis.availableVoices(for: languages)
        var updates = [AppLanguage: ComponentReadiness]()
        for language in languages {
            guard !Task.isCancelled else { return }
            let raw = await speech.assetReadiness(locale: language.locale)
            updates[language] = effectiveReadiness(raw, language: language, inventory: inventory)
        }
        guard !Task.isCancelled else { return }
        var states = languageStates
        for (language, readiness) in updates {
            states[language]?.listenReadiness = readiness
            states[language]?.listenReserved = inventory.contains(language)
            states[language]?.speakReadiness = voices.contains(language) ? .ready : .downloadRequired
        }
        if speechInventory != inventory { speechInventory = inventory }
        if languageStates != states { languageStates = states }
    }

    func install(_ pair: LanguagePair, onReady: ((TripReadiness) -> Void)? = nil) async {
        guard !isWorking else {
            errorMessage = "Wait for the current language-pack operation to finish."
            return
        }
        guard LocalConversationLanguagePolicy.supports(pair) else {
            errorMessage = LocalConversationLanguagePolicy.unsupportedMessage(for: pair)
            return
        }
        if selectedPair == nil {
            selectedPair = pair
        }

        generation += 1
        catalogLoad?.cancel()
        let current = generation
        clearPendingOperation()
        errorMessage = nil
        noticeMessage = nil
        isWorking = true
        installationDidSucceed = onReady
        activeOperation = .pair(pair)

        let strategy = preferredStrategy()
        operationReadiness = readiness.pair == pair && readiness.translationStrategy == strategy
            ? readiness
            : TripReadiness(pair: pair, translationStrategy: strategy)
        operationReadiness.pair = pair
        operationReadiness.generation = current
        let voices = await synthesis.availableVoices(for: [pair.traveler, pair.local])
        guard isCurrent(pair, current) else { return }
        operationReadiness.speakTraveler = voices.contains(pair.traveler) ? .ready : .downloadRequired
        operationReadiness.speakLocal = voices.contains(pair.local) ? .ready : .downloadRequired
        setPairError(nil, pair: pair)
        publishOperationReadiness()

        let inventory = await speech.inventorySnapshot()
        guard isCurrent(pair, current) else { return }
        updateInventory(inventory)

        do {
            try await prepareListeningAsset(pair.traveler, generation: current)
            try await prepareListeningAsset(pair.local, generation: current)
            try await prepareContinuousListeningAssets(pair, generation: current)

            let translation = translationForStrategy(strategy)
            let forward = await translation.availability(
                source: pair.traveler.language,
                target: pair.local.language
            )
            try requireCurrent(pair, current)
            operationReadiness.translateForward = forward
            publishOperationReadiness()

            let reverse = await translation.availability(
                source: pair.local.language,
                target: pair.traveler.language
            )
            try requireCurrent(pair, current)
            operationReadiness.translateReverse = reverse
            publishOperationReadiness()

            guard forward != .unavailable, reverse != .unavailable else {
                throw PipelineError.assetsUnavailable(
                    "On-device translation is unavailable for this language pair."
                )
            }
            if forward == .ready, reverse == .ready {
                markUsed(pair.traveler)
                markUsed(pair.local)
                completeOperation(installed: true)
                return
            }

            let firstDirection: TranslationDirection = forward == .ready ? .reverse : .forward
            await beginTranslationPreparation(
                direction: firstDirection,
                pair: pair,
                generation: current
            )
        } catch {
            guard isCurrent(pair, current) else { return }
            if Task.isCancelled || error is CancellationError {
                normalizePendingReadiness()
                completeOperation()
                return
            }
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            errorMessage = message
            setPairError(message, pair: pair)
            completeOperation()
        }
    }

    func downloadListen(for language: AppLanguage, protecting pair: LanguagePair) {
        guard !isWorking else { return }
        selectedPair = pair
        let interruptedPairCheck = checking != nil
        generation += 1
        let current = generation
        catalogLoad?.cancel()
        errorMessage = nil
        noticeMessage = nil
        setLanguageError(nil, language: language)
        isWorking = true
        activeOperation = .language(language)
        progressMessage = "Checking the listening model"
        listenDownload = Task {
            do {
                try await prepareListeningAsset(language, generation: current)
                try requireActiveOperation(current)
                markUsed(language)
            } catch {
                guard generation == current else { return }
                if !(error is CancellationError) {
                    errorMessage = error.localizedDescription
                    setLanguageError(error.localizedDescription, language: language)
                }
                resetListenProgress(for: language)
            }
            if interruptedPairCheck || pair.traveler == language || pair.local == language {
                operationReadiness = TripReadiness(
                    pair: pair, translationStrategy: preferredStrategy(), generation: current
                )
                await refreshOperationReadiness(pair, generation: current)
                guard generation == current else { return }
            }
            completeOperation()
        }
    }

    func isDownloadingListen(for language: AppLanguage) -> Bool {
        listenDownload != nil && activeOperation == .language(language)
    }

    func releaseListen(for language: AppLanguage) async {
        guard !isWorking else {
            errorMessage = "Wait for the current language-pack operation to finish."
            return
        }
        guard selectedPair?.traveler != language,
              selectedPair?.local != language else {
            errorMessage = "Change the selected conversation pair before releasing this Listen model."
            return
        }

        generation += 1
        catalogLoad?.cancel()
        let current = generation
        clearPendingOperation()
        errorMessage = nil
        noticeMessage = nil
        isWorking = true
        activeOperation = .language(language)
        progressMessage = "Releasing the \(language.displayName) Listen reservation"

        let inventory = await speech.inventorySnapshot()
        guard generation == current else { return }
        updateInventory(inventory)
        guard let reserved = inventory.reservedLocale(matching: language) else {
            noticeMessage = "The \(language.displayName) Listen model is not reserved by LocalLingo."
            completeOperation()
            return
        }

        let released = await speech.releaseAssets(reservedLocale: reserved)
        guard generation == current else { return }
        guard released else {
            let message = "iOS could not release the \(language.displayName) Listen reservation."
            errorMessage = message
            setLanguageError(message, language: language)
            completeOperation()
            return
        }

        let refreshed = await speech.inventorySnapshot()
        guard generation == current else { return }
        updateInventory(refreshed)
        guard !refreshed.contains(language) else {
            let message = "The \(language.displayName) Listen reservation is still active."
            errorMessage = message
            setLanguageError(message, language: language)
            completeOperation()
            return
        }

        var state = state(for: language)
        let raw = await speech.assetReadiness(locale: language.locale)
        guard generation == current else { return }
        state.listenReadiness = effectiveReadiness(
            raw,
            language: language,
            inventory: refreshed
        )
        state.listenReserved = false
        state.errorMessage = nil
        languageStates[language] = state
        noticeMessage = "Listen reservation released. iOS decides when shared model files are removed."
        completeOperation()
    }

    func cancelInstallation() {
        guard isWorking else { return }
        generation += 1
        if let listenDownload, case let .language(language) = activeOperation {
            listenDownload.cancel()
            resetListenProgress(for: language)
        }
        activeTranslationSession?.cancel()
        activeTranslationSession = nil
        if case .some(.pair) = activeOperation {
            operationReadiness.generation = generation
            normalizePendingReadiness()
        }
        errorMessage = nil
        noticeMessage = nil
        completeOperation()
    }

    func prepareTranslation(using session: TranslationSession) async {
        guard let token = currentTranslationToken() else { return }
        let expected = translationLanguages(for: token)
        guard sessionLanguage(session.sourceLanguage, matches: expected.source),
              sessionLanguage(session.targetLanguage, matches: expected.target) else {
            await finishTranslationPreparation(
                token: token,
                failureMessage: "iOS opened a Translation session for a different language pair. Retry the download."
            )
            return
        }

        activeTranslationSession = session
        defer {
            if activeTranslationSession === session {
                activeTranslationSession = nil
            }
        }
        await performPendingTranslation(token: token) {
            try await session.prepareTranslation()
            guard await session.isReady else {
                throw TranslationPreparationError.downloadStillInProgress
            }
        }
    }

    func preparePendingTranslation(
        _ operation: @MainActor () async throws -> Void,
        isReady: @MainActor () async -> Bool = { true }
    ) async {
        guard let token = currentTranslationToken() else { return }
        await performPendingTranslation(token: token) {
            try await operation()
            guard await isReady() else {
                throw TranslationPreparationError.downloadStillInProgress
            }
        }
    }

    func markUsed(_ language: AppLanguage) {
        guard AppLanguage.conversationLanguages.contains(language) else { return }
        let date = now()
        lastUsed[language] = date
        var state = state(for: language)
        state.lastUsedAt = date
        languageStates[language] = state
        saveUsage()
    }

    private func performPendingTranslation(
        token: TranslationPreparationToken,
        _ operation: @MainActor () async throws -> Void
    ) async {
        do {
            try await operation()
            await finishTranslationPreparation(token: token, failureMessage: nil)
        } catch {
            if Task.isCancelled || error is CancellationError {
                finishTranslationCancellation(token: token)
                return
            }
            await finishTranslationPreparation(
                token: token,
                failureMessage: error.localizedDescription
            )
        }
    }

    private enum TranslationPreparationError: LocalizedError {
        case downloadStillInProgress

        var errorDescription: String? {
            "The Translation download has not finished. Leave the iPhone on Wi-Fi, then retry."
        }
    }

    private func prepareListeningAsset(
        _ language: AppLanguage,
        generation current: Int
    ) async throws {
        let inventory = await speech.inventorySnapshot()
        try requireActiveOperation(current)
        updateInventory(inventory)

        let initialRaw = await speech.assetReadiness(locale: language.locale)
        try requireActiveOperation(current)
        let initial = effectiveReadiness(
            initialRaw,
            language: language,
            inventory: inventory
        )
        publishListenReadiness(initial, for: language)

        guard initial != .unavailable else {
            throw PipelineError.assetsUnavailable(
                "On-device Listen recognition is unavailable for \(language.displayName) on this iPhone."
            )
        }
        if initialRaw == .ready, inventory.contains(language) { return }

        try await ensureReservationCapacity(for: language, generation: current)

        if initialRaw == .ready {
            progressMessage = "Reserving Listen recognition: \(language.displayName)"
            installationProgress = nil
            try await speech.reserveAssets(locale: language.locale)
        } else {
            publishListenReadiness(.downloading, for: language)
            progressMessage = "Preparing Listen recognition: \(language.displayName). iOS may pause and resume this model download."
            installationProgress = nil
            try await speech.installAssets(locale: language.locale) { [weak self] fraction in
                guard let self,
                      self.isWorking,
                      self.generation == current else {
                    return
                }
                self.installationProgress = fraction
            }
        }
        try requireActiveOperation(current)

        var verifiedInventory = await speech.inventorySnapshot()
        try requireActiveOperation(current)
        if !verifiedInventory.contains(language) {
            try await speech.reserveAssets(locale: language.locale)
            try requireActiveOperation(current)
            verifiedInventory = await speech.inventorySnapshot()
            try requireActiveOperation(current)
        }
        updateInventory(verifiedInventory)

        let verifiedRaw = await speech.assetReadiness(locale: language.locale)
        try requireActiveOperation(current)
        let verified = effectiveReadiness(
            verifiedRaw,
            language: language,
            inventory: verifiedInventory
        )
        publishListenReadiness(verified, for: language)
        guard verified == .ready else {
            throw PipelineError.assetsUnavailable(
                "iOS has not finished installing and reserving the Listen model for \(language.displayName)."
            )
        }
    }

    private func ensureReservationCapacity(
        for language: AppLanguage,
        generation current: Int
    ) async throws {
        var inventory = await speech.inventorySnapshot()
        try requireActiveOperation(current)
        updateInventory(inventory)
        guard !inventory.contains(language) else { return }
        guard inventory.maximumReservedLocales > 0 else {
            throw PipelineError.assetsUnavailable(
                "This iPhone did not report any available Listen model reservations."
            )
        }

        while inventory.reservedCount >= inventory.maximumReservedLocales {
            // Hidden beta languages can remain reserved after installing a
            // build whose visible catalog no longer includes them.
            let candidates = AppLanguage.allCases
                .filter {
                    inventory.contains($0) && activeOperation?.contains($0) != true
                        && $0 != selectedPair?.traveler && $0 != selectedPair?.local
                }
                .sorted {
                    let lhs = lastUsed[$0] ?? .distantPast
                    let rhs = lastUsed[$1] ?? .distantPast
                    if lhs != rhs { return lhs < rhs }
                    return $0.rawValue < $1.rawValue
                }
            guard let candidate = candidates.first,
                  let reserved = inventory.reservedLocale(matching: candidate) else {
                throw PipelineError.assetsUnavailable(
                    "The Listen reservation limit is full and no inactive LocalLingo language can be released."
                )
            }

            progressMessage = "Releasing least recently used Listen model: \(candidate.displayName)"
            installationProgress = nil
            guard await speech.releaseAssets(reservedLocale: reserved) else {
                throw PipelineError.assetsUnavailable(
                    "iOS could not release the \(candidate.displayName) Listen reservation."
                )
            }
            try requireActiveOperation(current)
            let refreshed = await speech.inventorySnapshot()
            try requireActiveOperation(current)
            guard refreshed.reservedCount < inventory.reservedCount,
                  !refreshed.contains(candidate) else {
                throw PipelineError.assetsUnavailable(
                    "iOS did not free the \(candidate.displayName) Listen reservation."
                )
            }
            inventory = refreshed
            updateInventory(inventory)
        }
    }

    private func beginTranslationPreparation(
        direction: TranslationDirection,
        pair: LanguagePair,
        generation current: Int
    ) async {
        guard isCurrent(pair, current) else { return }
        pendingInstallation = (pair, current)
        pendingDirection = direction
        installationProgress = nil

        switch direction {
        case .forward:
            operationReadiness.translateForward = .checking
            progressMessage = "Preparing translation: \(pair.traveler.displayName) to \(pair.local.displayName)"
        case .reverse:
            operationReadiness.translateReverse = .checking
            progressMessage = "Preparing translation: \(pair.local.displayName) to \(pair.traveler.displayName)"
        }
        publishOperationReadiness()

        guard isCurrent(pair, current), pendingDirection == direction else { return }
        let languages = translationLanguages(
            for: TranslationPreparationToken(
                pair: pair,
                generation: current,
                direction: direction
            )
        )
        if var existing = translationDownloadConfiguration,
           existing.source == languages.source,
           existing.target == languages.target {
            existing.invalidate()
            translationDownloadConfiguration = existing
            return
        }
        translationDownloadConfiguration = configuration(
            source: languages.source,
            target: languages.target
        )
    }

    private func currentTranslationToken() -> TranslationPreparationToken? {
        guard let pending = pendingInstallation,
              let direction = pendingDirection,
              isCurrent(pending.pair, pending.generation) else {
            return nil
        }
        return TranslationPreparationToken(
            pair: pending.pair,
            generation: pending.generation,
            direction: direction
        )
    }

    private func translationLanguages(
        for token: TranslationPreparationToken
    ) -> (source: Locale.Language, target: Locale.Language) {
        switch token.direction {
        case .forward:
            (token.pair.traveler.language, token.pair.local.language)
        case .reverse:
            (token.pair.local.language, token.pair.traveler.language)
        }
    }

    private func sessionLanguage(
        _ actual: Locale.Language?,
        matches expected: Locale.Language
    ) -> Bool {
        actual?.languageCode == expected.languageCode
    }

    private func finishTranslationCancellation(token: TranslationPreparationToken) {
        guard let current = currentTranslationToken(),
              current.pair == token.pair,
              current.generation == token.generation,
              current.direction == token.direction else {
            return
        }
        switch token.direction {
        case .forward: operationReadiness.translateForward = .unknown
        case .reverse: operationReadiness.translateReverse = .unknown
        }
        publishOperationReadiness()
        completeOperation()
    }

    private func finishTranslationPreparation(
        token: TranslationPreparationToken,
        failureMessage: String?
    ) async {
        guard let pending = pendingInstallation,
              pending.pair == token.pair,
              pending.generation == token.generation,
              pendingDirection == token.direction,
              isCurrent(token.pair, token.generation) else {
            return
        }

        if let failureMessage {
            switch token.direction {
            case .forward: operationReadiness.translateForward = .unknown
            case .reverse: operationReadiness.translateReverse = .unknown
            }
            errorMessage = failureMessage
            setPairError(failureMessage, pair: token.pair)
            publishOperationReadiness()
            completeOperation()
            return
        }

        switch token.direction {
        case .forward:
            operationReadiness.translateForward = .ready
            publishOperationReadiness()
            if operationReadiness.translateReverse == .ready {
                markUsed(token.pair.traveler)
                markUsed(token.pair.local)
                completeOperation(installed: true)
            } else {
                await beginTranslationPreparation(
                    direction: .reverse,
                    pair: token.pair,
                    generation: token.generation
                )
            }
        case .reverse:
            operationReadiness.translateReverse = .ready
            publishOperationReadiness()
            markUsed(token.pair.traveler)
            markUsed(token.pair.local)
            completeOperation(installed: true)
        }
    }

    private func refreshOperationReadiness(
        _ pair: LanguagePair,
        generation current: Int
    ) async {
        let probed = await probeReadiness(
            pair: pair,
            inventory: speechInventory,
            generation: current
        )
        guard isCurrent(pair, current) else { return }
#if DEBUG
        print("Talk readiness [\(probed.translationStrategy.rawValue)]: listen=\(probed.listenTraveler)/\(probed.listenLocal)/\(probed.listenPair) translate=\(probed.translateForward)/\(probed.translateReverse)")
#endif
        operationReadiness = probed
        operationReadiness.generation = current
        publishOperationReadiness()
    }

    private func probeReadiness(
        pair: LanguagePair,
        inventory: SpeechAssetInventorySnapshot,
        generation current: Int
    ) async -> TripReadiness {
        let strategy = operationReadiness.translationStrategy
        let translation = translationForStrategy(strategy)
        var result = checkingReadiness(pair: pair, generation: current, strategy: strategy)
        let travelerSpeech = await speech.assetReadiness(locale: pair.traveler.locale)
        result.listenTraveler = effectiveReadiness(
            travelerSpeech,
            language: pair.traveler,
            inventory: inventory
        )
        let localSpeech = await speech.assetReadiness(locale: pair.local.locale)
        result.listenLocal = effectiveReadiness(
            localSpeech,
            language: pair.local,
            inventory: inventory
        )
        if result.listenTraveler == .ready, result.listenLocal == .ready {
            result.listenPair = await speech.continuousAssetReadiness(pair: pair)
        } else if result.listenTraveler == .unavailable || result.listenLocal == .unavailable {
            result.listenPair = .unavailable
        } else {
            result.listenPair = .downloadRequired
        }
        result.translateForward = await translation.availability(
            source: pair.traveler.language,
            target: pair.local.language
        )
        result.translateReverse = await translation.availability(
            source: pair.local.language,
            target: pair.traveler.language
        )
        let voices = await synthesis.availableVoices(for: [pair.traveler, pair.local])
        result.speakTraveler = voices.contains(pair.traveler) ? .ready : .downloadRequired
        result.speakLocal = voices.contains(pair.local) ? .ready : .downloadRequired
        return result
    }

    private func checkingReadiness(
        pair: LanguagePair,
        generation: Int,
        strategy: OnDeviceTranslationStrategy
    ) -> TripReadiness {
        TripReadiness(
            pair: pair,
            translationStrategy: strategy,
            generation: generation,
            listenTraveler: .checking,
            listenLocal: .checking,
            listenPair: .checking,
            translateForward: .checking,
            translateReverse: .checking,
            speakTraveler: .checking,
            speakLocal: .checking
        )
    }

    private func prepareContinuousListeningAssets(
        _ pair: LanguagePair,
        generation current: Int
    ) async throws {
        operationReadiness.listenPair = .checking
        publishOperationReadiness()
        let initial = await speech.continuousAssetReadiness(pair: pair)
        try requireCurrent(pair, current)
        operationReadiness.listenPair = initial
        publishOperationReadiness()

        guard initial == .downloadRequired || initial == .downloading else {
            return
        }

        operationReadiness.listenPair = .downloading
        progressMessage = "Preparing continuous Listen recognition for \(pair.traveler.displayName) and \(pair.local.displayName). iOS may pause and resume this model download."
        installationProgress = nil
        publishOperationReadiness()

        do {
            try await speech.installContinuousAssets(pair: pair) { [weak self] fraction in
                guard let self,
                      self.isWorking,
                      self.isCurrent(pair, current) else {
                    return
                }
                self.installationProgress = fraction
            }
            try requireCurrent(pair, current)
        } catch {
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            let verified = await speech.continuousAssetReadiness(pair: pair)
            try requireCurrent(pair, current)
            operationReadiness.listenPair = verified
            publishOperationReadiness()
            if verified == .unavailable {
                return
            }
            throw error
        }

        let verified = await speech.continuousAssetReadiness(pair: pair)
        try requireCurrent(pair, current)
        operationReadiness.listenPair = verified
        publishOperationReadiness()
        guard verified == .ready || verified == .unavailable else {
            throw PipelineError.assetsUnavailable(
                "iOS has not finished installing the continuous Listen models for \(pair.traveler.displayName) and \(pair.local.displayName)."
            )
        }
    }

    private func effectiveReadiness(
        _ readiness: ComponentReadiness,
        language: AppLanguage,
        inventory: SpeechAssetInventorySnapshot
    ) -> ComponentReadiness {
        if readiness == .ready, !inventory.contains(language) {
            return .downloadRequired
        }
        return readiness
    }

    private func requireActiveOperation(_ current: Int) throws {
        try Task.checkCancellation()
        guard generation == current, isWorking else { throw CancellationError() }
    }

    private func publishListenReadiness(_ value: ComponentReadiness, for language: AppLanguage) {
        if case let .pair(pair) = activeOperation {
            if pair.traveler == language { operationReadiness.listenTraveler = value }
            else { operationReadiness.listenLocal = value }
            publishOperationReadiness()
        } else {
            var state = state(for: language)
            state.listenReadiness = value
            state.listenReserved = speechInventory.contains(language)
            languageStates[language] = state
        }
    }

    private func resetListenProgress(for language: AppLanguage) {
        if state(for: language).listenReadiness == .downloading {
            languageStates[language]?.listenReadiness = .downloadRequired
        }
    }

    private func updateInventory(_ inventory: SpeechAssetInventorySnapshot) {
        guard speechInventory != inventory else { return }
        speechInventory = inventory
        var states = languageStates
        for language in AppLanguage.conversationLanguages {
            var state = state(for: language)
            state.listenReserved = inventory.contains(language)
            if state.listenReadiness == .ready, !state.listenReserved {
                state.listenReadiness = .downloadRequired
            }
            states[language] = state
        }
        if languageStates != states { languageStates = states }
    }

    private func publishOperationReadiness() {
        guard let pair = operationReadiness.pair else { return }
        var travelerState = state(for: pair.traveler)
        travelerState.listenReadiness = operationReadiness.listenTraveler
        travelerState.listenReserved = speechInventory.contains(pair.traveler)
        travelerState.speakReadiness = operationReadiness.speakTraveler
        travelerState.lastUsedAt = lastUsed[pair.traveler]
        languageStates[pair.traveler] = travelerState

        var localState = state(for: pair.local)
        localState.listenReadiness = operationReadiness.listenLocal
        localState.listenReserved = speechInventory.contains(pair.local)
        localState.speakReadiness = operationReadiness.speakLocal
        localState.lastUsedAt = lastUsed[pair.local]
        languageStates[pair.local] = localState

        if selectedPair == pair {
            readiness = operationReadiness
        }
    }

    private func setLanguageError(_ message: String?, language: AppLanguage) {
        var state = state(for: language)
        state.errorMessage = message
        languageStates[language] = state
    }

    private func setPairError(_ message: String?, pair: LanguagePair) {
        setLanguageError(message, language: pair.traveler)
        setLanguageError(message, language: pair.local)
    }

    private func requireCurrent(_ pair: LanguagePair, _ value: Int) throws {
        try Task.checkCancellation()
        guard isCurrent(pair, value) else { throw CancellationError() }
    }

    private func isCurrent(_ pair: LanguagePair, _ value: Int) -> Bool {
        generation == value
            && operationReadiness.pair == pair
            && operationReadiness.generation == value
    }

    private func clearPendingOperation() {
        pendingInstallation = nil
        pendingDirection = nil
        translationDownloadConfiguration = nil
        progressMessage = nil
        installationProgress = nil
    }

    private func completeOperation(installed: Bool = false) {
        let completion = installationDidSucceed
        listenDownload = nil
        installationDidSucceed = nil
        isWorking = false
        activeOperation = nil
        clearPendingOperation()
        invalidateCatalog()
        if installed { completion?(operationReadiness) }
    }

    private func normalizePendingReadiness() {
        operationReadiness.listenTraveler = normalizedAfterCancellation(
            operationReadiness.listenTraveler
        )
        operationReadiness.listenLocal = normalizedAfterCancellation(
            operationReadiness.listenLocal
        )
        operationReadiness.listenPair = normalizedAfterCancellation(
            operationReadiness.listenPair
        )
        operationReadiness.translateForward = normalizedAfterCancellation(
            operationReadiness.translateForward
        )
        operationReadiness.translateReverse = normalizedAfterCancellation(
            operationReadiness.translateReverse
        )
        operationReadiness.speakTraveler = normalizedAfterCancellation(
            operationReadiness.speakTraveler
        )
        operationReadiness.speakLocal = normalizedAfterCancellation(
            operationReadiness.speakLocal
        )
        publishOperationReadiness()
    }

    private func normalizedAfterCancellation(
        _ value: ComponentReadiness
    ) -> ComponentReadiness {
        switch value {
        case .checking, .downloading: .unknown
        default: value
        }
    }

    private func configuration(
        source: Locale.Language,
        target: Locale.Language
    ) -> TranslationSession.Configuration {
        if #available(iOS 26.4, *) {
            TranslationSession.Configuration(
                source: source,
                target: target,
                preferredStrategy: operationReadiness.translationStrategy.appleStrategy
            )
        } else {
            TranslationSession.Configuration(source: source, target: target)
        }
    }

    private static func loadUsage(defaults: UserDefaults) -> [AppLanguage: Date] {
        guard let stored = defaults.dictionary(forKey: usageKey) as? [String: Double] else {
            return [:]
        }
        return stored.reduce(into: [:]) { result, entry in
            guard let language = AppLanguage(rawValue: entry.key),
                  AppLanguage.conversationLanguages.contains(language) else {
                return
            }
            result[language] = Date(timeIntervalSince1970: entry.value)
        }
    }

    private func saveUsage() {
        let stored = lastUsed.reduce(into: [String: Double]()) { result, entry in
            result[entry.key.rawValue] = entry.value.timeIntervalSince1970
        }
        defaults.set(stored, forKey: Self.usageKey)
    }
}
