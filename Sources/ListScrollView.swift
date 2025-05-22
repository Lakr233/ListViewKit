//
//  Created by ktiays on 2025/2/18.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import SpringInterpolation
import UIKit

open class ListScrollView: UIScrollView {
    var scrollingDisplayLink: CADisplayLink?
    var scrollingContext: SpringInterpolation2D = .init(
        .init(
            angularFrequency: 8,
            dampingRatio: 1,
            threshold: 1,
            stopWhenHitTarget: true
        )
    )
    var scrollingTik: CFTimeInterval = .init()

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
            if !isContentOffsetWithinBounds(offset: currentOffset) {
                let suppose = nearestScrollLocationInBounds(offset: currentOffset)
                scroll(to: suppose)
            }
        }
    }

    override open var contentOffset: CGPoint {
        get { super.contentOffset }
        set {
            guard super.contentOffset != newValue else { return }
            super.contentOffset = newValue
        }
    }

    func isContentOffsetWithinBounds(offset: CGPoint) -> Bool {
        let min = minimumContentOffset
        let max = maximumContentOffset
        return true
            && offset.x >= min.x && offset.x <= max.x
            && offset.y >= min.y && offset.y <= max.y
    }

    func nearestScrollLocationInBounds(offset: CGPoint) -> CGPoint {
        let min = minimumContentOffset
        let max = maximumContentOffset
        return .init(
            x: CGFloat.minimum(CGFloat.maximum(min.x, offset.x), max.x),
            y: CGFloat.minimum(CGFloat.maximum(min.y, offset.y), max.y)
        )
    }

    public func scroll(to offset: CGPoint) {
        // update the context, but we need to keep the velocity
        scrollingContext.setCurrent(
            .init(x: contentOffset.x, y: contentOffset.y),
            vel: .init(
                x: scrollingContext.x.context.currentVel,
                y: scrollingContext.y.context.currentVel
            )
        )
        scrollingContext.setTarget(.init(x: offset.x, y: offset.y))

        guard scrollingDisplayLink == nil else { return }
        scrollingDisplayLink = CADisplayLink(target: self, selector: #selector(handleScrollingAnimation(_:)))
        if #available(iOS 15.0, macCatalyst 15.0, *) {
            scrollingDisplayLink?.preferredFrameRateRange = .init(minimum: 80, maximum: 120, preferred: 120)
            scrollingTik = CACurrentMediaTime()
        }
        scrollingDisplayLink?.add(to: .main, forMode: .common)
    }

    func cancelCurrentScrolling() {
        let currentContentOffset = contentOffset
        scrollingContext.setCurrent(
            .init(x: currentContentOffset.x, y: currentContentOffset.y),
            vel: .init(x: 0, y: 0)
        )
        scrollingContext.setTarget(.init(x: 0, y: 0))
        scrollingDisplayLink?.invalidate()
        scrollingDisplayLink = nil
    }

    @objc
    func handleScrollingAnimation(_: CADisplayLink) {
        if isTracking || scrollingContext.completed {
            cancelCurrentScrolling()
            return
        }
        let time = CACurrentMediaTime()
        let delta = min(1 / 30, time - scrollingTik)
        scrollingContext.update(withDeltaTime: delta)
        let loc = CGPoint(
            x: scrollingContext.x.value,
            y: scrollingContext.y.value
        )
        setContentOffset(loc, animated: false)
    }

    override open func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        assert(!animated)
        super.setContentOffset(contentOffset, animated: false)
    }
}
