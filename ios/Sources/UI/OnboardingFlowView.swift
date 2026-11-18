import SwiftUI

struct OnboardingFlowView: View {
    @ObservedObject var onboarding: OnboardingStore
    @ObservedObject var settings: SettingsStore
    @ObservedObject var languagePacks: LanguagePackManager
    @ObservedObject var access: TranslationAccessManager
    let openManualConversation: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var installationTask: Task<Void, Never>?
    @State private var completionError: String?

    private var step: Int { onboarding.progress.step }
    private var selectedPair: LanguagePair? {
        guard let language = onboarding.progress.defaultLanguage,
              let partner = onboarding.progress.partnerLanguage else { return nil }
        return LanguagePair(traveler: language, local: partner)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ProgressView(value: Double(step + 1), total: 4)
                        .accessibilityLabel("Setup step \(step + 1) of 4")
                    switch step {
                    case 0:
                        HStack(spacing: 8) {
                            greeting("Hello", color: TranslatorTheme.softAccent, tail: .leading)
                            Image(systemName: "waveform").foregroundStyle(TranslatorTheme.accent)
                            greeting("Hola", color: Color(.secondarySystemBackground), tail: .trailing)
                                .offset(y: 8)
                        }
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .padding(.vertical, 12)
                        .accessibilityHidden(true)
                        Text("Speak two languages. Have one conversation")
                            .font(dynamicTypeSize.isAccessibilitySize ? .title.bold() : .largeTitle.bold())
                        Text("Tap the mic once and take turns speaking. Speak Duet translates when you pause.")
                        Text("Your conversation stays on this iPhone.").foregroundStyle(.secondary)
                        nextButton("Get started") { onboarding.progress.step = 1 }
                    case 1:
                        Text("What language do you speak?").font(.largeTitle.bold())
                        Text("This will be your default. You can change it anytime in Settings.").foregroundStyle(.secondary)
                        languageChoices(isDefault: true)
                        nextButton("Continue") { onboarding.progress.step = 2 }
                            .disabled(onboarding.progress.defaultLanguage == nil)
                    case 2:
                        Text("What language does the other person speak?").font(.largeTitle.bold())
                        Text("You chose \(onboarding.progress.defaultLanguage?.nativeName ?? ""). Choose the language you’ll hear back.").foregroundStyle(.secondary)
                        languageChoices(isDefault: false)
                        if let pair = selectedPair { pairLabel(pair) }
                        nextButton("Continue") {
                            if let selectedPair { settings.value.pair = selectedPair }
                            onboarding.progress.step = 3
                        }.disabled(selectedPair == nil)
                    default:
                        Text("Get ready to talk.").font(.largeTitle.bold())
                        if let pair = selectedPair {
                            pairLabel(pair)
                            setupControls(for: pair)
                        }
                        if let completionError { Text(completionError).font(.footnote).foregroundStyle(.red) }
                    }
                }
                .padding(24)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .id(step)
            .navigationTitle("Speak Duet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if step > 0 {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back") {
                            completionError = nil
                            onboarding.progress.step -= 1
                        }
                            .disabled(languagePacks.isWorking)
                    }
                }
            }
            .task(id: step) {
                if step == 3, let selectedPair { await languagePacks.check(selectedPair) }
            }
        }
        .tint(TranslatorTheme.accent)
        .onDisappear {
            installationTask?.cancel()
            if installationTask != nil, let pair = selectedPair,
               languagePacks.activeOperation == .pair(pair) {
                languagePacks.cancelInstallation()
            }
        }
    }

    private func greeting(_ text: String, color: Color, tail: HorizontalAlignment) -> some View {
        Text(text).font(.title3.bold()).fixedSize()
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(color, in: RoundedRectangle(cornerRadius: 16))
            .overlay(alignment: Alignment(horizontal: tail, vertical: .bottom)) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 0))
                    path.addLine(to: CGPoint(x: 14, y: 0))
                    path.addLine(to: CGPoint(x: tail == .leading ? 0 : 14, y: 10))
                    path.closeSubpath()
                }
                .fill(color)
                .frame(width: 14, height: 10)
                .padding(.horizontal, 12)
                .offset(y: 9)
            }
    }

    private func pairLabel(_ pair: LanguagePair) -> some View {
        Text("\(pair.traveler.nativeName) ↔ \(pair.local.nativeName)").font(.title3.bold())
    }

    @ViewBuilder
    private func setupControls(for pair: LanguagePair) -> some View {
        let status = languagePacks.readiness
        if languagePacks.isWorking {
            if let progress = languagePacks.installationProgress { ProgressView(value: progress) }
            else { ProgressView() }
            Text(languagePacks.progressMessage ?? "Preparing your languages…")
            Button("Cancel download") {
                installationTask?.cancel()
                languagePacks.cancelInstallation()
                installationTask = nil
            }
        } else if status.pair != pair || status.listenTraveler == .checking {
            ProgressView("Checking languages…")
        } else if status.isReady(requiringVoices: false) {
            nextButton("Start conversation") { finish(pair, manual: false) }
        } else if status.listenPair == .unavailable && status.isManualReady(requiringVoices: false) {
            Text("This iPhone supports manual turns for this pair. Tap a speaker’s mic to record, then tap again to translate.")
            let textOnly = settings.value.autoSpeak && !status.isManualReady(requiringVoices: true)
            if textOnly { Text("The voices for this pair are unavailable. Starting in text mode turns off Auto Speak in Settings.") }
            nextButton(textOnly ? "Start with Auto Speak off" : "Start manual conversation") { finish(pair, manual: true) }
        } else if [status.listenTraveler, status.listenLocal, status.translateForward, status.translateReverse].contains(.unavailable) {
            Text("This pair is unavailable on this iPhone. Go back and choose another language.")
        } else {
            Text("Download the languages you need to talk offline.").foregroundStyle(.secondary)
            nextButton(languagePacks.errorMessage == nil ? "Download and start" : "Retry download") {
                completionError = nil
                installationTask = Task {
                    guard !Task.isCancelled else { return }
                    await languagePacks.install(pair) { ready in
                        if ready.isReady(requiringVoices: false) { finish(pair, manual: false) }
                    }
                }
            }
            if let error = languagePacks.errorMessage { Text(error).foregroundStyle(.red) }
        }
    }

    private func finish(_ pair: LanguagePair, manual: Bool) {
        guard step == 3, pair == selectedPair, !onboarding.isComplete else { return }
        guard access.activateFreeAccess() else {
            completionError = access.state.message
            return
        }
        if onboarding.complete(settings: settings), manual {
            if !languagePacks.readiness.isManualReady(requiringVoices: true) {
                settings.value.autoSpeak = false
            }
            openManualConversation()
        }
    }

    private func nextButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .foregroundStyle(TranslatorTheme.onAccent)
            .controlSize(.large)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("onboarding.continue")
    }

    private func languageChoices(isDefault: Bool) -> some View {
        VStack(spacing: 8) {
            ForEach(AppLanguage.conversationLanguages.filter { language in
                isDefault || onboarding.progress.defaultLanguage.map {
                    LocalConversationLanguagePolicy.supports(LanguagePair(traveler: $0, local: language))
                } == true
            }) { language in
                let selected = (isDefault ? onboarding.progress.defaultLanguage : onboarding.progress.partnerLanguage) == language
                Button {
                    if isDefault {
                        onboarding.progress.defaultLanguage = language
                        onboarding.progress.partnerLanguage = nil
                    } else { onboarding.progress.partnerLanguage = language }
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(language.nativeName).font(.headline)
                            Text(language.displayName).font(.caption).foregroundStyle(.secondary)
                            if isDefault, isSuggested(language) {
                                Text("Suggested for this iPhone").font(.caption2).foregroundStyle(TranslatorTheme.accent)
                            }
                        }
                        Spacer()
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    }
                    .padding()
                    .background(selected ? TranslatorTheme.softAccent : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .accessibilityIdentifier("onboarding.language.\(language.code)")
            }
        }
    }

    private func isSuggested(_ language: AppLanguage) -> Bool {
        guard let preferred = Locale.preferredLanguages.first else { return false }
        return language.locale.language.languageCode == Locale(identifier: preferred).language.languageCode
    }
}
