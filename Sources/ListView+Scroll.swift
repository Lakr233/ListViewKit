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

public extension ListView {
    /// Scrolls until the row at `index` sits at `position`.
    func scrollToRow(at index: Int, at position: ListRowPosition, animated: Bool = true) {
        guard index >= 0, index < content.count else { return }

        let targetRect = rectForRow(at: index)
        let insets = adjustedContentInset
        let visibleMinY = contentOffset.y + insets.top
        let visibleHeight = max(0, bounds.height - insets.top - insets.bottom)
        let visibleMaxY = visibleMinY + visibleHeight
        let targetOffsetY: CGFloat = switch position {
        case .nearest:
            if targetRect.height > visibleHeight || targetRect.minY < visibleMinY {
                // Taller than the viewport, or above it: align the top.
                targetRect.minY - insets.top
            } else if targetRect.maxY <= visibleMaxY {
                contentOffset.y
            } else {
                targetRect.maxY - bounds.height + insets.bottom
            }
        case .top:
            targetRect.minY - insets.top
        case .middle:
            targetRect.midY - insets.top - visibleHeight / 2
        case .bottom:
            targetRect.maxY - bounds.height + insets.bottom
        }

        let targetOffset = nearestScrollLocationInBounds(offset: CGPoint(
            x: contentOffset.x,
            y: targetOffsetY
        ))
        if animated {
            scroll(to: targetOffset)
        } else {
            setContentOffset(targetOffset, animated: false)
        }
    }

    /// Scrolls until the row for `identifier` sits at `position`.
    func scrollToRow(with identifier: Item.ID, at position: ListRowPosition, animated: Bool = true) {
        guard let index = index(of: identifier) else { return }
        scrollToRow(at: index, at: position, animated: animated)
    }

    /// Scrolls to the end of the content.
    func scrollToBottom(animated: Bool = true) {
        if animated {
            scroll(to: maximumContentOffset)
        } else {
            setContentOffset(maximumContentOffset, animated: false)
        }
    }
}
