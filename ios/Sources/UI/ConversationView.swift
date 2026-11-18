import SwiftUI

struct ConversationView: View {
    @ObservedObject var orchestrator: ConversationOrchestrator
    @ObservedObject var settings: SettingsStore
    let capabilities: AppCapabilities
    @Environment(\.scenePhase) private var scenePhase
    @State private var typedText = ""
    @State private var typedSpeaker: SpeakerSide = .traveler
    @State private var showTypedInput = false
    @AccessibilityFocusState private var statusFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            routeBanner
            if turns.isEmpty { emptyState } else { transcript }
            if !orchestrator.partialTranscript.isEmpty { partial }
            controls
        }
        .navigationTitle("Manual conversation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if capabilities.faceToFaceEnabled {
                        Picker("Layout", selection: layoutBinding) {
                            ForEach(ConversationLayout.allCases) { Text($0.title).tag($0) }
                        }
                    }
                    Button("Type instead", systemImage: "keyboard") { showTypedInput = true }
                        .disabled(!orchestrator.state.acceptsMicrophoneTap)
                    Button("Replay last", systemImage: "speaker.wave.2") { orchestrator.replayLast() }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .overlay(alignment: .bottom) { if case .confirming = orchestrator.state { CarefulModeView(orchestrator: orchestrator) } }
        .sheet(isPresented: $showTypedInput) { typedInputSheet }
        .accessibilityIdentifier("manualConversation")
        .onAppear {
            orchestrator.handleSceneActivity(isActive: scenePhase == .active)
            orchestrator.configure()
        }
        .onDisappear { orchestrator.endSession() }
        .onChange(of: orchestrator.state) { _, _ in statusFocused = true }
        .onChange(of: scenePhase) { _, phase in
            orchestrator.handleSceneActivity(isActive: phase == .active)
            guard phase != .active else { return }
            typedText = ""
            showTypedInput = false
        }
        .tint(TranslatorTheme.accent)
    }

    private var layoutBinding: Binding<ConversationLayout> {
        Binding(get: { settings.value.layout }, set: { settings.value.layout = $0 })
    }
    private var turns: [ConversationTurn] { orchestrator.turns }

    private var routeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: orchestrator.activeRoute == .local ? "iphone" : "network")
                .foregroundStyle(
                    orchestrator.activeRoute == .local
                        ? TranslatorTheme.accent
                        : Color.orange
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(
                    orchestrator.activeRoute == .local
                        ? "LOCAL · ON DEVICE"
                        : "ONLINE · GOOGLE CLOUD"
                )
                .font(.caption.bold())
                Text(orchestrator.routeDisclosure)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 9)
        .background(Color(.secondarySystemBackground))
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        ContentUnavailableView("Ready to talk", systemImage: "person.2.wave.2", description: Text("Tap the microphone for the person who is speaking. One person at a time."))
            .frame(maxHeight: .infinity)
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(turns) { turn in
                    TranslationTurnRow(
                        turn: turn,
                        rotatesForListener: capabilities.faceToFaceEnabled
                            && settings.value.layout == .faceToFace
                            && turn.speaker == .traveler,
                        showsRoute: false,
                        allowsFullScreen: true
                    )
                    Divider()
                }
            }
            .padding(.horizontal)
        }
    }

    private var partial: some View {
        HStack(alignment: .top) { ProgressView(); Text(orchestrator.partialTranscript).fixedSize(horizontal: false, vertical: true); Spacer() }
            .padding(.horizontal).padding(.vertical, 8).background(.thinMaterial)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            if case let .failed(message, _) = orchestrator.state { Text(message).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center) }
            Text(stateLabel).font(.caption).foregroundStyle(.secondary).accessibilityFocused($statusFocused)
            HStack(spacing: 28) {
                MicrophoneButton(language: settings.value.pair.traveler, side: .traveler, state: orchestrator.state) { orchestrator.microphoneTapped(for: .traveler) }
                MicrophoneButton(language: settings.value.pair.local, side: .local, state: orchestrator.state) { orchestrator.microphoneTapped(for: .local) }
            }
            Button("Type or use a repair phrase", systemImage: "keyboard") { showTypedInput = true }
                .font(.caption)
                .disabled(!orchestrator.state.acceptsMicrophoneTap)
        }
        .padding()
        .background(.bar)
    }

    private var stateLabel: String {
        switch orchestrator.state {
        case .notReady: "Preparing"
        case let .ready(side): "Ready for \(settings.value.pair.source(for: side).displayName)"
        case .preparing: "Preparing speech and translation"
        case .listening: "Listening — tap again to finish"
        case .finalizing: "Finishing speech"
        case .reviewing: "Reviewing transcript"
        case .translating: "Translating"
        case .confirming: "Check important details"
        case .speaking: "Speaking translation"
        case .failed: "Tap a microphone to retry"
        }
    }

    private var typedInputSheet: some View {
        NavigationStack {
            Form {
                Picker("Speaker", selection: $typedSpeaker) {
                    Text(settings.value.pair.traveler.displayName).tag(SpeakerSide.traveler)
                    Text(settings.value.pair.local.displayName).tag(SpeakerSide.local)
                }.pickerStyle(.segmented)
                TextField("Type a phrase", text: typedTextBinding, axis: .vertical).lineLimit(3...8)
                Text("Up to \(TurnTextPolicy.maximumUTF8Bytes) UTF-8 bytes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if settings.value.pair.source(for: typedSpeaker) == .englishUS {
                    Section("Repair phrases") {
                        ForEach(repairPhrases, id: \.self) { phrase in
                            Button(phrase) { typedText = phrase }
                        }
                    }
                }
            }
            .navigationTitle("Typed fallback")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showTypedInput = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Translate") {
                        let text = typedText; typedText = ""; showTypedInput = false
                        orchestrator.submitTyped(text, speaker: typedSpeaker)
                    }.disabled(typedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.presentationDetents([.medium, .large])
    }

    private var typedTextBinding: Binding<String> {
        Binding(get: { typedText }, set: { typedText = TurnTextPolicy.clamped($0) })
    }

    private let repairPhrases = ["Could you repeat that more slowly?", "Please type the name or number.", "I may have heard that incorrectly.", "One person at a time, please."]
}

