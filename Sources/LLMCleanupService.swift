import Foundation

// LLM cleanup over any OpenAI-compatible /chat/completions endpoint
// (Ollama's /v1, LM Studio, Groq, OpenAI, llama.cpp server).

struct LLMCleanupService {
    var baseURL: String
    var model: String
    var apiKey: String
    var customPrompt: String

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
        return t.isEmpty ? Self.defaultPrompt : t
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
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
            text = String(text.dropFirst().dropLast())
        }
        if text.uppercased() == "EMPTY" { return "" }
        return text
    }
}
