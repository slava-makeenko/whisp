import SwiftUI

/// A small voice-reactive waveform: bars bounce continuously, amplitude tracks `level` (RMS).
/// With Reduce Motion the bounce is dropped — bars become a steady level meter.
struct WaveformView: View {
    var level: Float
    var tint: Color = .accentColor
    var barCount: Int = 5

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let amplitude = min(CGFloat(level) * 4, 1)   // RMS is small — amplify and clamp to 0...1
        if reduceMotion {
            bars(amplitude: amplitude, t: 0)
        } else {
            TimelineView(.animation) { timeline in
                bars(amplitude: amplitude, t: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func bars(amplitude: CGFloat, t: TimeInterval) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                let phase = (sin(t * 6 + Double(index) * 0.9) + 1) / 2          // 0...1
                let height = 4 + amplitude * 26 * (0.45 + 0.55 * CGFloat(phase))
                Capsule()
                    .fill(tint)
                    .frame(width: 3, height: max(3, height))
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
