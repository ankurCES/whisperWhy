import SwiftUI

// Root SwiftUI view hosted inside the notch panel.
//
// Idle shows ONLY the logo (no text) — a wave-circle with an S-curve drawn
// through it, echoing the sample logo's flowing waveform, as an animated
// vector (stroke-draw) gradient glyph. Clicking the logo starts dictation.
// Recording shows the live equalizer; processing shows the wave + rotating
// status words; completion is signalled with an animated checkmark — the
// transcript itself is never displayed, it just goes to the paste target.

struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel
    /// Vertical layout (left/right screen edges): content stacks top-to-bottom.
    var vertical: Bool = false
    /// Called when the user taps the logo/button. Wired to the same
    /// start/stop pipeline the hotkey drives.
    var onMicButton: (() -> Void)?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black)
                .shadow(color: glowColor.opacity(0.5), radius: 10, y: 0)

            content
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
        .foregroundStyle(.white)
        // Spring the whole pill on every state change so the notch visibly
        // pops open when dictation starts and settles closed when it ends.
        // The same spring also fires when the anchor flips the layout
        // (vertical ↔ horizontal), so changing position in Settings glides.
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: model.state)
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: vertical)
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
        if vertical {
            VStack(spacing: 10) { contentPieces }
        } else {
            HStack(spacing: 10) { contentPieces }
        }
    }

    @ViewBuilder
    private var contentPieces: some View {
        switch model.state {
        case .idle:
            // Centered logo + engine wordmark.
            LogoButton(state: .idle, denied: model.accessibilityDenied, action: onMicButton)
            Wordmark(vertical: vertical)

        case .recording:
            LogoButton(state: .recording, denied: false, action: onMicButton)
            EqualizerBars(level: model.micLevel, vertical: vertical)
            Text(String(format: "%d:%02d", model.recordingSeconds / 60, model.recordingSeconds % 60))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                .rotationEffect(vertical ? .degrees(90) : .degrees(0))

        case .transcribing, .cleaning:
            ProcessingWave(vertical: vertical)
            RotatingWords(vertical: vertical)
                .transition(.scale(scale: 0.9).combined(with: .opacity))

        case .done:
            // Success: animated checkmark draw, no transcript text.
            CompletionMark()
                .transition(.scale(scale: 0.7).combined(with: .opacity))

        case .error(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 11))
            Text(message)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

// MARK: - Logo

/// The WhisperWhy mark: a circular wave with an S-curve flowing through it,
/// drawn from the sample logo's geometry. Idle renders as a static gradient
/// glyph; tap it to dictate. Recording switches it to a pulsing red stop.
struct LogoButton: View {
    enum Mode { case idle, recording }
    let state: Mode
    let denied: Bool
    let action: (() -> Void)?

    @State private var hovering = false
    @State private var appeared = false

    var body: some View {
        Button {
            action?()
        } label: {
            ZStack {
                LogoMark(drawn: appeared)
                    .frame(width: 22, height: 22)
                    .shadow(color: shadowColor.opacity(0.55), radius: state == .recording ? 6 : 3)
                if state == .recording {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(.white)
                        .frame(width: 8, height: 8)
                }
                if denied {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.yellow)
                        .offset(x: 10, y: -9)
                }
            }
            .scaleEffect(hovering ? 1.14 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9)) { appeared = true }
        }
        .help(state == .recording ? "Stop dictation" : "Start dictation")
    }

    private var shadowColor: Color {
        state == .recording ? .red : .cyan
    }
}

/// Engine wordmark beside the logo — identifies the speech engine.
struct Wordmark: View {
    var vertical: Bool = false
    @State private var shimmer = false

    var body: some View {
        Text("WhisperWhy")
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .foregroundStyle(
                LinearGradient(
                    colors: [.white.opacity(0.92), .white.opacity(0.55), .white.opacity(0.92)],
                    startPoint: shimmer ? .leading : .trailing,
                    endPoint: shimmer ? .trailing : .leading
                )
            )
            .tracking(0.3)
            .fixedSize()
            .rotationEffect(vertical ? .degrees(90) : .degrees(0))
            .onAppear {
                withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
                    shimmer = true
                }
            }
    }
}

