//
//  ListView+API.swift
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

public extension ListView {
    var visibleRowViews: [ListRowView] {
        visibleRows.values.map(\.view)
    }

    var indicesForVisibleRows: [Int] {
        Array(rowLayout.indices(intersecting: contentVisibleRect))
    }

    /// The row view showing `identifier`, if it is on screen.
    func rowView(for identifier: Item.ID) -> ListRowView? {
        visibleRows[identifier]?.view
    }

    func rectForRow(at index: Int) -> CGRect {
        guard var frame = rowLayout.frame(for: index) else { return .zero }
        frame.origin.y += topInset
        return frame
    }

    func rectForRow(with identifier: Item.ID) -> CGRect {
        guard let index = index(of: identifier) else { return .zero }
        return rectForRow(at: index)
    }

    /// Invalidates every row height.
    ///
    /// Prefer ``invalidateLayout(forRowWith:)`` when one self-sizing row
    /// changes: keeping the other measurements is substantially cheaper for
    /// streaming or expandable content.
    func invalidateLayout() {
        rowLayout.invalidateAll()
        requestLayout()
    }

    /// Invalidates the measured height of one row.
    ///
    /// Use this when hosted or expandable content changes size without the
    /// item itself changing. The row keeps its current height as an estimate
    /// until it is measured again.
    func invalidateLayout(forRowWith identifier: Item.ID) {
        rowLayout.invalidateHeights(for: CollectionOfOne(identifier))
        requestLayout()
    }
}

/// Internal collaboration with ``ListRowLayout``.
extension ListView {
    func index(of identifier: Item.ID) -> Int? {
        indexByID[identifier]
    }

    /// Height the row at `index` should have, or nil when no registration
    /// claims its item.
    func measuredHeight(at index: Int) -> CGFloat? {
        let item = content[index]
        guard let registrationIndex = registrationIndex(for: item) else { return nil }
        let registration = registration(registrationIndex)
        let context = context(at: index, purpose: .measurement)
        if let height = registration.height {
            return height(item, context)
        }
        return selfSizingHeight(for: item, registrationIndex: registrationIndex, context: context)
    }

    func estimatedHeight(for item: Item) -> CGFloat {
        guard let index = registrationIndex(for: item) else { return estimatedRowHeight }
        return registration(index).estimatedHeight ?? estimatedRowHeight
    }
}
