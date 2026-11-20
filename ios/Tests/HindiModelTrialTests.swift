import AVFoundation
import Darwin
import XCTest

@testable import LocalLingo

/// An opt-in development test. The signed adapter and model are supplied by the test runner.
final class HindiModelTrialTests: XCTestCase {
    @MainActor
    func testMatchedHindiAudio() async throws {
        guard ProcessInfo.processInfo.environment["HINDI_MODEL_TRIAL"] == "1" else {
            throw XCTSkip("Requires the local Whisper benchmark adapter")
        }
        let library = Bundle.main.privateFrameworksURL!.appendingPathComponent("libHindiModelTrial.dylib")
        let handle = try XCTUnwrap(dlopen(library.path, RTLD_NOW | RTLD_LOCAL), "Could not load the benchmark adapter")
        defer { dlclose(handle) }
        func symbol<T>(_ name: String, _ type: T.Type) throws -> T {
            unsafeBitCast(try XCTUnwrap(dlsym(handle, name)), to: type)
        }
        let load = try symbol(
            "duet_trial_load", (@convention(c) (UnsafePointer<CChar>) -> UnsafeMutableRawPointer?).self)
        let decode = try symbol(
            "duet_trial_decode",
            (@convention(c) (UnsafeMutableRawPointer, UnsafePointer<Float>, Int32, UnsafeMutablePointer<CChar>, Int32)
                -> Int32).self)
        let freeModel = try symbol("duet_trial_free", (@convention(c) (UnsafeMutableRawPointer) -> Void).self)
        let peak = try symbol("duet_trial_peak_bytes", (@convention(c) () -> UInt64).self)
        let energy = try symbol("duet_trial_cpu_energy_nj", (@convention(c) () -> UInt64).self)
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(
            "hindi-model-trial")
        let started = Date()
        let model = root.appendingPathComponent("model.bin")
        let context = try XCTUnwrap(load(model.path))
        defer { freeModel(context) }
        let loadMs = Int(-started.timeIntervalSinceNow * 1000)
        let engine = AppleTranslationEngine(strategy: .lowLatency)
        let groups = [
            ("additional", [1, 4, 5, 8, 9]), ("heldout", Array(1...6)),
            ("matrix", Array(0...2)), ("original", [2, 3, 6, 7, 9]),
        ]
        let files = groups.flatMap { name, indices in indices.map { root.appendingPathComponent("\(name)-\($0).wav") } }
        for file in files {
            let input = try AVAudioFile(forReading: file)
            XCTAssertEqual(input.processingFormat.sampleRate, 16_000)
            XCTAssertEqual(input.processingFormat.channelCount, 1)
            let pcm = try XCTUnwrap(
                AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length)))
            try input.read(into: pcm)
            var output = [CChar](repeating: 0, count: 16384)
            let start = Date()
            let energyBefore = energy()
            let status = decode(
                context, try XCTUnwrap(pcm.floatChannelData)[0], Int32(pcm.frameLength), &output, Int32(output.count))
            XCTAssertEqual(status, 0)
            let transcript = String(cString: output).trimmingCharacters(in: .whitespacesAndNewlines)
            let decoderMs = Int(-start.timeIntervalSinceNow * 1000)
            let afterDecode = energy()
            let english =
                (try? await engine.translate(
                    transcript, source: AppLanguage.hindiIndia.language, target: AppLanguage.englishUS.language)) ?? ""
            var record = [
                "file": file.lastPathComponent, "hindi": transcript, "english": english, "loadMs": String(loadMs),
                "decodeMs": String(decoderMs), "totalMs": String(Int(-start.timeIntervalSinceNow * 1000)),
                "peakBytes": String(peak()), "thermalState": String(ProcessInfo.processInfo.thermalState.rawValue),
            ]
            if energyBefore > 0 && afterDecode > energyBefore {
                record["whisperDecodeCpuEnergyNJ"] = String(afterDecode - energyBefore)
            }
            do {
                let beforeControl = energy()
                let control = try await recognize(file, language: .hindiIndia)
                let afterControl = energy()
                if beforeControl > 0 && afterControl > beforeControl {
                    record["appleStreamingControlCpuEnergyNJ"] = String(afterControl - beforeControl)
                }
                record["appleHindi"] = control.text
                record["appleEnglish"] = try await engine.translate(
                    control.text, source: AppLanguage.hindiIndia.language,
                    target: AppLanguage.englishUS.language)
                record["appleEndpointMs"] = String(Int(-control.endpoint.timeIntervalSinceNow * 1000))
            } catch {
                record["appleError"] = error.localizedDescription
            }
            print("HINDI_TRIAL " + String(decoding: try JSONEncoder().encode(record), as: UTF8.self))
            if file == files.first || file == files.last {
                try await checkEnglishReply(after: file.lastPathComponent)
            }
        }
        if ProcessInfo.processInfo.environment["HINDI_MODEL_CLEANUP"] == "1" {
            for file in files + [model] { try FileManager.default.removeItem(at: file) }
            print("HINDI_TRIAL_CACHE_CLEARED")
        }
    }

    @MainActor
    private func checkEnglishReply(after file: String) async throws {
        let root = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "continuous-speech", withExtension: nil))
        let reply = try await recognize(root.appendingPathComponent("en-US-0.wav"), language: .englishUS)
        let engine = AppleTranslationEngine(strategy: .lowLatency)
        defer { engine.cancel() }
        let translated = try await engine.translate(
            reply.text, source: AppLanguage.englishUS.language,
            target: AppLanguage.hindiIndia.language)
        let row = [
            "after": file, "english": reply.text, "hindi": translated,
            "endpointMs": String(Int(-reply.endpoint.timeIntervalSinceNow * 1000)),
        ]
        print("HINDI_ENGLISH_REPLY " + String(decoding: try JSONEncoder().encode(row), as: UTF8.self))
        XCTAssertTrue(reply.text.lowercased().contains("station"))
    }

    @MainActor
    private func recognize(_ file: URL, language: AppLanguage) async throws -> (text: String, endpoint: Date) {
        let recording = try AVAudioFile(forReading: file)
        let speech = AppleSpeechRecognitionEngine()
        defer { speech.cancel() }
        try await speech.start(locale: language.locale) { _ in }
        while recording.framePosition < recording.length {
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: recording.processingFormat, frameCapacity: 1024))
            try recording.read(into: pcm)
            try speech.append(pcm)
            try await Task.sleep(for: .seconds(Double(pcm.frameLength) / recording.processingFormat.sampleRate))
        }
        let endpoint = Date()
        return (try await speech.finish().text, endpoint)
    }
}
