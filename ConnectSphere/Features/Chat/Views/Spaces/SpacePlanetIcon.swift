import SwiftUI

/// The Spaces mark: a ringed planet 🪐 drawn in a space's colour. Apple's
/// symbol set has no planet with a ring, so it's drawn here — the ring passes
/// behind the sphere and then in front of it, with a thin cut where it
/// crosses so it still reads at 14 pt.
struct SpacePlanetIcon: View {
    let color: Color
    var size: CGFloat = 16

    var body: some View {
        Canvas { context, canvas in
            let w = canvas.width, h = canvas.height
            let center = CGPoint(x: w / 2, y: h / 2)
            let radius = w * 0.29
            let ring = Path(ellipseIn: CGRect(x: w * 0.03, y: h * 0.37, width: w * 0.94, height: h * 0.26))
            let sphere = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                width: radius * 2, height: radius * 2))
            let lineWidth = max(1.2, w * 0.085)

            /// The ring tilted, clipped to its back (top) or front (bottom) half.
            func tilted(_ draw: (inout GraphicsContext) -> Void, front: Bool) {
                var ctx = context
                ctx.translateBy(x: center.x, y: center.y)
                ctx.rotate(by: .degrees(-22))
                ctx.translateBy(x: -center.x, y: -center.y)
                ctx.clip(to: Path(CGRect(x: 0, y: front ? h / 2 : 0, width: w, height: h / 2)))
                draw(&ctx)
            }

            tilted({ $0.stroke(ring, with: .color(color), lineWidth: lineWidth) }, front: false)
            context.fill(sphere, with: .color(color))
            // Soft highlight so the sphere reads as round, not a flat dot.
            context.fill(Path(ellipseIn: CGRect(x: center.x - radius * 0.62, y: center.y - radius * 0.72,
                                                width: radius * 0.62, height: radius * 0.46)),
                         with: .color(.white.opacity(0.35)))
            // Cut where the front of the ring crosses the sphere, then the ring itself.
            tilted({ ctx in
                var onSphere = ctx
                onSphere.clip(to: sphere)
                onSphere.stroke(ring, with: .color(.white.opacity(0.85)), lineWidth: lineWidth * 2.2)
                ctx.stroke(ring, with: .color(color), lineWidth: lineWidth)
            }, front: true)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
