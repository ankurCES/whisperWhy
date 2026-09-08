import SwiftUI

// Root SwiftUI view hosted inside the notch panel. Renders the pill for the
// current state. Recording state shows a live equalizer driven by real mic
// RMS levels, so a working mic is always visibly different from a dead one.

struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)

            content
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
        }
        .foregroundStyle(.white)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: model.state)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .semibold))
                Text(model.hotkeyHint)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }

        case .recording:
            HStack(spacing: 10) {
                EqualizerBars(level: model.micLevel)
                Text(String(format: "%d:%02d", model.recordingSeconds / 60, model.recordingSeconds % 60))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
            }

        case .transcribing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("transcribing")
                    .font(.system(size: 12, weight: .medium))
            }

        case .cleaning:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("cleaning up")
                    .font(.system(size: 12, weight: .medium))
            }

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
        }
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
