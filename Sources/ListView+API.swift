//
//  ListView+API.swift
//  ListViewKit
//
//  Created by 秋星桥 on 5/22/25.
//

import Foundation
import UIKit

public extension ListView {
    var visibleRowViews: [ListRowView] {
        visibleRows.values.map(\.self)
    }

    var indicesForVisibleRows: [Int] {
        let visibleRect = CGRect(origin: contentOffset, size: bounds.size)
        return layoutCache.allFrames()
            .filter { $0.value.intersects(visibleRect) }
            .map(\.key)
            .sorted()
    }

    func invaliateLayout() {
        layoutCache.invalidateAll()
        setNeedsLayout()
    }

    func rowView(at index: Int) -> ListRowView? {
        guard let identifier = dataSource?.itemIdentifier(at: index, in: self) else {
            return nil
        }
        return visibleRows[AnyHashable(identifier)]
    }

    func rectForRow(at index: Int) -> CGRect {
        layoutCache.frame(for: index) ?? .zero
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
        invaliateLayout()
    }
}
