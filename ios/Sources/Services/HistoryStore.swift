import Combine
import Foundation

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var conversations: [ConversationRecord] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = false
    @Published var errorMessage: String?

    private let local: LocalHistoryStore
    private var nextOffset = 0
    private var deletedConversationIDs = Set<UUID>()
    private var deleteAllCutoff: Date?

    init(local: LocalHistoryStore = LocalHistoryStore()) {
        self.local = local
        errorMessage = local.persistenceError
    }

    func load(enabled: Bool) async {
        guard enabled else {
            conversations = []
            nextOffset = 0
            hasMore = false
            errorMessage = local.persistenceError
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try local.loadPage(enabled: true, offset: 0)
            conversations = page.records
            nextOffset = page.nextOffset
            hasMore = page.hasMore
            errorMessage = local.persistenceError
        } catch {
            conversations = []
            nextOffset = 0
            hasMore = false
            errorMessage = error.localizedDescription
        }
    }

    func loadMore(enabled: Bool) async {
        guard enabled, hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try local.loadPage(enabled: true, offset: nextOffset)
            conversations.append(contentsOf: page.records)
            nextOffset = page.nextOffset
            hasMore = page.hasMore
            errorMessage = local.persistenceError
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// SwiftData writes are main-actor synchronous. Keeping this API
    /// synchronous avoids creating an unnecessary reentrancy point halfway
    /// through a turn commit.
    func saveOnDevice(_ conversation: ConversationRecord, enabled: Bool) {
        guard enabled,
              !deletedConversationIDs.contains(conversation.id),
              deleteAllCutoff.map({ conversation.createdAt > $0 }) ?? true else { return }
        do {
            try local.save(conversation, enabled: true)
            let page = try local.loadPage(enabled: true, offset: 0)
            conversations = page.records
            nextOffset = page.nextOffset
            hasMore = page.hasMore
            errorMessage = local.persistenceError
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ conversation: ConversationRecord) async {
        deletedConversationIDs.insert(conversation.id)
        do {
            try local.delete(id: conversation.id)
            await load(enabled: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteAll() async {
        deleteAllCutoff = Date()
        do {
            try local.deleteAll()
            conversations = []
            nextOffset = 0
            hasMore = false
            errorMessage = local.persistenceError
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportText(_ conversation: ConversationRecord) -> String {
        conversation.turns.map { turn in
            let label = turn.speaker == .traveler ? "Traveler" : "Local"
            let review = turn.languageReviewStatus == .needsReview ? " [Needs Review]" : ""
            return "\(label) [\(turn.sourceLocale)]\(review): \(turn.sourceText)\nTranslation [\(turn.targetLocale)]: \(turn.translatedText)"
        }.joined(separator: "\n\n")
    }
}
