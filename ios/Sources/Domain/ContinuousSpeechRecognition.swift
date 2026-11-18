import AVFoundation
import CoreMedia
import Foundation
import Speech

enum LanguageReviewReason: String, CaseIterable, Equatable, Hashable, Sendable {
    case shortUtterance
    case lowScore
    case closeScores
    case languageDisagreement
    case missingAlternate
    case experimentalLanguagePair
}

struct RecognitionCandidate: Equatable, Sendable {
    let language: AppLanguage
    let text: String
    let isFinal: Bool
    let confidence: Double?
    let lowConfidenceFraction: Double
    let constrainedLanguageProbability: Double?
    let score: Double
}

struct LanguageDecision: Equatable, Sendable {
    let selected: RecognitionCandidate
    let alternate: RecognitionCandidate?
    let reviewReasons: Set<LanguageReviewReason>

    var needsReview: Bool { !reviewReasons.isEmpty }
}

struct ContinuousDraft: Equatable, Sendable {
    let language: AppLanguage
    let text: String
    let confidence: Double?
    let score: Double
}

@MainActor
protocol ContinuousSpeechRecognizing: AnyObject {
    func start(
        pair: LanguagePair,
        onDraft: @escaping @MainActor (ContinuousDraft?) -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) async throws
    func append(_ buffer: AVAudioPCMBuffer, at audioTime: AVAudioTime?) throws
    func beginUtterance(at start: CMTime)
    func takeDraft(in range: CMTimeRange, onRevision: @escaping @MainActor (ContinuousDraft?) -> Void) -> ContinuousDraft?
    func finishInput() throws -> CMTime?
    func finalizeUtterance(in range: CMTimeRange) async throws -> LanguageDecision
    func cancelAnalysis(before time: CMTime)
    func stop()
}

struct ContinuousFinalizationProgress {
    private(set) var times: [AppLanguage: CMTime] = [:]

    mutating func record(_ time: CMTime, for language: AppLanguage) {
        guard time.isValid, time.isNumeric || time.isPositiveInfinity else { return }
        if let current = times[language], CMTimeCompare(current, time) >= 0 {
            return
        }
        times[language] = time
    }

    func includes(
        _ languages: [AppLanguage],
        through target: CMTime
    ) -> Bool {
        guard target.isValid, target.isNumeric else { return false }
        return languages.allSatisfy { language in
            guard let time = times[language] else { return false }
            return CMTimeCompare(time, target) >= 0
        }
    }
}

enum ContinuousRecognitionTimingPolicy {
    static func finalizableRange(
        requested: CMTimeRange,
        deliveredThrough: CMTime?
    ) -> CMTimeRange? {
        let requestedStart = requested.start
        let requestedEnd = CMTimeRangeGetEnd(requested)
        guard requestedStart.isValid,
              requestedStart.isNumeric,
              requestedEnd.isValid,
              requestedEnd.isNumeric,
              let deliveredThrough,
              deliveredThrough.isValid,
              deliveredThrough.isNumeric else {
            return nil
        }
        let cappedEnd = CMTimeCompare(requestedEnd, deliveredThrough) <= 0
            ? requestedEnd
            : deliveredThrough
        guard CMTimeCompare(cappedEnd, requestedStart) > 0 else { return nil }
        return CMTimeRange(start: requestedStart, end: cappedEnd)
    }
}

struct ContinuousRecognitionSegment {
    let range: CMTimeRange
    let text: String
    let isFinal: Bool
    let confidence: Double?
    let lowConfidenceFraction: Double
    let timedText: AttributedString?

    /// A word belongs to the turn in which it ends. Preserve spaces and
    /// punctuation between timed runs, which Apple can return without timing.
    func clipped(to interval: CMTimeRange) -> Self? {
        guard let timedText else { return self }
        let start = CMTimeMaximum(range.start, interval.start)
        let end = CMTimeMinimum(range.end, interval.end)
        guard start < end else { return nil }
        if start == range.start && end == range.end { return self }

        let included = timedText.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let time = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self],
                  time.end > start, time.end <= end else { return nil }
            return run.range
        }
        guard let first = included.first, let last = included.last else { return nil }
        let words = AttributedString(timedText[first.lowerBound..<last.upperBound])
        return Self(range: CMTimeRange(start: start, end: end), text: String(words.characters),
                    isFinal: isFinal, confidence: confidence, lowConfidenceFraction: lowConfidenceFraction,
                    timedText: words)
    }
}

/// Applies volatile transcript revisions and produces a bounded snapshot for an
/// utterance time range.
struct ContinuousRecognitionAccumulator {
    private(set) var segments: [ContinuousRecognitionSegment] = []

