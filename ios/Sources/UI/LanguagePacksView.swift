import SwiftUI

struct LanguagePacksView: View {
    @ObservedObject var manager: LanguagePackManager
    @ObservedObject var settings: SettingsStore
    @State private var operationTask: Task<Void, Never>?

    private var pair: LanguagePair { settings.value.pair }
    private var pairReadiness: TripReadiness { manager.readiness }
    private var isPreparingPair: Bool {
        manager.isWorking && manager.activeOperation == .pair(pair)
    }

    var body: some View {
        List {
            selectedPairSection
            reservationSection

            Section("Languages") {
                ForEach(AppLanguage.conversationLanguages) { language in
                    NavigationLink {
                        LanguageAssetDetailView(
                            language: language,
                            manager: manager,
                            settings: settings
                        )
                    } label: {
                        LanguageAssetRow(
                            state: manager.state(for: language),
                            selectedSide: selectedSide(for: language),
                            isWorking: manager.isWorking
                                && manager.activeOperation?.contains(language) == true
                        )
                    }
                    .accessibilityIdentifier("languagePacks.\(language.code)")
                }
            }

            Section("System-managed components") {
                Label("Translation downloads", systemImage: "character.book.closed")
                Text("Remove translation languages in Settings > Apps > Translate > Downloaded Languages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label("Speak voices", systemImage: "speaker.wave.2")
                Text("Install or remove voices in Settings > Accessibility > Read & Speak > Voices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let notice = manager.noticeMessage {
                Section {
                    Label(notice, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Language Packs")
        .accessibilityIdentifier("languagePacks.list")
        .task {
            await manager.check(pair)
            await manager.refreshAll()
        }
        .refreshable {
            await manager.check(pair)
            await manager.refreshAll()
        }
        .onDisappear {
            operationTask?.cancel()
        }
        .tint(TranslatorTheme.accent)
    }

    private var selectedPairSection: some View {
        Section("Selected Pair") {
            LabeledContent(
                pair.traveler.displayName,
                value: "Language A"
            )
            LabeledContent(
                pair.local.displayName,
                value: "Language B"
            )

            ReadinessRow(
                title: "Listen: \(pair.traveler.displayName)",
                value: readiness(\.listenTraveler)
            )
            ReadinessRow(
                title: "Listen: \(pair.local.displayName)",
                value: readiness(\.listenLocal)
            )
            ReadinessRow(
                title: "Listen together",
                value: readiness(\.listenPair)
            )
            ReadinessRow(
                title: "Translate both directions",
                value: combine(
                    readiness(\.translateForward),
                    readiness(\.translateReverse)
                )
            )
            ReadinessRow(
                title: "Speak both languages",
                value: combine(
                    readiness(\.speakTraveler),
                    readiness(\.speakLocal)
                )
            )

            if continuousListeningUnavailable {
                Label(
                    manualConversationReady
                        ? "Manual conversation is ready; continuous listening is unavailable for this pair on this iPhone."
                        : "Continuous listening is unavailable; complete the remaining setup for manual turns.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if isPreparingPair {
                preparationProgress
                Button(role: .cancel) {
                    operationTask?.cancel()
                    operationTask = nil
                    manager.cancelInstallation()
                } label: {
                    Label("Cancel preparation", systemImage: "xmark.circle")
                }
            } else {
                Button {
                    operationTask?.cancel()
                    operationTask = Task {
                        await manager.install(pair)
                    }
                } label: {
                    Label(
                        selectedPairActionTitle,
                        systemImage: "arrow.down.circle"
                    )
                }
                .disabled(
                    manager.isWorking
                        || !LocalConversationLanguagePolicy.supports(pair)
                        || (continuousListeningUnavailable
                            && (manualConversationReady || manualVoiceSetupRequired))
                )
            }

            if let error = manager.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var continuousListeningUnavailable: Bool {
        pairReadiness.pair == pair && pairReadiness.listenPair == .unavailable
    }

    private var manualConversationReady: Bool {
        pairReadiness.pair == pair
            && pairReadiness.isManualReady(
                requiringVoices: settings.value.autoSpeak
            )
    }

    private var manualVoiceSetupRequired: Bool {
        pairReadiness.pair == pair
            && settings.value.autoSpeak
            && pairReadiness.isManualReady(requiringVoices: false)
            && !pairReadiness.isManualReady(requiringVoices: true)
    }

    private var selectedPairActionTitle: String {
        if continuousListeningUnavailable {
            if manualConversationReady { return "Manual conversation ready" }
            if manualVoiceSetupRequired {
                return "Install Speak voices or turn off Auto Speak"
            }
            return "Download and verify manual setup"
        }
        return pairReadiness.isReady(requiringVoices: false)
            && pairReadiness.pair == pair
            ? "Verify selected pair"
            : "Download and verify selected pair"
    }

    private var reservationSection: some View {
        Section("Listen Reservations") {
            LabeledContent("In use", value: reservationUsage)
            reservationProgress
            Text("Speak Duet protects both selected languages. When the iPhone limit is full, it releases the least recently used inactive reservation.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var preparationProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = manager.progressMessage {
                Text(message)
                    .font(.caption)
            }
            if let fraction = manager.installationProgress {
                HStack {
                    ProgressView(value: fraction)
                    Text(
                        fraction,
                        format: .percent.precision(.fractionLength(0))
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
            }
        }
    }

    private var reservationUsage: String {
        let inventory = manager.speechInventory
        guard inventory.maximumReservedLocales > 0 else { return "Checking" }
        return "\(inventory.reservedCount) of \(inventory.maximumReservedLocales)"
    }

    @ViewBuilder
    private var reservationProgress: some View {
        let inventory = manager.speechInventory
        if inventory.maximumReservedLocales > 0 {
            ProgressView(
                value: Double(inventory.reservedCount),
                total: Double(inventory.maximumReservedLocales)
            )
            .progressViewStyle(.linear)
            .accessibilityLabel("Listen reservations")
            .accessibilityValue(reservationUsage)
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .accessibilityLabel("Checking Listen reservation capacity")
        }
    }

    private func selectedSide(for language: AppLanguage) -> SpeakerSide? {
        if pair.traveler == language { return .traveler }
        if pair.local == language { return .local }
        return nil
    }

    private func readiness(
        _ keyPath: KeyPath<TripReadiness, ComponentReadiness>
    ) -> ComponentReadiness {
        guard pairReadiness.pair == pair else { return .checking }
        return pairReadiness[keyPath: keyPath]
    }
}

private struct LanguageAssetRow: View {
    let state: LanguageAssetState
    let selectedSide: SpeakerSide?
    let isWorking: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(state.language.nativeName)
                    .font(.body)
                if state.language.nativeName != state.language.displayName {
                    Text(state.language.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Label(status.label, systemImage: status.icon)
                    .font(.caption)
                    .foregroundStyle(status.color)
                if let selectedSide {
                    Text(selectedSide == .traveler ? "Language A" : "Language B")
                        .font(.caption2)
                        .foregroundStyle(TranslatorTheme.accent)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var status: LanguageAssetStatusPresentation {
        LanguageAssetStatusPresentation(state: state, isWorking: isWorking)
    }
}

private struct LanguageAssetDetailView: View {
    let language: AppLanguage
    @ObservedObject var manager: LanguagePackManager
    @ObservedObject var settings: SettingsStore
    @State private var operationTask: Task<Void, Never>?

    private var state: LanguageAssetState { manager.state(for: language) }
    private var selectedSide: SpeakerSide? {
        if settings.value.pair.traveler == language { return .traveler }
        if settings.value.pair.local == language { return .local }
        return nil
    }
    private var isCurrentOperation: Bool {
        manager.isWorking && manager.activeOperation?.contains(language) == true
    }

    var body: some View {
        Form {
            if let selectedSide {
                Section {
                    Label(
                        selectedSide == .traveler
                            ? "Selected as Language A"
                            : "Selected as Language B",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(TranslatorTheme.success)
                }
            }

            Section("Components") {
                ReadinessRow(
                    title: "Listen recognition",
                    value: state.listenReadiness
                )
                LabeledContent(
                    "Listen reservation",
                    value: state.listenReserved ? "Reserved" : "Not reserved"
                )
                ReadinessRow(
                    title: "Speak voice",
                    value: state.speakReadiness
                )
            }

            if language == .hindiIndia {
                Section("Availability") {
                    LabeledContent("Conversation pairing", value: "English only")
                }
            }

            Section {
                if state.listenReserved {
                    Button {
                        operationTask?.cancel()
                        operationTask = Task {
                            await manager.releaseListen(for: language)
                        }
                    } label: {
                        Label("Release Listen reservation", systemImage: "minus.circle")
                    }
                    .disabled(manager.isWorking || selectedSide != nil)
                }

                if selectedSide != nil, state.listenReserved {
                    Text("Change the selected conversation pair before releasing this Listen reservation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Releasing a reservation does not force immediate deletion. iOS removes shared Listen files when it chooses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = state.errorMessage
                ?? (isCurrentOperation ? manager.errorMessage : nil) {
                Section {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Other downloads") {
                Text("Translation: Settings > Apps > Translate > Downloaded Languages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Speak: Settings > Accessibility > Read & Speak > Voices")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(language.displayName)
        .accessibilityIdentifier("languagePacks.detail.\(language.code)")
        .task { await manager.refresh(language) }
        .onDisappear {
            operationTask?.cancel()
        }
        .tint(TranslatorTheme.accent)
    }
}

private struct LanguageAssetStatusPresentation {
    let label: String
    let icon: String
    let color: Color

    init(state: LanguageAssetState, isWorking: Bool) {
        if isWorking {
            label = "Preparing"
            icon = "arrow.down.circle.fill"
            color = .orange
        } else if state.listenReadiness == .unavailable {
            label = "Unavailable"
            icon = "xmark.circle.fill"
            color = .red
        } else if state.isListenReady && state.speakReadiness == .ready {
            label = "Ready"
            icon = "checkmark.circle.fill"
            color = TranslatorTheme.success
        } else if state.listenReadiness == .checking
                    || state.listenReadiness == .unknown {
            label = "Checking"
            icon = "hourglass"
            color = .orange
        } else {
            label = "Setup needed"
            icon = "arrow.down.circle"
            color = .orange
        }
    }
}

private func combine(
    _ first: ComponentReadiness,
    _ second: ComponentReadiness
) -> ComponentReadiness {
    if first == .unavailable || second == .unavailable { return .unavailable }
    if first == .downloading || second == .downloading { return .downloading }
    if first == .downloadRequired || second == .downloadRequired {
        return .downloadRequired
    }
    if first == .checking || second == .checking { return .checking }
    if first == .ready, second == .ready { return .ready }
    return .unknown
}
