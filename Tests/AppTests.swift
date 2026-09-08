import Foundation

// Unit tests for the pure cores: WAV parsing, transcript finalization,
// LLM request/response shaping, settings round-trip.

func runAllTests() {
    TestRunner.run("WAVCore parses 16-bit PCM") {
        // Hand-build a tiny 1-sample WAV.
        var wav = Data()
        func s(_ str: String) { wav.append(str.data(using: .ascii)!) }
        func u32(_ v: UInt32) { var x = v.littleEndian; wav.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; wav.append(Data(bytes: &x, count: 2)) }
        s("RIFF"); u32(36 + 2); s("WAVE")
        s("fmt "); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        s("data"); u32(2)
        wav.append(contentsOf: [0x00, 0x40]) // Int16 LE = 0x4000 ≈ +0.5
        let samples = try WAVCore.samples(from: wav) ?! "parse failed"
        try expectEqual(samples.count, 1, "sample count")
        try expectTrue(abs(samples[0] - 0.5) < 0.01, "sample value ≈0.5, got \(samples[0])")
    }

    TestRunner.run("WAVCore rejects garbage") {
        try expectEqual(WAVCore.samples(from: Data("not a wav".utf8)), nil, "garbage → nil")
        try expectEqual(WAVCore.samples(from: Data()), nil, "empty → nil")
    }

    TestRunner.run("TranscriptCore trims + collapses") {
        try expectEqual(TranscriptCore.finalize("  hello   world  "), "hello world", "trim+collapse")
        try expectEqual(TranscriptCore.finalize("hello world."), "hello world. ", "trailing space after period")
        try expectEqual(TranscriptCore.finalize("what?!"), "what?! ", "punct ?! gets space")
        try expectEqual(TranscriptCore.finalize("no punct"), "no punct", "no punct → no space")
    }

    TestRunner.run("LLM endpoint normalization") {
        try expectEqual(
            LLMCleanupService.endpoint(fromBase: "http://localhost:11434")?.absoluteString,
            "http://localhost:11434/v1/chat/completions",
            "bare host → /v1/chat/completions"
        )
        try expectEqual(
            LLMCleanupService.endpoint(fromBase: "http://localhost:11434/v1/")?.absoluteString,
            "http://localhost:11434/v1/chat/completions",
            "trailing slash stripped"
        )
        try expectEqual(LLMCleanupService.endpoint(fromBase: "not a url"), nil, "invalid → nil")
    }

    TestRunner.run("LLM response parsing") {
        let ok = #"{"choices":[{"message":{"content":"  Cleaned text.  "}}]}"#
        try expectEqual(try LLMCleanupService.parseResponse(Data(ok.utf8)), "Cleaned text.", "content extracted+trimmed")
        let empty = #"{"choices":[{"message":{"content":"EMPTY"}}]}"#
        try expectEqual(try LLMCleanupService.parseResponse(Data(empty.utf8)), "", "EMPTY contract")
        let quoted = #"{"choices":[{"message":{"content":"\"Hello.\""}}]}"#
        try expectEqual(try LLMCleanupService.parseResponse(Data(quoted.utf8)), "Hello.", "quote-stripped")
        let bad = Data("garbage".utf8)
        do {
            _ = try LLMCleanupService.parseResponse(bad)
            throw TestFailure("should have thrown")
        } catch {}
    }

    TestRunner.run("LLM request shaping") {
        let req = try LLMCleanupService.makeRequest(
            baseURL: "http://localhost:11434", model: "llama3.2:3b",
            apiKey: "sk-test", prompt: "SYS", input: "raw text"
        )
        try expectEqual(req.url?.absoluteString, "http://localhost:11434/v1/chat/completions", "URL")
        try expectEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test", "auth header")
        let body = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any] ?! "body json"
        try expectEqual(body["model"] as? String, "llama3.2:3b", "model field")
        let messages = try body["messages"] as? [[String: Any]] ?! "messages"
        try expectEqual(messages.count, 2, "system+user")
        try expectEqual(messages[0]["role"] as? String, "system", "system first")
        try expectEqual(messages[1]["content"] as? String, "raw text", "user content")
    }

    TestRunner.run("Settings default prompt non-empty") {
        try expectTrue(!LLMCleanupService.defaultPrompt.isEmpty, "default prompt exists")
        let svc = LLMCleanupService(baseURL: "x", model: "m", apiKey: "", customPrompt: "  ")
        try expectEqual(svc.prompt, LLMCleanupService.defaultPrompt, "blank custom → default")
        let svc2 = LLMCleanupService(baseURL: "x", model: "m", apiKey: "", customPrompt: "Be terse.")
        try expectEqual(svc2.prompt, "Be terse.", "custom prompt honored")
    }

    TestRunner.run("WAV header writer round-trips") {
        // Header declares exactly 2 data bytes for sampleCount 1…
        let header = AudioRecorder.wavHeader(sampleCount: 1)
        // …so header alone fails the bounds check (declared > actual).
        try expectEqual(WAVCore.samples(from: header), nil, "truncated file → nil")
        // Full file: header + one silent sample parses to 1 sample.
        var full = header
        full.append(contentsOf: [0x00, 0x00])
        let samples = try WAVCore.samples(from: full) ?! "full parse"
        try expectEqual(samples.count, 1, "one silent sample")
    }

    print("\n\(TestRunner.passed) passed, \(TestRunner.failures) failed")
    exit(TestRunner.failures == 0 ? 0 : 1)
}
