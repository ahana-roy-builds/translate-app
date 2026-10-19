import SwiftUI

struct HistoryView: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Group {
            if !settings.value.saveHistoryOnDevice {
                ContentUnavailableView(
                    "History is off",
                    systemImage: "clock.badge.xmark",
                    description: Text(
                        "Turn on on-device history in Settings. Text stays on this iPhone, and audio is never saved."
                    )
                )
            } else if store.isLoading && store.conversations.isEmpty {
                ProgressView("Loading private history...")
            } else if let error = store.errorMessage, store.conversations.isEmpty {
                ContentUnavailableView {
                    Label(
                        "History unavailable",
                        systemImage: "exclamationmark.triangle"
                    )
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") {
                        Task {
                            await store.load(
                                enabled: settings.value.saveHistoryOnDevice
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("history.retry")
                }
            } else if store.conversations.isEmpty {
                ContentUnavailableView(
                    "No saved conversations",
                    systemImage: "clock",
                    description: Text("Text-only sessions you finish will appear here.")
                )
            } else {
                historyList
            }
        }
        .navigationTitle("History")
        .task { await store.load(enabled: settings.value.saveHistoryOnDevice) }
        .tint(TranslatorTheme.accent)
    }

    private var historyList: some View {
        List {
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            ForEach(store.conversations) { conversation in
                NavigationLink {
                    HistoryDetailView(
                        conversation: conversation,
                        store: store
                    )
                } label: {
                    HistoryRow(conversation: conversation)
                }
                .swipeActions {
                    Button("Delete", role: .destructive) {
                        Task { await store.delete(conversation) }
                    }
                }
            }

            if store.hasMore {
                Button {
                    Task {
                        await store.loadMore(
                            enabled: settings.value.saveHistoryOnDevice
                        )
                    }
                } label: {
                    if store.isLoading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Load more").frame(maxWidth: .infinity)
                    }
                }
                .disabled(store.isLoading)
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("history.list")
        .refreshable {
            await store.load(enabled: settings.value.saveHistoryOnDevice)
        }
    }
}

private struct HistoryRow: View {
    let conversation: ConversationRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(conversation.title)
                .font(.headline)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    updatedLabel
                    turnCountLabel
                }
                VStack(alignment: .leading, spacing: 4) {
                    updatedLabel
                    turnCountLabel
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("history.row.\(conversation.id.uuidString)")
    }

    private var updatedLabel: some View {
        Label {
            Text(conversation.updatedAt, style: .relative)
        } icon: {
            Image(systemName: "clock")
        }
    }

    private var turnCountLabel: some View {
        Label(
            "\(conversation.turns.count) \(conversation.turns.count == 1 ? "turn" : "turns")",
            systemImage: "text.bubble"
        )
    }
}

private struct HistoryDetailView: View {
    let conversation: ConversationRecord
    let store: HistoryStore

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(conversation.turns) { turn in
                    TranslationTurnRow(turn: turn)
                    Divider()
                }
            }
            .padding(.horizontal)
        }
        .background(Color(.systemBackground))
        .accessibilityIdentifier("history.detail")
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: store.exportText(conversation)) {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Share conversation")
            .accessibilityIdentifier("history.share")
        }
        .tint(TranslatorTheme.accent)
    }
}
