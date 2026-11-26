import SwiftUI
import UIKit

enum TranslatorTheme {
    static let accent = adaptive(0x3949AA, 0xAAB8FF)
    static let onAccent = adaptive(0xFFFFFF, 0x121B3D)
    static let canvas = adaptive(0xF0F1FB, 0x151A30)
    static let partnerPanel = adaptive(0xE4E8FB, 0x1D2441)
    static let card = adaptive(0xFFFFFF, 0x293154)
    static let ink = adaptive(0x1E2452, 0xF1F2FF)
    static let muted = adaptive(0x535D7C, 0xC1C7E3)
    static let edge = adaptive(0xC9CDE2, 0x444D72)
    static let ribbon = adaptive(0x2C346E, 0x10162C)
    static let signal = Color(red: 192 / 255, green: 202 / 255, blue: 1)
    static let success = adaptive(0x176448, 0x92DBC0)
    static var softAccent: Color { accent.opacity(0.12) }
    static let cornerRadius: CGFloat = 16

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        })
    }
}

extension View {
    func relayCard(fill: Color = TranslatorTheme.card, border: Color = TranslatorTheme.edge,
                   radius: CGFloat = TranslatorTheme.cornerRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(fill, in: shape)
            .overlay { shape.strokeBorder(border, lineWidth: 1).allowsHitTesting(false) }
    }
}

extension AppAppearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .automatic: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct SpeakDuetLogo: View {
    let height: CGFloat

    var body: some View {
        Image("SpeakDuetLogo")
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .frame(height: height)
            .accessibilityHidden(true)
    }
}

struct ReadinessRow: View {
    let title: String
    let value: ComponentReadiness

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(title)
                Spacer()
                status
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                status
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(label)")
    }

    private var status: some View {
        Label(label, systemImage: icon)
            .font(.caption)
            .foregroundStyle(color)
    }

    private var icon: String {
        switch value {
        case .ready: "checkmark.circle.fill"
        case .checking: "hourglass"
        case .downloading: "arrow.down.circle.fill"
        case .downloadRequired: "arrow.down.circle"
        case .unavailable: "xmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private var color: Color {
        switch value {
        case .ready: TranslatorTheme.success
        case .unavailable: .red
        default: .orange
        }
    }

    private var label: String {
        switch value {
        case .ready: "Ready"
        case .checking: "Checking"
        case .downloading: "Downloading"
        case .downloadRequired: "Download needed"
        case .unavailable: "Unavailable"
        case .unknown: "Unknown"
        }
    }
}

struct TranslationTurnRow: View {
    let turn: ConversationTurn
    var rotatesForListener = false
    var showsRoute = true
    var allowsFullScreen = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsFullScreenText = false

    private var alignsTrailing: Bool { turn.speaker == .local }
    private var frameAlignment: Alignment {
        alignsTrailing && !dynamicTypeSize.isAccessibilitySize ? .trailing : .leading
    }
    private var textAlignment: TextAlignment {
        alignsTrailing && !dynamicTypeSize.isAccessibilitySize ? .trailing : .leading
    }
    private var horizontalAlignment: HorizontalAlignment {
        alignsTrailing && !dynamicTypeSize.isAccessibilitySize ? .trailing : .leading
    }

    var body: some View {
        VStack(alignment: horizontalAlignment, spacing: 6) {
            HStack(spacing: 8) {
                if alignsTrailing && !dynamicTypeSize.isAccessibilitySize {
                    Spacer(minLength: 40)
                }
                Text(languageLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if !alignsTrailing || dynamicTypeSize.isAccessibilitySize {
                    Spacer(minLength: 8)
                }
                if allowsFullScreen {
                    Button {
                        showsFullScreenText = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show translation full screen")
                }
            }

            Text(turn.translatedText)
                .font(.body.weight(.semibold))
                .multilineTextAlignment(textAlignment)
                .frame(maxWidth: .infinity, alignment: frameAlignment)
                .textSelection(.enabled)

            Text(turn.sourceText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(textAlignment)
                .frame(maxWidth: .infinity, alignment: frameAlignment)
                .textSelection(.enabled)

            if !turn.entities.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(
                            Array(
                                turn.entities.prefix(
                                    ConversationContentPolicy.maximumRenderedSafetyEntities
                                )
                            )
                        ) { entity in
                            EntityChip(entity: entity)
                        }
                    }
                }
            }

            if showsRoute {
                Label(
                    turn.route == .local ? "On device" : "Online Quality",
                    systemImage: turn.route == .local ? "iphone" : "network"
                )
                .font(.caption2)
                .foregroundStyle(turn.route == .local ? TranslatorTheme.accent : .orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
        .padding(.leading, alignsTrailing && !dynamicTypeSize.isAccessibilitySize ? 40 : 0)
        .padding(.trailing, alignsTrailing || dynamicTypeSize.isAccessibilitySize ? 0 : 40)
        .padding(.vertical, 10)
        .rotationEffect(rotatesForListener ? .degrees(180) : .zero)
        .accessibilityElement(children: .contain)
        .fullScreenCover(isPresented: $showsFullScreenText) {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
                Text(turn.translatedText)
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.35)
                    .multilineTextAlignment(.center)
                    .padding(32)
            }
            .overlay(alignment: .topTrailing) {
                Button("Done") { showsFullScreenText = false }
                    .padding(24)
                    .buttonStyle(.borderedProminent)
            }
            .tint(TranslatorTheme.accent)
        }
    }

    private var languageLabel: String {
        "\(languageName(for: turn.sourceLocale)) to \(languageName(for: turn.targetLocale))"
    }

    private func languageName(for localeIdentifier: String) -> String {
        let normalized = localeIdentifier.replacingOccurrences(of: "_", with: "-")
        if let language = AppLanguage.allCases.first(where: {
            $0.code.caseInsensitiveCompare(normalized) == .orderedSame
        }) {
            return language.displayName
        }
        return Locale.current.localizedString(forIdentifier: localeIdentifier)
            ?? localeIdentifier
    }
}
