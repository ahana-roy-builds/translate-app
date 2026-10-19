import AVFoundation
import CoreMedia
import Foundation
import Speech

@MainActor
final class SpeechAnalyzerInputConverter {
    private final class InputProvider: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer: AVAudioPCMBuffer?

        init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }

        func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            lock.lock()
            defer { lock.unlock() }
            guard let buffer else {
                status.pointee = .noDataNow
                return nil
            }
            self.buffer = nil
            status.pointee = .haveData
            return buffer
        }
    }

    private let analyzerFormat: AVAudioFormat
    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var pendingStartTime: CMTime?
    private var hasEmittedConvertedAudio = false
    private var finished = false
    private(set) var deliveredThrough: CMTime?

    init(analyzerFormat: AVAudioFormat) {
        self.analyzerFormat = analyzerFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer, at audioTime: AVAudioTime?) throws -> [AnalyzerInput] {
        guard !finished else {
            throw PipelineError.server("Speech audio conversion has already finished.")
        }
        guard buffer.frameLength > 0 else { return [] }
        if let sourceFormat {
            guard sourceFormat.isEqual(buffer.format) else {
                throw PipelineError.server("The microphone audio format changed during capture. Please try again.")
            }
        } else {
            sourceFormat = buffer.format
        }

        let startTime = try Self.startTime(from: audioTime)
        if buffer.format.isEqual(analyzerFormat) {
            return [AnalyzerInput(buffer: buffer, bufferStartTime: startTime)]
        }

        if converter == nil {
            guard let converter = AVAudioConverter(from: buffer.format, to: analyzerFormat) else {
                throw PipelineError.server("Could not convert microphone audio for speech recognition.")
            }
            self.converter = converter
        }
        if !hasEmittedConvertedAudio, pendingStartTime == nil {
            pendingStartTime = startTime
        }

        guard let converter else { return [] }
        let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
        let estimate = ceil(Double(buffer.frameLength) * ratio)
        guard estimate.isFinite, estimate >= 0,
              estimate <= Double(AVAudioFrameCount.max - 64),
              let output = AVAudioPCMBuffer(
                  pcmFormat: analyzerFormat,
                  frameCapacity: AVAudioFrameCount(estimate) + 64
              ) else {
            throw PipelineError.server("Could not allocate converted microphone audio.")
        }

        let provider = InputProvider(buffer: buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            provider.next(status: inputStatus)
        }
        if let conversionError { throw conversionError }
        guard status != .error else {
            throw PipelineError.server("Could not convert microphone audio for speech recognition.")
        }
        guard output.frameLength > 0 else { return [] }
        return [makeAnalyzerInput(output)]
    }

    func flush() throws -> [AnalyzerInput] {
        guard !finished else { return [] }
        finished = true
        guard let converter else {
            pendingStartTime = nil
            return []
        }
        var inputs: [AnalyzerInput] = []

        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: 4_096) else {
                throw PipelineError.server("Could not allocate converted microphone audio.")
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if let conversionError { throw conversionError }
            guard status != .error else {
                throw PipelineError.server("Could not finish converting microphone audio.")
            }
            if output.frameLength > 0 { inputs.append(makeAnalyzerInput(output)) }
            if status == .endOfStream || output.frameLength == 0 { break }
        }
        self.converter = nil
        pendingStartTime = nil
        return inputs
    }

    @discardableResult
    func recordDelivery(of input: AnalyzerInput) throws -> CMTime {
        let sampleRate = input.buffer.format.sampleRate
        guard input.buffer.frameLength > 0,
              sampleRate.isFinite,
              sampleRate >= 1,
              sampleRate <= Double(CMTimeScale.max) else {
            throw PipelineError.server(
                "Speech recognition produced an invalid converted audio buffer."
            )
        }
        let start = input.bufferStartTime ?? deliveredThrough ?? .zero
        guard start.isValid, start.isNumeric else {
            throw PipelineError.server(
                "Speech recognition produced an invalid converted audio timestamp."
            )
        }
        let duration = CMTime(
            value: CMTimeValue(input.buffer.frameLength),
            timescale: CMTimeScale(sampleRate.rounded())
        )
        let end = CMTimeAdd(start, duration)
        guard end.isValid,
              end.isNumeric,
              deliveredThrough.map({ CMTimeCompare(end, $0) >= 0 }) ?? true else {
            throw PipelineError.server(
                "Speech recognition produced a non-monotonic audio timeline."
            )
        }
        deliveredThrough = end
        return end
    }

    private func makeAnalyzerInput(_ buffer: AVAudioPCMBuffer) -> AnalyzerInput {
        let startTime = hasEmittedConvertedAudio ? nil : pendingStartTime
        hasEmittedConvertedAudio = true
        pendingStartTime = nil
        return AnalyzerInput(buffer: buffer, bufferStartTime: startTime)
    }

    private static func startTime(from audioTime: AVAudioTime?) throws -> CMTime? {
        guard let audioTime else { return nil }
        guard audioTime.isSampleTimeValid,
              audioTime.sampleTime >= 0,
              audioTime.sampleRate.isFinite,
              audioTime.sampleRate >= 1,
              audioTime.sampleRate <= Double(CMTimeScale.max) else {
            throw PipelineError.server("The microphone supplied an invalid audio timestamp.")
        }
        return CMTime(
            value: audioTime.sampleTime,
            timescale: CMTimeScale(audioTime.sampleRate.rounded())
        )
    }
}
