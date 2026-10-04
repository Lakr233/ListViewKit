//
//  ListView+Scroll.swift
//  ListViewKit
//
//  Created by 秋星桥 on 5/21/25.
//

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#else
    #error("ListViewKit requires UIKit or AppKit")
#endif

/// Where a row should end up when the list scrolls to it.
public enum ListRowPosition {
    /// Fully visible, with as little movement as possible.
    case nearest
    case top
    case middle
    case bottom
}

/// What an animated scroll was asked to reach, kept in those terms rather
/// than as an offset.
///
/// The offset is only as good as the heights it was computed from, and most
/// of those are estimates until the scroll passes them. Rows measured on the
/// way move the destination, so it is resolved again after every layout pass
/// for as long as the scroll that set out for it is still running.
struct ListScrollDestination<ID: Hashable> {
    enum Place {
        /// Never `.nearest`, which is resolved once, against the offset the
        /// scroll started from: asked again mid-flight it would answer for
        /// wherever the scroll happens to be.
        case row(ID, ListRowPosition)
        case bottom
    }

    let place: Place
    /// ``ListScrollView/scrollingSerial`` of the scroll carrying the list
    /// there. Any other value means the scroll ended or someone else's
    /// started, and the destination is no longer anyone's.
    let serial: UInt
}

extension ListView {
    /// Points the scroll in flight at where its destination is now.
    ///
    /// Called at the end of the measurement in every layout pass. A
    /// compensation moves the target together with the content, so this only
    /// ever changes anything when a row between the viewport and the
    /// destination was measured, which is exactly the case compensation
    /// leaves alone. The spring keeps its velocity and its pace.
    func retargetScrollDestination() {
        guard let destination = scrollDestination else { return }
        guard destination.serial == scrollingSerial else {
            scrollDestination = nil
            return
        }
        switch destination.place {
        case let .row(identifier, position):
            guard let index = index(of: identifier) else {
                // The row is gone; the scroll finishes where it was going.
                scrollDestination = nil
                return
            }
            retargetScrolling(to: offset(showingRowAt: index, at: position))
        case .bottom:
            retargetScrolling(to: maximumContentOffset)
        }
    }

    /// Turns `.nearest` into the edge the row will be aligned to, or `nil`
    /// when it is already fully visible and nothing should move. Every other
    /// position is returned as it is.
    func resolvedPlacement(ofRowAt index: Int, at position: ListRowPosition) -> ListRowPosition? {
        guard position == .nearest else { return position }
        let targetRect = rectForRow(at: index)
        let insets = adjustedContentInset
        let visibleMinY = contentOffset.y + insets.top
        let visibleHeight = max(0, bounds.height - insets.top - insets.bottom)
        if targetRect.height > visibleHeight || targetRect.minY < visibleMinY {
            // Taller than the viewport, or above it: align the top.
            return .top
        }
        if targetRect.maxY <= visibleMinY + visibleHeight {
            return nil
        }
        return .bottom
    }

    func offset(showingRowAt index: Int, at position: ListRowPosition) -> CGPoint {
        let targetRect = rectForRow(at: index)
        let insets = adjustedContentInset
        let visibleHeight = max(0, bounds.height - insets.top - insets.bottom)
        let targetOffsetY: CGFloat = switch position {
        case .nearest, .top:
            targetRect.minY - insets.top
        case .middle:
            targetRect.midY - insets.top - visibleHeight / 2
        case .bottom:
            targetRect.maxY - bounds.height + insets.bottom
        }
        return nearestScrollLocationInBounds(offset: CGPoint(
            x: contentOffset.x,
            y: targetOffsetY
        ))
    }
}
