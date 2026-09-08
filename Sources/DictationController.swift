import Foundation
import AppKit
import AVFoundation

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
        applyShortcut()

        // Diagnose the mic at launch so problems surface in the notch before
        // the first dictation attempt. This is the missing piece behind
        // "I don't see mic permissions requested": if the TCC row exists but
        // is set to denied (e.g. from a stale debug build), the OS prompt
        // never appears and the engine silently captures silence. We log the
        // exact state so it shows up in `log show`.
        diagnoseMic()

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

    /// Re-reads the shortcut from settings and pushes it to the hotkey manager.
    /// Called at launch and whenever Settings saves a new hotkey.
    func applyShortcut() {
        hotkey.requireCommand = settings.hotkey.requireCommand
        hotkey.requireOption = settings.hotkey.requireOption
        hotkey.requireControl = settings.hotkey.requireControl
        hotkey.requireShift = settings.hotkey.requireShift
        hotkey.setTriggerKeyCode(CGKeyCode(settings.hotkey.keyCode))
        notchModel.hotkeyHint = settings.hotkey.displayName + " to dictate"
    }

    func shutdown() {
        hotkey.stop()
        task?.cancel()
    }

    /// Logs the exact mic permission + input-device state at launch. Answers
    /// "why is there no prompt?" — if the TCC row already says denied (e.g. a
    /// stale debug build), macOS never re-prompts and the engine captures
    /// silence. We surface that in the notch instead of looking dead.
    private func diagnoseMic() {
        let perm = AVCaptureDevice.authorizationStatus(for: .audio)
        let inputAvailable = AVCaptureDevice.default(for: .audio) != nil
        NSLog("WhisperWhy mic: permission=%ld inputDevice=%@",
              perm.rawValue, inputAvailable ? "yes" : "NO")
        if perm == .denied || perm == .restricted {
            notchModel.fail("Mic denied in System Settings → Privacy → Microphone. Enable WhisperWhy, then relaunch.")
        } else if !inputAvailable {
            notchModel.fail("No input device — check your mic / call audio settings.")
        }
    }

    private func handle(_ event: ShortcutEvent) {
        switch event {
        case .startHold:
            beginRecording()
        case .endHold:
            finishRecording()
        case .cancel:
            cancelRecording()
        case .toggle:
            break
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
