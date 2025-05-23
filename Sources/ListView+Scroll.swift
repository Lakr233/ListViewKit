//
//  ListView+Scroll.swift
//  ListViewKit
//
//  Created by 秋星桥 on 5/21/25.
//

import UIKit

public extension ListView {
    /// The position in the list view (top, middle, bottom) to scroll a specified row to.
    enum ScrollPosition {
        /// The list view scrolls the row of interest to be fully visible with a minimum of movement.
        case none
        /// The list view scrolls the row of interest to the top of the visible table view.
        case top
        /// The list view scrolls the row of interest to the middle of the visible table view.
        case middle
        /// The list view scrolls the row of interest to the bottom of the visible table view.
        case bottom
    }

    /// Scrolls through the list view until a row that an index path identifies is at a particular location on the screen.
    func scrollToRow(at index: Int, at scrollPosition: ScrollPosition, animated: Bool = true) {
        let targetRect = rectForRow(at: index)
        let targetContentOffsetY: CGFloat = {
            switch scrollPosition {
            case .none:
                let visibleRect = CGRect(origin: contentOffset, size: bounds.size)
                if targetRect.height > visibleRect.height {
                    return targetRect.minY
                }

                if visibleRect.contains(targetRect) {
                    // The `targetRect` is already visible.
                    return contentOffset.y
                }

                return if targetRect.minY < visibleRect.minY {
                    // The `targetRect` is above `visibleRect`
                    targetRect.minY
                } else {
                    // The `targetRect` is below `visibleRect`
                    targetRect.maxY - bounds.height
                }
            case .top:
                return targetRect.minY
            case .middle:
                return targetRect.midY - bounds.midY
            case .bottom:
                return targetRect.maxY - bounds.height
            }
        }()
        if animated {
            scroll(to: .init(x: 0, y: targetContentOffsetY))
        } else {
            setContentOffset(.init(x: 0, y: targetContentOffsetY), animated: false)
        }
    }
}
