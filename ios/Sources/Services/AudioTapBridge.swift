import AVFoundation
import Dispatch
import Foundation

enum AudioTapTermination: Equatable, Sendable {
    case finished
    case overflow
    case copyFailed
    case limitReached
    case consumerFailed(String)
}

enum AudioCaptureTerminalAction: Equatable, Sendable {
    case none
    case limitReached
    case failed(String)
}

extension AudioTapTermination {
    var action: AudioCaptureTerminalAction {
        switch self {
        case .finished:
            .none
        case .limitReached:
            .limitReached
        case .overflow:
            .failed("Audio processing could not keep up. Please try a shorter turn.")
        case .copyFailed:
            .failed("Could not copy microphone audio.")
        case let .consumerFailed(message):
            .failed(message)
        }
    }

    var abortsDelivery: Bool {
        switch self {
        case .overflow, .copyFailed, .consumerFailed:
            true
        case .finished, .limitReached:
            false
        }
    }

    fileprivate var priority: Int {
        switch self {
        case .finished:
            0
        case .limitReached:
            1
        case .overflow, .copyFailed, .consumerFailed:
            2
        }
    }
}

struct CapturedAudioBuffer: @unchecked Sendable {
    // The tap fully owns and populates this copy before yielding it. No code
    // mutates the buffer after it crosses the stream boundary.
    let buffer: AVAudioPCMBuffer
    let audioTime: AVAudioTime
    let generation: UUID
}

final class AudioTapBridge: @unchecked Sendable {
    private enum Phase {
        case active
        case closed(AudioTapTermination)
    }

    let id: UUID
    let stream: AsyncStream<CapturedAudioBuffer>

    private let continuation: AsyncStream<CapturedAudioBuffer>.Continuation
    private let lock = NSLock()
    private let callbackGroup = DispatchGroup()
    private var phase: Phase = .active

    init(id: UUID = UUID(), bufferingLimit: Int = 128) {
        self.id = id
        let pair = AsyncStream.makeStream(
            of: CapturedAudioBuffer.self,
            bufferingPolicy: .bufferingOldest(bufferingLimit)
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    func makeTapHandler() -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { [bridge = self] buffer, audioTime in
            bridge.receive(buffer, at: audioTime)
        }
    }

    func receive(_ buffer: AVAudioPCMBuffer, at audioTime: AVAudioTime) {
        guard beginReceive() else { return }
        defer { callbackGroup.leave() }

        guard let copy = buffer.captureCopy() else {
            close(.copyFailed)
            return
        }

        var shouldFinish = false
        lock.lock()
        guard case .active = phase else {
            lock.unlock()
            return
        }
        switch continuation.yield(CapturedAudioBuffer(
            buffer: copy,
            audioTime: audioTime,
            generation: id
        )) {
        case .enqueued:
            break
        case .dropped:
            phase = .closed(.overflow)
            shouldFinish = true
        case .terminated:
            phase = .closed(.finished)
        @unknown default:
            phase = .closed(.overflow)
            shouldFinish = true
        }
        lock.unlock()

        if shouldFinish { continuation.finish() }
    }

    @discardableResult
    func close(_ reason: AudioTapTermination) -> Bool {
        var shouldFinish = false
        lock.lock()
        switch phase {
        case .active:
            phase = .closed(reason)
            shouldFinish = true
        case let .closed(current) where reason.priority > current.priority:
            // A failure detected by an in-flight callback must not be masked by
            // a normal stop that happened a moment earlier.
            phase = .closed(reason)
        case .closed:
            break
        }
        lock.unlock()

        if shouldFinish { continuation.finish() }
        return shouldFinish
    }

    // Call only after close(). Closing prevents any later callback from
    // entering the group, so the notification cannot race a new enter().
    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            callbackGroup.notify(queue: .global(qos: .userInitiated)) {
                continuation.resume()
            }
        }
    }

    var termination: AudioTapTermination? {
        lock.lock()
        defer { lock.unlock() }
        guard case let .closed(reason) = phase else { return nil }
        return reason
    }

    private func beginReceive() -> Bool {
        lock.lock()
        guard case .active = phase else {
            lock.unlock()
            return false
        }
        callbackGroup.enter()
        lock.unlock()
        return true
    }
}

private extension AVAudioPCMBuffer {
    func captureCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == target.count else { return nil }

        for index in source.indices {
            let byteCount = source[index].mDataByteSize
            guard byteCount <= target[index].mDataByteSize,
                  let sourceData = source[index].mData,
                  let targetData = target[index].mData else {
                return nil
            }
            memcpy(targetData, sourceData, Int(byteCount))
            target[index].mDataByteSize = byteCount
        }
        return copy
    }
}
