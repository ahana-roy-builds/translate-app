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
        case .paused, .interrupted:
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
        case .preparing, .listening, .catchingUp, .pausedForPlayback, .paused:
            true
        case .idle, .pausing, .resuming, .ending, .ended, .interrupted, .failed:
            false
        }
    }

    static func usesBottomDock(
        state: ContinuousConversationState,
        hasTurns: Bool
    ) -> Bool {
        if state.isRunning || hasTurns || state == .ended || state == .interrupted {
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
    @State private var bottomSeat: SpeakerSide = .traveler
    @State private var languagePickerSide: SpeakerSide?
    @State private var showVoiceDetails = false
    @State private var showSafetyInformation = false
    @State private var recheckBeforeStarting = false
    @State private var confirmedSetupNeeded = false
    @AccessibilityFocusState private var statusFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if showsWaveLayout {
                faceToFaceConversation
            } else {
                languageHeader

                if coordinator.turns.isEmpty && !usesBottomDock && shouldShowVoiceNotice {
                    ScrollView {
                        setupNotice
                        emptyConversation
                            .frame(minHeight: 360)
                    }
                } else {
                    setupNotice

                    if coordinator.turns.isEmpty && visibleDraft == nil {
                        emptyConversation
                    } else {
                        transcript
                    }
                }

                if usesBottomDock {
                    controlDock
                }
            }
        }
        .background(TranslatorTheme.canvas)
        .navigationTitle("Speak Duet")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(coordinator.isRunning && !showsWaveLayout ? .hidden : .visible, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    settings.value.talkLayout = settings.value.talkLayout == .faceToFace ? .heldPhone : .faceToFace
                } label: {
                    Image(systemName: settings.value.talkLayout == .faceToFace ? "iphone" : "rectangle.split.2x1")
                }
                .accessibilityLabel(settings.value.talkLayout == .faceToFace ? "Switch to held phone" : "Switch to face to face")
                .accessibilityIdentifier("talk.switch-layout")
                speakerPreferenceButton

                if showsWaveLayout || !coordinator.isRunning {
                    overflowMenu
                        .disabled(coordinator.isReviewedPlaybackActive)
                }
            }
        }
        .sheet(item: $languagePickerSide) { side in
            languagePicker(for: side)
        }
        .sheet(isPresented: $showSafetyInformation) {
            safetyInformation
        }
        .task {
            syncSpokenTranslationPreference()
            guard scenePhase == .active else { return }
            await languagePacks.check(settings.value.pair)
        }
        .task(id: recheckBeforeStarting) {
            guard recheckBeforeStarting else { return }
            let pair = settings.value.pair
            let strategy = settings.value.continuousTranslationStrategy
            let action = primaryAction
            await languagePacks.check(pair)
            guard !Task.isCancelled, recheckBeforeStarting, scenePhase == .active,
                  settings.value.pair == pair, settings.value.continuousTranslationStrategy == strategy,
                  action == primaryAction else { return }
            recheckBeforeStarting = false
            confirmedSetupNeeded = !coreReady
            if coreReady && primaryActionEnabled { performReadyAction() }
        }
        .onDisappear {
            recheckBeforeStarting = false
            if showsWaveLayout && coordinator.isSessionActive {
                coordinator.handleSceneActivity(isActive: false)
            }
        }
        .onChange(of: settings.value.pair) { _, _ in
            bottomSeat = .traveler
            resetStartCheck()
        }
        .onChange(of: settings.value.continuousTranslationStrategy) { _, _ in resetStartCheck() }
        .environmentObject(coordinator)
        .onAppear {
            coordinator.handleSceneActivity(isActive: scenePhase == .active)
            syncSpokenTranslationPreference()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { resetStartCheck() }
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
    }

    private var showsWaveLayout: Bool {
        settings.value.talkLayout == .faceToFace
    }

    private var visibleDraft: ContinuousDraft? {
        coordinator.draft ?? coordinator.pendingDrafts.max(by: { $0.key < $1.key })?.value
    }

    private var faceToFaceConversation: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                languageHeader
                seat(bottomSeat.other)
                    .rotationEffect(.degrees(180))
            }
            .frame(maxHeight: .infinity)
            relayConversationControl
            seat(bottomSeat)
        }
        .onChange(of: coordinator.turns.last?.id) { _, id in
            if id != nil, UIAccessibility.isVoiceOverRunning, let turn = coordinator.turns.last {
                UIAccessibility.post(notification: .announcement, argument: turn.translatedText)
            }
        }
    }

    private var relayConversationControl: some View {
        VStack(spacing: 4) {
            ZStack {
                TalkWaveRibbon(phase: wavePhase)
                    .allowsHitTesting(false)
                primaryMicrophoneButton(diameter: 60)
                    .background(TranslatorTheme.softAccent, in: Circle().inset(by: -4))
            }
            Text(coordinator.state == .idle && canOfferStart && !recheckBeforeStarting
                 ? "Start conversation" : wavePhase.status ?? emptyStateTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(TranslatorTheme.ink)
                .accessibilityFocused($statusFocused)
                .accessibilityIdentifier("talk.session-status")
            if let error = coordinator.errorMessage {
                Text(error).foregroundStyle(.red).font(.caption)
            } else if needsLanguageSetup {
                languageSetupLink
            } else if shouldShowVoiceNotice {
                Button(spokenOutputNoticeTitle) { showVoiceDetails = true }
                    .font(.caption)
                    .popover(isPresented: $showVoiceDetails) {
                        Text(spokenOutputNoticeMessage).padding().presentationCompactAdaptation(.popover)
                    }
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private var wavePhase: TalkWavePhase {
        TalkWavePhase(state: coordinator.state, speaking: coordinator.hasActiveSpeech,
                      replaying: coordinator.isReviewedPlaybackActive)
    }

    private func seat(_ side: SpeakerSide) -> some View {
        let language = settings.value.pair.source(for: side)
        return TalkParticipantPanel(
            side: side, language: language, turns: coordinator.turns,
            pending: coordinator.pendingDrafts, live: coordinator.draft,
            allowsCorrection: coordinator.canRequestLanguageCorrection,
            playbackID: coordinator.reviewedPlaybackTurnID,
            canReplay: coordinator.canReplayTranslation,
            correct: coordinator.swapLanguage, replay: coordinator.replayTranslation
        )
        .id(side)
    }

    @ViewBuilder
    private var setupNotice: some View {
        if needsLanguageSetup {
            languageSetupLink
        } else if shouldShowVoiceNotice {
            voiceNotice
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var needsLanguageSetup: Bool {
        !coordinator.isSessionActive && !isCheckingInitialPair && !canOfferStart
    }

    private var languageSetupLink: some View {
        Group {
            if languagePacks.readiness.listenPair == .unavailable && canStartManualConversation {
                NavigationLink {
                    ConversationView(orchestrator: conversation, settings: settings, capabilities: capabilities)
                } label: {
                    Label("Use manual conversation", systemImage: "mic.badge.plus")
                }
            } else {
                NavigationLink {
                    LanguagePacksView(manager: languagePacks, settings: settings)
                } label: {
                    Label("Set up languages", systemImage: "arrow.down.circle")
                }
            }
        }
        .font(.subheadline)
        .accessibilityIdentifier("talk.language-setup")
    }

    private var languageHeader: some View {
        VStack(spacing: 10) {
            let first = showsWaveLayout ? bottomSeat : .traveler
            HStack(spacing: 4) {
                languagePickerButton(for: first, leading: true)
                Button(action: swapLanguagePair) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(TranslatorTheme.accent)
                        .frame(width: 32, height: 32)
                        .background(showsWaveLayout ? TranslatorTheme.softAccent : .clear, in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canFlipSeats && pairControlsDisabled)
                .accessibilityLabel("Swap conversation languages")
                .accessibilityIdentifier("talk.swap-languages")
                languagePickerButton(for: first.other, leading: false)
            }
            .padding(.horizontal, showsWaveLayout ? 10 : 0)
            .background {
                if showsWaveLayout {
                    RoundedRectangle(cornerRadius: 13).fill(TranslatorTheme.card)
                        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(TranslatorTheme.edge) }
                }
            }

            if !showsWaveLayout {
                Label("On device", systemImage: "lock.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        "On device. Microphone, language detection, and translation stay on this iPhone."
                    )
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, showsWaveLayout ? 6 : 12)
        .background(TranslatorTheme.canvas)
    }

    private func languagePickerButton(for side: SpeakerSide, leading: Bool) -> some View {
        let language = settings.value.pair.source(for: side)
        return Button {
            openLanguagePicker(for: side)
        } label: {
            if showsWaveLayout {
                HStack(spacing: 5) {
                    Text(language.nativeName).font(.headline).lineLimit(2)
                    Image(systemName: "chevron.down").font(.caption2.bold())
                }
                .foregroundStyle(TranslatorTheme.accent)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: leading ? .leading : .trailing)
                .contentShape(Rectangle())
            } else {
                languageTile(nativeName: language.nativeName, displayName: language.displayName, isInteractive: true)
            }
        }
        .buttonStyle(.plain)
        .disabled(pairControlsDisabled)
        .accessibilityLabel("\(leading ? "First" : "Second") language, \(language.displayName)")
        .accessibilityHint("Opens the language picker")
        .accessibilityIdentifier(leading ? "talk.traveler-language" : "talk.partner-language")
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
            draft: visibleDraft,
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
            Image(systemName: showsWaveLayout && primaryAction == .pause ? "mic.fill" : primaryActionIcon)
                .font(.system(size: diameter * 0.34, weight: .semibold))
                .frame(width: diameter, height: diameter)
                .foregroundStyle(TranslatorTheme.onAccent)
                .background(
                    primaryActionEnabled
                        ? TranslatorTheme.accent
                        : Color(uiColor: .systemGray4),
                    in: RoundedRectangle(cornerRadius: diameter * (showsWaveLayout ? 0.5 : 0.32))
                )
                .contentShape(Rectangle())
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
            if coordinator.isRunning {
                Button("End conversation", systemImage: "stop.fill", role: .destructive) {
                    coordinator.endSession()
                }
                .disabled(!canEndSession)
                .accessibilityIdentifier("talk.end")
            } else {
                Button {
                    settings.useDefaultLanguage()
                } label: {
                    Label("Use my default language", systemImage: "person.crop.circle")
                }
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
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More options")
        .accessibilityIdentifier("talk.more")
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

    private func languagePicker(for side: SpeakerSide) -> some View {
        let selected = settings.value.pair.source(for: side)
        let choices = LocalConversationLanguagePolicy.availableLanguages(replacing: side, in: settings.value.pair)
        return NavigationStack {
            List {
                Section {
                    ForEach(choices) { language in
                        Button {
                            selectLanguage(language, for: side)
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(language.nativeName).font(.headline)
                                    if language.nativeName != language.displayName {
                                        Text(language.displayName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if selected == language {
                                    Image(systemName: "checkmark.circle.fill")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(TranslatorTheme.accent)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected == language ? .isSelected : [])
                        .listRowBackground(selected == language ? TranslatorTheme.softAccent : TranslatorTheme.card)
                        .accessibilityIdentifier(
                            "talk.\(side.rawValue)-language.\(language.code)"
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
            .scrollContentBackground(.hidden)
            .background(TranslatorTheme.canvas)
            .navigationTitle(side == .traveler ? "First Language" : "Second Language")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        languagePickerSide = nil
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
                        "Speak Duet is not an emergency, medical, or professional-interpreter service. For urgent situations, contact local emergency services or a qualified interpreter."
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

    // A negative translation inventory at launch is provisional. Recheck on an
    // explicit start before sending someone with working speech assets to setup.
    private var canOfferStart: Bool {
        if coreReady { return true }
        let readiness = languagePacks.readiness
        return !confirmedSetupNeeded && readiness.pair == settings.value.pair
            && readiness.translationStrategy == settings.value.continuousTranslationStrategy
            && ContinuousModePolicy.supports(settings.value.pair)
            && readiness.listenTraveler == .ready && readiness.listenLocal == .ready && readiness.listenPair == .ready
    }

    private func resetStartCheck() {
        recheckBeforeStarting = false
        confirmedSetupNeeded = false
    }

    private var primaryActionEnabled: Bool {
        !recheckBeforeStarting && !coordinator.isReviewedPlaybackActive
            && (coordinator.state != .interrupted || (canOfferStart && !languagePacks.isWorking))
            && ContinuousTalkPresentation.isPrimaryActionEnabled(
            primaryAction,
            coreReady: canOfferStart,
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
        if !canOfferStart, primaryAction == .start || primaryAction == .retry || coordinator.state == .interrupted {
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
        if !coreReady, canOfferStart, primaryAction == .start || primaryAction == .retry || coordinator.state == .interrupted {
            recheckBeforeStarting = true
        } else {
            performReadyAction()
        }
    }

    private func performReadyAction() {
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

    private var showsEndButton: Bool {
        coordinator.isRunning
    }

    private var canEndSession: Bool {
        ContinuousTalkPresentation.canEndSession(in: coordinator.state)
    }

    private var emptyStateTitle: String {
        switch coordinator.state {
        case .idle:
            isCheckingInitialPair || recheckBeforeStarting ? "Checking languages…" : (canOfferStart ? "Ready to translate" : "Language setup needed")
        case .preparing:
            "Preparing"
        case .pausing:
            "Finishing what you said"
        case .paused, .interrupted:
            coordinator.statusText
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
            if isCheckingInitialPair || recheckBeforeStarting { return "Checking this language pair." }
            return canOfferStart
                ? "Tap the microphone and speak either language."
                : "Download the selected languages to start."
        case .paused:
            return "Tap resume when you are ready to continue."
        case .ended:
            return "Tap the microphone to start a new conversation."
        case .failed:
            return "Tap retry to keep this transcript and reopen the microphone."
        default:
            return coordinator.statusText
        }
    }

    private var emptyStateIcon: String {
        switch coordinator.state {
        case .failed:
            "exclamationmark.triangle"
        case .paused, .interrupted:
            "pause.circle"
        case .pausedForPlayback:
            "speaker.wave.2.fill"
        case .ending:
            "stop.circle"
        default:
            "waveform"
        }
    }

    private var isCheckingInitialPair: Bool {
        !languagePacks.isWorking && (languagePacks.readiness.pair != settings.value.pair
            || languagePacks.readiness.translationStrategy != settings.value.continuousTranslationStrategy
            || languagePacks.readiness.listenTraveler == .checking)
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
        languagePacks.readiness.translationStrategy == settings.value.continuousTranslationStrategy
            && ContinuousModePolicy.isReady(pair: settings.value.pair, readiness: languagePacks.readiness)
    }

    private var voicesReady: Bool {
        languagePacks.readiness.pair == settings.value.pair
            && languagePacks.readiness.speakTraveler == .ready
            && languagePacks.readiness.speakLocal == .ready
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
        coordinator.isSessionActive || languagePacks.isWorking || recheckBeforeStarting
    }

    private func openLanguagePicker(for side: SpeakerSide) {
        guard !pairControlsDisabled else { return }
        languagePickerSide = side
    }

    private func selectLanguage(
        _ language: AppLanguage,
        for side: SpeakerSide
    ) {
        languagePickerSide = nil
        guard language != settings.value.pair.source(for: side),
              let pair = settings.value.pair.replacing(side, with: language),
              LocalConversationLanguagePolicy.supports(pair) else {
            return
        }
        applyLanguagePair(showsWaveLayout && bottomSeat == .local ? pair.swapped : pair)
    }

    private var canFlipSeats: Bool {
        showsWaveLayout && (coordinator.isSessionActive || !coordinator.turns.isEmpty || coordinator.state == .interrupted)
    }

    private func swapLanguagePair() {
        if canFlipSeats {
            // Move readers and their history together while the audio session
            // keeps its original speaker identities and playback direction.
            bottomSeat = bottomSeat.other
        } else {
            applyLanguagePair(settings.value.pair.swapped)
        }
    }

    private func applyLanguagePair(_ pair: LanguagePair) {
        guard !pairControlsDisabled,
              LocalConversationLanguagePolicy.supports(pair),
              pair != settings.value.pair else {
            return
        }
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
        case .paused, .interrupted, .ended, .failed:
            return true
        case .idle, .preparing, .pausing, .resuming, .catchingUp,
             .pausedForPlayback, .ending:
            return false
        }
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

    private var directionLabel: String {
        if turn.warnings.contains(.unresolvedSpeaker) { return "Check detected language" }
        return "\(languageName(turn.sourceLocale)) to \(languageName(turn.targetLocale))"
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
                            isNewest && !turn.warnings.contains(.unresolvedSpeaker)
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

                if !turn.warnings.contains(.unresolvedSpeaker) { translationAndPlayback }

                Text(turn.sourceText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(textAlignment)
                    .textSelection(.enabled)

                TalkTurnReview(turn: turn, allowsLanguageCorrection: allowsLanguageCorrection, onSwapLanguage: onSwapLanguage)
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
        TalkReplayButton(turn: turn, isReviewedPlaybackActive: isReviewedPlaybackActive,
                         canReplayTranslation: canReplayTranslation, onReplayTranslation: onReplayTranslation)
    }
}

struct TalkTurnReview: View {
    let turn: ConversationTurn
    var readerLanguage: AppLanguage = .englishUS
    let allowsLanguageCorrection: Bool
    let onSwapLanguage: () -> Void

    @EnvironmentObject private var coordinator: ContinuousConversationCoordinator
    @State private var editingLanguage: AppLanguage?
    @State private var reviewedText = ""

    @ViewBuilder
    var body: some View {
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
                ParticipantLabels(readerLanguage).mismatch,
                systemImage: "exclamationmark.shield.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }

        if requiresHindiEntityReview {
            Label(
                ParticipantLabels(readerLanguage).reviewBeforePlaying,
                systemImage: "speaker.slash.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }

        if turn.warnings.contains(.unresolvedSpeaker) && coordinator.canResolveSpeaker {
            Text(ParticipantLabels(readerLanguage).chooseSpeaker).font(.caption.bold())
            let options = [turn.sourceLocale, turn.targetLocale].compactMap { code in
                AppLanguage.allCases.first { $0.code == code }
            }
            HStack {
                ForEach(options, id: \.code) { language in
                    Button(language.nativeName) {
                        reviewedText = language.code == turn.sourceLocale ? turn.sourceText : turn.alternateTranscript?.text ?? ""
                        editingLanguage = language
                    }
                }
            }
            .buttonStyle(.bordered)
            if let editingLanguage {
                TextField(editingLanguage.nativeName, text: $reviewedText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button {
                    if coordinator.confirmSpeaker(for: turn.id, language: editingLanguage, text: reviewedText) {
                        self.editingLanguage = nil
                    }
                } label: {
                    Label(ParticipantLabels(readerLanguage).translation, systemImage: "checkmark")
                }
                .disabled((try? TurnTextPolicy.validated(reviewedText)) == nil || !reviewedText.contains { $0.isLetter || $0.isNumber })
            }
        } else if allowsLanguageCorrection,
           turn.languageReviewStatus == .needsReview,
           turn.alternateTranscript != nil {
            Button(action: onSwapLanguage) {
                Label(
                    ParticipantLabels(readerLanguage).swapLanguage,
                    systemImage: "arrow.left.arrow.right"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
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

}

struct TalkReplayButton: View {
    let turn: ConversationTurn
    let isReviewedPlaybackActive: Bool
    let canReplayTranslation: Bool
    let onReplayTranslation: () -> Void

    private var playbackPresentation: ContinuousTurnPlaybackPresentation {
        .resolve(
            isActive: isReviewedPlaybackActive,
            canReplay: canReplayTranslation,
            isSafetyBlocked: turn.warnings.contains(.entityMismatch)
        )
    }

    var body: some View {
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
}

private func languageName(_ code: String) -> String {
    AppLanguage.allCases.first(where: { $0.code == code })?.displayName
        ?? Locale.current.localizedString(forIdentifier: code)
        ?? code
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
