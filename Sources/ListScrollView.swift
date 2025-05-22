//
//  Created by ktiays on 2025/2/18.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import UIKit

open class ListScrollView: UIScrollView {
    var scrollingDisplayLink: CADisplayLink?
    var xScrollingProperty: ScrollingProperty?
    var yScrollingProperty: ScrollingProperty?

    /// The minimum point (in content view coordinates) that the view can be scrolled.
    public var minimumContentOffset: CGPoint {
        .init(x: -adjustedContentInset.left, y: -adjustedContentInset.top)
    }

    /// The maximum point (in content view coordinates) that the view can be scrolled.
    public var maximumContentOffset: CGPoint {
        let min = minimumContentOffset
        return .init(
            x: max(min.x, contentSize.width - bounds.width + adjustedContentInset.right),
            y: max(min.y, contentSize.height - bounds.height + adjustedContentInset.bottom)
        )
    }

    override open var contentSize: CGSize {
        get { super.contentSize }
        set {
            guard super.contentSize != newValue else { return }
            let currentOffset = contentOffset
            super.contentSize = newValue
            setContentOffset(currentOffset, animated: false)
            let suppose = nearestScrollLocationInBounds(offset: currentOffset)
            scroll(to: suppose, animated: true)
        }
    }

    func nearestScrollLocationInBounds(offset: CGPoint) -> CGPoint {
        let min = minimumContentOffset
        let max = maximumContentOffset
        return .init(
            x: CGFloat.minimum(CGFloat.maximum(min.x, offset.x), max.x),
            y: CGFloat.minimum(CGFloat.maximum(min.y, offset.y), max.y)
        )
    }

    /// Scrolls the position of the scroll view to the content offset you provide.
    public func scroll(to offset: CGPoint, animated: Bool = false) {
        if !animated {
            cancelCurrentScrolling()
            setContentOffset(offset, animated: false)
            return
        }

        let currentContentOffset = contentOffset
        if bounds.width > 0 {
            if var property = xScrollingProperty {
                property.target = offset.x
                xScrollingProperty = property
            } else {
                xScrollingProperty = .init(target: offset.x, current: currentContentOffset.x)
            }
        }
        if bounds.height > 0 {
            if var property = yScrollingProperty {
                property.target = offset.y
                yScrollingProperty = property
            } else {
                yScrollingProperty = .init(target: offset.y, current: currentContentOffset.y)
            }
        }

        if xScrollingProperty != nil || yScrollingProperty != nil, scrollingDisplayLink == nil {
            scrollingDisplayLink = CADisplayLink(target: self, selector: #selector(handleScrollingAnimation(_:)))
            if #available(iOS 15.0, macCatalyst 15.0, *) {
                scrollingDisplayLink?.preferredFrameRateRange = .init(minimum: 80, maximum: 120, preferred: 120)
            }
            scrollingDisplayLink?.add(to: .main, forMode: .common)
        }
    }

    /// Cancels any current scrolling animations.
    func cancelCurrentScrolling() {
        xScrollingProperty = nil
        yScrollingProperty = nil
        scrollingDisplayLink?.invalidate()
        scrollingDisplayLink = nil
    }

    @objc
    func handleScrollingAnimation(_ sender: CADisplayLink) {
        if isTracking || (xScrollingProperty == nil && yScrollingProperty == nil) {
            // if user is handling dragging or animation is finished
            sender.invalidate()
            scrollingDisplayLink = nil
            return
        }

        let time = CACurrentMediaTime()
        var targetContentOffset = contentOffset

        if var property = xScrollingProperty {
            targetContentOffset.x = property.value(at: time)
        }
        if abs(targetContentOffset.x - contentOffset.x) < 1 {
            xScrollingProperty = nil
        }

        if var property = yScrollingProperty {
            targetContentOffset.y = property.value(at: time)
        }
        if abs(targetContentOffset.y - contentOffset.y) < 1 {
            yScrollingProperty = nil
        }

        setContentOffset(targetContentOffset, animated: false)
    }
}