private struct MicrophoneButton: View {
    let language: AppLanguage
    let side: SpeakerSide
    let state: ConversationState
    let action: () -> Void
    private var isListening: Bool { if case let .listening(active) = state { active == side } else { false } }
    private var enabled: Bool { state.acceptsMicrophoneTap || isListening }
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: isListening ? "stop.fill" : "mic.fill")
                    .font(.title)
                    .frame(width: 64, height: 64)
                    .background(
                        isListening ? Color.red : TranslatorTheme.accent,
                        in: Circle()
                    )
                    .foregroundStyle(
                        isListening ? Color.white : TranslatorTheme.onAccent
                    )
                Text(language.nativeName).font(.caption.bold())
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityIdentifier("manualConversation.microphone.\(side.rawValue)")
        .accessibilityLabel(isListening ? "Stop recording \(language.displayName)" : "Record \(language.displayName) speaker")
        .accessibilityValue(isListening ? "Listening" : enabled ? "Ready" : "Unavailable while \(stateDescription)")
        .accessibilityHint(isListening ? "Stops recording and begins translation" : "Starts a turn for the \(language.displayName) speaker")
    }

    private var stateDescription: String {
        switch state {
        case .preparing: "preparing"
        case .finalizing: "finishing speech"
        case .reviewing: "reviewing"
        case .translating: "translating"
        case .confirming: "confirming details"
        default: "another action is running"
        }
    }
}

struct EntityChip: View {
    let entity: CriticalEntity

    var body: some View {
        Label(entity.value, systemImage: "exclamationmark.shield")
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Color.orange.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 6)
            )
    }
}
