import Foundation
import Combine

// What the notch is showing right now.
enum NotchState: Equatable {
    case idle          // collapsed pill: app name + hotkey hint
    case recording     // red dot pulsing + elapsed time
    case transcribing  // spinner: whisper running
    case cleaning      // spinner: LLM cleanup running
    case done          // flash success briefly — the transcript is pasted,
                       // never displayed in the notch
    case error(String) // flash the error briefly
}

@MainActor
final class NotchViewModel: ObservableObject {
    @Published var state: NotchState = .idle
    @Published var recordingSeconds: Int = 0
    @Published var hotkeyHint: String = "⌘Fn to dictate"
    /// Live mic RMS 0...1, for the equalizer bars.
    @Published var micLevel: Float = 0
    /// False while a mic-permission problem is being shown.
    @Published var micPermissionDenied = false
    /// False while Accessibility (hotkey-listening) permission is missing.
    @Published var accessibilityDenied = false

    private var ticker: AnyCancellable?
    private var lastLevelAt = Date.distantPast
    private var levelAccumulator: Float = 0
    private var levelSamples = 0

    /// Number of equalizer bars the view renders.
    static let barCount = 7

    func toggleExpanded() {
        // Phase 2+ will expand to show last transcript + copy button.
        // For now a click while idle just pulses.
    }

    func beginRecording() {
        state = .recording
        recordingSeconds = 0
        micLevel = 0
        micPermissionDenied = false
        levelAccumulator = 0
        levelSamples = 0
        ticker?.cancel()
        ticker = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.recordingSeconds += 1 }
    }

    func endRecording() {
        ticker?.cancel()
        ticker = nil
        micLevel = 0
    }

    /// Called from the audio thread at ~10 Hz; batched so SwiftUI re-renders
    /// ~15×/s instead of per audio callback.
    func feed(level: Float) {
        levelAccumulator = max(levelAccumulator, level)
        levelSamples += 1
        let now = Date()
        guard now.timeIntervalSince(lastLevelAt) >= 0.065 else { return }
        lastLevelAt = now
        micLevel = levelAccumulator
        levelAccumulator = 0
        levelSamples = 0
    }

    func micDenied() {
        endRecording()
        micPermissionDenied = true
        state = .error("Mic access denied — enable WhisperWhy in System Settings → Privacy → Microphone")
    }

    func setTranscribing() { state = .transcribing }
    func setCleaning() { state = .cleaning }

    func finish(_ text: String) {
        _ = text // transcript is pasted, not shown
        show(.done, then: .idle)
    }

    func fail(_ message: String) {
        show(.error(message), then: .idle)
    }

    private func show(_ transient: NotchState, then final: NotchState) {
        state = transient
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self, self.state.isTransient else { return }
            self.state = final
        }
    }
}

extension NotchState {
    var isTransient: Bool {
        if case .done = self { return true }
        if case .error = self { return true }
        return false
    }
}
