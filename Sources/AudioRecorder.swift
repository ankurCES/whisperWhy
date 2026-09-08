import AVFoundation
import Foundation

// Microphone capture → 16 kHz mono Float32 → 16-bit PCM WAV temp file.
// Whisper expects 16 kHz PCM; converting during capture via AVAudioConverter
// keeps the offload off the transcription path.

enum AudioRecorderError: LocalizedError {
    case noInputDevice
    case cannotConvert
    case engineStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No microphone input device found."
        case .cannotConvert: return "Could not set up audio conversion."
        case .engineStartFailed(let why): return "Recording failed to start: \(why)"
        }
    }
}

final class AudioRecorder {
    /// Called from the audio thread with RMS level 0...1 for visual feedback.
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    /// True while the engine is capturing. Set on start, cleared on stop.
    private(set) var isRecording = false
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
    )!

    private var wavURL: URL?
    private var fileHandle: FileHandle?
    private var sampleCount = 0
    private var pendingData = Data()

    /// Elapsed recorded seconds, for the notch timer.
    var recordedSeconds: Double { Double(sampleCount) / 16000.0 }

    /// Prompts for microphone access on first use; returns false if denied.
    /// Without this the engine "starts" but captures silence, and macOS never
    /// shows its own prompt — so the mic appears broken.
    @MainActor
    static func ensureMicPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .undetermined:
            return await withCheckedContinuation { cont in
                AVAudioApplication.requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    func start() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { throw AudioRecorderError.noInputDevice }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioRecorderError.cannotConvert
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperwhy-\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw AudioRecorderError.engineStartFailed("cannot create temp file")
        }
        // Placeholder header; patched with real sizes on stop.
        handle.write(Self.wavHeader(sampleCount: 0))

        wavURL = url
        fileHandle = handle
        sampleCount = 0
        pendingData = Data()

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.consume(buffer: buffer, converter: converter)
        }
        engine.prepare()
        do {
            try engine.start()
            isRecording = true
        } catch {
            input.removeTap(onBus: 0)
            throw AudioRecorderError.engineStartFailed(error.localizedDescription)
        }
    }

    /// Stops capture, finalizes the WAV, returns its URL. Nil if never started.
    func stop() -> URL? {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        defer {
            try? fileHandle?.close()
            fileHandle = nil
        }
        guard let url = wavURL, let handle = fileHandle else { return nil }
        handle.seek(toFileOffset: 0)
        handle.write(Self.wavHeader(sampleCount: sampleCount))
        return sampleCount > 1600 ? url : nil // <0.1s of audio: treat as accidental tap
    }

    private func consume(buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        // Level metering on the raw input signal, for the notch animation.
        if let onLevel, let ch = buffer.floatChannelData {
            let frames = Int(buffer.frameLength)
            if frames > 0 {
                let p = ch[0]
                var sum: Float = 0
                for i in stride(from: 0, to: frames, by: 4) { sum += p[i] * p[i] }
                let n = Float((frames + 3) / 4)
                let rms = sqrt(sum / n)
                onLevel(max(0, min(1, rms * 6))) // gain so normal speech reaches full scale
            }
        }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var convertError: NSError?
        converter.convert(to: out, error: &convertError) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard convertError == nil, let channels = out.floatChannelData else { return }
        let frames = Int(out.frameLength)
        let floats = UnsafeBufferPointer(start: channels[0], count: frames)
        var ints = [Int16](repeating: 0, count: frames)
        for i in 0..<frames {
            let s = max(-1.0, min(1.0, floats[i]))
            ints[i] = Int16(s * 32767.0)
        }
        ints.withUnsafeBytes { pendingData.append(contentsOf: $0) }
        sampleCount += frames
        flushPending()
    }

    /// Writes buffered PCM in chunks so long recordings don't balloon memory.
    private func flushPending() {
        guard pendingData.count >= 64 * 1024, let handle = fileHandle else { return }
        handle.write(pendingData)
        pendingData.removeAll(keepingCapacity: true)
    }

    // MARK: - WAV

    /// Canonical 44-byte RIFF header for 16-bit mono 16 kHz PCM.
    static func wavHeader(sampleCount: Int) -> Data {
        let dataBytes = UInt32(sampleCount * 2)
        var h = Data()
        func append(_ s: String) { h.append(s.data(using: .ascii)!) }
        func append32(_ v: UInt32) { var x = v.littleEndian; h.append(Data(bytes: &x, count: 4)) }
        func append16(_ v: UInt16) { var x = v.littleEndian; h.append(Data(bytes: &x, count: 2)) }
        append("RIFF"); append32(36 + dataBytes); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)
        append32(16000); append32(32000); append16(2); append16(16)
        append("data"); append32(dataBytes)
        return h
    }
}
