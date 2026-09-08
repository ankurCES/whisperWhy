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
        // Mirror the activation modifiers from settings.
        hotkey.requireCommand = settings.hotkey.requireCommand
        hotkey.requireOption = settings.hotkey.requireOption
        hotkey.requireControl = settings.hotkey.requireControl
        hotkey.requireShift = settings.hotkey.requireShift
        notchModel.hotkeyHint = (settings.hotkey.requireCommand ? "⌘" : "") + "Fn to dictate"

        // Prompt for Accessibility the first time; without it the event tap
        // starts but never delivers flagsChanged, so ⌘Fn silently does nothing.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        do {
            try hotkey.start()
            if !trusted {
                notchModel.fail("Grant Accessibility to WhisperWhy, then relaunch — hotkey needs it")
            }
        } catch {
            notchModel.fail(error.localizedDescription)
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
        recorder.onLevel = { [weak self] level in
            // Audio thread → hop to main before touching published state.
            Task { @MainActor in self?.notchModel.feed(level: level) }
        }
        Task { @MainActor in
            guard await AudioRecorder.ensureMicPermission() else {
                notchModel.micDenied()
                return
            }
            do {
                try recorder.start()
                recordingURL = nil
                notchModel.beginRecording()
            } catch {
                notchModel.fail(error.localizedDescription)
            }
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
            hotkey.endLatch() // a latched session ends once we've pasted
            PasteService.paste(finalText)
        } catch {
            notchModel.fail(error.localizedDescription)
        }
    }

    static func defaultModelPath() -> String {
        let appSupport = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true)[0]
            + "/WhisperWhy/models"
        let candidates = [
            appSupport + "/ggml-small.en.bin",
            appSupport + "/ggml-base.en.bin",
            "models/ggml-small.en.bin", // dev layout
            "models/ggml-base.en.bin",
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
