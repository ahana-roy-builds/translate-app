@preconcurrency import AVFoundation
@preconcurrency import CoreML
import CoreMedia
import Foundation

actor SileroVoiceActivityDetector: VoiceActivityDetecting {
    private final class ConverterInput: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer: AVAudioPCMBuffer?

        init(_ buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }

        func next(
            status: UnsafeMutablePointer<AVAudioConverterInputStatus>
        ) -> AVAudioBuffer? {
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

    private static let modelName = "silero-vad-unified-256ms-v6.2.1"
    private static let sampleRate: Double = 16_000
    private static let chunkSize = 4_096
    private static let contextSize = 64
    private static let stateSize = 128
    private static let modelInputSize = chunkSize + contextSize

    private let bundle: Bundle
    private var model: MLModel?
    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var pendingSamples: [Float] = []
    private var hiddenState = Array(repeating: Float.zero, count: stateSize)
    private var cellState = Array(repeating: Float.zero, count: stateSize)
    private var context = Array(repeating: Float.zero, count: contextSize)
    private var origin: CMTime?
    private var boundary = VoiceActivityBoundaryDetector()

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func prepare() async throws {
        resetStream()
        guard model == nil else { return }
        let modelURL = bundle.url(
            forResource: Self.modelName,
            withExtension: "mlmodelc",
            subdirectory: "Models"
        ) ?? bundle.url(
            forResource: Self.modelName,
            withExtension: "mlmodelc"
        )
        guard let modelURL else {
            throw PipelineError.assetsUnavailable(
                "The bundled continuous-listening model is missing."
            )
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let loaded = try MLModel(contentsOf: modelURL, configuration: configuration)
        let requiredInputs = Set(["audio_input", "hidden_state", "cell_state"])
        let requiredOutputs = Set([
            "vad_output",
            "new_hidden_state",
            "new_cell_state"
        ])
        guard requiredInputs.isSubset(
            of: Set(loaded.modelDescription.inputDescriptionsByName.keys)
        ), requiredOutputs.isSubset(
            of: Set(loaded.modelDescription.outputDescriptionsByName.keys)
        ) else {
            throw PipelineError.assetsUnavailable(
                "The bundled continuous-listening model is incompatible."
            )
        }
        model = loaded
    }

    func process(_ input: VoiceActivityInput) async throws -> VoiceActivityResult {
        guard model != nil else {
            throw PipelineError.assetsUnavailable(
                "Continuous listening is not prepared."
            )
        }
        if origin == nil {
            origin = try Self.startTime(from: input.audioTime)
        }
        let converted = try convert(input.buffer)
        pendingSamples.append(contentsOf: converted)

        var probabilities: [Float] = []
        var sampleEvents: [VoiceActivitySampleEvent] = []
        while pendingSamples.count >= Self.chunkSize {
            let chunk = Array(pendingSamples.prefix(Self.chunkSize))
            pendingSamples.removeFirst(Self.chunkSize)
            let probability = try predict(chunk)
            probabilities.append(probability)
            sampleEvents.append(contentsOf: boundary.process(
                probability: probability,
                sampleCount: chunk.count
            ))
        }
        return result(probabilities: probabilities, sampleEvents: sampleEvents)
    }

    func finish() async throws -> VoiceActivityResult {
        guard model != nil else {
            throw PipelineError.assetsUnavailable(
                "Continuous listening is not prepared."
            )
        }
        pendingSamples.append(contentsOf: try flushConverter())
        var probabilities: [Float] = []
        var sampleEvents: [VoiceActivitySampleEvent] = []
        while pendingSamples.count >= Self.chunkSize {
            let chunk = Array(pendingSamples.prefix(Self.chunkSize))
            pendingSamples.removeFirst(Self.chunkSize)
            let probability = try predict(chunk)
            probabilities.append(probability)
            sampleEvents.append(contentsOf: boundary.process(
                probability: probability,
                sampleCount: chunk.count
            ))
        }
        if !pendingSamples.isEmpty {
            let actualCount = pendingSamples.count
            var finalChunk = pendingSamples
            finalChunk.append(contentsOf: repeatElement(
                Float.zero,
                count: Self.chunkSize - finalChunk.count
            ))
            pendingSamples = []
            let probability = try predict(finalChunk)
            probabilities.append(probability)
            sampleEvents.append(contentsOf: boundary.process(
                probability: probability,
                sampleCount: actualCount
            ))
        }
        sampleEvents.append(contentsOf: boundary.finish())
        return result(probabilities: probabilities, sampleEvents: sampleEvents)
    }

    func reset() async {
        resetStream()
    }

    private func resetStream() {
        sourceFormat = nil
        converter = nil
        pendingSamples = []
        hiddenState = Array(repeating: 0, count: Self.stateSize)
        cellState = Array(repeating: 0, count: Self.stateSize)
        context = Array(repeating: 0, count: Self.contextSize)
        origin = nil
        boundary = VoiceActivityBoundaryDetector()
    }

    private func convert(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        let targetFormat = try Self.targetFormat()
        if let sourceFormat {
            guard sourceFormat.isEqual(buffer.format) else {
                throw PipelineError.server(
                    "The microphone audio format changed during continuous listening."
                )
            }
        } else {
            sourceFormat = buffer.format
            guard let converter = AVAudioConverter(
                from: buffer.format,
                to: targetFormat
            ) else {
                throw PipelineError.server(
                    "Could not convert microphone audio for continuous listening."
                )
            }
            self.converter = converter
        }
        guard let converter else { return [] }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let estimate = ceil(Double(buffer.frameLength) * ratio)
        guard estimate.isFinite,
              estimate >= 0,
              estimate <= Double(AVAudioFrameCount.max - 64),
              let output = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: AVAudioFrameCount(estimate) + 64
              ) else {
            throw PipelineError.server(
                "Could not allocate continuous-listening audio."
            )
        }

        let provider = ConverterInput(buffer)
        var conversionError: NSError?
        let status = converter.convert(
            to: output,
            error: &conversionError
        ) { _, inputStatus in
            provider.next(status: inputStatus)
        }
        if let conversionError { throw conversionError }
        guard status != .error else {
            throw PipelineError.server(
                "Could not convert microphone audio for continuous listening."
            )
        }
        return try Self.samples(from: output)
    }

    private func flushConverter() throws -> [Float] {
        guard let converter else { return [] }
        let targetFormat = try Self.targetFormat()
        var samples: [Float] = []
        while true {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: 4_096
            ) else {
                throw PipelineError.server(
                    "Could not finish continuous-listening audio conversion."
                )
            }
            var conversionError: NSError?
            let status = converter.convert(
                to: output,
                error: &conversionError
            ) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if let conversionError { throw conversionError }
            guard status != .error else {
                throw PipelineError.server(
                    "Could not finish continuous-listening audio conversion."
                )
            }
            samples.append(contentsOf: try Self.samples(from: output))
            if status == .endOfStream || output.frameLength == 0 { break }
        }
        self.converter = nil
        return samples
    }

    private func predict(_ chunk: [Float]) throws -> Float {
        guard let model, chunk.count == Self.chunkSize else {
            throw PipelineError.malformedResponse
        }
        let audio = try MLMultiArray(
            shape: [1, NSNumber(value: Self.modelInputSize)],
            dataType: .float32
        )
        let hidden = try MLMultiArray(
            shape: [1, NSNumber(value: Self.stateSize)],
            dataType: .float32
        )
        let cell = try MLMultiArray(
            shape: [1, NSNumber(value: Self.stateSize)],
            dataType: .float32
        )
        let audioPointer = audio.dataPointer.assumingMemoryBound(to: Float.self)
        for index in 0..<Self.contextSize {
            audioPointer[index] = context[index]
        }
        for index in 0..<Self.chunkSize {
            audioPointer[index + Self.contextSize] = chunk[index]
        }
        let hiddenPointer = hidden.dataPointer.assumingMemoryBound(to: Float.self)
        let cellPointer = cell.dataPointer.assumingMemoryBound(to: Float.self)
        for index in 0..<Self.stateSize {
            hiddenPointer[index] = hiddenState[index]
            cellPointer[index] = cellState[index]
        }

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "audio_input": MLFeatureValue(multiArray: audio),
            "hidden_state": MLFeatureValue(multiArray: hidden),
            "cell_state": MLFeatureValue(multiArray: cell)
        ])
        let output = try model.prediction(from: input)
        guard let probabilityArray = output.featureValue(
            for: "vad_output"
        )?.multiArrayValue,
        let newHidden = output.featureValue(
            for: "new_hidden_state"
        )?.multiArrayValue,
        let newCell = output.featureValue(
            for: "new_cell_state"
        )?.multiArrayValue,
        probabilityArray.count >= 1,
        newHidden.count >= Self.stateSize,
        newCell.count >= Self.stateSize else {
            throw PipelineError.malformedResponse
        }
        let probability = probabilityArray.dataPointer
            .assumingMemoryBound(to: Float.self)[0]
        guard probability.isFinite else { throw PipelineError.malformedResponse }
        let newHiddenPointer = newHidden.dataPointer.assumingMemoryBound(to: Float.self)
        let newCellPointer = newCell.dataPointer.assumingMemoryBound(to: Float.self)
        hiddenState = (0..<Self.stateSize).map { newHiddenPointer[$0] }
        cellState = (0..<Self.stateSize).map { newCellPointer[$0] }
        context = Array(chunk.suffix(Self.contextSize))
        return min(max(probability, 0), 1)
    }

    private func result(
        probabilities: [Float],
        sampleEvents: [VoiceActivitySampleEvent]
    ) -> VoiceActivityResult {
        VoiceActivityResult(
            probabilities: probabilities,
            events: sampleEvents.map(event),
            processedThrough: time(forSample: boundary.processedSamples)
        )
    }

    private func event(_ sampleEvent: VoiceActivitySampleEvent) -> VoiceActivityEvent {
        switch sampleEvent {
        case let .speechStarted(sample):
            .speechStarted(at: time(forSample: sample))
        case let .speechEnded(startSample, endSample, reason):
            .speechEnded(
                range: CMTimeRange(
                    start: time(forSample: startSample),
                    end: time(forSample: endSample)
                ),
                reason: reason
            )
        }
    }

    private func time(forSample sample: Int64) -> CMTime {
        CMTimeAdd(
            origin ?? .zero,
            CMTime(value: sample, timescale: CMTimeScale(Self.sampleRate))
        )
    }

    private static func targetFormat() throws -> AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw PipelineError.server(
                "Could not create the continuous-listening audio format."
            )
        }
        return format
    }

    private static func samples(from buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard buffer.frameLength == 0 || buffer.floatChannelData != nil else {
            throw PipelineError.server(
                "Continuous-listening audio was not Float32 PCM."
            )
        }
        guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else {
            return []
        }
        return Array(UnsafeBufferPointer(
            start: channel,
            count: Int(buffer.frameLength)
        ))
    }

    private static func startTime(from audioTime: AVAudioTime) throws -> CMTime {
        guard audioTime.isSampleTimeValid,
              audioTime.sampleTime >= 0,
              audioTime.sampleRate.isFinite,
              audioTime.sampleRate >= 1,
              audioTime.sampleRate <= Double(CMTimeScale.max) else {
            throw PipelineError.server(
                "The microphone supplied an invalid continuous-listening timestamp."
            )
        }
        return CMTime(
            value: audioTime.sampleTime,
            timescale: CMTimeScale(audioTime.sampleRate.rounded())
        )
    }
}
