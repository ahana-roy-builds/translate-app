import Foundation

enum ConversationState: Equatable, Sendable {
    case notReady
    case ready(SpeakerSide)
    case preparing(SpeakerSide)
    case listening(SpeakerSide)
    case finalizing(SpeakerSide)
    case reviewing(SpeakerSide)
    case confirming(SpeakerSide)
    case translating(SpeakerSide)
    case speaking(outputFor: SpeakerSide, recoverTo: SpeakerSide)
    case failed(message: String, recoverTo: SpeakerSide)

    var speaker: SpeakerSide? {
        switch self {
        case let .ready(s), let .preparing(s), let .listening(s), let .finalizing(s), let .reviewing(s), let .confirming(s), let .translating(s): s
        case let .speaking(outputFor: s, recoverTo: _): s
        case let .failed(_, s): s
        case .notReady: nil
        }
    }


    var recoverySpeaker: SpeakerSide? {
        switch self {
        case let .ready(s), let .preparing(s), let .listening(s), let .finalizing(s),
             let .reviewing(s), let .confirming(s), let .translating(s): s
        case let .speaking(outputFor: _, recoverTo: speaker): speaker
        case let .failed(_, speaker): speaker
        case .notReady: nil
        }
    }

    var isBusy: Bool {
        switch self {
        case .preparing, .listening, .finalizing, .reviewing, .confirming, .translating, .speaking: true
        case .notReady, .ready, .failed: false
        }
    }

    var acceptsMicrophoneTap: Bool {
        switch self { case .ready, .speaking, .failed: true; default: false }
    }
}

enum ConversationTransitionError: Error, Equatable { case invalid(ConversationState, ConversationState) }

struct ConversationStateMachine: Sendable {
    private(set) var state: ConversationState = .notReady

    mutating func transition(to next: ConversationState) throws {
        guard Self.isAllowed(from: state, to: next) else { throw ConversationTransitionError.invalid(state, next) }
        state = next
    }

    mutating func reset(speaker: SpeakerSide = .traveler) { state = .ready(speaker) }

    static func isAllowed(from: ConversationState, to: ConversationState) -> Bool {
        switch (from, to) {
        case (.notReady, .ready),
             (.ready, .preparing),
             (.speaking, .preparing),
             (.failed, .preparing),
             (.preparing, .listening),
             (.preparing, .reviewing),
             (.preparing, .ready),
             (.ready, .reviewing),
             (.ready, .speaking),
             (.listening, .finalizing),
             (.finalizing, .reviewing),
             (.reviewing, .translating),
             (.translating, .confirming),
             (.translating, .speaking),
             (.translating, .ready),
             (.confirming, .translating),
             (.confirming, .speaking),
             (.confirming, .ready),
             (.speaking, .ready),
             (_, .failed),
             (_, .notReady): true
        default: false
        }
    }
}
