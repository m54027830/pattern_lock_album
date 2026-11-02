import CoreGraphics
import Foundation

nonisolated enum PatternRules {
    static let gridSize = 5
    static let supportedSizes = [3, 4, 5]
    static let minimumDots = 4
    static let dotCount = gridSize * gridSize

    static func isValid(_ nodes: [Int], gridSize: Int = 5) -> Bool {
        let dotCount = gridSize * gridSize
        return supportedSizes.contains(gridSize) && (minimumDots...dotCount).contains(nodes.count)
            && Set(nodes).count == nodes.count
            && nodes.allSatisfy { (0..<dotCount).contains($0) }
    }
}

/// Nodes are numbered left to right, then top to bottom. A crossed dot is included
/// automatically; already-used dots cannot be added to the same pattern twice.
nonisolated struct PatternPath: Equatable {
    let gridSize: Int
    private(set) var nodes: [Int] = []

    init(gridSize: Int = 5) { self.gridSize = gridSize }

    mutating func append(_ node: Int) {
        guard (0..<(gridSize * gridSize)).contains(node), !nodes.contains(node) else { return }
        if let last = nodes.last {
            let dx = node % gridSize - last % gridSize
            let dy = node / gridSize - last / gridSize
            let steps = greatestCommonDivisor(abs(dx), abs(dy))
            if steps > 1 {
                for step in 1..<steps {
                    let crossed = (last / gridSize + dy / steps * step) * gridSize + last % gridSize + dx / steps * step
                    if !nodes.contains(crossed) { nodes.append(crossed) }
                }
            }
        }
        nodes.append(node)
    }

    mutating func reset() { nodes.removeAll(keepingCapacity: false) }

    private func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var a = a, b = b
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }
}

nonisolated struct PatternGridGeometry {
    let side: CGFloat
    var gridSize = 5
    var inset: CGFloat { side * 0.085 }
    var spacing: CGFloat { (side - 2 * inset) / CGFloat(gridSize - 1) }
    var hitRadius: CGFloat { min(22, spacing * 0.32) }

    func center(_ node: Int) -> CGPoint {
        CGPoint(x: inset + CGFloat(node % gridSize) * spacing, y: inset + CGFloat(node / gridSize) * spacing)
    }

    /// Swept hit testing prevents a fast finger movement from skipping dots
    /// when the system coalesces touch updates.
    func crossedNodes(from start: CGPoint, to end: CGPoint) -> [Int] {
        let dx = end.x - start.x, dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        return (0..<(gridSize * gridSize)).compactMap { node -> (Int, CGFloat)? in
            let point = center(node)
            let projection = lengthSquared == 0 ? 0 : max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
            let nearest = CGPoint(x: start.x + projection * dx, y: start.y + projection * dy)
            let distance = hypot(point.x - nearest.x, point.y - nearest.y)
            return distance <= hitRadius ? (node, projection) : nil
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }.map(\.0)
    }
}
