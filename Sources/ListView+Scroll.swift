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
    func scrollToRow(at index: Int, at scrollPosition: ScrollPosition, animated: Bool) {
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
        scroll(
            to: .init(
                x: 0,
                y: min(max(minimumContentOffset.y, targetContentOffsetY), maximumContentOffset.y)
            ),
            animated: animated
        )
    }
}

// MARK: Delegate Forwarding

extension ListView: UIScrollViewDelegate {
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        _delegate?.scrollViewDidScroll?(scrollView)
        adapter?.listView(self, onEvent: .didUpdateContentOffset(offset: scrollView.contentOffset))
    }

    public func scrollViewDidZoom(_ scrollView: UIScrollView) {
        _delegate?.scrollViewDidZoom?(scrollView)
    }

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        _delegate?.scrollViewWillBeginDragging?(scrollView)
        visibleRowViews.forEach { $0.prepareForMove() }
    }

    public func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        _delegate?.scrollViewWillEndDragging?(scrollView, withVelocity: velocity, targetContentOffset: targetContentOffset)
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        _delegate?.scrollViewDidEndDragging?(scrollView, willDecelerate: decelerate)
    }

    public func scrollViewWillBeginDecelerating(_ scrollView: UIScrollView) {
        _delegate?.scrollViewWillBeginDecelerating?(scrollView)
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        _delegate?.scrollViewDidEndDecelerating?(scrollView)
    }

    public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        _delegate?.scrollViewDidEndScrollingAnimation?(scrollView)
    }

    public func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        _delegate?.viewForZooming?(in: scrollView)
    }

    public func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        _delegate?.scrollViewWillBeginZooming?(scrollView, with: view)
    }

    public func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        _delegate?.scrollViewDidEndZooming?(scrollView, with: view, atScale: scale)
    }

    public func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        _delegate?.scrollViewShouldScrollToTop?(scrollView) ?? true
    }

    public func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        _delegate?.scrollViewDidScrollToTop?(scrollView)
    }

    public func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) {
        _delegate?.scrollViewDidChangeAdjustedContentInset?(scrollView)
    }
}
