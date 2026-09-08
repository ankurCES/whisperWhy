import SwiftUI

// Root SwiftUI view hosted inside the notch panel. Renders the pill for the
// current state. Recording state shows a live equalizer driven by real mic
// RMS levels, so a working mic is always visibly different from a dead one.

struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel
    /// Called when the user taps the mic button. Wired to the same
    /// start/stop pipeline the hotkey drives.
    var onMicButton: (() -> Void)?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black)
                .shadow(color: glowColor.opacity(0.5), radius: 10, y: 0)

            content
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
        }
        .foregroundStyle(.white)
        // Spring the whole pill on every state change so the notch visibly
        // pops open when the hotkey is pressed and settles closed on release.
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: model.state)
    }

    /// Recording glows red-pink; processing glows blue; idle has no glow.
    private var glowColor: Color {
        switch model.state {
        case .recording: return .pink
        case .transcribing, .cleaning: return .blue
        case .done: return .green
        case .error: return .yellow
        case .idle: return model.accessibilityDenied ? .yellow : .clear
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            HStack(spacing: 8) {
                if model.accessibilityDenied {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.yellow)
                }
                MicButton(state: .idle, action: onMicButton)
                Text(model.accessibilityDenied ? "Hotkey blocked — grant Accessibility" : model.hotkeyHint)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }

        case .recording:
            HStack(spacing: 10) {
                MicButton(state: .recording, action: onMicButton)
                EqualizerBars(level: model.micLevel)
                Text(String(format: "%d:%02d", model.recordingSeconds / 60, model.recordingSeconds % 60))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
            }

        case .transcribing, .cleaning:
            HStack(spacing: 10) {
                ProcessingWave()
                RotatingWords()
            }
            .transition(.scale(scale: 0.9).combined(with: .opacity))

        case .done(let text):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 12))
                Text(text)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .transition(.scale(scale: 0.9).combined(with: .opacity))

        case .error(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.system(size: 12))
                Text(message)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }
}

// Colorful circular mic button — the primary affordance. Idle shows a
// gradient-filled mic icon; recording shows a pulsing red stop icon.
// Bypasses the hotkey entirely: works even without Accessibility permission.
struct MicButton: View {
    enum Mode { case idle, recording }
    let state: Mode
    let action: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        Button {
            action?()
        } label: {
            ZStack {
                Circle()
                    .fill(gradient)
                    .frame(width: 20, height: 20)
                    .shadow(color: shadowColor.opacity(0.6), radius: state == .recording ? 6 : 3)
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
            .scaleEffect(hovering ? 1.15 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(state == .recording ? "Stop recording" : "Start recording")
    }

    private var gradient: LinearGradient {
        switch state {
        case .idle:
            LinearGradient(colors: [.cyan, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .recording:
            LinearGradient(colors: [.red, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var shadowColor: Color {
        state == .recording ? .red : .purple
    }

    private var icon: String {
        state == .recording ? "stop.fill" : "mic.fill"
    }
}

// Live equalizer: 7 gradient bars whose heights combine the real mic level
// (envelope) with a per-bar sine wave (texture), so it dances even at low
// input and flatlines visibly when the mic captures nothing.
struct EqualizerBars: View {
    var level: Float
    var barCount: Int = NotchViewModel.barCount

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0 ..< barCount, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(barGradient)
                        .frame(width: 3.5, height: barHeight(index: i, time: t))
                        .shadow(color: .pink.opacity(0.45), radius: 2.5)
                        .animation(.linear(duration: 0.05), value: level)
                }
            }
        }
    }

    private var barGradient: LinearGradient {
        LinearGradient(
            colors: [.cyan, .purple, .pink],
            startPoint: .bottom, endPoint: .top
        )
    }

    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        let envelope = Double(max(level, 0.06)) // floor so silence still breathes
        let phase = Double(index) * 0.9
        let wave = 0.5 + 0.5 * sin(time * 9 + phase)          // 0...1 texture
        let pulse = 0.5 + 0.5 * sin(time * 3.3 - Double(index) * 0.4)
        let h = 4 + envelope * (10 + 12 * wave * pulse + 4 * wave)
        return CGFloat(min(h, 28))
    }
}

// Colorful rotating wave shown while whisper / the LLM is working: 5 bars
// cycling through a hue-rotating gradient, each pulsing out of phase so it
// reads as motion even before any status word appears.
struct ProcessingWave: View {
    var barCount = 5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0 ..< barCount, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(barGradient(time: t, index: i))
                        .frame(width: 3.5, height: barHeight(index: i, time: t))
                }
            }
        }
    }

    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        let phase = Double(index) * 0.85
        let wave = 0.5 + 0.5 * sin(time * 6.5 + phase)
        let h = 5 + wave * 17
        return CGFloat(h)
    }

    private func barGradient(time: TimeInterval, index: Int) -> LinearGradient {
        // Hue rotates over time; neighbouring bars offset so the colour
        // appears to travel along the wave.
        let base = (time * 0.25 + Double(index) * 0.14).truncatingRemainder(dividingBy: 1)
        let c1 = Color(hue: base, saturation: 0.85, brightness: 0.95)
        let c2 = Color(hue: (base + 0.18).truncatingRemainder(dividingBy: 1), saturation: 0.85, brightness: 1.0)
        return LinearGradient(colors: [c1, c2], startPoint: .bottom, endPoint: .top)
    }
}

// Rotating status words — "transcribing" → "cleaning up" → "polishing" —
// sliding vertically with a blur so the notch communicates progress even when
// the underlying stage doesn't change (e.g. a long whisper run).
struct RotatingWords: View {
    private let words = ["transcribing", "cleaning up", "polishing", "almost there"]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.4)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let idx = Int(elapsed / 1.4) % words.count
            Text(words[idx])
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .id(idx) // force re-render so the transition fires
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                ))
                .animation(.easeInOut(duration: 0.35), value: idx)
        }
        .frame(width: 84, alignment: .leading)
        .clipped()
    }
}
