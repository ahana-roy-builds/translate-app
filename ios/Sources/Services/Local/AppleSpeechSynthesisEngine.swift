import AVFoundation
import Foundation

@MainActor
final class AppleSpeechSynthesisEngine: NSObject, SpeechSynthesisEngine, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var speechContinuation: CheckedContinuation<Void, Error>?
    private var playerContinuation: CheckedContinuation<Void, Error>?
    private var speechGeneration: UUID?
    private var speechObjectID: ObjectIdentifier?
    private var playerGeneration: UUID?
    private var playerObjectID: ObjectIdentifier?
    private nonisolated let callbackState = PlaybackCallbackState()

    override init() {
        super.init()
        // Recording and playback alternate in LocalLingo. Let the system own
        // synthesis audio-session activation so speech does not inherit the
        // microphone session after capture is stopped.
        synthesizer.usesApplicationAudioSession = false
        synthesizer.delegate = self
    }

    var usesApplicationAudioSession: Bool {
        synthesizer.usesApplicationAudioSession
    }

    func isVoiceAvailable(locale: Locale) -> Bool {
        Self.voice(for: locale, in: AVSpeechSynthesisVoice.speechVoices()) != nil
    }

    func availableVoices(for languages: [AppLanguage]) async -> Set<AppLanguage> {
        await Task.detached(priority: .userInitiated) {
            let voices = AVSpeechSynthesisVoice.speechVoices()
            return Set(languages.filter { Self.voice(for: $0.locale, in: voices) != nil })
        }.value
    }

    func speak(_ text: String, locale: Locale, rate: Float) async throws {
        // A retained replacement task can cancel this task before it receives
        // MainActor time. Such a stale task must not cancel current playback.
        try Task.checkCancellation()
        cancel()
        guard let voice = Self.voice(for: locale, in: AVSpeechSynthesisVoice.speechVoices()) else {
            throw PipelineError.assetsUnavailable("The Speak voice for \(locale.identifier) is not installed. Install it in Settings → Accessibility → Read & Speak → Voices.")
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = rate
        let generation = UUID()
        let objectID = ObjectIdentifier(utterance)
        speechGeneration = generation
        speechObjectID = objectID
        callbackState.activateSpeech(objectID: objectID, generation: generation)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                speechContinuation = continuation
                synthesizer.speak(utterance)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelSpeechRequest(objectID: objectID, generation: generation)
            }
        }
    }

    func play(data: Data, format: String?) async throws {
        try Task.checkCancellation()
        cancel()
        let player = try AVAudioPlayer(data: data)
        self.player = player
        player.delegate = self
        player.prepareToPlay()
        let generation = UUID()
        let objectID = ObjectIdentifier(player)
        playerGeneration = generation
        playerObjectID = objectID
        callbackState.activatePlayer(objectID: objectID, generation: generation)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                playerContinuation = continuation
                guard player.play() else {
                    callbackState.clearPlayer(generation: generation)
                    playerGeneration = nil
                    playerObjectID = nil
                    playerContinuation = nil
                    continuation.resume(throwing: PipelineError.server("Could not play translated audio."))
                    return
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPlayerRequest(objectID: objectID, generation: generation)
            }
        }
    }

    func cancel() {
        let hadSpeechRequest = speechGeneration != nil || speechContinuation != nil || synthesizer.isSpeaking
        callbackState.clearSpeech(generation: speechGeneration)
        callbackState.clearPlayer(generation: playerGeneration)
        speechGeneration = nil
        speechObjectID = nil
        playerGeneration = nil
        playerObjectID = nil
        if hadSpeechRequest { synthesizer.stopSpeaking(at: .immediate) }
        player?.stop(); player = nil
        speechContinuation?.resume(throwing: CancellationError()); speechContinuation = nil
        playerContinuation?.resume(throwing: CancellationError()); playerContinuation = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let objectID = ObjectIdentifier(utterance)
        guard let generation = callbackState.speechGeneration(matching: objectID) else { return }
        Task { @MainActor [weak self] in self?.finishSpeech(objectID: objectID, generation: generation) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let objectID = ObjectIdentifier(utterance)
        guard let generation = callbackState.speechGeneration(matching: objectID) else { return }
        Task { @MainActor [weak self] in self?.cancelSpeech(objectID: objectID, generation: generation) }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let objectID = ObjectIdentifier(player)
        guard let generation = callbackState.playerGeneration(matching: objectID) else { return }
        Task { @MainActor [weak self] in self?.finishPlayer(objectID: objectID, generation: generation, success: flag) }
    }

    private func finishSpeech(objectID: ObjectIdentifier, generation: UUID) {
        guard speechObjectID == objectID, speechGeneration == generation else { return }
        callbackState.clearSpeech(generation: generation)
        speechObjectID = nil
        speechGeneration = nil
        speechContinuation?.resume()
        speechContinuation = nil
    }

    private func cancelSpeech(objectID: ObjectIdentifier, generation: UUID) {
        guard speechObjectID == objectID, speechGeneration == generation else { return }
        callbackState.clearSpeech(generation: generation)
        speechObjectID = nil
        speechGeneration = nil
        speechContinuation?.resume(throwing: CancellationError())
        speechContinuation = nil
    }

    private func cancelSpeechRequest(objectID: ObjectIdentifier, generation: UUID) {
        guard speechObjectID == objectID, speechGeneration == generation else { return }
        callbackState.clearSpeech(generation: generation)
        speechObjectID = nil
        speechGeneration = nil
        synthesizer.stopSpeaking(at: .immediate)
        speechContinuation?.resume(throwing: CancellationError())
        speechContinuation = nil
    }

    private func finishPlayer(objectID: ObjectIdentifier, generation: UUID, success: Bool) {
        guard playerObjectID == objectID, playerGeneration == generation else { return }
        callbackState.clearPlayer(generation: generation)
        playerObjectID = nil
        playerGeneration = nil
        if success { playerContinuation?.resume() }
        else { playerContinuation?.resume(throwing: PipelineError.server("Translated audio stopped unexpectedly.")) }
        playerContinuation = nil; player = nil
    }

    private func cancelPlayerRequest(objectID: ObjectIdentifier, generation: UUID) {
        guard playerObjectID == objectID, playerGeneration == generation else { return }
        callbackState.clearPlayer(generation: generation)
        playerObjectID = nil
        playerGeneration = nil
        player?.stop()
        player = nil
        playerContinuation?.resume(throwing: CancellationError())
        playerContinuation = nil
    }

    private nonisolated static func voice(for locale: Locale, in voices: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        if let exact = voices.first(where: {
            $0.language.caseInsensitiveCompare(locale.identifier) == .orderedSame
        }) { return exact }
        guard let language = locale.language.languageCode?.identifier else { return nil }
        return voices.first {
            Locale(identifier: $0.language).language.languageCode?.identifier == language
        }
    }
}

final class PlaybackCallbackState: @unchecked Sendable {
    private let lock = NSLock()
    private var speech: (objectID: ObjectIdentifier, generation: UUID)?
    private var player: (objectID: ObjectIdentifier, generation: UUID)?

    func activateSpeech(objectID: ObjectIdentifier, generation: UUID) {
        lock.lock(); speech = (objectID, generation); lock.unlock()
    }

    func speechGeneration(matching objectID: ObjectIdentifier) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        guard speech?.objectID == objectID else { return nil }
        return speech?.generation
    }

    func clearSpeech(generation: UUID?) {
        lock.lock(); defer { lock.unlock() }
        guard generation == nil || speech?.generation == generation else { return }
        speech = nil
    }

    func activatePlayer(objectID: ObjectIdentifier, generation: UUID) {
        lock.lock(); player = (objectID, generation); lock.unlock()
    }

    func playerGeneration(matching objectID: ObjectIdentifier) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        guard player?.objectID == objectID else { return nil }
        return player?.generation
    }

    func clearPlayer(generation: UUID?) {
        lock.lock(); defer { lock.unlock() }
        guard generation == nil || player?.generation == generation else { return }
        player = nil
    }
}
