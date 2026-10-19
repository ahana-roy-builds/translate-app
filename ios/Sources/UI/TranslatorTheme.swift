import SwiftUI
import UIKit

enum TranslatorTheme {
    static var accent: Color {
        adaptive(
            light: UIColor(red: 15 / 255, green: 118 / 255, blue: 110 / 255, alpha: 1),
            dark: UIColor(red: 94 / 255, green: 234 / 255, blue: 212 / 255, alpha: 1)
        )
    }

    static var onAccent: Color {
        adaptive(
            light: .white,
            dark: UIColor(red: 4 / 255, green: 47 / 255, blue: 46 / 255, alpha: 1)
        )
    }

    static var success: Color { accent }
    static var softAccent: Color { accent.opacity(0.12) }
    static let cornerRadius: CGFloat = 8

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
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
        case .downloadRequired: "Download"
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
