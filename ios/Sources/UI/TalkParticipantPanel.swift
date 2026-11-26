import SwiftUI

/// One reader's view of the session. A turn has the same identity on both sides.
struct TalkParticipantPanel: View {
    let side: SpeakerSide
    let language: AppLanguage
    let turns: [ConversationTurn]
    let pending: [Int: ContinuousDraft]
    let live: ContinuousDraft?
    let allowsCorrection: Bool
    let playbackID: UUID?
    let canReplay: (ConversationTurn) -> Bool
    let correct: (UUID) -> Void
    let replay: (UUID) -> Void

    @State private var following = true
    @State private var userScrolling = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var words: ParticipantLabels { ParticipantLabels(language) }
    private var liveText: String? { live?.language == language ? live?.text : nil }
    private var pendingSequences: [Int] { pending.keys.filter { pending[$0]?.language == language }.sorted() }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7, pinnedViews: [.sectionHeaders]) {
                    Section {
                        if turns.isEmpty && pendingSequences.isEmpty && liveText == nil {
                            Text(words.placeholder)
                                .font(.title3).foregroundStyle(.secondary)
                        }
                        ForEach(turns) { turn in
                            committedRow(turn, current: turn.id == turns.last?.id && pendingSequences.isEmpty && liveText == nil)
                        }
                        ForEach(pendingSequences, id: \.self) { sequence in
                            if let draft = pending[sequence] {
                                draftCard(draft.text, current: sequence == pendingSequences.last && liveText == nil)
                            }
                        }
                        if let liveText {
                            draftCard(liveText, current: true)
                                .accessibilityIdentifier("talk.draft.\(side.rawValue)")
                        }
                        Color.clear.frame(height: 1).id("latest")
                    } header: {
                        Text(language.nativeName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(TranslatorTheme.ink)
                            .padding(.vertical, 5)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("talk.seat-language.\(side.rawValue)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(TranslatorTheme.canvas)
                    }
                }
                .padding(.vertical, 4)
            }
            .defaultScrollAnchor(.center, for: .alignment)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: turns.last?.id)
            .onScrollPhaseChange { _, newPhase, context in
                if newPhase == .interacting {
                    userScrolling = true
                    following = false
                }
                if newPhase == .idle && userScrolling {
                    userScrolling = false
                    let geometry = context.geometry
                    following = geometry.visibleRect.maxY >= geometry.contentSize.height - 32
                }
            }
            .onAppear { proxy.scrollTo("latest", anchor: .bottom) }
            .onChange(of: turns.last) { _, _ in if following { proxy.scrollTo("latest", anchor: .bottom) } }
            .onChange(of: liveText) { _, _ in if following { proxy.scrollTo("latest", anchor: .bottom) } }
            .onChange(of: pendingSequences) { _, _ in if following { proxy.scrollTo("latest", anchor: .bottom) } }
            .overlay(alignment: .bottomTrailing) {
                if !following && !userScrolling {
                    Button {
                        following = true
                        proxy.scrollTo("latest", anchor: .bottom)
                    } label: {
                        Image(systemName: "arrow.down").frame(width: 44, height: 44)
                            .foregroundStyle(TranslatorTheme.onAccent)
                            .background(TranslatorTheme.accent, in: Circle())
                    }
                    .accessibilityLabel("Jump to latest")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TranslatorTheme.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("talk.seat.\(side.rawValue)")
    }

    private func draftCard(_ text: String, current: Bool) -> some View {
        phrase(text, caption: words.original, prominent: current)
            .modifier(TurnCard(current: current))
    }

    private func phrase(_ text: String, caption: String, prominent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption)
                .font(.caption2.weight(.bold))
                .foregroundStyle(prominent ? TranslatorTheme.accent : TranslatorTheme.muted)
                .padding(.horizontal, prominent ? 6 : 0).padding(.vertical, prominent ? 3 : 0)
                .background(prominent ? TranslatorTheme.softAccent : .clear, in: RoundedRectangle(cornerRadius: 5))
            Text(verbatim: text)
                .font(prominent ? .title.weight(.bold) : .body)
                .foregroundStyle(TranslatorTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .environment(\.locale, language.locale)
    }

    private func committedRow(_ turn: ConversationTurn, current: Bool) -> some View {
        let own = turn.speaker == side
        let unresolved = turn.warnings.contains(.unresolvedSpeaker)
        let caption = unresolved ? words.checkLanguage : (own ? words.original : words.translation)
        return VStack(alignment: .leading, spacing: 5) {
            let layout = current ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                                 : AnyLayout(HStackLayout(alignment: .center, spacing: 6))
            layout {
                phrase(own || unresolved ? turn.sourceText : turn.translatedText,
                       caption: caption, prominent: current)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !own && !unresolved {
                    TalkReplayButton(turn: turn, isReviewedPlaybackActive: playbackID == turn.id,
                                     canReplayTranslation: canReplay(turn), onReplayTranslation: { replay(turn.id) })
                }
            }
            if turn.languageReviewStatus == .needsReview && !unresolved {
                Label(words.checkLanguage, systemImage: "questionmark.diamond")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TalkTurnReview(turn: turn, readerLanguage: language, allowsLanguageCorrection: allowsCorrection, onSwapLanguage: { correct(turn.id) })
        }
        .modifier(TurnCard(current: current))
    }
}

private struct TurnCard: ViewModifier {
    let current: Bool

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, current ? 15 : 11)
            .padding(.vertical, current ? 12 : 7)
            .relayCard(fill: current ? TranslatorTheme.card : .clear, radius: current ? 18 : 12)
    }
}

