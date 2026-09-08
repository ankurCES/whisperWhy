import Foundation
import Speech

// On-device Apple Speech fallback (requires the NSSpeechRecognitionUsageDescription
// key + a one-time permission grant). Used when the whisper.cpp engine is
// unavailable or the user prefers the system recognizer.

final class AppleSpeechService: NSObject, SFSpeechRecognizerDelegate {
    func transcribe(url: URL, language: String) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language == "auto" ? "en_US" : language)) else {
            throw SpeechError.unavailable
        }
        guard recognizer.isAvailable else { throw SpeechError.offline }

        let authState = await Self.authorization()
        guard authState == .authorized else { throw SpeechError.unauthorized }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        if language != "auto" {
            request.addsPunctuation = true
        }

        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if !finished { finished = true; continuation.resume(throwing: error) }
                    return
                }
                if let result, result.isFinal {
                    if !finished {
                        finished = true
                        continuation.resume(returning: result.bestTranscription.formattedString)
                    }
                }
            }
        }
    }

    private static func authorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    enum SpeechError: LocalizedError {
        case unavailable, offline, unauthorized

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Apple Speech recognizer unavailable for this locale."
            case .offline: return "Apple Speech is offline."
            case .unauthorized: return "Speech recognition permission not granted (System Settings → Privacy & Security → Speech Recognition)."
            }
        }
    }
}
