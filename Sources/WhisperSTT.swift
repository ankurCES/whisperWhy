import Foundation

// C interop for vendored whisper.cpp. The Makefile links build/whisper's
// static libs; this wrapper exposes one call: transcribe(WAV file) → text.
#if canImport(whisper)
import whisper

enum WhisperSTT {
    /// Transcribes a 16-bit mono WAV file with the given ggml model.
    /// - Parameters:
    ///   - modelPath: path to ggml-*.bin
    ///   - language: ISO code ("en", "auto" passes nil → auto-detect)
    /// - Throws: WhisperError with a human-readable reason.
    static func transcribe(wavURL: URL, modelPath: String, language: String) throws -> String {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw WhisperError.modelNotFound(modelPath)
        }

        let data = try Data(contentsOf: wavURL)
        guard let samples = WAVCore.samples(from: data) else {
            throw WhisperError.badWAV
        }

        var cparams = whisper_context_default_params()
        cparams.use_gpu = true // Metal on Apple Silicon
        guard let ctx = whisper_init_from_file_with_params(modelPath, cparams) else {
            throw WhisperError.initFailed
        }
        defer { whisper_free(ctx) }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.single_segment = false
        if language.lowercased() != "auto" {
            params.language = (language as NSString).utf8String!
        }
        params.translate = false

        let result = samples.withUnsafeBufferPointer { buf in
            whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
        }
        guard result == 0 else { throw WhisperError.inferenceFailed(result) }

        var text = ""
        let n = whisper_full_n_segments(ctx)
        for i in 0..<n {
            if let seg = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: seg)
            }
        }
        return text
    }

    enum WhisperError: LocalizedError {
        case modelNotFound(String)
        case badWAV
        case initFailed
        case inferenceFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .modelNotFound(let p): return "Whisper model not found at \(p). Download one from Settings or `make model`."
            case .badWAV: return "Recorded audio could not be decoded."
            case .initFailed: return "Whisper could not load the model (out of memory?)."
            case .inferenceFailed(let code): return "Whisper inference failed (code \(code))."
            }
        }
    }
}
#endif
