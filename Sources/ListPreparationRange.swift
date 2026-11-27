//
//  ListPreparationRange.swift
//  ListViewKit
//

import CoreGraphics

/// How far past the viewport a list keeps rows ready.
///
/// ```swift
/// list.preparationRange = .viewports(1.5)
/// ```
///
/// A list measures, builds, fills in and lays out a row in the pass that
/// brings it into view, so that frame pays for all of it. With a range, the
/// rows within that distance of the viewport are made ready beforehand, a
/// step at a time between frames, and scrolling to one only uncovers it.
/// See ``ListView/preparationRange``.
public struct ListPreparationRange: Hashable, Sendable {
    enum Extent: Hashable, Sendable {
        case points(CGFloat)
        case viewports(CGFloat)
    }

    let extent: Extent

    /// Nothing is made ready ahead of the scroll. The default.
    public static let none = ListPreparationRange(extent: .points(0))

    /// Rows within `distance` points of the viewport, above and below.
    public static func points(_ distance: CGFloat) -> ListPreparationRange {
        .init(extent: .points(distance))
    }

    /// Rows within `multiple` viewport heights of the viewport, above and
    /// below, so the range grows and shrinks with the list.
    public static func viewports(_ multiple: CGFloat) -> ListPreparationRange {
        .init(extent: .viewports(multiple))
    }

    /// The distance past a viewport of `viewportHeight`, never negative.
    /// Infinite for a range that asks for everything.
    func distance(viewportHeight: CGFloat) -> CGFloat {
        let distance = switch extent {
        case let .points(distance): distance
        case let .viewports(multiple): multiple * viewportHeight
        }
        // Also what a NaN answers, which compares false with everything.
        return distance > 0 ? distance : 0
    }
}
