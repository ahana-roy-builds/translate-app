import SwiftUI

enum ContinuousTalkPrimaryAction: Equatable {
    case start
    case pause
    case resume
    case retry
    case unavailable
}

struct ContinuousTalkPresentation {
    static func primaryAction(
        for state: ContinuousConversationState
    ) -> ContinuousTalkPrimaryAction {
        switch state {
        case .idle, .ended:
            .start
        case .listening, .catchingUp:
            .pause
        case .pausedByUser:
            .resume
        case .failed:
            .retry
        case .preparing, .pausing, .resuming, .pausedForPlayback, .ending:
            .unavailable
        }
    }

    static func isPrimaryActionEnabled(
        _ action: ContinuousTalkPrimaryAction,
        coreReady: Bool,
        languagePackOperationInProgress: Bool
    ) -> Bool {
        switch action {
        case .start, .retry:
            coreReady && !languagePackOperationInProgress
        case .pause, .resume:
            true
        case .unavailable:
            false
        }
    }

    static func canEndSession(in state: ContinuousConversationState) -> Bool {
        switch state {
        case .preparing, .listening, .catchingUp, .pausedForPlayback, .pausedByUser:
            true
        case .idle, .pausing, .resuming, .ending, .ended, .failed:
            false
        }
    }

    static func usesBottomDock(
        state: ContinuousConversationState,
        hasTurns: Bool
    ) -> Bool {
        if state.isRunning || hasTurns || state == .ended {
            return true
        }
        if case .failed = state {
            return true
        }
        return false
    }
}

struct ContinuousTranscriptPresentation {
    static func newestTurnID(in turns: [ConversationTurn]) -> UUID? {
        turns.max { first, second in
            first.sequence < second.sequence
        }?.id
    }

}

enum ContinuousTurnPlaybackPresentation: Equatable {
    case ready
    case playing
    case temporarilyUnavailable
    case safetyBlocked

    static func resolve(
        isActive: Bool,
        canReplay: Bool,
        isSafetyBlocked: Bool
    ) -> ContinuousTurnPlaybackPresentation {
        if isSafetyBlocked { return .safetyBlocked }
        if isActive { return .playing }
        return canReplay ? .ready : .temporarilyUnavailable
    }

    var systemImage: String {
        switch self {
        case .ready, .temporarilyUnavailable:
            "speaker.wave.2"
        case .playing:
            "speaker.wave.2.fill"
        case .safetyBlocked:
            "speaker.slash.fill"
        }
    }

    var isEnabled: Bool { self == .ready }
}

struct ContinuousConversationView: View {
    @ObservedObject var coordinator: ContinuousConversationCoordinator
    @ObservedObject var settings: SettingsStore
    @ObservedObject var subscription: SubscriptionManager
    @ObservedObject var network: NetworkStatus
    @ObservedObject var languagePacks: LanguagePackManager
    @ObservedObject var conversation: ConversationOrchestrator
    let capabilities: AppCapabilities

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var installationTask: Task<Void, Never>?
    @State private var showLanguagePicker = false
    @State private var languagePickerSide: SpeakerSide = .traveler
    @State private var showSafetyInformation = false
    @AccessibilityFocusState private var statusFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            languageHeader

            if usesScrollableSetupLayout {
                ScrollView {
                    setupNotice
                    emptyConversation
                        .frame(minHeight: 360)
                }
            } else {
                setupNotice

                if coordinator.turns.isEmpty {
                    emptyConversation
                } else {
                    transcript
                }
            }

