//
//  ListView+API.swift
//  ListViewKit
//
//  Created by 秋星桥 on 5/22/25.
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
        visibleRows.values.map(\.self)
    }

    var indicesForVisibleRows: [Int] {
        Array(rowLayout.indices(intersecting: contentVisibleRect))
    }

    /// Invalidates every row height.
    ///
    /// Prefer ``invalidateLayout(forRowWithID:)`` when one self-sizing row
    /// changes: keeping the other measurements is substantially cheaper for
    /// streaming or expandable content.
    func invalidateLayout() {
        rowLayout.invalidateAll()
        requestLayout()
    }

    /// Invalidates the measured height of one row.
    ///
    /// The identifier must match the item's `Identifiable.id`, not its row
    /// kind. Unknown identifiers are ignored. The row keeps its current height
    /// as an estimate until the adapter is asked again during the next layout
    /// pass or drain.
    func invalidateLayout(forRowWithID identifier: some Hashable) {
        rowLayout.invalidateHeights(for: CollectionOfOne(AnyHashable(identifier)))
        requestLayout()
    }

    func rowView(at index: Int) -> ListRowView? {
        guard let identifier = dataSource?.itemIdentifier(at: index, in: self) else {
            return nil
        }
        return visibleRows[AnyHashable(identifier)]
    }

    func rectForRow(at index: Int) -> CGRect {
        guard var location = rowLayout.frame(for: index) else { return .zero }
        location.origin.y += topInset
        return location
    }

    func rectForRow(with identifier: some Hashable) -> CGRect {
        guard let index = dataSource?.itemIndex(for: identifier, in: self) else {
            return .zero
        }
        return rectForRow(at: index)
    }

    func reloadData() {
        visibleRows.forEach { $0.value.removeFromSuperview() }
        visibleRows.removeAll()
        removeUnusedRowsFromSuperview()
        reusableRows.removeAll()
        invalidateLayout()
    }

    internal func requestLayout() {
        #if canImport(UIKit)
            setNeedsLayout()
        #elseif canImport(AppKit)
            needsLayout = true
        #endif
    }
}
