import SwiftUI

// Root SwiftUI view hosted inside the notch panel. Renders the pill for the
// current state. Deliberately styled like codenotch: black rounded rect,
// white monochrome content, compact.

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
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 9, height: 9)
                    .modifier(PulsingModifier())
                Text(String(format: "%d:%02d", model.recordingSeconds / 60, model.recordingSeconds % 60))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                Text("listening…")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
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

// Pulsing opacity for the recording dot.
struct PulsingModifier: ViewModifier {
    @State private var on = true
    func body(content: Content) -> some View {
        content
            .opacity(on ? 1.0 : 0.25)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}