    @discardableResult
    mutating func apply(
        range: CMTimeRange,
        text: String,
        isFinal: Bool,
        confidence: Double?,
        lowConfidenceFraction: Double,
        timedText: AttributedString? = nil
    ) -> Bool {
        segments.removeAll { Self.overlaps($0.range, range) }

        let replacement = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replacement.isEmpty else { return true }
        guard segments.count < ConversationContentPolicy.maximumSpeechSegments else { return false }
        segments.append(ContinuousRecognitionSegment(
            range: range,
            text: replacement,
            isFinal: isFinal,
            confidence: confidence,
            lowConfidenceFraction: ContinuousLanguageDecisionPolicy.clamp(lowConfidenceFraction),
            timedText: timedText
        ))
        segments.sort { CMTimeCompare($0.range.start, $1.range.start) < 0 }
        return true
    }

    func transcript(in range: CMTimeRange? = nil) -> Transcript? {
        let included = range.map { requested in
            segments.filter { Self.overlaps($0.range, requested) }.compactMap { $0.clipped(to: requested) }
        } ?? segments
        guard !included.isEmpty else { return nil }

        let text = included
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let characterCount = included.reduce(0) { $0 + $1.text.count }
        guard characterCount > 0 else { return nil }
        let hasMissingConfidence = included.contains { $0.confidence == nil }
        let confidence: Double? = hasMissingConfidence ? nil : included.reduce(0) { partial, segment in
            partial + ContinuousLanguageDecisionPolicy.clamp(segment.confidence ?? 0)
                * Double(segment.text.count)
        } / Double(characterCount)
        let lowConfidenceFraction = included.reduce(0) { partial, segment in
            partial + segment.lowConfidenceFraction * Double(segment.text.count)
        } / Double(characterCount)

        return Transcript(
            text: text,
            isFinal: included.allSatisfy(\.isFinal),
            confidence: confidence,
            lowConfidenceFraction: lowConfidenceFraction
        )
    }

    mutating func discard(before time: CMTime) {
        let cutoff = CMTimeGetSeconds(time)
        guard cutoff.isFinite else { return }
        segments.removeAll { segment in
            let end = CMTimeGetSeconds(CMTimeRangeGetEnd(segment.range))
            return end.isFinite && end <= cutoff + Self.timeTolerance
        }
    }

    mutating func retireLiveDraft(through boundary: CMTime) {
        segments = segments.compactMap { segment in
            if segment.range.start >= boundary { return segment }
            guard segment.range.end > boundary else { return nil }
            return segment.clipped(to: CMTimeRange(start: boundary, end: segment.range.end))
        }
    }

    private static let timeTolerance = 0.01

    private static func overlaps(_ lhs: CMTimeRange, _ rhs: CMTimeRange) -> Bool {
        let lhsStart = CMTimeGetSeconds(lhs.start)
        let lhsEnd = CMTimeGetSeconds(CMTimeRangeGetEnd(lhs))
        let rhsStart = CMTimeGetSeconds(rhs.start)
        let rhsEnd = CMTimeGetSeconds(CMTimeRangeGetEnd(rhs))
        guard lhsStart.isFinite, lhsEnd.isFinite, rhsStart.isFinite, rhsEnd.isFinite else {
            return false
        }
        let overlapStart = max(lhsStart, rhsStart)
        let overlapEnd = min(lhsEnd, rhsEnd)
        let rhsIsPoint = rhsEnd - rhsStart < timeTolerance
        let lhsIsPoint = lhsEnd - lhsStart < timeTolerance
        return overlapEnd - overlapStart >= timeTolerance
            || abs(lhsStart - rhsStart) < timeTolerance
            || (rhsIsPoint && rhsStart >= lhsStart - timeTolerance && rhsStart <= lhsEnd + timeTolerance)
            || (lhsIsPoint && lhsStart >= rhsStart - timeTolerance && lhsStart <= rhsEnd + timeTolerance)
    }
}

enum ContinuousLanguageDecisionPolicy {
    static let minimumScore = 0.65
    static let minimumWinnerMargin = 0.08
    static let minimumAlphabeticCharacters = 12
    static let strongDisagreementProbability = 0.25

    static func makeCandidate(
        language: AppLanguage,
        transcript: Transcript,
        constrainedLanguageProbability: Double?
    ) -> RecognitionCandidate? {
        let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let confidence = clamp(transcript.confidence ?? 0.5)
        let lowConfidenceFraction = clamp(transcript.lowConfidenceFraction)
        let languageProbability = clamp(constrainedLanguageProbability ?? 0.5)
        let score = 0.70 * confidence
            + 0.20 * (1 - lowConfidenceFraction)
            + 0.10 * languageProbability
        return RecognitionCandidate(
            language: language,
            text: text,
            isFinal: transcript.isFinal,
            confidence: transcript.confidence.map(clamp),
            lowConfidenceFraction: lowConfidenceFraction,
            constrainedLanguageProbability: constrainedLanguageProbability.map(clamp),
            score: score
        )
    }