struct ParticipantLabels {
    let chooseSpeaker: String
    let original: String
    let translation: String
    let placeholder: String
    let checkLanguage: String
    let swapLanguage: String
    let mismatch: String
    let reviewBeforePlaying: String

    init(_ language: AppLanguage) {
        chooseSpeaker = switch language {
        case .englishUS: "Which language was spoken?"
        case .spanishSpain: "¿En qué idioma se habló?"
        case .frenchFrance: "Quelle langue a été parlée ?"
        case .germanGermany: "Welche Sprache wurde gesprochen?"
        case .italianItaly: "In quale lingua si è parlato?"
        case .portugueseBrazil: "Qual idioma foi falado?"
        case .japaneseJapan: "どちらの言語で話しましたか？"
        case .koreanSouthKorea: "어떤 언어로 말했나요?"
        case .hindiIndia: "किस भाषा में कहा गया था?"
        }
        (original, translation, placeholder) = switch language {
        case .englishUS: ("You said", "Translation", "Your conversation appears here.")
        case .spanishSpain: ("Dijiste", "Traducción", "Tu conversación aparecerá aquí.")
        case .frenchFrance: ("Vous avez dit", "Traduction", "Votre conversation apparaîtra ici.")
        case .germanGermany: ("Sie sagten", "Übersetzung", "Ihr Gespräch erscheint hier.")
        case .italianItaly: ("Hai detto", "Traduzione", "La conversazione apparirà qui.")
        case .portugueseBrazil: ("Você disse", "Tradução", "Sua conversa aparecerá aqui.")
        case .japaneseJapan: ("あなたの発言", "翻訳", "ここに会話が表示されます。")
        case .koreanSouthKorea: ("내가 한 말", "번역", "여기에 대화가 표시됩니다.")
        case .hindiIndia: ("आपने कहा", "अनुवाद", "आपकी बातचीत यहाँ दिखाई देगी।")
        }
        (checkLanguage, swapLanguage, mismatch, reviewBeforePlaying) = switch language {
        case .englishUS: ("Check detected language", "Swap detected language", "Important details may not match", "Review important details before playing this translation")
        case .spanishSpain: ("Revisa el idioma detectado", "Cambiar el idioma detectado", "Puede que algunos datos importantes no coincidan", "Revisa los datos importantes antes de reproducir la traducción")
        case .frenchFrance: ("Vérifiez la langue détectée", "Changer la langue détectée", "Certains détails importants peuvent différer", "Vérifiez les détails importants avant d’écouter la traduction")
        case .germanGermany: ("Erkannte Sprache prüfen", "Erkannte Sprache wechseln", "Wichtige Angaben können abweichen", "Prüfen Sie wichtige Angaben vor dem Abspielen der Übersetzung")
        case .italianItaly: ("Controlla la lingua rilevata", "Cambia la lingua rilevata", "Alcuni dettagli importanti potrebbero non corrispondere", "Controlla i dettagli importanti prima di ascoltare la traduzione")
        case .portugueseBrazil: ("Confira o idioma detectado", "Trocar o idioma detectado", "Alguns detalhes importantes podem estar diferentes", "Confira os detalhes importantes antes de ouvir a tradução")
        case .japaneseJapan: ("認識された言語を確認", "認識された言語を切り替える", "重要な情報が一致しない可能性があります", "翻訳を再生する前に重要な情報を確認してください")
        case .koreanSouthKorea: ("감지된 언어 확인", "감지된 언어 변경", "중요한 정보가 일치하지 않을 수 있습니다", "번역을 재생하기 전에 중요한 정보를 확인하세요")
        case .hindiIndia: ("पहचानी गई भाषा जाँचें", "पहचानी गई भाषा बदलें", "ज़रूरी जानकारी अलग हो सकती है", "अनुवाद सुनने से पहले ज़रूरी जानकारी जाँचें")
        }
    }
}

enum TalkWavePhase: Equatable {
    case quiet, speaking, resolving, playback

    init(state: ContinuousConversationState, speaking: Bool, replaying: Bool) {
        if replaying || state == .pausedForPlayback { self = .playback; return }
        switch state {
        case .catchingUp: self = speaking ? .speaking : .resolving
        case .listening: self = speaking ? .speaking : .quiet
        default: self = .quiet
        }
    }

    var status: String? {
        switch self {
        case .quiet: nil
        case .speaking: "Hearing speech"
        case .resolving: "Translating"
        case .playback: "Playing translation"
        }
    }
}

struct TalkWaveRibbon: View {
    let phase: TalkWavePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24,
                                paused: reduceMotion || phase == .quiet || phase == .playback)) { timeline in
            Canvas { context, size in
                let t = (reduceMotion || phase == .quiet || phase == .playback) ? 0 : timeline.date.timeIntervalSinceReferenceDate
                let spacing: CGFloat = 6
                let halfWidth = size.width / 2
                let steps = Int(halfWidth / spacing)
                guard steps > 0 else { return }
                let amplitude: CGFloat = switch phase {
                case .quiet: 11
                case .resolving: 15
                case .speaking: 27
                case .playback: 18
                }
                for i in -steps...steps {
                    let offset = CGFloat(i) * spacing
                    let envelope = max(0, 1 - abs(offset) / halfWidth)
                    let wave = 0.3 + 0.7 * abs(sin(abs(offset) * 0.045 + t * (phase == .speaking ? 6 : 3)))
                    let height = 2.5 + amplitude * envelope * wave
                    let rect = CGRect(x: halfWidth + offset - 1.5, y: (size.height - height) / 2, width: 3, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                                 with: .color(TranslatorTheme.accent.opacity(0.78)))
                }
            }
        }
        .frame(height: 32)
        .accessibilityHidden(true)
    }
}
