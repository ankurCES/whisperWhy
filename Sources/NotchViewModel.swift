import Foundation
import Combine

// What the notch is showing right now.
enum NotchState: Equatable {
    case idle          // collapsed pill: app name + hotkey hint
    case recording     // red dot pulsing + elapsed time
    case transcribing  // spinner: whisper running
    case cleaning      // spinner: LLM cleanup running
    case done(String)  // flash the final text briefly
    case error(String) // flash the error briefly
}

@MainActor
final class NotchViewModel: ObservableObject {
    @Published var state: NotchState = .idle
    @Published var recordingSeconds: Int = 0
    @Published var hotkeyHint: String = "⌘Fn to dictate"

    private var ticker: AnyCancellable?

    func toggleExpanded() {
        // Phase 2+ will expand to show last transcript + copy button.
        // For now a click while idle just pulses.
    }

    func beginRecording() {
        state = .recording
        recordingSeconds = 0
        ticker?.cancel()
        ticker = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.recordingSeconds += 1 }
    }

    func endRecording() {
        ticker?.cancel()
        ticker = nil
    }

    func setTranscribing() { state = .transcribing }
    func setCleaning() { state = .cleaning }

    func finish(_ text: String) {
        show(.done(text), then: .idle)
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
