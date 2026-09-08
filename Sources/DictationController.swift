import Foundation
import AppKit

// Orchestrates the dictation pipeline:
// hotkey → record → transcribe → (optional) LLM cleanup → paste at cursor.
// Owns AudioRecorder + HotkeyManager, drives the notch view model.

@MainActor
final class DictationController: NSObject, ObservableObject {
    private let recorder = AudioRecorder()
    private let hotkey = HotkeyManager()
    let notchModel = NotchViewModel()
    private var settings: SettingsStore
    private var recordingURL: URL?
    private var task: Task<Void, Never>?
    private var cancelled = false

    init(settings: SettingsStore) {
        self.settings = settings
        super.init()
    }

    func start() {
        hotkey.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        do {
            try hotkey.start()
        } catch {
            notchModel.fail("Hotkey unavailable: grant Accessibility + Input Monitoring")
        }
    }

    func shutdown() {
        hotkey.stop()
        task?.cancel()
    }

    private func handle(_ event: ShortcutEvent) {
        switch event {
        case .startHold:
            beginRecording()
        case .endHold:
            finishRecording()
        case .toggle:
            break // latching state is tracked inside HotkeyManager
        }
    }

    private func beginRecording() {
        guard task == nil else { return } // ignore double-press
        cancelled = false
        do {
            try recorder.start()
            recordingURL = nil
            notchModel.beginRecording()
        } catch {
            notchModel.fail(error.localizedDescription)
        }
    }

    private func finishRecording() {
        guard task == nil else { return }
        notchModel.endRecording()
        guard let url = recorder.stop() else {
            notchModel.fail("No audio captured")
            return
        }
        recordingURL = url
        let settings = self.settings
        task = Task { [weak self] in
            await self?.runPipeline(url: url, settings: settings)
            self?.task = nil
        }
    }

    /// Esc / error path: drop the recording without transcribing.
    func cancelRecording() {
        cancelled = true
        _ = recorder.stop()
        notchModel.endRecording()
        notchModel.finish("cancelled")
    }

    // MARK: - Pipeline

    private func runPipeline(url: URL, settings: SettingsStore) async {
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            notchModel.setTranscribing()
            let engine = settings.engine
            let raw: String
            switch engine {
            case .whisperCPP:
                #if canImport(whisper)
                let modelPath = settings.whisperModelPath.isEmpty
                    ? Self.defaultModelPath() : settings.whisperModelPath
                raw = try WhisperSTT.transcribe(
                    wavURL: url, modelPath: modelPath, language: settings.language
                )
                #else
                throw WhisperUnavailable()
                #endif
            case .appleSpeech:
                raw = try await AppleSpeechService().transcribe(url: url, language: settings.language)
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                notchModel.fail("Heard nothing")
                return
            }

            var finalText = TranscriptCore.finalize(trimmed)
            if settings.cleanupEnabled {
                notchModel.setCleaning()
                let service = LLMCleanupService(
                    baseURL: settings.llmBaseURL,
                    model: settings.llmModel,
                    apiKey: settings.llmAPIKey,
                    customPrompt: settings.customCleanupPrompt
                )
                let cleaned = try await service.clean(trimmed)
                if !cleaned.isEmpty { finalText = TranscriptCore.finalize(cleaned) }
            }

            guard !cancelled else { return }
            notchModel.finish(finalText)
            PasteService.paste(finalText)
        } catch {
            notchModel.fail(error.localizedDescription)
        }
    }

    static func defaultModelPath() -> String {
        let candidates = [
            "models/ggml-base.en.bin", // dev layout
            (NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true)[0]
                + "/WhisperWhy/models/ggml-base.en.bin"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
            ?? candidates[0]
    }

    struct WhisperUnavailable: LocalizedError {
        var errorDescription: String? {
            "whisper.cpp engine is not built into this binary. Run `make whisper` and rebuild."
        }
    }
}
