import Foundation
import CoreGraphics

// MARK: - Configuration Groupings

public struct ProjectSessionWindowFrame: Codable, Sendable {
    public var originX: Double
    public var originY: Double
    public var width: Double
    public var height: Double

    public init(originX: Double, originY: Double, width: Double, height: Double) {
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
    }

    public init(rect: CGRect) {
        self.init(originX: rect.origin.x, originY: rect.origin.y, width: rect.size.width, height: rect.size.height)
    }

    public var rect: CGRect {
        CGRect(x: originX, y: originY, width: width, height: height)
    }

    private enum CodingKeys: String, CodingKey {
        case originX = "x"
        case originY = "y"
        case width
        case height
    }
}