/// Vector logo: a mic-waveform mark — a vertical "voice bar" cluster inside a
/// gradient ring, continuously animated: the bars breathe with a traveling
/// sine wave and the ring's gradient rotates. `drawn` animates the stroke-in
/// on first appear.
struct LogoMark: View {
    var drawn: Bool
    private let barCount = 5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle()
                    .trim(from: 0, to: drawn ? 1 : 0)
                    .stroke(
                        AngularGradient(
                            colors: [.cyan, .blue, .purple, .pink, .cyan],
                            center: .center,
                            startAngle: .degrees(t * 40),
                            endAngle: .degrees(t * 40 + 360)
                        ),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                HStack(spacing: 1.8) {
                    ForEach(0 ..< barCount, id: \.self) { i in
                        let centerBias = 1.0 - abs(Double(i) - 2.0) / 2.5   // taller in middle
                        let wave = 0.5 + 0.5 * sin(t * 2.6 + Double(i) * 0.9)
                        let h = 4 + 9 * centerBias * (0.35 + 0.65 * wave)
                        Capsule()
                            .fill(barGradient(hue: (t * 0.12 + Double(i) / Double(barCount)).truncatingRemainder(dividingBy: 1)))
                            .frame(width: 2.2, height: CGFloat(h))
                    }
                }
            }
        }
    }

    private func barGradient(hue: Double) -> LinearGradient {
        let c1 = Color(hue: hue, saturation: 0.8, brightness: 1.0)
        let c2 = Color(hue: (hue + 0.2).truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 1.0)
        return LinearGradient(colors: [c1, c2], startPoint: .bottom, endPoint: .top)
    }
}



/// Animated success checkmark — strokes draw in, glow pulse, then fade out
/// is handled by the state timer in the view model.
struct CompletionMark: View {
    @State private var drawn = false

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(
                    LinearGradient(colors: [.green, .mint], startPoint: .top, endPoint: .bottom),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
            CheckShape()
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(Color.green, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 20, height: 20)
        .shadow(color: .green.opacity(0.6), radius: drawn ? 5 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.45)) { drawn = true }
        }
    }
}

struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.width * 0.22, y: rect.height * 0.54))
        p.addLine(to: CGPoint(x: rect.width * 0.44, y: rect.height * 0.74))
        p.addLine(to: CGPoint(x: rect.width * 0.78, y: rect.height * 0.30))
        return p
    }
}

// MARK: - Recording equalizer

// Live equalizer: 7 gradient bars whose heights combine the real mic level
// (envelope) with a per-bar sine wave (texture), so it dances even at low
// input and flatlines visibly when the mic captures nothing.
struct EqualizerBars: View {
    var level: Float
    var vertical: Bool = false
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
            .rotationEffect(vertical ? .degrees(-90) : .degrees(0))
        }
    }

    private var barGradient: LinearGradient {
        LinearGradient(
            colors: [.cyan, .purple, .pink],
            startPoint: .bottom, endPoint: .top
        )
    }

    private func barHeight(index: Int, time t: TimeInterval) -> CGFloat {
        let base = CGFloat(4 + 18 * min(1, level * 3))
        let wave = (sin(t * 5.0 + Double(index) * 0.9) + 1) / 2 // 0...1
        let envelope = 0.35 + 0.65 * CGFloat(wave)
        return max(3, base * envelope)
    }
}

// MARK: - Processing

// Colorful processing wave — 5 bars pulsing out of phase, hue continuously
// rotating so the color appears to travel along the wave. Shows while the
// pipeline (whisper + LLM) is running.
struct ProcessingWave: View {
    var vertical: Bool = false
    private let barCount = 5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0 ..< barCount, id: \.self) { i in
                    let phase = Double(i) * 0.7
                    let h = 6 + 14 * (0.5 + 0.5 * sin(t * 4.2 + phase))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barGradient(hue: (t * 0.25 + Double(i) / Double(barCount)).truncatingRemainder(dividingBy: 1)))
                        .frame(width: 4, height: CGFloat(h))
                }
            }
            .rotationEffect(vertical ? .degrees(-90) : .degrees(0))
        }
    }

    private func barGradient(hue: Double) -> LinearGradient {
        let c1 = Color(hue: hue, saturation: 0.85, brightness: 1.0)
        let c2 = Color(hue: (hue + 0.18).truncatingRemainder(dividingBy: 1), saturation: 0.85, brightness: 1.0)
        return LinearGradient(colors: [c1, c2], startPoint: .bottom, endPoint: .top)
    }
}

// Rotating status words — "transcribing" → "cleaning up" → "polishing" —
// sliding vertically so the notch communicates progress even when the
// underlying stage doesn't change (e.g. a long whisper run).
struct RotatingWords: View {
    var vertical: Bool = false
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
                    insertion: .move(edge: vertical ? .trailing : .bottom).combined(with: .opacity),
                    removal: .move(edge: vertical ? .leading : .top).combined(with: .opacity)
                ))
                .animation(.easeInOut(duration: 0.35), value: idx)
        }
        .frame(width: vertical ? nil : 84, height: vertical ? 90 : nil, alignment: vertical ? .center : .leading)
        .clipped()
    }
}
