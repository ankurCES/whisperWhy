import AppKit
import AVFoundation
import SwiftUI

// Settings window: single SwiftUI form over SettingsStore.

final class SettingsWindowController: NSWindowController {
    convenience init(store: SettingsStore) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "WhisperWhy Settings"
        window.center()
        self.init(window: window)
        window.contentView = NSHostingView(rootView: SettingsView(store: store))
    }
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var modelDownloadStatus: String?
    @State private var testStatus: TestStatus?
    @State private var micStatus: AVAudioApplication.recordPermission = AVAudioApplication.shared.recordPermission

    enum TestStatus {
        case testing, ok(String), fail(String)
    }

    var body: some View {
        Form {
            Section("Dictation Hotkey") {
                HStack {
                    Text("Trigger")
                    Spacer()
                    HotkeyRecorderButton(shortcut: $store.hotkey)
                }
                Text("Press the combo to start recording; press it again to stop, transcribe, clean up and paste. A modifier (⌘ ⌥ ⌃ ⇧) is required — Fn is the only key that works alone. Esc cancels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notch") {
                Picker("Position", selection: $store.notchPosition) {
                    ForEach(NotchPosition.allCases) { pos in
                        Text(pos.displayName).tag(pos)
                    }
                }
                Text("Where the notch pill anchors on the top edge of your screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                HStack {
                    Text("Microphone")
                    Spacer()
                    switch micStatus {
                    case .granted:
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .denied:
                        Button("Open Microphone Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                        }
                        .controlSize(.small)
                    default:
                        Button("Request Microphone Access") {
                            Task {
                                _ = await AudioRecorder.ensureMicPermission()
                                micStatus = AVAudioApplication.shared.recordPermission
                            }
                        }
                        .controlSize(.small)
                    }
                }
                if micStatus == .denied {
                    Text("Denied — macOS won't re-ask. Enable WhisperWhy in System Settings, then relaunch.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .onAppear { micStatus = AVAudioApplication.shared.recordPermission }

            Section("Transcription") {
                Picker("Engine", selection: $store.engine) {
                    ForEach(TranscriptionEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                if store.engine == .whisperCPP {
                    HStack {
                        TextField("Whisper model", text: $store.whisperModelPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Download") { downloadModel() }
                    }
                    if let status = modelDownloadStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("Language (e.g. en, auto)", text: $store.language)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Section("Cleanup LLM") {
                Toggle("Clean up transcript with LLM", isOn: $store.cleanupEnabled)
                Picker("Provider", selection: $store.llmProvider) {
                    ForEach(LLMProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                TextField("Base URL", text: $store.llmBaseURL)
                    .textFieldStyle(.roundedBorder)
                TextField("Model", text: $store.llmModel)
                    .textFieldStyle(.roundedBorder)
                if store.llmProvider == .openAICompatible {
                    SecureField("API key", text: $store.llmAPIKey)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Button(testButtonTitle) { testConnection() }
                        .disabled(testStatus != nil && isTesting)
                    if let status = testStatus {
                        testStatusView(status)
                    }
                }
            }

            Section("Cleanup Prompt — System Instructions") {
                TextEditor(text: $store.customCleanupPrompt)
                    .frame(minHeight: 80)
                    .font(.system(size: 11, design: .monospaced))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3))
                    )
                Text("System instructions the cleanup LLM follows on your speech. Leave empty to use the built-in dictation cleanup prompt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Reset to Default") { store.customCleanupPrompt = "" }
                    Spacer()
                    Text(store.customCleanupPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? "Currently: built-in default" : "Currently: custom")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Custom Vocabulary (terms & jargon)") {
                TextEditor(text: $store.customTerms)
                    .frame(minHeight: 90)
                    .font(.system(size: 11, design: .monospaced))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3))
                    )
                Text("One per line. Fix what the STT hears wrong: `what's up => WhatsApp`, `zoom call => Zoom call`, `k8s => Kubernetes`, or a bare `Kubernetes` to enforce a spelling. '#' lines are ignored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(LLMCleanupService.parseVocabulary(store.customTerms).count) term(s) active — injected into every cleanup request.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at login", isOn: $store.launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 580)
        .padding()
    }

    private var hotkeyDescription: String {
        store.hotkey.displayName
    }

    private var isTesting: Bool {
        if case .testing = testStatus { return true }
        return false
    }

    private var testButtonTitle: String {
        isTesting ? "Testing…" : "Test Connection"
    }

    @ViewBuilder
    private func testStatusView(_ status: TestStatus) -> some View {
        switch status {
        case .testing:
            ProgressView().controlSize(.small)
        case .ok(let msg):
            Label(msg, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .fail(let msg):
            Label(msg, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .lineLimit(2)
        }
    }

    private func testConnection() {
        testStatus = .testing
        let service = LLMCleanupService(
            baseURL: store.llmBaseURL,
            model: store.llmModel,
            apiKey: store.llmAPIKey,
            customPrompt: "",
            customTerms: ""
        )
        Task {
            let result = await service.testConnection()
            await MainActor.run {
                testStatus = result.ok ? .ok(result.message) : .fail(result.message)
            }
        }
    }

    private func downloadModel() {
        modelDownloadStatus = "Downloading…"
        let modelsDir = Self.modelsDirectory()
        try? FileManager.default.createDirectory(atPath: modelsDir, withIntermediateDirectories: true)
        let dest = modelsDir + "/ggml-small.en.bin"
        let url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        task.arguments = ["-fSL", "--progress-bar", "-o", dest, url]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.terminationHandler = { [weak store] _ in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                if FileManager.default.fileExists(atPath: dest) {
                    store?.whisperModelPath = dest
                    modelDownloadStatus = "Model ready: \(dest)"
                } else {
                    modelDownloadStatus = "Download failed: \(out.suffix(200))"
                }
            }
        }
        do {
            try task.run()
        } catch {
            modelDownloadStatus = "Could not start download: \(error.localizedDescription)"
        }
    }

    /// Where downloaded models live when running as an installed .app.
    static func modelsDirectory() -> String {
        NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true)[0]
            + "/WhisperWhy/models"
    }
}
