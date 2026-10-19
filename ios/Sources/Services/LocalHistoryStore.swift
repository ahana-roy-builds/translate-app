import Foundation
import SwiftData

@Model
final class LocalConversationSnapshot {
    @Attribute(.unique) var id: UUID
    var updatedAt: Date
    var payloadByteCount: Int = 0
    var turnCount: Int = 0
    @Attribute(.externalStorage) var payload: Data

    init(id: UUID, updatedAt: Date, payloadByteCount: Int, turnCount: Int, payload: Data) {
        self.id = id
        self.updatedAt = updatedAt
        self.payloadByteCount = payloadByteCount
        self.turnCount = turnCount
        self.payload = payload
    }
}

struct LocalHistoryPage: Equatable {
    let records: [ConversationRecord]
    let nextOffset: Int
    let hasMore: Bool
}

enum LocalHistoryPolicy {
    static let pageSize = 25
    static let maximumConversations = 500
    static let maximumSnapshotBytes = 8 * 1_024 * 1_024
    static let maximumAggregateBytes = 16 * 1_024 * 1_024
    static let maximumTitleBytes = 512

    static func validate(_ conversation: ConversationRecord) throws {
        let nowLimit = Date().addingTimeInterval(86_400)
        guard conversation.createdAt.timeIntervalSinceReferenceDate.isFinite,
              conversation.updatedAt.timeIntervalSinceReferenceDate.isFinite,
              conversation.createdAt <= conversation.updatedAt,
              conversation.updatedAt <= nowLimit,
              supportedLocales.contains(conversation.languageA),
              supportedLocales.contains(conversation.languageB),
              conversation.languageA != conversation.languageB,
              !conversation.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              conversation.title.utf8.count <= maximumTitleBytes,
              !conversation.turns.isEmpty,
              conversation.turns.count <= ConversationContentPolicy.maximumTurns else {
            throw LocalHistoryError.invalidRecord
        }

        var turnIDs = Set<UUID>()
        var sequences = Set<Int>()
        var lastSequence = -1
        for turn in conversation.turns {
            let entityIDs = Set(turn.entities.map(\.id))
            guard turnIDs.insert(turn.id).inserted,
                  sequences.insert(turn.sequence).inserted,
                  turn.sequence >= 0,
                  turn.sequence < ConversationContentPolicy.maximumTurns,
                  turn.sequence > lastSequence,
                  supportedLocales.contains(turn.sourceLocale),
                  supportedLocales.contains(turn.targetLocale),
                  turn.sourceLocale != turn.targetLocale,
                  Set([turn.sourceLocale, turn.targetLocale]) == Set([conversation.languageA, conversation.languageB]),
                  !turn.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !turn.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  turn.sourceText.utf8.count <= ConversationContentPolicy.maximumFinalTextUTF8Bytes,
                  turn.translatedText.utf8.count <= ConversationContentPolicy.maximumFinalTextUTF8Bytes,
                  turn.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  turn.createdAt >= conversation.createdAt,
                  turn.createdAt <= conversation.updatedAt,
                  turn.createdAt <= nowLimit,
                  turn.entities.count <= ConversationContentPolicy.maximumSafetyEntities,
                  entityIDs.count == turn.entities.count,
                  turn.entities.allSatisfy({ entity in
                      !entity.value.isEmpty
                          && entity.value.utf8.count <= ConversationContentPolicy.maximumFinalTextUTF8Bytes
                          && !entity.normalizedValue.isEmpty
                          && entity.normalizedValue.utf8.count <= ConversationContentPolicy.maximumFinalTextUTF8Bytes
                  }),
                  turn.recognitionConfidence.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
                  turn.alternateTranscript.map({ alternate in
                      alternate.locale == turn.targetLocale
                          && !alternate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && alternate.text.utf8.count <= ConversationContentPolicy.maximumFinalTextUTF8Bytes
                          && (alternate.recognitionConfidence.map({
                              $0.isFinite && (0...1).contains($0)
                          }) ?? true)
                  }) ?? true else {
                throw LocalHistoryError.invalidRecord
            }
            lastSequence = turn.sequence
        }
    }

