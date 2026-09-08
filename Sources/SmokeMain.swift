import Foundation

// CLI smoke harness: `swift run`-style test entry compiled alongside the app
// sources when WW_SMOKE is defined. Transcribes a WAV through the real model
// and prints the result. Used by `make smoke`.
#if WW_SMOKE
let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: whisperwhy-smoke <wav> <model> [language]\n".data(using: .utf8)!)
    exit(2)
}
do {
    let t0 = Date()
    let text = try WhisperSTT.transcribe(
        wavURL: URL(fileURLWithPath: args[1]),
        modelPath: args[2],
        language: args.count > 3 ? args[3] : "en"
    )
    print("TRANSCRIPT[\(String(format: "%.1fs", -t0.timeIntervalSinceNow))]: \(TranscriptCore.finalize(text))")
} catch {
    FileHandle.standardError.write("SMOKE FAILED: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
#endif