    static func decide(
        candidates: [RecognitionCandidate],
        pair: LanguagePair? = nil
    ) -> LanguageDecision? {
        let eligible = candidates.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let preferredLanguage: AppLanguage? = if let pair,
            Set([pair.traveler, pair.local]) == Set([.englishUS, .hindiIndia]) {
            eligible.contains {
                $0.language == .hindiIndia
                    && PairLanguageEvidencePolicy.hasStrongHindiScriptEvidence($0.text)
            } ? .hindiIndia : .englishUS
        } else {
            nil
        }
        let ranked = eligible.sorted {
                if let preferredLanguage, $0.language != $1.language {
                    if $0.language == preferredLanguage { return true }
                    if $1.language == preferredLanguage { return false }
                }
                if abs($0.score - $1.score) > .ulpOfOne { return $0.score > $1.score }
                return $0.language.rawValue < $1.language.rawValue
            }
        guard let selected = ranked.first else { return nil }
        let alternate = ranked.dropFirst().first
        var reasons = Set<LanguageReviewReason>()

        if selected.text.filter(\.isLetter).count < minimumAlphabeticCharacters {
            reasons.insert(.shortUtterance)
        }
        if selected.score < minimumScore {
            reasons.insert(.lowScore)
        }
        if let alternate, selected.score - alternate.score < minimumWinnerMargin {
            reasons.insert(.closeScores)
        }
        if alternate == nil {
            reasons.insert(.missingAlternate)
        }
        if let probability = selected.constrainedLanguageProbability,
           probability < strongDisagreementProbability {
            reasons.insert(.languageDisagreement)
        }
        if let pair,
           Set([pair.traveler, pair.local]) == Set([.englishUS, .hindiIndia]) {
            // SpeechTranscriber and DictationTranscriber confidence values are
            // not calibrated against each other. Keep every beta decision
            // reviewable until physical-corpus evidence establishes a safe
            // automatic threshold.
            reasons.insert(.experimentalLanguagePair)
        }
        return LanguageDecision(selected: selected, alternate: alternate, reviewReasons: reasons)
    }

    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

enum PairLanguageEvidencePolicy {
    static func constrainedProbability(
        base: Double?,
        text: String,
        expected: AppLanguage,
        pair: LanguagePair
    ) -> Double? {
        let languages = Set([pair.traveler, pair.local])
        guard languages == Set([.englishUS, .hindiIndia]) else { return base }

        guard hasStrongHindiScriptEvidence(text) else { return base }
        let value = ContinuousLanguageDecisionPolicy.clamp(base ?? 0.5)
        return expected == .hindiIndia ? max(value, 0.98) : min(value, 0.02)
    }

    static func hasStrongHindiScriptEvidence(_ text: String) -> Bool {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            if (0x0900...0x097F).contains(Int(scalar.value)) {
                count += 1
            }
        } >= 2
    }
}

struct ContinuousDraftSelector {
    private(set) var selectedLanguage: AppLanguage?
    private var pendingLanguage: AppLanguage?
    private var pendingCount = 0

    mutating func select(
        candidates: [RecognitionCandidate],
        requiredLead: Double = ContinuousLanguageDecisionPolicy.minimumWinnerMargin,
        consecutiveUpdates: Int = 2
    ) -> RecognitionCandidate? {
        let ranked = candidates.sorted {
            if abs($0.score - $1.score) > .ulpOfOne { return $0.score > $1.score }
            return $0.language.rawValue < $1.language.rawValue
        }
        guard let leader = ranked.first else {
            reset()
            return nil
        }
        guard let selectedLanguage,
              let selected = ranked.first(where: { $0.language == selectedLanguage }) else {
            self.selectedLanguage = leader.language
            clearPendingSwitch()
            return leader
        }
        guard leader.language != selectedLanguage else {
            clearPendingSwitch()
            return selected
        }
        guard leader.score - selected.score >= max(requiredLead, 0) else {
            clearPendingSwitch()
            return selected
        }

        if pendingLanguage == leader.language {
            pendingCount += 1
        } else {
            pendingLanguage = leader.language
            pendingCount = 1
        }
        if pendingCount >= max(consecutiveUpdates, 1) {
            self.selectedLanguage = leader.language
            clearPendingSwitch()
            return leader
        }
        return selected
    }

    mutating func reset() {
        selectedLanguage = nil
        clearPendingSwitch()
    }

    private mutating func clearPendingSwitch() {
        pendingLanguage = nil
        pendingCount = 0
    }
}
