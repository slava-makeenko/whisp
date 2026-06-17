import SwiftUI

/// A small voice-reactive waveform: bars bounce continuously, amplitude tracks `level` (RMS).
/// With Reduce Motion the bounce is dropped — bars become a steady level meter.
struct WaveformView: View {
    var level: Float
    var tint: Color = .accentColor
    var barCount: Int = 5
    /// Peak bar height. Callers that constrain the view to a small frame should pass a
    /// matching value so loud input never overflows (the bar math is derived from this).
    var maxBarHeight: CGFloat = 30
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 3

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
        let base = max(3, maxBarHeight * 0.13)
        return HStack(spacing: spacing) {
            ForEach(0..<barCount, id: \.self) { index in
                let phase = (sin(t * 6 + Double(index) * 0.9) + 1) / 2          // 0...1
                let height = base + amplitude * (maxBarHeight - base) * (0.45 + 0.55 * CGFloat(phase))
                Capsule()
                    .fill(tint)
                    .frame(width: barWidth, height: max(3, height))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
