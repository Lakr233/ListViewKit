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
        let offset = contentOffset
        let visibleRect = CGRect(
            origin: .init(x: offset.x, y: offset.y - topInset),
            size: bounds.size
        )
        return layoutCache.indices(intersecting: visibleRect)
    }

    /// Invalidates every cached row height and frame.
    ///
    /// Prefer ``invalidateLayout(forRowWithID:)`` when one self-sizing row
    /// changes. Keeping the remaining identity-based height cache intact is
    /// substantially cheaper for streaming or expandable content.
    func invalidateLayout() {
        layoutCache.invalidateAll()
        requestLayout()
    }

    /// Invalidates the cached height and all dependent frames for one row.
    ///
    /// The identifier must match the item's `Identifiable.id`, not its row
    /// kind. Unknown identifiers are ignored. The adapter's height closure is
    /// called again, and the new frames are installed during the next layout
    /// pass.
    func invalidateLayout(forRowWithID identifier: some Hashable) {
        guard dataSource?.itemIndex(for: identifier, in: self) != nil else {
            return
        }
        let identifiers = CollectionOfOne(identifier)
        if !layoutCache.invalidateHeights(for: identifiers) {
            layoutCache.requestInvalidateHeights(for: identifiers)
        }
        requestLayout()
    }

    @available(*, deprecated, renamed: "invalidateLayout()")
    func invaliateLayout() {
        invalidateLayout()
    }

    func rowView(at index: Int) -> ListRowView? {
        guard let identifier = dataSource?.itemIdentifier(at: index, in: self) else {
            return nil
        }
        return visibleRows[AnyHashable(identifier)]
    }

    func rectForRow(at index: Int) -> CGRect {
        if var location = layoutCache.frame(for: index) {
            location.origin.y += topInset
            return location
        }
        return .zero
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
