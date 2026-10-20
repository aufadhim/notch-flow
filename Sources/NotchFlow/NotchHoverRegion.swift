import Foundation

enum NotchHoverRegion {
    static func contains(_ point: CGPoint, in rect: CGRect) -> Bool {
        // CGRect.contains excludes its maximum edges. The screen's top edge
        // must remain active, including the physical camera cutout.
        point.x >= rect.minX && point.x <= rect.maxX &&
            point.y >= rect.minY && point.y <= rect.maxY
    }
}
