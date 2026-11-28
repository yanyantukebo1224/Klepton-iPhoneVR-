import SwiftUI
import PopinVRTracking

/// Debug visualization of MediaPipe's 2D image-space landmarks.
/// This deliberately does not pretend hand-local 3D landmarks are world-space.
struct PopinVRHandOverlay: View {
    let frame: PopinVRTrackingFrame?

    private let bones: [(Int, Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 4),
        (0, 5), (5, 6), (6, 7), (7, 8),
        (5, 9), (9, 10), (10, 11), (11, 12),
        (9, 13), (13, 14), (14, 15), (15, 16),
        (13, 17), (17, 18), (18, 19), (19, 20),
        (0, 17)
    ]

    var body: some View {
        Canvas { context, size in
            guard let frame else { return }

            for hand in frame.hands {
                let color: Color
                switch hand.side {
                case .left: color = .cyan
                case .right: color = .orange
                case .unknown: color = .white
                }

                let points = hand.joints.map {
                    CGPoint(
                        x: CGFloat($0.x) * size.width,
                        y: CGFloat($0.y) * size.height
                    )
                }

                for (start, end) in bones where start < points.count && end < points.count {
                    let a = hand.joints[start]
                    let b = hand.joints[end]
                    guard a.confidence > 0.05, b.confidence > 0.05 else { continue }
                    var path = Path()
                    path.move(to: points[start])
                    path.addLine(to: points[end])
                    context.stroke(path, with: .color(color.opacity(0.85)), lineWidth: 3)
                }

                for (index, point) in points.enumerated() {
                    guard hand.joints[index].confidence > 0.05 else { continue }
                    let radius: CGFloat = index == 0 ? 6 : 4
                    let dot = Path(ellipseIn: CGRect(
                        x: point.x - radius,
                        y: point.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    ))
                    context.fill(dot, with: .color(color))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityLabel("Live hand landmark overlay")
    }
}
