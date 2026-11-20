import AVFoundation
import Foundation

@MainActor
final class AudioCaptureService {
    var onCaptureInterrupted: (() -> Void)?
    var onCaptureLimitReached: (() -> Void)?
    var onCaptureFailed: ((String) -> Void)?

    private let microphone: MicrophoneCaptureSession
    private let accumulator = AudioBufferAccumulator()
    private var startedAt: ContinuousClock.Instant?
    private var captureGeneration = UUID()

    init(notificationCenter: NotificationCenter = .default) {
        microphone = MicrophoneCaptureSession(
            notificationCenter: notificationCenter
        )
        microphone.onCaptureInterrupted = { [weak self] _ in
            self?.onCaptureInterrupted?()
        }
        microphone.onCaptureLimitReached = { [weak self] in
            self?.onCaptureLimitReached?()
        }
        microphone.onCaptureFailed = { [weak self] message in
            self?.onCaptureFailed?(message)
        }
    }

    func requestPermission() async -> Bool {
        await microphone.requestPermission()
    }

    func start(onBuffer: @escaping @MainActor (AVAudioPCMBuffer) throws -> Void) throws {
        guard startedAt == nil else {
            throw PipelineError.server("Audio capture is already active.")
        }
        captureGeneration = UUID()
        let generation = captureGeneration
        accumulator.begin(generation: generation)

        do {
            try microphone.start(generation: generation) { [weak self] captured in
                guard let self,
                      self.captureGeneration == captured.generation else {
                    return .finish(.finished)
                }
                switch self.accumulator.append(
                    captured.buffer,
                    generation: generation
                ) {
                case .accepted:
                    try onBuffer(captured.buffer)
                    return .continueCapture
                case .limitReached:
                    return .finish(.limitReached)
                case .stopped, .staleGeneration:
                    return .finish(.finished)
                }
            }
            startedAt = .now
        } catch {
            accumulator.cancel(generation: generation)
            throw error
        }
    }

    func stop() async throws -> AudioTurn {
        guard startedAt != nil else { throw PipelineError.noSpeech }
        let generation = captureGeneration
        do {
            try await microphone.stop()
        } catch {
            accumulator.cancel(generation: generation)
            captureGeneration = UUID()
            startedAt = nil
            throw error
        }
        try Task.checkCancellation()
        guard captureGeneration == generation else { throw CancellationError() }
        guard let buffers = accumulator.finish(generation: generation) else {
            captureGeneration = UUID()
            startedAt = nil
            throw PipelineError.noSpeech
        }
        captureGeneration = UUID()
        startedAt = nil
        let data = try WAVEncoder.encode(buffers: buffers)
        let pcmByteCount = max(0, data.count - 44)
        return AudioTurn(wavData: data, duration: Double(pcmByteCount) / 32_000)
    }

    func cancel() {
        let generation = captureGeneration
        captureGeneration = UUID()
        microphone.cancel()
        accumulator.cancel(generation: generation)
        startedAt = nil
    }
}

@MainActor
final class AudioBufferAccumulator {
    enum AppendResult: Equatable { case accepted, limitReached, stopped, staleGeneration }
    private static let maximumDuration: TimeInterval = 30
    private static let maximumSourceBytes = 16 * 1_024 * 1_024
    private var buffers: [AVAudioPCMBuffer] = []
    private var duration: TimeInterval = 0
    private var sourceBytes = 0
    private var stopped = false
    private var generation: UUID?

    func begin(generation: UUID) {
        self.generation = generation
        buffers.removeAll()
        duration = 0
        sourceBytes = 0
        stopped = false
    }

    func append(_ buffer: AVAudioPCMBuffer, generation expected: UUID) -> AppendResult {
        guard generation == expected else { return .staleGeneration }
        guard !stopped else { return .stopped }
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        let bytes = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList).reduce(0) { $0 + Int($1.mDataByteSize) }
        guard duration + seconds <= Self.maximumDuration, sourceBytes + bytes <= Self.maximumSourceBytes else {
            stopped = true
            return .limitReached
        }
        duration += seconds
        sourceBytes += bytes
        buffers.append(buffer)
        return .accepted
    }

    func finish(generation expected: UUID) -> [AVAudioPCMBuffer]? {
        guard generation == expected else { return nil }
        let result = buffers
        clearLocked()
        return result
    }

    func cancel(generation expected: UUID) {
        guard generation == expected else { return }
        clearLocked()
    }

    private func clearLocked() {
        generation = nil
        buffers.removeAll()
        duration = 0
        sourceBytes = 0
        stopped = true
    }
}

enum WAVEncoder {
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

    static func encode(buffers: [AVAudioPCMBuffer]) throws -> Data {
        guard let first = buffers.first else { throw PipelineError.noSpeech }
        let format = first.format
        guard let converter = AVAudioConverter(from: format, to: AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!) else {
            throw PipelineError.server("Could not convert microphone audio.")
        }
        var pcm = Data()
        for source in buffers {
            let ratio = 16_000 / source.format.sampleRate
            let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio + 32)
            guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { continue }
            let provider = InputProvider(buffer: source)
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, status in
                provider.next(status: status)
            }
            if let conversionError { throw conversionError }
            if status == .error { throw PipelineError.server("Could not convert microphone audio.") }
            if let data = output.int16ChannelData?.pointee {
                pcm.append(Data(bytes: data, count: Int(output.frameLength) * MemoryLayout<Int16>.size))
                guard pcm.count <= 960_000 else { throw PipelineError.server("Please keep each turn under 30 seconds.") }
            }
        }
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: 1_024) else { break }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if let conversionError { throw conversionError }
            if let data = output.int16ChannelData?.pointee, output.frameLength > 0 {
                pcm.append(Data(bytes: data, count: Int(output.frameLength) * MemoryLayout<Int16>.size))
                guard pcm.count <= 960_000 else { throw PipelineError.server("Please keep each turn under 30 seconds.") }
            }
            if status == .endOfStream || output.frameLength == 0 { break }
            if status == .error { throw PipelineError.server("Could not flush microphone audio.") }
        }
        return header(byteCount: pcm.count, sampleRate: 16_000, channels: 1, bits: 16) + pcm
    }

    private static func header(byteCount: Int, sampleRate: Int, channels: Int, bits: Int) -> Data {
        var data = Data()
        func ascii(_ value: String) { data.append(value.data(using: .ascii)!) }
        func u16(_ value: Int) { var v = UInt16(value).littleEndian; data.append(Data(bytes: &v, count: 2)) }
        func u32(_ value: Int) { var v = UInt32(value).littleEndian; data.append(Data(bytes: &v, count: 4)) }
        ascii("RIFF"); u32(36 + byteCount); ascii("WAVEfmt "); u32(16); u16(1); u16(channels)
        u32(sampleRate); u32(sampleRate * channels * bits / 8); u16(channels * bits / 8); u16(bits)
        ascii("data"); u32(byteCount)
        return data
    }
}