            if usesBottomDock {
                controlDock
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("LocalLingo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(coordinator.isSessionActive ? .hidden : .visible, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                speakerPreferenceButton

                if !coordinator.isSessionActive {
                    overflowMenu
                }
            }
        }
        .sheet(isPresented: $showLanguagePicker) {
            languagePicker
        }
        .sheet(isPresented: $showSafetyInformation) {
            safetyInformation
        }
        .task {
            syncSpokenTranslationPreference()
            await languagePacks.check(settings.value.pair)
            await languagePacks.refreshAll()
        }
        .onAppear {
            coordinator.handleSceneActivity(isActive: scenePhase == .active)
            syncSpokenTranslationPreference()
        }
        .onChange(of: scenePhase) { _, phase in
            coordinator.handleSceneActivity(isActive: phase == .active)
        }
        .onChange(of: coordinator.state) { oldState, newState in
            guard shouldAnnounceStatusChange(from: oldState, to: newState) else {
                return
            }
            statusFocused = true
        }
        .onChange(of: settings.value.autoSpeak) { _, _ in
            syncSpokenTranslationPreference()
        }
        .onChange(of: voicesReady) { _, _ in
            syncSpokenTranslationPreference()
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: usesBottomDock)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: shouldShowReadinessPanel)
    }

    @ViewBuilder
    private var setupNotice: some View {
        if shouldShowReadinessPanel {
            readinessPanel
                .transition(.move(edge: .top).combined(with: .opacity))
        } else if shouldShowVoiceNotice {
            voiceNotice
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var languageHeader: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    openLanguagePicker(for: .traveler)
                } label: {
                    languageTile(
                        nativeName: settings.value.pair.traveler.nativeName,
                        displayName: settings.value.pair.traveler.displayName,
                        isInteractive: true
                    )
                }
                .buttonStyle(.plain)
                .disabled(pairControlsDisabled)
                .accessibilityLabel(
                    "First language, \(settings.value.pair.traveler.displayName)"
                )
                .accessibilityHint("Opens the language picker")
                .accessibilityIdentifier("talk.traveler-language")

                Button(action: swapLanguagePair) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(TranslatorTheme.accent)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(pairControlsDisabled)
                .accessibilityLabel("Swap conversation languages")
                .accessibilityIdentifier("talk.swap-languages")

                Button {
                    openLanguagePicker(for: .local)
                } label: {
                    languageTile(
                        nativeName: settings.value.pair.local.nativeName,
                        displayName: settings.value.pair.local.displayName,
                        isInteractive: true
                    )
                }
                .buttonStyle(.plain)
                .disabled(pairControlsDisabled)
                .accessibilityLabel(
                    "Second language, \(settings.value.pair.local.displayName)"
                )
                .accessibilityHint("Opens the language picker")
                .accessibilityIdentifier("talk.partner-language")
            }

            Label("On device", systemImage: "lock.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    "On device. Microphone, language detection, and translation stay on this iPhone."
                )
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Color(uiColor: .systemBackground))
    }

    private func languageTile(
        nativeName: String,
        displayName: String,
        isInteractive: Bool
    ) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Text(nativeName)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if isInteractive {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            if nativeName != displayName {
                Text(displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .contentShape(Rectangle())
    }

    private var emptyConversation: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 24)

            if !usesBottomDock {
                primaryMicrophoneButton(diameter: 112)
            } else {
                Image(systemName: emptyStateIcon)
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(TranslatorTheme.accent)
                    .accessibilityHidden(true)
            }

            VStack(spacing: 6) {
                Text(emptyStateTitle)
                    .font(.title3.weight(.semibold))
                Text(emptyStateMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)

            if let error = coordinator.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcript: some View {
        ContinuousTranscriptView(
            turns: coordinator.turns,
            draft: coordinator.draft,
            pair: settings.value.pair,
            allowsLanguageCorrection: coordinator.canRequestLanguageCorrection,
            reviewedPlaybackTurnID: coordinator.reviewedPlaybackTurnID,
            canReplayTranslation: coordinator.canReplayTranslation,
            onSwapLanguage: coordinator.swapLanguage,
            onReplayTranslation: coordinator.replayTranslation
        )
    }

    private var controlDock: some View {
        VStack(spacing: 8) {
            if let error = coordinator.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Text(coordinator.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityFocused($statusFocused)
                .accessibilityIdentifier("talk.session-status")

            ZStack {
                primaryMicrophoneButton(diameter: 76)

                HStack {
                    Spacer()
                    if showsEndButton {
                        Button(role: .destructive) {
                            coordinator.endSession()
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.body.weight(.semibold))
                                .frame(width: 44, height: 44)
                                .background(.red.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .disabled(!canEndSession)
                        .accessibilityLabel("End conversation")
                        .accessibilityIdentifier("talk.end")
                    }
                }
            }
            .frame(height: 78)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.bar)
    }

    private func primaryMicrophoneButton(diameter: CGFloat) -> some View {
        Button(action: performPrimaryAction) {
            Image(systemName: primaryActionIcon)
                .font(.system(size: diameter * 0.34, weight: .semibold))
                .frame(width: diameter, height: diameter)
                .foregroundStyle(TranslatorTheme.onAccent)
                .background(
                    primaryActionEnabled
                        ? TranslatorTheme.accent
                        : Color(uiColor: .systemGray4),
                    in: Circle()
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!primaryActionEnabled)
        .accessibilityLabel(primaryActionLabel)
        .accessibilityHint(primaryActionHint)
        .accessibilityIdentifier("talk.primary-microphone")
    }

    private var speakerPreferenceButton: some View {
        Button {
            settings.value.autoSpeak.toggle()
            syncSpokenTranslationPreference()
        } label: {
            Image(
                systemName: settings.value.autoSpeak
                    ? "speaker.wave.2.fill"
                    : "speaker.slash.fill"
            )
        }
        .accessibilityLabel(
            settings.value.autoSpeak
                ? "Turn off spoken translations"
                : "Turn on spoken translations"
        )
        .accessibilityValue(settings.value.autoSpeak ? "On" : "Off")
        .accessibilityIdentifier("talk.spoken-translations")
    }

    private var overflowMenu: some View {
        Menu {
            NavigationLink {
                ConversationView(
                    orchestrator: conversation,
                    settings: settings,
                    capabilities: capabilities
                )
            } label: {
                Label("Manual Conversation", systemImage: "mic.badge.plus")
            }
            .disabled(!canStartManualConversation)

            NavigationLink {
                LanguagePacksView(
                    manager: languagePacks,
                    settings: settings
                )
            } label: {
                Label("Manage Language Packs", systemImage: "square.stack.3d.up")
            }

            Button {
                showSafetyInformation = true
            } label: {
                Label("Privacy & Safety", systemImage: "hand.raised")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More options")
        .accessibilityIdentifier("talk.more")
    }

    private var readinessPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Offline setup", systemImage: "arrow.down.circle")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if languagePacks.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            ReadinessRow(
                title: "Listen: \(settings.value.pair.traveler.displayName)",
                value: selectedListenTravelerReadiness
            )
            ReadinessRow(
                title: "Listen: \(settings.value.pair.local.displayName)",
                value: selectedListenLocalReadiness
            )
            ReadinessRow(
                title: "Listen together",
                value: selectedListenPairReadiness
            )
            ReadinessRow(
                title: "Translate: \(settings.value.pair.traveler.displayName) and \(settings.value.pair.local.displayName)",
                value: combinedTranslationReadiness
            )

            if selectedListenPairReadiness == .unavailable {
                if manualConversationReady {
                    Label(
                        "Continuous listening is unavailable; Manual Conversation is ready.",
                        systemImage: "mic.badge.plus"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if manualVoiceSetupRequired {
                    Label(
                        "Continuous listening is unavailable; install Speak voices or turn off Auto Speak for Manual Conversation.",
                        systemImage: "speaker.badge.exclamationmark"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if isPreparingSelectedPair {
                if let message = languagePacks.progressMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let fraction = languagePacks.installationProgress {
                    HStack {
                        ProgressView(value: fraction)
                        Text(
                            fraction,
                            format: .percent.precision(.fractionLength(0))
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
                Button(role: .cancel) {
                    installationTask?.cancel()
                    installationTask = nil
                    languagePacks.cancelInstallation()
                } label: {
                    Label("Cancel download", systemImage: "xmark.circle")
                }
            } else if isOtherLanguagePackOperationInProgress {
                Label(
                    "Finishing another language-pack operation",
                    systemImage: "hourglass"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Button {
                    let pair = settings.value.pair
                    installationTask?.cancel()
                    installationTask = Task {
                        await languagePacks.install(pair)
                    }
                } label: {
                    Label(
                        readinessActionTitle,
                        systemImage: readinessActionIcon
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(TranslatorTheme.accent)
                .disabled(
                    !ContinuousModePolicy.supports(settings.value.pair)
                        || hasUnavailableManualComponent
                        || (selectedListenPairReadiness == .unavailable
                            && (manualConversationReady
                                || manualVoiceSetupRequired))
                )
            }

            if let error = selectedPairErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(TranslatorTheme.softAccent)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityIdentifier("talk.offline-setup")
    }

    private var voiceNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "speaker.badge.exclamationmark")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(spokenOutputNoticeTitle)
                    .font(.subheadline.weight(.semibold))
                Text(spokenOutputNoticeMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
        .accessibilityElement(children: .combine)
    }

    private var languagePicker: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(availablePickerLanguages) { language in
                        Button {
                            selectLanguage(language, for: languagePickerSide)
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(language.nativeName)
                                    if language.nativeName != language.displayName {
                                        Text(language.displayName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if selectedPickerLanguage == language {
                                    Image(systemName: "checkmark")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(TranslatorTheme.accent)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(
                            "talk.\(languagePickerSide.rawValue)-language.\(language.code)"
                        )
                    }
                }

                Section {
                    NavigationLink {
                        LanguagePacksView(
                            manager: languagePacks,
                            settings: settings
                        )
                    } label: {
                        Label(
                            "Manage Language Packs",
                            systemImage: "square.stack.3d.up"
                        )
                    }
                }
            }
            .navigationTitle(languagePickerTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        showLanguagePicker = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var safetyInformation: some View {
        NavigationStack {
            List {
                Section {
                    Label(
                        "Microphone, language detection, and translation stay on this iPhone.",
                        systemImage: "lock.fill"
                    )
                } header: {
                    Text("Private by design")
                }

                Section {
                    Label("Translations can be wrong", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(
                        "LocalLingo is not an emergency, medical, or professional-interpreter service. For urgent situations, contact local emergency services or a qualified interpreter."
                    )
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Important")
                }
            }
            .navigationTitle("Privacy & Safety")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showSafetyInformation = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var primaryAction: ContinuousTalkPrimaryAction {
        ContinuousTalkPresentation.primaryAction(for: coordinator.state)
    }

    private var primaryActionEnabled: Bool {
        !coordinator.isReviewedPlaybackActive
            && ContinuousTalkPresentation.isPrimaryActionEnabled(
            primaryAction,
            coreReady: coreReady,
            languagePackOperationInProgress: languagePacks.isWorking
        )
    }

    private var primaryActionIcon: String {
        switch primaryAction {
        case .pause:
            "pause.fill"
        case .resume:
            "play.fill"
        case .retry:
            "arrow.clockwise"
        case .start, .unavailable:
            "mic.fill"
        }
    }

    private var primaryActionLabel: String {
        switch primaryAction {
        case .start:
            "Start continuous conversation"
        case .pause:
            "Pause listening"
        case .resume:
            "Resume listening"
        case .retry:
            "Retry continuous conversation"
        case .unavailable:
            coordinator.statusText
        }
    }

    private var primaryActionHint: String {
        let languageNames = ContinuousModePolicy.languageNames(
            for: settings.value.pair
        )
        if !coreReady, primaryAction == .start || primaryAction == .retry {
            return "Download offline support for \(languageNames) first"
        }
        return switch primaryAction {
        case .start:
            "Starts listening for \(languageNames)"
        case .retry:
            "Restarts listening for \(languageNames) and keeps completed transcript turns"
        case .pause:
            "Finishes the current utterance, then pauses the microphone"
        case .resume:
            "Reopens the microphone"
        case .unavailable:
            ""
        }
    }

    private func performPrimaryAction() {
        switch primaryAction {
        case .start:
            syncSpokenTranslationPreference()
            coordinator.start(pair: settings.value.pair)
        case .pause:
            coordinator.pauseSession()
        case .resume:
            coordinator.resumeSession()
        case .retry:
            syncSpokenTranslationPreference()
            coordinator.retrySession(pair: settings.value.pair)
        case .unavailable:
            break
        }
    }

    private var usesBottomDock: Bool {
        ContinuousTalkPresentation.usesBottomDock(
            state: coordinator.state,
            hasTurns: !coordinator.turns.isEmpty
        )
    }

    private var usesScrollableSetupLayout: Bool {
        coordinator.turns.isEmpty
            && !usesBottomDock
            && (shouldShowReadinessPanel || shouldShowVoiceNotice)
    }

    private var showsEndButton: Bool {
        coordinator.isSessionActive
    }

    private var canEndSession: Bool {
        ContinuousTalkPresentation.canEndSession(in: coordinator.state)
    }

    private var emptyStateTitle: String {
        switch coordinator.state {
        case .idle:
            coreReady ? "Ready to translate" : "Offline setup required"
        case .preparing:
            "Preparing"
        case .pausing:
            "Finishing what you said"
        case .pausedByUser:
            "Listening paused"
        case .resuming:
            "Resuming"
        case .listening, .catchingUp:
            "Listening"
        case .pausedForPlayback:
            "Speaking translation"
        case .ending:
            "Finishing conversation"
        case .ended:
            "Conversation ended"
        case .failed:
            "Listening stopped"
        }
    }

    private var emptyStateMessage: String {
        switch coordinator.state {
        case .idle:
            coreReady
                ? "Tap the microphone and speak either language."
                : "Download the selected languages to start."
        case .pausedByUser:
            "Tap resume when you are ready to continue."
        case .ended:
            "Tap the microphone to start a new conversation."
        case .failed:
            "Tap retry to keep this transcript and reopen the microphone."
        default:
            coordinator.statusText
        }
    }

    private var emptyStateIcon: String {
        switch coordinator.state {
        case .failed:
            "exclamationmark.triangle"
        case .pausedByUser:
            "pause.circle"
        case .pausedForPlayback:
            "speaker.wave.2.fill"
        case .ending:
            "stop.circle"
        default:
            "waveform"
        }
    }

    private var shouldShowReadinessPanel: Bool {
        !coordinator.isSessionActive
            && (!coreReady
                || isPreparingSelectedPair
                || isOtherLanguagePackOperationInProgress
                || selectedPairErrorMessage != nil)
    }

    private var shouldShowVoiceNotice: Bool {
        coreReady
            && settings.value.autoSpeak
            && (!voicesReady || !coordinator.speakTranslations)
    }

    private var spokenOutputNoticeTitle: String {
        voicesReady ? "Spoken translations unavailable" : "Voice setup needed"
    }

    private var spokenOutputNoticeMessage: String {
        if voicesReady {
            return "Text translation will continue. Turn spoken translations off and on to retry audio."
        }
        return "Text translation is ready. Install missing voices in Settings > Accessibility > Read & Speak > Voices to hear translations."
    }

    private var coreReady: Bool {
        ContinuousModePolicy.isReady(
            pair: settings.value.pair,
            readiness: languagePacks.readiness
        )
    }

    private var voicesReady: Bool {
        languagePacks.readiness.pair == settings.value.pair
            && languagePacks.readiness.speakTraveler == .ready
            && languagePacks.readiness.speakLocal == .ready
    }

    private var combinedTranslationReadiness: ComponentReadiness {
        combine(
            selectedTranslateForwardReadiness,
            selectedTranslateReverseReadiness
        )
    }

    private var hasUnavailableManualComponent: Bool {
        selectedListenTravelerReadiness == .unavailable
            || selectedListenLocalReadiness == .unavailable
            || selectedTranslateForwardReadiness == .unavailable
            || selectedTranslateReverseReadiness == .unavailable
    }

    private var manualConversationReady: Bool {
        languagePacks.readiness.pair == settings.value.pair
            && languagePacks.readiness.isManualReady(
                requiringVoices: settings.value.autoSpeak
            )
    }

    private var manualVoiceSetupRequired: Bool {
        languagePacks.readiness.pair == settings.value.pair
            && settings.value.autoSpeak
            && languagePacks.readiness.isManualReady(requiringVoices: false)
            && !languagePacks.readiness.isManualReady(requiringVoices: true)
    }

    private var readinessActionTitle: String {
        if hasUnavailableManualComponent {
            return "Unavailable on this iPhone"
        }
        if selectedListenPairReadiness == .unavailable {
            if manualConversationReady { return "Manual Conversation Ready" }
            if manualVoiceSetupRequired {
                return "Install Speak Voices or Turn Off Auto Speak"
            }
            return "Download and Verify Manual Setup"
        }
        return languagePacks.errorMessage == nil
            ? "Download and Verify"
            : "Retry Download"
    }

    private var readinessActionIcon: String {
        if hasUnavailableManualComponent { return "xmark.circle.fill" }
        if selectedListenPairReadiness == .unavailable
            && manualConversationReady {
            return "checkmark.circle.fill"
        }
        if selectedListenPairReadiness == .unavailable
            && manualVoiceSetupRequired {
            return "speaker.badge.exclamationmark"
        }
        return "arrow.down.circle.fill"
    }

    private var selectedListenTravelerReadiness: ComponentReadiness {
        readinessForSelectedPair(\.listenTraveler)
    }

    private var selectedListenLocalReadiness: ComponentReadiness {
        readinessForSelectedPair(\.listenLocal)
    }

    private var selectedListenPairReadiness: ComponentReadiness {
        readinessForSelectedPair(\.listenPair)
    }

    private var selectedTranslateForwardReadiness: ComponentReadiness {
        readinessForSelectedPair(\.translateForward)
    }

    private var selectedTranslateReverseReadiness: ComponentReadiness {
        readinessForSelectedPair(\.translateReverse)
    }

    private var pairSupportsOnline: Bool {
        capabilities.onlineFeaturesEnabled
            && OnlineLanguagePolicy.supports(settings.value.pair)
    }

    private var canStartManualConversation: Bool {
        guard languagePacks.readiness.pair == settings.value.pair else {
            return false
        }
        if !pairSupportsOnline {
            return languagePacks.readiness.isManualReady(
                requiringVoices: settings.value.autoSpeak
            )
        }
        let manualVoicesReady = !settings.value.autoSpeak || voicesReady
        switch settings.value.routing {
        case .localOnly:
            return languagePacks.readiness.isManualReady(
                requiringVoices: settings.value.autoSpeak
            )
        case .onlineQuality:
            return manualVoicesReady
                && subscription.hasPro
                && network.isOnline
                && settings.value.hasCurrentOnlineProcessingConsent
        case .automatic:
            return languagePacks.readiness.isManualReady(
                requiringVoices: settings.value.autoSpeak
            )
        }
    }

    private var pairControlsDisabled: Bool {
        coordinator.isSessionActive || languagePacks.isWorking
    }

    private var isPreparingSelectedPair: Bool {
        languagePacks.isWorking
            && languagePacks.activeOperation == .pair(settings.value.pair)
    }

    private var isOtherLanguagePackOperationInProgress: Bool {
        languagePacks.isWorking && !isPreparingSelectedPair
    }

    private var selectedPairErrorMessage: String? {
        let pair = settings.value.pair
        let travelerError = languagePacks.state(for: pair.traveler).errorMessage
        let localError = languagePacks.state(for: pair.local).errorMessage
        guard let travelerError, travelerError == localError else { return nil }
        return travelerError
    }

    private var selectedPickerLanguage: AppLanguage {
        settings.value.pair.source(for: languagePickerSide)
    }

    private var availablePickerLanguages: [AppLanguage] {
        LocalConversationLanguagePolicy.availableLanguages(
            replacing: languagePickerSide,
            in: settings.value.pair
        )
    }

    private var languagePickerTitle: String {
        languagePickerSide == .traveler ? "First Language" : "Second Language"
    }

    private func openLanguagePicker(for side: SpeakerSide) {
        guard !pairControlsDisabled else { return }
        languagePickerSide = side
        showLanguagePicker = true
    }

    private func selectLanguage(
        _ language: AppLanguage,
        for side: SpeakerSide
    ) {
        showLanguagePicker = false
        guard let pair = settings.value.pair.replacing(side, with: language),
              LocalConversationLanguagePolicy.supports(pair) else {
            return
        }
        applyLanguagePair(pair)
    }

    private func swapLanguagePair() {
        applyLanguagePair(settings.value.pair.swapped)
    }

    private func applyLanguagePair(_ pair: LanguagePair) {
        guard !pairControlsDisabled,
              LocalConversationLanguagePolicy.supports(pair),
              pair != settings.value.pair else {
            return
        }
        installationTask?.cancel()
        installationTask = nil
        coordinator.cancelSession()

        var updatedSettings = settings.value
        updatedSettings.pair = pair
        updatedSettings.routing = OnlineLanguagePolicy.normalizedRouting(
            updatedSettings.routing,
            for: pair
        )
        settings.value = updatedSettings
        syncSpokenTranslationPreference()

        Task {
            await languagePacks.check(pair)
        }
    }

    private func readinessForSelectedPair(
        _ keyPath: KeyPath<TripReadiness, ComponentReadiness>
    ) -> ComponentReadiness {
        guard languagePacks.readiness.pair == settings.value.pair else {
            return .checking
        }
        return languagePacks.readiness[keyPath: keyPath]
    }

    private func syncSpokenTranslationPreference() {
        coordinator.speakTranslations = settings.value.autoSpeak && voicesReady
    }

    private func shouldAnnounceStatusChange(
        from oldState: ContinuousConversationState,
        to newState: ContinuousConversationState
    ) -> Bool {
        switch newState {
        case .listening:
            return oldState == .preparing
                || oldState == .resuming
                || oldState == .pausedForPlayback
        case .pausedByUser, .ended, .failed:
            return true
        case .idle, .preparing, .pausing, .resuming, .catchingUp,
             .pausedForPlayback, .ending:
            return false
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
        if first == .ready && second == .ready { return .ready }
        return .unknown
    }
}

private struct ContinuousTranscriptView: View {
    let turns: [ConversationTurn]
    let draft: ContinuousDraft?
    let pair: LanguagePair
    let allowsLanguageCorrection: Bool
    let reviewedPlaybackTurnID: UUID?
    let canReplayTranslation: (ConversationTurn) -> Bool
    let onSwapLanguage: (UUID) -> Void
    let onReplayTranslation: (UUID) -> Void

    @State private var isNearBottom = true
    private let bottomID = "continuous-transcript-bottom"

    var body: some View {
        let newestTurnID = ContinuousTranscriptPresentation.newestTurnID(in: turns)

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(turns) { turn in
                        ContinuousTurnRow(
                            turn: turn,
                            isNewest: newestTurnID == turn.id,
                            allowsLanguageCorrection: allowsLanguageCorrection,
                            isReviewedPlaybackActive: reviewedPlaybackTurnID == turn.id,
                            canReplayTranslation: canReplayTranslation(turn),
                            onSwapLanguage: {
                                onSwapLanguage(turn.id)
                            },
                            onReplayTranslation: {
                                onReplayTranslation(turn.id)
                            }
                        )
                    }

                    if let draft, !draft.text.isEmpty {
                        ContinuousDraftRow(draft: draft, pair: pair)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .padding(.horizontal, 16)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - 72
            } action: { _, newValue in
                isNearBottom = newValue
            }
            .onChange(of: turns.count) { _, _ in
                guard isNearBottom else { return }
                scrollToBottom(proxy)
            }
            .onChange(of: draft?.text) { _, _ in
                guard isNearBottom else { return }
                scrollToBottom(proxy)
            }
            .overlay(alignment: .bottomTrailing) {
                if !isNearBottom {
                    Button {
                        scrollToBottom(proxy)
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                    .accessibilityLabel("Jump to latest translation")
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }
}

struct ContinuousTurnRow: View {
    let turn: ConversationTurn
    let isNewest: Bool
    let allowsLanguageCorrection: Bool
    let isReviewedPlaybackActive: Bool
    let canReplayTranslation: Bool
    let onSwapLanguage: () -> Void
    let onReplayTranslation: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var alignsTrailing: Bool {
        turn.speaker == .local && !dynamicTypeSize.isAccessibilitySize
    }

    private var alignment: HorizontalAlignment {
        alignsTrailing ? .trailing : .leading
    }

    private var textAlignment: TextAlignment {
        alignsTrailing ? .trailing : .leading
    }

    private var frameAlignment: Alignment {
        alignsTrailing ? .trailing : .leading
    }

    private var latestAccentAlignment: Alignment {
        alignsTrailing ? .trailing : .leading
    }

    private var playbackPresentation: ContinuousTurnPlaybackPresentation {
        .resolve(
            isActive: isReviewedPlaybackActive,
            canReplay: canReplayTranslation,
            isSafetyBlocked: turn.warnings.contains(.entityMismatch)
        )
    }

    private var directionLabel: String {
        "\(languageName(turn.sourceLocale)) to \(languageName(turn.targetLocale))"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if alignsTrailing {
                Spacer(minLength: 36)
            }

            VStack(alignment: alignment, spacing: 7) {
                HStack(spacing: 6) {
                    if alignsTrailing { Spacer(minLength: 0) }
                    Text(directionLabel)
                        .font(.caption.weight(isNewest ? .bold : .semibold))
                        .foregroundStyle(isNewest ? TranslatorTheme.accent : Color.secondary)
                        .accessibilityLabel(
                            isNewest
                                ? "Latest translation, \(directionLabel)"
                                : directionLabel
                        )
                    if turn.languageReviewStatus == .needsReview {
                        Image(systemName: "questionmark.diamond.fill")
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Check detected language")
                    } else if turn.languageReviewStatus == .corrected {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(TranslatorTheme.success)
                            .accessibilityLabel("Detected language corrected")
                    }
                    if !alignsTrailing { Spacer(minLength: 0) }
                }

                translationAndPlayback

                Text(turn.sourceText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(textAlignment)
                    .textSelection(.enabled)

                if !turn.entities.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(Array(turn.entities.prefix(
                                ConversationContentPolicy.maximumRenderedSafetyEntities
                            ))) {
                                EntityChip(entity: $0)
                            }
                        }
                    }
                }

                if turn.warnings.contains(.entityMismatch) {
                    Label(
                        "Important details may not match",
                        systemImage: "exclamationmark.shield.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                if requiresHindiEntityReview {
                    Label(
                        "Review important details before playing this translation",
                        systemImage: "speaker.slash.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                if allowsLanguageCorrection,
                   turn.languageReviewStatus == .needsReview,
                   turn.alternateTranscript != nil {
                    Button(action: onSwapLanguage) {
                        Label(
                            "Swap detected language",
                            systemImage: "arrow.left.arrow.right"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: alignsTrailing ? .trailing : .leading)

            if turn.speaker == .traveler && !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 36)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 14)
        .background(isNewest ? TranslatorTheme.softAccent : Color.clear)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .overlay(alignment: latestAccentAlignment) {
            if isNewest {
                Rectangle()
                    .fill(TranslatorTheme.accent)
                    .frame(width: 3)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("talk.turn.\(turn.id.uuidString)")
    }

    @ViewBuilder
    private var translationAndPlayback: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: alignment, spacing: 4) {
                translatedText
                playbackButton
            }
            .frame(maxWidth: .infinity, alignment: frameAlignment)
        } else {
            HStack(alignment: .top, spacing: 8) {
                translatedText
                    .layoutPriority(1)
                playbackButton
            }
            .frame(maxWidth: .infinity, alignment: frameAlignment)
        }
    }

    private var translatedText: some View {
        Text(turn.translatedText)
            .font(isNewest ? .title2.weight(.semibold) : .body.weight(.semibold))
            .multilineTextAlignment(textAlignment)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var playbackButton: some View {
        Button(action: onReplayTranslation) {
            Image(systemName: playbackPresentation.systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(playbackTint)
                .frame(width: 44, height: 44)
                .background(
                    playbackPresentation == .playing
                        ? TranslatorTheme.softAccent
                        : Color.clear,
                    in: Circle()
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!playbackPresentation.isEnabled)
        .accessibilityLabel(playbackAccessibilityLabel)
        .accessibilityHint(playbackAccessibilityHint)
        .accessibilityIdentifier("talk.turn.\(turn.id.uuidString).play")
    }

    private var playbackTint: Color {
        switch playbackPresentation {
        case .ready, .playing:
            TranslatorTheme.accent
        case .temporarilyUnavailable:
            .secondary
        case .safetyBlocked:
            .orange
        }
    }

    private var playbackAccessibilityLabel: String {
        let target = languageName(turn.targetLocale)
        return switch playbackPresentation {
        case .ready, .temporarilyUnavailable:
            "Play \(target) translation"
        case .playing:
            "Playing \(target) translation"
        case .safetyBlocked:
            "Playback unavailable for \(target) translation"
        }
    }

    private var playbackAccessibilityHint: String {
        switch playbackPresentation {
        case .ready:
            "Temporarily pauses listening while the translation plays."
        case .playing:
            "Translation playback is in progress."
        case .temporarilyUnavailable:
            "Playback is temporarily unavailable."
        case .safetyBlocked:
            "Important details may not match."
        }
    }

    private var requiresHindiEntityReview: Bool {
        isHindiBetaTurn
            && !turn.entities.isEmpty
            && !turn.warnings.contains(.entityMismatch)
    }

    private var isHindiBetaTurn: Bool {
        turn.sourceLocale == AppLanguage.hindiIndia.code
            || turn.targetLocale == AppLanguage.hindiIndia.code
    }

    private func languageName(_ code: String) -> String {
        AppLanguage.allCases.first(where: { $0.code == code })?.displayName
            ?? Locale.current.localizedString(forIdentifier: code)
            ?? code
    }
}

private struct ContinuousDraftRow: View {
    let draft: ContinuousDraft
    let pair: LanguagePair
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var alignsTrailing: Bool {
        draft.language == pair.local && !dynamicTypeSize.isAccessibilitySize
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if alignsTrailing {
                Spacer(minLength: 36)
            }

            HStack(alignment: .top, spacing: 10) {
                ProgressView()
                    .tint(TranslatorTheme.accent)
                VStack(
                    alignment: alignsTrailing ? .trailing : .leading,
                    spacing: 4
                ) {
                    Text("\(draft.language.displayName) · Listening")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(TranslatorTheme.accent)
                    Text(draft.text)
                        .font(.body)
                        .multilineTextAlignment(alignsTrailing ? .trailing : .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: alignsTrailing ? .trailing : .leading)
            .padding(.vertical, 14)

            if draft.language == pair.traveler
                && !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 36)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live \(draft.language.displayName) transcript, \(draft.text)")
    }
}
