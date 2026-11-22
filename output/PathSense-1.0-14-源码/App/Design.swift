import SwiftUI

// The radius is the distance along an edge from the vertex to its tangent point.
struct G2Rectangle: InsettableShape {
    var radius: CGFloat
    private var insetAmount: CGFloat = 0

    init(_ radius: CGFloat) { self.radius = radius }

    func inset(by amount: CGFloat) -> Self {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard box.width > 0, box.height > 0 else { return Path() }
        let r = max(0, min(radius - insetAmount, box.width / 2, box.height / 2))
        var path = Path()
        // Each corner starts and ends with three collinear control points (zero curvature).
        // The two cubics also have equal first and second derivatives at their shared midpoint.
        func turn(from start: CGPoint, along u: CGVector, toward v: CGVector) {
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: start.x + r * (x * u.dx + y * v.dx),
                        y: start.y + r * (x * u.dy + y * v.dy))
            }
            path.addLine(to: start)
            path.addCurve(to: point(0.8, 0.2), control1: point(0.2, 0), control2: point(0.6, 0))
            path.addCurve(to: point(1, 1), control1: point(1, 0.4), control2: point(1, 0.8))
        }
        let right = CGVector(dx: 1, dy: 0), down = CGVector(dx: 0, dy: 1)
        let left = CGVector(dx: -1, dy: 0), up = CGVector(dx: 0, dy: -1)
        path.move(to: CGPoint(x: box.minX + r, y: box.minY))
        turn(from: CGPoint(x: box.maxX - r, y: box.minY), along: right, toward: down)
        turn(from: CGPoint(x: box.maxX, y: box.maxY - r), along: down, toward: left)
        turn(from: CGPoint(x: box.minX + r, y: box.maxY), along: left, toward: up)
        turn(from: CGPoint(x: box.minX, y: box.minY + r), along: up, toward: right)
        path.closeSubpath()
        return path
    }
}

enum Radius {
    static let panel: CGFloat = 32
    static let control: CGFloat = 25
}

enum Palette {
    static let page = Color(uiColor: .systemGroupedBackground)
    static let paper = Color(uiColor: .secondarySystemGroupedBackground)
    static let accent = Color(uiColor: .systemBlue)
}

extension View {
    func surface(_ color: Color, radius: CGFloat, border: Color = .clear, width: CGFloat = 1) -> some View {
        let shape = G2Rectangle(radius)
        return background(color, in: shape)
            .overlay { shape.strokeBorder(border, lineWidth: width).allowsHitTesting(false).accessibilityHidden(true) }
    }
}

/// The drawn surface follows the same curvature as the cards. Text size, focus,
/// pressed feedback, and colors follow the system appearance.
struct SignButton: ButtonStyle {
    enum Tone { case primary, secondary }
    var tone: Tone = .secondary
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline).multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity).frame(minHeight: 52)
            .foregroundStyle(tone == .primary ? Color.white : Palette.accent)
            .surface(tone == .primary ? Palette.accent : Palette.paper, radius: Radius.control)
            .contentShape(G2Rectangle(Radius.control))
            .opacity(enabled ? (configuration.isPressed ? 0.70 : 1) : 0.45)
    }
}
