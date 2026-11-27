//
//  ListPreparationRange.swift
//  ListViewKit
//

import CoreGraphics

/// How far past the viewport a list keeps rows ready.
///
/// ```swift
/// list.preparationRange = .viewports(ahead: 3, behind: 1)
/// ```
///
/// A list measures, builds, fills in and lays out a row in the pass that
/// brings it into view, so that frame pays for all of it. With a range, the
/// rows within that distance of the viewport are made ready beforehand, a
/// step at a time between frames, and scrolling to one only uncovers it.
/// See ``ListView/preparationRange``.
public struct ListPreparationRange: Hashable, Sendable {
    enum Unit: Hashable, Sendable {
        case points
        case viewports
    }

    let unit: Unit
    let ahead: CGFloat
    let behind: CGFloat

    /// Nothing is made ready ahead of the scroll. The default.
    public static let none = ListPreparationRange(unit: .points, ahead: 0, behind: 0)

    /// Rows within `distance` points of the viewport, above and below.
    public static func points(_ distance: CGFloat) -> ListPreparationRange {
        .init(unit: .points, ahead: distance, behind: distance)
    }

    /// Rows within `multiple` viewport heights of the viewport, above and
    /// below, so the range grows and shrinks with the list.
    public static func viewports(_ multiple: CGFloat) -> ListPreparationRange {
        .init(unit: .viewports, ahead: multiple, behind: multiple)
    }

    /// Rows within `ahead` points on the side the list last scrolled
    /// towards, and `behind` on the side it came from.
    ///
    /// A reader mostly keeps going the way they were going, and the rows
    /// behind were on screen a moment ago: they only have to be kept, where
    /// the ones ahead have to be made. Until the list has scrolled, ahead is
    /// towards the end; standing at the edge it was heading for, it is the
    /// other way, the only way left to go.
    public static func points(ahead: CGFloat, behind: CGFloat) -> ListPreparationRange {
        .init(unit: .points, ahead: ahead, behind: behind)
    }

    /// The same in viewport heights. See ``points(ahead:behind:)``.
    public static func viewports(ahead: CGFloat, behind: CGFloat) -> ListPreparationRange {
        .init(unit: .viewports, ahead: ahead, behind: behind)
    }

    /// The distances past a viewport of `viewportHeight`, never negative.
    /// Infinite for a range that asks for everything.
    func reach(viewportHeight: CGFloat) -> (ahead: CGFloat, behind: CGFloat) {
        func distance(_ value: CGFloat) -> CGFloat {
            let distance = unit == .viewports ? value * viewportHeight : value
            // Also what a NaN answers, which compares false with everything.
            return distance > 0 ? distance : 0
        }
        return (distance(ahead), distance(behind))
    }

    /// Whether this asks for nothing, however it was spelled.
    var isEmpty: Bool {
        !(ahead > 0) && !(behind > 0)
    }
}
