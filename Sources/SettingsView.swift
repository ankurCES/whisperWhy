import AppKit
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

    var body: some View {
        Form {
            Section("Dictation Hotkey") {
                HStack {
                    Text("Toggle dictation")
                    Spacer()
                    Text(hotkeyDescription)
                        .foregroundStyle(.secondary)
                }
                Text("Hold Fn to talk, tap ⌘Fn to start/stop. Configurable key codes land in a later phase.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
            }

            Section("Cleanup Prompt") {
                TextEditor(text: $store.customCleanupPrompt)
                    .frame(minHeight: 80)
                    .font(.system(size: 11, design: .monospaced))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3))
                    )
                Text("Leave empty to use the built-in dictation cleanup prompt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at login", isOn: $store.launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 460)
        .padding()
    }

    private var hotkeyDescription: String {
        let mods = store.hotkey.requireCommand ? "⌘" : ""
        return "\(mods)Fn"
    }

    private func downloadModel() {
        modelDownloadStatus = "Downloading…"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        let script = FileManager.default.currentDirectoryPath + "/scripts/fetch-model.sh"
        task.arguments = [script, "small.en"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.terminationHandler = { [weak store] _ in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8) ?? ""
            let path = FileManager.default.currentDirectoryPath + "/models/ggml-small.en.bin"
            DispatchQueue.main.async {
                if FileManager.default.fileExists(atPath: path) {
                    store?.whisperModelPath = path
                    modelDownloadStatus = "Model ready: \(path)"
                } else {
                    modelDownloadStatus = "Download failed: \(out.suffix(200))"
                }
            }
        }
        try? task.run()
    }
}
