//
//  Created by ktiays on 2025/2/18.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import SpringInterpolation

#if canImport(UIKit)
    import UIKit

    open class ListScrollView: UIScrollView {
        var scrollingDisplayLink: CADisplayLink?
        var scrollingContext: SpringInterpolation2D = .init(
            .init(
                angularFrequency: 6,
                dampingRatio: 1,
                threshold: 0.05,
                stopWhenHitTarget: true
            )
        )
        var scrollingTik: CFTimeInterval = .init()
        private var scrollingTarget: CGPoint?

        /// The minimum point (in content view coordinates) that the view can be scrolled.
        public var minimumContentOffset: CGPoint {
            .init(x: -adjustedContentInset.left, y: -adjustedContentInset.top)
        }

        /// The maximum point (in content view coordinates) that the view can be scrolled.
        public var maximumContentOffset: CGPoint {
            let min = minimumContentOffset
            return .init(
                x: ceil(max(min.x, contentSize.width - bounds.width + adjustedContentInset.right)),
                y: ceil(max(min.y, contentSize.height - bounds.height + adjustedContentInset.bottom))
            )
        }

        override open var contentSize: CGSize {
            get { super.contentSize }
            set {
                guard super.contentSize != newValue else { return }
                let currentOffset = contentOffset
                super.contentSize = newValue
                setContentOffset(currentOffset, animated: false)
                let clampedOffset = nearestScrollLocationInBounds(offset: currentOffset)
                let clampedTarget = scrollingTarget.map { nearestScrollLocationInBounds(offset: $0) }
                if clampedOffset != currentOffset {
                    scroll(to: clampedOffset, preserveVelocity: false)
                } else if let clampedTarget, clampedTarget != scrollingTarget {
                    scroll(to: clampedTarget, preserveVelocity: false)
                } else if let clampedTarget {
                    scrollingTarget = clampedTarget
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

        /// scroll to an offset
        /// - Parameters:
        ///   - offset: where
        ///   - angularFrequency: bigger value will handle animation faster
        ///   - preserveVelocity: keep current velocity when retargeting
        public func scroll(
            to offset: CGPoint,
            angularFrequency: Double? = nil,
            preserveVelocity: Bool = true
        ) {
            let target = nearestScrollLocationInBounds(offset: offset)
            // update the context, but we need to keep the velocity
            let velocity: CGPoint = if preserveVelocity {
                .init(
                    x: scrollingContext.x.context.currentVel,
                    y: scrollingContext.y.context.currentVel
                )
            } else {
                .init(x: 0, y: 0)
            }
            scrollingContext.setCurrent(
                .init(x: ceil(contentOffset.x), y: ceil(contentOffset.y)),
                vel: .init(x: velocity.x, y: velocity.y)
            )
            if let angularFrequency {
                assert(angularFrequency > 0)
                scrollingContext.x.config.angularFrequency = angularFrequency
                scrollingContext.y.config.angularFrequency = angularFrequency
            }
            scrollingContext.setTarget(.init(x: ceil(target.x), y: ceil(target.y)))
            scrollingTarget = target

            guard scrollingDisplayLink == nil else { return }
            scrollingDisplayLink = CADisplayLink(target: self, selector: #selector(handleScrollingAnimation(_:)))
            if #available(iOS 15.0, macCatalyst 15.0, *) {
                scrollingDisplayLink?.preferredFrameRateRange = .init(minimum: 80, maximum: 120, preferred: 120)
                scrollingTik = CACurrentMediaTime()
            }
            scrollingDisplayLink?.add(to: .main, forMode: .common)
        }

        public func cancelCurrentScrolling() {
            let currentContentOffset = contentOffset
            scrollingContext.setCurrent(
                .init(x: currentContentOffset.x, y: currentContentOffset.y),
                vel: .init(x: 0, y: 0)
            )
            scrollingTarget = nil
            scrollingContext.setTarget(.init(x: currentContentOffset.x, y: currentContentOffset.y))
            scrollingDisplayLink?.invalidate()
            scrollingDisplayLink = nil
        }

        @objc func handleScrollingAnimation(_: CADisplayLink) {
            if isTracking || scrollingContext.completed {
                cancelCurrentScrolling()
                return
            }
            let time = CACurrentMediaTime()
            let delta = min(1 / 30, time - scrollingTik)
            scrollingContext.update(withDeltaTime: delta)
            let loc = nearestScrollLocationInBounds(offset: .init(
                x: scrollingContext.x.value,
                y: scrollingContext.y.value
            ))
            setContentOffset(loc, animated: false)
        }

        override open func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
            assert(!animated)
            super.setContentOffset(contentOffset, animated: false)
        }
    }

#elseif canImport(AppKit)
    import AppKit
    import MSDisplayLink

    open class ListScrollView: NSView {
        override open var isFlipped: Bool {
            true
        }

        var scrollingDisplayLink: DisplayLink?
        var scrollingContext: SpringInterpolation2D = .init(
            .init(
                angularFrequency: 6,
                dampingRatio: 1,
                threshold: 0.05,
                stopWhenHitTarget: true
            )
        )
        var scrollingTik: CFTimeInterval = .init()
        private var scrollingTarget: CGPoint?

        private var _contentOffset: CGPoint = .zero
        private var _contentSize: CGSize = .zero

        /// Whether the user is currently interacting with scroll (trackpad/mouse).
        private var _isTracking: Bool = false
        var isTracking: Bool {
            _isTracking
        }

        open var contentInsets: NSEdgeInsets = .init() {
            didSet { needsLayout = true }
        }

        var alwaysBounceVertical: Bool = true

        /// The minimum point (in content view coordinates) that the view can be scrolled.
        public var minimumContentOffset: CGPoint {
            .init(x: -contentInsets.left, y: -contentInsets.top)
        }

        /// The maximum point (in content view coordinates) that the view can be scrolled.
        public var maximumContentOffset: CGPoint {
            let min = minimumContentOffset
            return .init(
                x: ceil(max(min.x, _contentSize.width - bounds.width + contentInsets.right)),
                y: ceil(max(min.y, _contentSize.height - bounds.height + contentInsets.bottom))
            )
        }

        /// The content offset of the scroll view, analogous to UIScrollView.contentOffset.
        open var contentOffset: CGPoint {
            get { _contentOffset }
            set {
                guard _contentOffset != newValue else { return }
                _contentOffset = newValue
                needsLayout = true
            }
        }

        /// The total content size, analogous to UIScrollView.contentSize.
        open var contentSize: CGSize {
            get { _contentSize }
            set {
                guard _contentSize != newValue else { return }
                let currentOffset = contentOffset
                _contentSize = newValue
                setContentOffset(currentOffset, animated: false)
                let clampedOffset = nearestScrollLocationInBounds(offset: currentOffset)
                let clampedTarget = scrollingTarget.map { nearestScrollLocationInBounds(offset: $0) }
                if clampedOffset != currentOffset {
                    scroll(to: clampedOffset, preserveVelocity: false)
                } else if let clampedTarget, clampedTarget != scrollingTarget {
                    scroll(to: clampedTarget, preserveVelocity: false)
                } else if let clampedTarget {
                    scrollingTarget = clampedTarget
                }
            }
        }

        /// Analogous to UIScrollView.adjustedContentInset for cross-platform code.
        var adjustedContentInset: NSEdgeInsets {
            contentInsets
        }

        override public init(frame: CGRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        @available(*, unavailable)
        public required init?(coder _: NSCoder) {
            fatalError()
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

        override open func scrollWheel(with event: NSEvent) {
            if event.phase == .began || event.momentumPhase == .began {
                _isTracking = true
                cancelCurrentScrolling()
            }

            let deltaY = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10)
            let deltaX = event.scrollingDeltaX * (event.hasPreciseScrollingDeltas ? 1 : 10)

            var newOffset = contentOffset
            newOffset.x -= deltaX
            newOffset.y -= deltaY

            // Rubber-band if out of bounds
            let min = minimumContentOffset
            let max = maximumContentOffset
            if newOffset.y < min.y {
                let overscroll = min.y - newOffset.y
                newOffset.y = min.y - rubberBand(overscroll, dimension: bounds.height)
            } else if newOffset.y > max.y {
                let overscroll = newOffset.y - max.y
                newOffset.y = max.y + rubberBand(overscroll, dimension: bounds.height)
            }
            if newOffset.x < min.x {
                let overscroll = min.x - newOffset.x
                newOffset.x = min.x - rubberBand(overscroll, dimension: bounds.width)
            } else if newOffset.x > max.x {
                let overscroll = newOffset.x - max.x
                newOffset.x = max.x + rubberBand(overscroll, dimension: bounds.width)
            }

            setContentOffset(newOffset, animated: false)

            if event.phase == .ended || event.phase == .cancelled
                || event.momentumPhase == .ended || event.momentumPhase == .cancelled
            {
                _isTracking = false
                // Snap back if out of bounds
                let clamped = nearestScrollLocationInBounds(offset: contentOffset)
                if clamped != contentOffset {
                    scroll(to: clamped, preserveVelocity: false)
                }
            }
        }

        private func rubberBand(_ offset: CGFloat, dimension: CGFloat) -> CGFloat {
            let constant: CGFloat = 0.55
            return (1.0 - (1.0 / ((offset * constant / dimension) + 1.0))) * dimension
        }

        /// scroll to an offset
        /// - Parameters:
        ///   - offset: where
        ///   - angularFrequency: bigger value will handle animation faster
        ///   - preserveVelocity: keep current velocity when retargeting
        public func scroll(
            to offset: CGPoint,
            angularFrequency: Double? = nil,
            preserveVelocity: Bool = true
        ) {
            let target = nearestScrollLocationInBounds(offset: offset)
            let velocity: CGPoint = if preserveVelocity {
                .init(
                    x: scrollingContext.x.context.currentVel,
                    y: scrollingContext.y.context.currentVel
                )
            } else {
                .init(x: 0, y: 0)
            }
            scrollingContext.setCurrent(
                .init(x: ceil(contentOffset.x), y: ceil(contentOffset.y)),
                vel: .init(x: velocity.x, y: velocity.y)
            )
            if let angularFrequency {
                assert(angularFrequency > 0)
                scrollingContext.x.config.angularFrequency = angularFrequency
                scrollingContext.y.config.angularFrequency = angularFrequency
            }
            scrollingContext.setTarget(.init(x: ceil(target.x), y: ceil(target.y)))
            scrollingTarget = target

            guard scrollingDisplayLink == nil else { return }
            let link = DisplayLink()
            link.delegatingObject(self)
            scrollingDisplayLink = link
            scrollingTik = CACurrentMediaTime()
        }

        public func cancelCurrentScrolling() {
            let currentContentOffset = contentOffset
            scrollingContext.setCurrent(
                .init(x: currentContentOffset.x, y: currentContentOffset.y),
                vel: .init(x: 0, y: 0)
            )
            scrollingTarget = nil
            scrollingContext.setTarget(.init(x: currentContentOffset.x, y: currentContentOffset.y))
            scrollingDisplayLink?.delegatingObject(nil)
            scrollingDisplayLink = nil
        }

        func handleScrollingAnimation(_ context: DisplayLinkCallbackContext) {
            if isTracking || scrollingContext.completed {
                cancelCurrentScrolling()
                return
            }
            let delta = min(1 / 30, context.duration)
            scrollingContext.update(withDeltaTime: delta)
            let loc = nearestScrollLocationInBounds(offset: .init(
                x: scrollingContext.x.value,
                y: scrollingContext.y.value
            ))
            setContentOffset(loc, animated: false)
        }

        open func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
            assert(!animated)
            self.contentOffset = contentOffset
        }
    }

    extension ListScrollView: @MainActor DisplayLinkDelegate {
        public func synchronization(context: DisplayLinkCallbackContext) {
            handleScrollingAnimation(context)
        }
    }

#else
    #error("ListViewKit requires UIKit or AppKit")
#endif
