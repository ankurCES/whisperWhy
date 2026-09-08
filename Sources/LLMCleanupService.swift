import Foundation

// LLM cleanup over any OpenAI-compatible /chat/completions endpoint
// (Ollama's /v1, LM Studio, Groq, OpenAI, llama.cpp server).

struct LLMCleanupService {
    var baseURL: String
    var model: String
    var apiKey: String
    var customPrompt: String
    // Lines of "heard => replacement" (or a bare preferred term). Injected
    // into the system prompt so a 3B local model can correct homophones and
    // jargon — e.g. "what's up => WhatsApp" — that it would otherwise miss.
    var customTerms: String

    static let defaultPrompt = """
    You are a dictation post-processor. You receive raw speech-to-text output and return clean text ready to be typed into an application.

    Your job:
    - Remove filler words (um, uh, you know, like) unless they carry meaning.
    - Fix spelling, grammar, and punctuation errors.
    - Preserve the speaker's intent, tone, and meaning exactly. Do not add content that was not spoken.

    Output rules:
    - Return ONLY the cleaned transcript text, nothing else. Never output words like "Here is the cleaned transcript".
    - If the transcription is empty or unintelligible, return exactly: EMPTY
    - Do not change the meaning of what was said. Keep the speaker's language.
    """

    var prompt: String {
        let t = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var base = t.isEmpty ? Self.defaultPrompt : t
        let terms = Self.vocabularyBlock(from: customTerms)
        if let terms, !terms.isEmpty {
            base += "\n\n" + terms
        }
        return base
    }

    /// Parse the user's vocabulary list into (heard, replacement) pairs.
    /// Accepted line forms: "heard => replacement", "heard -> replacement",
    /// "heard = replacement", or a bare "replacement" (must always be spelled
    /// this way). Comment lines (#) and blanks are skipped.
    static func parseVocabulary(_ text: String) -> [(heard: String?, replacement: String)] {
        var pairs: [(String?, String)] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            for marker in ["=>", "->", "="] {
                if let range = line.range(of: marker) {
                    let heard = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let replacement = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !replacement.isEmpty { pairs.append((heard.isEmpty ? nil : heard, replacement)) }
                    break
                }
            }
            if line.allSatisfy({ $0.isLetter || $0.isNumber || $0.isWhitespace }) && !line.isEmpty && pairs.last?.1 != line {
                pairs.append((nil, line))
            }
        }
        return pairs
    }

    /// Render vocabulary as a prompt section, or nil when nothing usable.
    static func vocabularyBlock(from text: String) -> String? {
        let pairs = parseVocabulary(text)
        guard !pairs.isEmpty else { return nil }
        var lines = ["Vocabulary — always spell these exactly as written in the output:"]
        for (heard, replacement) in pairs {
            if let heard {
                lines.append("- When you hear or read \"\(heard)\", write \"\(replacement)\".")
            } else {
                lines.append("- \"\(replacement)\" is the correct spelling; fix any variant of it.")
            }
        }
        return lines.joined(separator: "\n")
    }

    enum CleanupError: LocalizedError {
        case badURL, http(Int, String), emptyResponse

        var errorDescription: String? {
            switch self {
            case .badURL: return "Cleanup LLM base URL is invalid."
            case .http(let code, let body): return "Cleanup LLM HTTP \(code): \(body.prefix(160))"
            case .emptyResponse: return "Cleanup LLM returned no content."
            }
        }
    }

    func clean(_ rawTranscript: String) async throws -> String {
        let request = try Self.makeRequest(
            baseURL: baseURL, model: model, apiKey: apiKey, prompt: prompt, input: rawTranscript
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw CleanupError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        return try Self.parseResponse(data)
    }

    /// Lightweight connectivity probe for the Settings "Test connection"
    /// button. Sends a minimal chat completion and reports what came back so
    /// the user can distinguish auth / URL / model errors from a good config.
    func testConnection() async -> TestResult {
        var request: URLRequest
        do {
            request = try Self.makeRequest(
                baseURL: baseURL, model: model, apiKey: apiKey,
                prompt: "You are a connectivity check. Reply with exactly: ok",
                input: "ping"
            )
        } catch {
            return .failure(error.localizedDescription)
        }
        request.timeoutInterval = 15
        let started = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let latency = Date().timeIntervalSince(started)
            guard (200..<300).contains(status) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                return .failure("HTTP \(status): \(body.prefix(200))")
            }
            let reply = (try? Self.parseResponse(data)) ?? ""
            return .success(latency: latency, reply: reply)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    enum TestResult {
        case success(latency: TimeInterval, reply: String)
        case failure(String)

        var message: String {
            switch self {
            case .success(let latency, let reply):
                let r = reply.isEmpty ? "" : " — \(reply.prefix(40))"
                return String(format: "Connected in %.2fs%@", latency, r)
            case .failure(let why): return why
            }
        }
        var ok: Bool { if case .success = self { return true }; return false }
    }

    // MARK: - Pure, testable pieces

    static func endpoint(fromBase baseURL: String) -> URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { return nil }
        // Ollama's native API lives at /api/chat; its OpenAI shim at /v1.
        // Accept a bare host:port and default to the OpenAI-compatible path.
        if !trimmed.hasSuffix("/v1") { trimmed += "/v1" }
        return URL(string: trimmed + "/chat/completions")
    }

    static func makeRequest(baseURL: String, model: String, apiKey: String, prompt: String, input: String) throws -> URLRequest {
        guard let url = endpoint(fromBase: baseURL) else { throw CleanupError.badURL }
        var request = URLRequest(url: url, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": input],
            ],
            "temperature": 0.2,
            "stream": false,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Extracts `choices[0].message.content`, applies the EMPTY contract.
    static func parseResponse(_ data: Data) throws -> String {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = obj["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else { throw CleanupError.emptyResponse }

        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reasoning models (MiniMax-M3, DeepSeek-R1, QwQ…) wrap their chain of
        // thought in <think>…</think>. That is not dictation output — drop it
        // so it never gets pasted into the user's text box.
        text = Self.stripThinkBlocks(text)
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
            text = String(text.dropFirst().dropLast())
        }
        if text.uppercased() == "EMPTY" { return "" }
        return text
    }

    /// Removes <think>…</think> (and unclosed leading <think>) sections.
    static func stripThinkBlocks(_ text: String) -> String {
        var t = text
        // Closed blocks first.
        while let open = t.range(of: "<think>"), let close = t.range(of: "</think>"), open.lowerBound < close.lowerBound {
            t.removeSubrange(open.lowerBound..<close.upperBound)
        }
        // A leading unclosed <think> (stream cut off) — drop to end.
        if let open = t.range(of: "<think>"), open.lowerBound == t.startIndex {
            t = ""
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
