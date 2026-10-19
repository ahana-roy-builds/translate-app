@preconcurrency import AVFoundation
import CoreMedia
import Foundation

enum VoiceActivityEndReason: Equatable, Sendable {
    case silence
    case maximumDuration
}

enum VoiceActivityEvent: Equatable, Sendable {
    case speechStarted(at: CMTime)
    case speechEnded(range: CMTimeRange, reason: VoiceActivityEndReason)
}

struct VoiceActivityResult: Equatable, Sendable {
    let probabilities: [Float]
    let events: [VoiceActivityEvent]
    let processedThrough: CMTime
}

struct VoiceActivityInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let audioTime: AVAudioTime
}

protocol VoiceActivityDetecting: Sendable {
    func prepare() async throws
    func process(_ input: VoiceActivityInput) async throws -> VoiceActivityResult
    func finish() async throws -> VoiceActivityResult
    func reset() async
}

enum VoiceActivitySampleEvent: Equatable, Sendable {
    case speechStarted(sample: Int64)
    case speechEnded(
        startSample: Int64,
        endSample: Int64,
        reason: VoiceActivityEndReason
    )
}

struct VoiceActivityBoundaryDetector: Sendable {
    let sampleRate: Int64
    let positiveThreshold: Float
    let negativeThreshold: Float
    let minimumSpeechSamples: Int64
    let minimumSilenceSamples: Int64
    let maximumSpeechSamples: Int64
    let paddingSamples: Int64

    private(set) var processedSamples: Int64 = 0
    private var rawSpeechStartSample: Int64?
    private var rangeStartSample: Int64?
    private var silenceStartSample: Int64?
    private var didEmitStart = false

    init(
        sampleRate: Int64 = 16_000,
        positiveThreshold: Float = 0.75,
        negativeThreshold: Float = 0.60,
        minimumSpeechDuration: TimeInterval = 0.25,
        minimumSilenceDuration: TimeInterval = 0.90,
        maximumSpeechDuration: TimeInterval = 20,
        speechPadding: TimeInterval = 0.10
    ) {
        precondition(sampleRate > 0)
        precondition((0...1).contains(positiveThreshold))
        precondition((0...positiveThreshold).contains(negativeThreshold))
        precondition(minimumSpeechDuration >= 0)
        precondition(minimumSilenceDuration >= 0)
        precondition(maximumSpeechDuration > 0)
        precondition(speechPadding >= 0)
        self.sampleRate = sampleRate
        self.positiveThreshold = positiveThreshold
        self.negativeThreshold = negativeThreshold
        minimumSpeechSamples = Int64(minimumSpeechDuration * Double(sampleRate))
        minimumSilenceSamples = Int64(minimumSilenceDuration * Double(sampleRate))
        maximumSpeechSamples = Int64(maximumSpeechDuration * Double(sampleRate))
        paddingSamples = Int64(speechPadding * Double(sampleRate))
    }

    mutating func process(
        probability: Float,
        sampleCount: Int
    ) -> [VoiceActivitySampleEvent] {
        guard sampleCount > 0 else { return [] }
        let chunkStart = processedSamples
        processedSamples += Int64(sampleCount)
        var events: [VoiceActivitySampleEvent] = []

        if probability >= positiveThreshold {
            silenceStartSample = nil
            if rawSpeechStartSample == nil {
                beginSpeech(at: chunkStart, includeLeadingPadding: true)
            }
        } else if probability < negativeThreshold, rawSpeechStartSample != nil {
            if silenceStartSample == nil {
                silenceStartSample = chunkStart
            }
            if let silenceStartSample,
               processedSamples - silenceStartSample >= minimumSilenceSamples {
                let end = min(processedSamples, silenceStartSample + paddingSamples)
                events.append(contentsOf: finishSpeech(
                    at: end,
                    speechEndedAt: silenceStartSample,
                    reason: .silence
                ))
            }
        }

        events.append(contentsOf: emitStartIfConfirmed())

        while let rawSpeechStartSample,
              processedSamples - rawSpeechStartSample >= maximumSpeechSamples {
            let exactEnd = rawSpeechStartSample + maximumSpeechSamples
            events.append(contentsOf: finishSpeech(
                at: exactEnd,
                speechEndedAt: exactEnd,
                reason: .maximumDuration
            ))
            // Audio beyond the exact split remains part of the next utterance.
            // It starts exactly at the prior end so ranges cannot overlap.
            beginSpeech(at: exactEnd, includeLeadingPadding: false)
            events.append(contentsOf: emitStartIfConfirmed())
        }
        return events
    }

    mutating func finish() -> [VoiceActivitySampleEvent] {
        let speechEnd = silenceStartSample ?? processedSamples
        let paddedEnd = silenceStartSample.map {
            min(processedSamples, $0 + paddingSamples)
        } ?? processedSamples
        return finishSpeech(
            at: paddedEnd,
            speechEndedAt: speechEnd,
            reason: .silence
        )
    }

    private mutating func finishSpeech(
        at endSample: Int64,
        speechEndedAt speechEndSample: Int64,
        reason: VoiceActivityEndReason
    ) -> [VoiceActivitySampleEvent] {
        guard let rawStart = rawSpeechStartSample,
              let rangeStart = rangeStartSample else { return [] }
        rawSpeechStartSample = nil
        rangeStartSample = nil
        silenceStartSample = nil
        let hadEmittedStart = didEmitStart
        didEmitStart = false
        guard speechEndSample > rawStart,
              speechEndSample - rawStart >= minimumSpeechSamples,
              endSample > rangeStart else { return [] }
        var events: [VoiceActivitySampleEvent] = []
        if !hadEmittedStart {
            events.append(.speechStarted(sample: rangeStart))
        }
        events.append(.speechEnded(
            startSample: rangeStart,
            endSample: endSample,
            reason: reason
        ))
        return events
    }

    private mutating func beginSpeech(
        at rawStart: Int64,
        includeLeadingPadding: Bool
    ) {
        rawSpeechStartSample = rawStart
        rangeStartSample = includeLeadingPadding
            ? max(0, rawStart - paddingSamples)
            : rawStart
        silenceStartSample = nil
        didEmitStart = false
    }

    private mutating func emitStartIfConfirmed() -> [VoiceActivitySampleEvent] {
        guard !didEmitStart,
              let rawStart = rawSpeechStartSample,
              let rangeStart = rangeStartSample,
              processedSamples > rawStart,
              processedSamples - rawStart >= minimumSpeechSamples else {
            return []
        }
        didEmitStart = true
        return [.speechStarted(sample: rangeStart)]
    }
}
