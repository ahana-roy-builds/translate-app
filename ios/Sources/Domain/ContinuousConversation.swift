import Foundation

enum LocalConversationLanguagePolicy {
    static func supports(
        _ pair: LanguagePair,
        availableLanguages: [AppLanguage] = AppLanguage.conversationLanguages
    ) -> Bool {
        guard pair.isValid,
              availableLanguages.contains(pair.traveler),
              availableLanguages.contains(pair.local) else {
            return false
        }
        let usesHindi = pair.traveler == .hindiIndia || pair.local == .hindiIndia
        guard usesHindi else { return true }
        return Set([pair.traveler, pair.local]) == Set([.englishUS, .hindiIndia])
    }

    static func availableLanguages(
        replacing side: SpeakerSide,
        in pair: LanguagePair
    ) -> [AppLanguage] {
        AppLanguage.conversationLanguages.filter { language in
            guard let replacement = pair.replacing(side, with: language) else {
                return false
            }
            return supports(replacement)
        }
    }

    static func unsupportedMessage(for pair: LanguagePair) -> String {
        guard pair.isValid else { return "Choose two different supported languages." }
        if pair.traveler == .hindiIndia || pair.local == .hindiIndia {
            return "Hindi is currently available only with English."
        }
        return "This language pair is not supported."
    }
}

enum ListeningPauseReason: Equatable, Sendable {
    case user
    case silence
}

enum ContinuousConversationState: Equatable, Sendable {
    case idle
    case preparing
    case listening
    case catchingUp(pendingTurns: Int)
    case pausedForPlayback
    case pausing
    case paused(ListeningPauseReason)
    case resuming
    case ending
    case ended
    case interrupted
    case failed(String)

    var isRunning: Bool {
        switch self {
        case .preparing, .listening, .catchingUp, .pausedForPlayback,
             .pausing, .paused, .resuming, .ending:
            true
        case .idle, .ended, .interrupted, .failed:
            false
        }
    }
}

enum ContinuousModePolicy {
    static let silenceTimeout: TimeInterval = 20
    static let maximumPendingTurns = 4
    static let resumeCapturePendingTurns = 1

    static func supports(_ pair: LanguagePair) -> Bool {
        LocalConversationLanguagePolicy.supports(pair)
    }

    static func canCorrectLanguage(in state: ContinuousConversationState) -> Bool {
        switch state {
        case .listening, .catchingUp, .paused:
            true
        case .idle, .preparing, .pausedForPlayback, .pausing, .resuming,
             .ending, .ended, .interrupted, .failed:
            false
        }
    }

    static func languageNames(for pair: LanguagePair) -> String {
        "\(pair.traveler.displayName) and \(pair.local.displayName)"
    }

    static func isReady(pair: LanguagePair, readiness: TripReadiness) -> Bool {
        guard supports(pair), readiness.pair == pair else { return false }
        return readiness.listenTraveler == .ready
            && readiness.listenLocal == .ready
            && readiness.listenPair == .ready
            && readiness.translateForward == .ready
            && readiness.translateReverse == .ready
    }

    static func shouldPauseCapture(pendingTurns: Int) -> Bool {
        pendingTurns >= maximumPendingTurns
    }

    static func shouldResumeCapture(pendingTurns: Int) -> Bool {
        pendingTurns <= resumeCapturePendingTurns
    }

    static func canEnqueueWork(pendingTurns: Int) -> Bool {
        pendingTurns < maximumPendingTurns
    }

    static func shouldSpeakTranslation(
        wasEnabledAtBoundary: Bool,
        isEnabledNow: Bool
    ) -> Bool {
        wasEnabledAtBoundary && isEnabledNow
    }

    static func shouldSpeakTranslation(
        wasEnabledAtBoundary: Bool,
        isEnabledNow: Bool,
        pair: LanguagePair,
        requiresLanguageReview: Bool = false,
        requiresEntityReview: Bool = false,
        hasEntityMismatch: Bool = false
    ) -> Bool {
        guard shouldSpeakTranslation(
            wasEnabledAtBoundary: wasEnabledAtBoundary,
            isEnabledNow: isEnabledNow
        ) else { return false }
        guard !hasEntityMismatch else { return false }
        if pair.traveler == .hindiIndia || pair.local == .hindiIndia {
            // Hindi remains reviewable because its two recognizers do not
            // expose calibrated confidence values. Honor the explicit Speak
            // preference for ordinary turns, but never speak a turn whose
            // important entities require confirmation.
            return !requiresEntityReview
        }
        return true
    }
}