    private static let supportedLocales = Set(AppLanguage.allCases.map(\.code))
}

enum LocalHistoryError: LocalizedError, Equatable {
    case invalidRecord
    case snapshotTooLarge
    case capacityExceeded
    case corruptSnapshot

    var errorDescription: String? {
        switch self {
        case .invalidRecord: "A history record contained invalid or unsupported values."
        case .snapshotTooLarge: "This conversation is too large to save safely. Start a new conversation."
        case .capacityExceeded: "On-device history is full. Delete older conversations before saving more."
        case .corruptSnapshot: "A saved conversation is damaged and could not be opened safely."
        }
    }
}

@MainActor
final class LocalHistoryStore {
    private let container: ModelContainer
    private let context: ModelContext
    private(set) var persistenceError: String?
    private(set) var storageDirectoryURL: URL?

    init(inMemory: Bool = false) {
        let resolvedContainer: ModelContainer
        do {
            if inMemory {
                storageDirectoryURL = nil
                let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
                resolvedContainer = try ModelContainer(for: LocalConversationSnapshot.self, configurations: configuration)
            } else {
                let directory = try Self.prepareProtectedDirectory()
                storageDirectoryURL = directory
                let schema = Schema([LocalConversationSnapshot.self])
                let storeURL = directory.appending(path: "LocalHistory.store", directoryHint: .notDirectory)
                let configuration = ModelConfiguration("LocalHistory", schema: schema, url: storeURL, allowsSave: true, cloudKitDatabase: .none)
                try Self.applyProtection(to: directory)
                resolvedContainer = try ModelContainer(for: schema, configurations: [configuration])
            }
        } catch {
            // Keep the app usable if the persistent store is damaged. This fallback
            // is intentionally process-local and never silently writes elsewhere.
            persistenceError = "On-device history could not open its persistent store: \(error.localizedDescription)"
            storageDirectoryURL = nil
            let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
            resolvedContainer = try! ModelContainer(for: LocalConversationSnapshot.self, configurations: configuration)
        }
        container = resolvedContainer
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    private static func prepareProtectedDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appending(path: "LocalLingoPrivateHistory", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        try applyProtection(to: directory)
        return directory
    }

    private static func applyProtection(to directory: URL) throws {
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
    }

    func load(enabled: Bool) throws -> [ConversationRecord] {
        try loadPage(enabled: enabled, offset: 0).records
    }

    func loadPage(enabled: Bool, offset: Int, limit: Int = LocalHistoryPolicy.pageSize) throws -> LocalHistoryPage {
        guard enabled else { return LocalHistoryPage(records: [], nextOffset: 0, hasMore: false) }
        guard offset >= 0 else { throw LocalHistoryError.invalidRecord }
        let pageLimit = min(max(1, limit), LocalHistoryPolicy.pageSize)
        var descriptor = FetchDescriptor<LocalConversationSnapshot>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = pageLimit + 1
        let snapshots = try context.fetch(descriptor)
        let pageSnapshots = Array(snapshots.prefix(pageLimit))
        var records: [ConversationRecord] = []
        records.reserveCapacity(pageSnapshots.count)
        var migratedMetadata = false

        for snapshot in pageSnapshots {
            guard snapshot.payloadByteCount >= 0,
                  snapshot.payloadByteCount <= LocalHistoryPolicy.maximumSnapshotBytes,
                  snapshot.turnCount >= 0,
                  snapshot.turnCount <= ConversationContentPolicy.maximumTurns else {
                throw LocalHistoryError.corruptSnapshot
            }
            let payloadSize = snapshot.payload.count
            guard payloadSize <= LocalHistoryPolicy.maximumSnapshotBytes,
                  snapshot.payloadByteCount == 0 || snapshot.payloadByteCount == payloadSize,
                  snapshot.turnCount <= ConversationContentPolicy.maximumTurns else {
                throw LocalHistoryError.corruptSnapshot
            }
            let record: ConversationRecord
            do { record = try JSONDecoder().decode(ConversationRecord.self, from: snapshot.payload) }
            catch { throw LocalHistoryError.corruptSnapshot }
            do { try LocalHistoryPolicy.validate(record) }
            catch { throw LocalHistoryError.corruptSnapshot }
            guard record.id == snapshot.id,
                  record.updatedAt == snapshot.updatedAt,
                  snapshot.turnCount == 0 || snapshot.turnCount == record.turns.count else {
                throw LocalHistoryError.corruptSnapshot
            }
            if snapshot.payloadByteCount == 0 || snapshot.turnCount == 0 {
                snapshot.payloadByteCount = payloadSize
                snapshot.turnCount = record.turns.count
                migratedMetadata = true
            }
            records.append(record)
        }
        if migratedMetadata { try context.save() }
        return LocalHistoryPage(
            records: records,
            nextOffset: offset + records.count,
            hasMore: snapshots.count > pageLimit
        )
    }

    func save(_ conversation: ConversationRecord, enabled: Bool) throws {
        guard enabled, !conversation.turns.isEmpty else { return }
        try LocalHistoryPolicy.validate(conversation)
        let data = try JSONEncoder().encode(conversation)
        guard data.count <= LocalHistoryPolicy.maximumSnapshotBytes else { throw LocalHistoryError.snapshotTooLarge }

        let allSnapshots = try context.fetch(FetchDescriptor<LocalConversationSnapshot>())
        guard allSnapshots.count <= LocalHistoryPolicy.maximumConversations else { throw LocalHistoryError.capacityExceeded }
        let stored = allSnapshots.first { $0.id == conversation.id }
        if stored == nil, allSnapshots.count >= LocalHistoryPolicy.maximumConversations {
            throw LocalHistoryError.capacityExceeded
        }
        var aggregateBytes = 0
        for snapshot in allSnapshots {
            let size = snapshot.payloadByteCount == 0 ? snapshot.payload.count : snapshot.payloadByteCount
            guard size >= 0, size <= LocalHistoryPolicy.maximumSnapshotBytes else { throw LocalHistoryError.corruptSnapshot }
            aggregateBytes += size
            guard aggregateBytes <= LocalHistoryPolicy.maximumAggregateBytes else { throw LocalHistoryError.capacityExceeded }
        }
        let priorSize = stored.map { $0.payloadByteCount == 0 ? $0.payload.count : $0.payloadByteCount } ?? 0
        guard aggregateBytes - priorSize + data.count <= LocalHistoryPolicy.maximumAggregateBytes else {
            throw LocalHistoryError.capacityExceeded
        }

        if let stored {
            guard stored.updatedAt <= conversation.updatedAt else { return }
            stored.updatedAt = conversation.updatedAt
            stored.payloadByteCount = data.count
            stored.turnCount = conversation.turns.count
            stored.payload = data
        } else {
            context.insert(LocalConversationSnapshot(
                id: conversation.id,
                updatedAt: conversation.updatedAt,
                payloadByteCount: data.count,
                turnCount: conversation.turns.count,
                payload: data
            ))
        }
        try context.save()
    }

    func delete(id: UUID) throws {
        let requestedID = id
        let descriptor = FetchDescriptor<LocalConversationSnapshot>(predicate: #Predicate<LocalConversationSnapshot> { snapshot in
            snapshot.id == requestedID
        })
        for stored in try context.fetch(descriptor) { context.delete(stored) }
        try context.save()
    }

    func deleteAll() throws {
        try context.delete(model: LocalConversationSnapshot.self)
        try context.save()
    }
}
