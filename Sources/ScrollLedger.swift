//
//  ScrollLedger.swift
//  ListViewKit
//

import Foundation

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#else
    #error("ListViewKit requires UIKit or AppKit")
#endif

/// How much of the offset's travel the reader actually saw.
///
/// A row animator is fed the scrolling a reader perceives, which is not the
/// same as every write to `contentOffset`. Deferred measurement shifts the
/// offset specifically so that nothing appears to move, and a clamp after a
/// content-size change is a correction rather than a scroll; feeding either
/// one in would spring the rows for a motion that never happened. A discrete
/// mouse wheel is excluded too — motion the reader did see, but stepped
/// rather than continuous, and the row effects are meant for the scrolling a
/// hand drives directly.
///
/// The classification is by exclusion rather than by enumeration. Under UIKit
/// the writes that matter most — a finger, momentum, the rubber band — happen
/// inside `UIScrollView` and never pass through this class, so there is no
/// write point to label. What can be labelled is the far smaller set of shifts
/// this package performs on purpose, and everything else is travel by default.
/// A new offset path added later is then counted rather than silently dropped,
/// which is the direction this should fail in.
struct ScrollLedger {
    /// Travel accrued since the last ``consume()``.
    private(set) var pending: CGFloat = 0
    /// Where the offset stood when it was last reconciled.
    private var reference: CGFloat = 0

    /// Attributes everything the offset has moved since the last call to
    /// perceived scrolling.
    mutating func accrue(offsetY: CGFloat) {
        pending += offsetY - reference
        reference = offsetY
    }

    /// Declares `dy` of the offset's motion to be something the reader is not
    /// meant to perceive.
    ///
    /// Order-independent by construction: it moves the reference rather than
    /// the total, so it reads the same whether it lands before or after the
    /// travel around it has been accrued.
    mutating func exclude(_ dy: CGFloat) {
        reference += dy
    }

    mutating func consume() -> CGFloat {
        defer { pending = 0 }
        return pending
    }

    /// Forgets both the pending travel and where the offset was, for when the
    /// list stops having an opinion about either.
    mutating func reset(offsetY: CGFloat) {
        pending = 0
        reference = offsetY
    }
}
