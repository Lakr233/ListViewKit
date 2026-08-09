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

        /// While set, an offset that a content-size change pushed out of
        /// bounds travels to its new home instead of snapping there. A caller
        /// animating its rows has to move the viewport along with them, or the
        /// correction reads as a jump in the middle of the animation.
        var animatesContentSizeCorrection = false

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
                if super.contentSize != newValue {
                    let currentOffset = contentOffset
                    // Shrinking the content makes UIScrollView pull the offset
                    // back in by itself. That is a clamp, not a scroll, and
                    // inside a caller's block it would animate as one.
                    withoutListAnimation { super.contentSize = newValue }
                    applyContentOffset(currentOffset)
                }
                reconcileOffsetWithContentSize()
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

        /// Puts the offset back in bounds at the end of a layout pass. It runs
        /// even when the size is unchanged: a row shrinking above the anchor
        /// and one growing below it cancel out in the total while the offset
        /// still moved, and nothing else would notice it left the bounds.
        ///
        /// Whether the offset may sit outside the bounds is a question about
        /// who owns it, not about the offset itself: deferred measurement
        /// routinely shifts it past an edge on its way to the right place.
        private func reconcileOffsetWithContentSize() {
            // A finger, momentum or a rebound already owns the offset. Those
            // either clamp themselves every frame or are holding a deliberate
            // overscroll, and interrupting one cancels the bounce.
            guard !isUserInteractingWithScroll else { return }
            if let target = scrollingTarget {
                // A programmatic scroll keeps running, retargeted onto the new
                // edge so it lands there instead of short of it.
                let clamped = nearestScrollLocationInBounds(offset: target)
                if clamped != target {
                    scroll(to: clamped)
                }
                return
            }
            let clamped = nearestScrollLocationInBounds(offset: contentOffset)
            guard clamped != contentOffset else { return }
            if animatesContentSizeCorrection {
                scroll(to: clamped, preserveVelocity: false)
            } else {
                // Deferred measurement resizes the content over and over, so
                // an idle list lands on the new edge outright: animating every
                // correction restarts the slide on each pass and reads as the
                // list scrolling by itself.
                applyContentOffset(clamped)
            }
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
            scrollingDisplayLink?.preferredFrameRateRange = .init(minimum: 80, maximum: 120, preferred: 120)
            scrollingTik = CACurrentMediaTime()
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

        /// Shifts the current offset and any in-flight programmatic scroll by
        /// `dy` without cancelling it. Deferred height correction uses this so
        /// rows above the viewport can change size while visible rows stay
        /// visually stationary.
        func compensateScrollOffset(by dy: CGFloat) {
            guard dy != 0 else { return }
            // The whole point of this shift is that the reader cannot see it.
            // Animating it is exactly how it becomes visible.
            withoutListAnimation { super.contentOffset.y += dy }
            if var target = scrollingTarget {
                target.y += dy
                scrollingTarget = target
                scrollingContext.setCurrent(
                    .init(x: scrollingContext.x.value, y: scrollingContext.y.value + dy),
                    vel: .init(
                        x: scrollingContext.x.context.currentVel,
                        y: scrollingContext.y.context.currentVel
                    )
                )
                scrollingContext.setTarget(.init(x: ceil(target.x), y: ceil(target.y)))
            }
        }

        @objc func handleScrollingAnimation(_: CADisplayLink) {
            if isTracking || scrollingContext.completed {
                cancelCurrentScrolling()
                return
            }
            let time = CACurrentMediaTime()
            let delta = min(1 / 30, time - scrollingTik)
            scrollingTik = time
            scrollingContext.update(withDeltaTime: delta)
            let loc = nearestScrollLocationInBounds(offset: .init(
                x: scrollingContext.x.value,
                y: scrollingContext.y.value
            ))
            applyContentOffset(loc)
        }

        override open func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
            if animated {
                scroll(to: contentOffset)
            } else {
                cancelCurrentScrolling()
                applyContentOffset(contentOffset)
            }
        }

        /// The funnel for every offset this class owns: display-link ticks, the
        /// clamp after a content-size change, and the unanimated branch of
        /// `setContentOffset`. None of those is a scroll anyone asked for, so
        /// none may ride an animation the caller happens to have open. The
        /// scrolls this class does animate run off the display link, which the
        /// suppression never touches; the public setter is left alone, since
        /// animating that one is a fair thing for a host to ask for.
        private func applyContentOffset(_ contentOffset: CGPoint) {
            withoutListAnimation {
                super.setContentOffset(contentOffset, animated: false)
            }
        }

        override open func layoutSubviews() {
            super.layoutSubviews()
            layoutContent()
        }

        /// Where a subclass lays out its content. Mirrors the AppKit hook so
        /// `ListView` needs no platform split.
        func layoutContent() {}
    }

#elseif canImport(AppKit)
    import AppKit
    import MSDisplayLink

    enum AppKitScrollPhysics {
        // AppKit exports distinct hyperbolic coefficients for trackpads and
        // touch input. macOS trackpad scrolling uses 0.075; 0.55 is the touch
        // coefficient used by UIKit-style rubber banding.
        static let rubberBandCoefficient: CGFloat = 0.075
        static let reboundAmplitude: CGFloat = 0.31
        static let reboundPeriod: TimeInterval = 1.6
        static let reboundStiffness: CGFloat = 20
        static let maximumReboundVelocity: CGFloat = 20_000

        static func elasticDelta(forReboundDelta delta: CGFloat, dimension: CGFloat) -> CGFloat {
            guard dimension > 0 else { return 0 }
            let magnitude = abs(delta)
            let elasticMagnitude = dimension * magnitude * rubberBandCoefficient
                / (dimension + magnitude * rubberBandCoefficient)
            return delta < 0 ? -elasticMagnitude : elasticMagnitude
        }

        static func reboundDelta(forElasticDelta delta: CGFloat, dimension: CGFloat) -> CGFloat {
            guard dimension > 0 else { return 0 }
            let magnitude = abs(delta)
            guard magnitude < dimension else { return delta }
            let reboundMagnitude = magnitude * dimension
                / (rubberBandCoefficient * (dimension - magnitude))
            return delta < 0 ? -reboundMagnitude : reboundMagnitude
        }

        /// Matches `_NSElasticDeltaForTimeDelta` without linking private SPI.
        static func elasticDelta(
            initialPosition: CGFloat,
            initialVelocity: CGFloat,
            elapsedTime: TimeInterval
        ) -> CGFloat {
            let clampedVelocity = min(
                maximumReboundVelocity,
                max(-maximumReboundVelocity, initialVelocity)
            )
            let decay = exp(-elapsedTime * reboundStiffness / reboundPeriod)
            return (initialPosition - elapsedTime * clampedVelocity * reboundAmplitude) * decay
        }

        static func momentumDuration(initialVelocity: CGFloat) -> TimeInterval {
            guard initialVelocity != 0 else { return 0 }
            return cbrt(abs(initialVelocity) / 4_000)
        }

        static func momentumDisplacement(
            initialVelocity: CGFloat,
            elapsedTime: TimeInterval,
            duration: TimeInterval
        ) -> CGFloat {
            guard duration > 0 else { return 0 }
            let progress = min(1, max(0, elapsedTime / duration))
            let remainingVelocityFraction = pow(1 - progress, 4)
            return initialVelocity * duration / 4 * (1 - remainingVelocityFraction)
        }

        static func momentumVelocity(
            initialVelocity: CGFloat,
            elapsedTime: TimeInterval,
            duration: TimeInterval
        ) -> CGFloat {
            guard duration > 0 else { return 0 }
            let progress = min(1, max(0, elapsedTime / duration))
            return initialVelocity * pow(1 - progress, 3)
        }

        static func roundToDevicePixelTowardZero(_ value: CGFloat) -> CGFloat {
            var value = value
            let roundedValue = round(value)
            if abs(value - roundedValue) < 0.125 {
                value = roundedValue
            }
            return value > 0 ? ceil(value - 0.5) : floor(value + 0.5)
        }
    }

    private final class ListOverlayScroller: NSScroller {
        weak var owner: ListScrollView?
        weak var overlay: ListScrollerOverlay?

        override class var isCompatibleWithOverlayScrollers: Bool {
            self == ListOverlayScroller.self
        }

        override func mouseDown(with event: NSEvent) {
            owner?.verticalScrollerTrackingDidBegin()
            overlay?.isHandlingScrollerInteraction = true
            defer {
                overlay?.isHandlingScrollerInteraction = false
                owner?.verticalScrollerTrackingDidEnd()
            }
            super.mouseDown(with: event)
        }
    }

    private final class ListScrollerDocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    private final class ListScrollerOverlay: NSScrollView {
        weak var owner: ListScrollView?
        var isSynchronizing = false
        /// True only while NSScroller itself owns a mouse interaction. Wheel
        /// observation must never feed the driver's private offset back into the list.
        var isHandlingScrollerInteraction = false

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard !isHidden, let hitView = super.hitTest(point),
                  let verticalScroller
            else { return nil }
            return hitView === verticalScroller || hitView.isDescendant(of: verticalScroller)
                ? hitView
                : nil
        }

        override func scrollWheel(with event: NSEvent) {
            owner?.scrollWheel(with: event)
        }

        func observeScrollWheel(_ event: NSEvent) {
            guard !isHidden else { return }
            // AppKit needs the real event to drive overlay visibility and its
            // native elastic knob. Driver offsets never flow back unless the
            // user is directly interacting with NSScroller.
            isSynchronizing = true
            defer { isSynchronizing = false }
            super.scrollWheel(with: event)
        }

        override func reflectScrolledClipView(_ clipView: NSClipView) {
            super.reflectScrolledClipView(clipView)
            guard clipView === contentView,
                  !isSynchronizing,
                  isHandlingScrollerInteraction
            else { return }
            owner?.nativeScrollerDidScroll(to: clipView.bounds.origin.y)
        }
    }

    open class ListScrollView: NSView {
        override open var isFlipped: Bool {
            true
        }

        var scrollingDisplayLink: DisplayLink?
        var scrollingContext: SpringInterpolation2D = .init(
            .init(
                angularFrequency: 16,
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
            _isTracking || _momentumAnimation != nil || _isVerticalScrollerTracking
        }

        /// Raw (un-rubber-banded) Y offset during user scroll tracking.
        /// Delta is always applied to this value; rubber-band is applied only for display.
        private var _trackingRawOffsetY: CGFloat = 0

        /// True while AppKit-style overscroll rebound is active.
        private var _isBouncing: Bool = false

        /// True while native momentum events are superseded by ListViewKit's
        /// AppKit-matched momentum or rebound animation.
        private var _ignoresMomentumEvents: Bool = false

        /// Estimated raw scroll velocity (points/sec) for momentum and rebound handoff.
        private var _scrollVelocityY: CGFloat = 0
        private var _prevScrollTime: CFTimeInterval = 0
        private var _lastVelocitySampleTime: CFTimeInterval = 0

        private struct MomentumAnimation {
            var initialOffset: CGPoint
            let initialVelocityY: CGFloat
            let duration: TimeInterval
            var elapsedTime: TimeInterval = 0
        }

        private var _momentumAnimation: MomentumAnimation?

        private struct RubberBandAnimation {
            var targetOffset: CGPoint
            let initialPositionY: CGFloat
            let initialVelocityY: CGFloat
            var elapsedTime: TimeInterval = 0
        }

        private var _rubberBandAnimation: RubberBandAnimation?

        private let scrollerOverlay = ListScrollerOverlay(frame: .zero)
        private let scrollerDocumentView = ListScrollerDocumentView(frame: .zero)
        private var _isVerticalScrollerTracking = false

        /// Everything ``applyScrollerGeometry(_:)`` reads. Re-tiling an
        /// `NSScrollView` walks the view tree, re-runs Auto Layout, and
        /// re-derives scroller metrics — an order of magnitude more work than
        /// a scroll frame's own layout. None of it depends on the content
        /// offset, so the pass runs only when one of these inputs moves.
        private struct ScrollerGeometry: Equatable {
            var boundsSize: CGSize
            /// Normalized to zero while hidden so a growing content size cannot
            /// re-tile a scroller nobody can see.
            var scrollableRange: CGFloat
            var showsScroller: Bool
            /// Padding that keeps overlay knob endpoints clear of rounded
            /// window corners, already netted against the overlay's own safe
            /// area so an underlapping titlebar is not counted twice.
            var knobEndpointInsets: (top: CGFloat, bottom: CGFloat)

            static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.boundsSize == rhs.boundsSize
                    && lhs.scrollableRange == rhs.scrollableRange
                    && lhs.showsScroller == rhs.showsScroller
                    && lhs.knobEndpointInsets == rhs.knobEndpointInsets
            }
        }

        private var appliedScrollerGeometry: ScrollerGeometry?

        /// Overlay placement already applied: where the chrome was pinned, and
        /// where the knob sits inside its track. Both derive from the content
        /// offset and the insets, so comparing them also answers "did the
        /// content move, should the overlay flash".
        private var appliedScrollerPlacement: (origin: CGPoint, knobOffsetY: CGFloat)?

        /// Number of times the expensive geometry pass actually ran. Tests use
        /// this to prove that scrolling alone does not re-tile the scroller.
        private(set) var scrollerGeometryPassCount: Int = 0

        open var contentInsets: NSEdgeInsets = .init() {
            didSet { needsLayout = true }
        }

        /// While set, an offset that a content-size change pushed out of
        /// bounds travels to its new home instead of snapping there. A caller
        /// animating its rows has to move the viewport along with them, or the
        /// correction reads as a jump in the middle of the animation.
        var animatesContentSizeCorrection = false

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
                setBoundsOrigin(newValue)
                needsLayout = true
            }
        }

        /// The total content size, analogous to UIScrollView.contentSize.
        open var contentSize: CGSize {
            get { _contentSize }
            set {
                if _contentSize != newValue {
                    let currentOffset = contentOffset
                    _contentSize = newValue
                    applyContentOffset(currentOffset)
                    needsLayout = true
                }
                reconcileOffsetWithContentSize()
            }
        }

        /// Analogous to UIScrollView.adjustedContentInset for cross-platform code.
        var adjustedContentInset: NSEdgeInsets {
            contentInsets
        }

        override public init(frame: CGRect) {
            super.init(frame: frame)
            wantsLayer = true

            let verticalScroller = ListOverlayScroller(frame: .zero)
            verticalScroller.owner = self
            verticalScroller.overlay = scrollerOverlay
            verticalScroller.scrollerStyle = .overlay
            verticalScroller.controlSize = .regular

            scrollerOverlay.owner = self
            scrollerOverlay.borderType = .noBorder
            scrollerOverlay.drawsBackground = false
            scrollerOverlay.contentView.drawsBackground = false
            scrollerOverlay.hasHorizontalScroller = false
            scrollerOverlay.hasVerticalScroller = true
            scrollerOverlay.verticalScrollElasticity = .allowed
            scrollerOverlay.verticalScroller = verticalScroller
            scrollerOverlay.scrollerStyle = .overlay
            scrollerOverlay.autohidesScrollers = true
            scrollerOverlay.documentView = scrollerDocumentView
            addSubview(scrollerOverlay)
            updateVerticalScroller()
        }

        @available(*, unavailable)
        public required init?(coder _: NSCoder) {
            fatalError()
        }

        override open func layout() {
            super.layout()
            layoutContent()
            // After `layoutContent`, which may have changed `contentSize`.
            // AppKit will not re-enter `layout()` for an invalidation raised
            // from inside it, so a scroller synced first would stay stale.
            updateVerticalScroller()
        }

        /// Where a subclass lays out its content. Runs inside the same layout
        /// pass that refreshes the scroller.
        func layoutContent() {}

        override open func didAddSubview(_ subview: NSView) {
            super.didAddSubview(subview)
            guard subview !== scrollerOverlay, scrollerOverlay.superview === self else { return }
            addSubview(scrollerOverlay, positioned: .above, relativeTo: subview)
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

        /// Brings the overlay scroller in line with the current content. Driven
        /// from ``layout()``, so any number of offset writes within one frame
        /// cost a single update.
        private func updateVerticalScroller() {
            let minOffset = minimumContentOffset.y
            let scrollableRange = maximumContentOffset.y - minOffset
            let showsScroller = scrollableRange > 0 && bounds.height > 0

            // NSScrollView already applies its own safe area when tiling the
            // scroller, so only the remainder is ours to add.
            let endpointInset = ceil(NSScroller.scrollerWidth(
                for: .regular,
                scrollerStyle: .overlay
            ) / 2)
            let safeAreaInsets = scrollerOverlay.safeAreaInsets
            let geometry = ScrollerGeometry(
                boundsSize: bounds.size,
                scrollableRange: showsScroller ? scrollableRange : 0,
                showsScroller: showsScroller,
                knobEndpointInsets: (
                    top: max(0, endpointInset - safeAreaInsets.top),
                    bottom: max(0, endpointInset - safeAreaInsets.bottom)
                )
            )
            if geometry != appliedScrollerGeometry {
                appliedScrollerGeometry = geometry
                scrollerGeometryPassCount &+= 1
                applyScrollerGeometry(geometry)
            }

            let placement = (origin: bounds.origin, knobOffsetY: contentOffset.y - minOffset)
            guard showsScroller else { return }
            if let applied = appliedScrollerPlacement, applied == placement { return }
            appliedScrollerPlacement = placement
            // Scrolling moves the bounds origin, and the overlay is chrome
            // rather than content, so it has to be dragged back. Moving the
            // origin does not re-tile the way resizing does.
            scrollerOverlay.setFrameOrigin(placement.origin)
            // Overscroll is owned by the rubber-band animation; leaving the knob
            // where it is matches AppKit's own behaviour at the edges.
            if placement.knobOffsetY >= 0, placement.knobOffsetY <= scrollableRange {
                scrollerOverlay.isSynchronizing = true
                scrollerOverlay.contentView.scroll(to: .init(x: 0, y: placement.knobOffsetY))
                scrollerOverlay.reflectScrolledClipView(scrollerOverlay.contentView)
                scrollerOverlay.isSynchronizing = false
            }
            // Wheel events reach the overlay directly and AppKit flashes it
            // itself; this covers programmatic and compensated motion.
            scrollerOverlay.flashScrollers()
        }

        /// Re-tiles the overlay. Expensive, and correct only for the inputs
        /// captured in ``ScrollerGeometry``.
        private func applyScrollerGeometry(_ geometry: ScrollerGeometry) {
            // List updates may run inside an implicit AppKit animation context.
            // The overlay is infrastructure, not list content: keep its geometry
            // current even while hidden and never interpolate it into position.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false

                scrollerOverlay.frame = bounds
                scrollerOverlay.scrollerStyle = .overlay
                // Autohiding follows the system preference while a knob is
                // live. A hidden overlay pins it off so AppKit cannot fade
                // a scroller back in over content that cannot scroll.
                scrollerOverlay.autohidesScrollers = geometry.showsScroller
                scrollerOverlay.hasVerticalScroller = true

                scrollerOverlay.scrollerInsets = NSEdgeInsets(
                    top: geometry.knobEndpointInsets.top,
                    left: 0,
                    bottom: geometry.knobEndpointInsets.bottom,
                    right: 0
                )
                scrollerOverlay.layoutSubtreeIfNeeded()

                let viewportSize = scrollerOverlay.contentSize
                scrollerDocumentView.frame = CGRect(
                    origin: .zero,
                    size: CGSize(
                        width: max(1, viewportSize.width),
                        height: geometry.showsScroller
                            ? max(viewportSize.height, geometry.scrollableRange + viewportSize.height)
                            : viewportSize.height
                    )
                )
                scrollerOverlay.tile()
                scrollerOverlay.layoutSubtreeIfNeeded()

                // AppKit places the scroller against the track it knew about
                // when tiling, so the new document size needs a second pass.
                scrollerOverlay.isHidden = !geometry.showsScroller
                guard geometry.showsScroller else { return }
                scrollerOverlay.tile()
                scrollerOverlay.layoutSubtreeIfNeeded()
            }
            // The knob has to be re-placed against the new track.
            appliedScrollerPlacement = nil
        }

        /// Puts the offset back in bounds at the end of a layout pass. It runs
        /// even when the size is unchanged: a row shrinking above the anchor
        /// and one growing below it cancel out in the total while the offset
        /// still moved, and nothing else would notice it left the bounds.
        ///
        /// Whether the offset may sit outside the bounds is a question about
        /// who owns it, not about the offset itself: deferred measurement
        /// routinely shifts it past an edge on its way to the right place.
        private func reconcileOffsetWithContentSize() {
            // A finger, momentum or a rebound already owns the offset. Those
            // either clamp themselves every frame or are holding a deliberate
            // overscroll, and interrupting one cancels the bounce.
            guard !isUserInteractingWithScroll else { return }
            if let target = scrollingTarget {
                // A programmatic scroll keeps running, retargeted onto the new
                // edge so it lands there instead of short of it.
                let clamped = nearestScrollLocationInBounds(offset: target)
                if clamped != target {
                    scroll(to: clamped)
                }
                return
            }
            let clamped = nearestScrollLocationInBounds(offset: contentOffset)
            guard clamped != contentOffset else { return }
            if animatesContentSizeCorrection {
                scroll(to: clamped, preserveVelocity: false)
            } else {
                // Deferred measurement resizes the content over and over, so
                // an idle list lands on the new edge outright: animating every
                // correction restarts the slide on each pass and reads as the
                // list scrolling by itself.
                applyContentOffset(clamped)
            }
        }

        fileprivate func verticalScrollerTrackingDidBegin() {
            _isVerticalScrollerTracking = true
            cancelCurrentScrolling()
        }

        fileprivate func verticalScrollerTrackingDidEnd() {
            _isVerticalScrollerTracking = false
        }

        func nativeScrollerDidScroll(to offsetY: CGFloat) {
            let targetOffsetY = minimumContentOffset.y + offsetY
            setContentOffset(.init(
                x: contentOffset.x,
                y: min(max(targetOffsetY, minimumContentOffset.y), maximumContentOffset.y)
            ), animated: false)
        }

        public func flashScrollers() {
            guard !scrollerOverlay.isHidden else { return }
            scrollerOverlay.flashScrollers()
        }

        override open func scrollWheel(with event: NSEvent) {
            scrollerOverlay.observeScrollWheel(event)

            let min = minimumContentOffset
            let max = maximumContentOffset
            let isDiscreteWheelEvent = event.phase.isEmpty && event.momentumPhase.isEmpty
            let hasDirectGesturePhase = !event.phase.isEmpty
            let startsDirectInteraction = hasDirectGesturePhase && (
                event.phase == .mayBegin
                    || event.phase == .began
                    || !_isTracking
            )

            // A local momentum or rebound animation owns deceleration after handoff. Keep
            // consuming native momentum from that gesture even if the animation finishes
            // before AppKit emits the terminal momentum event.
            if _ignoresMomentumEvents, !event.momentumPhase.isEmpty {
                if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                    _ignoresMomentumEvents = false
                }
                return
            }

            // A new direct touch or phase-less wheel event interrupts the rebound
            // and starts a fresh interaction.
            if _isBouncing {
                if startsDirectInteraction || isDiscreteWheelEvent {
                    _isBouncing = false
                    // Keep consuming the previous gesture's native momentum tail.
                    // Direct events are still processed because they have no momentum phase.
                    // fall through to normal began handling
                } else {
                    return
                }
            }

            if startsDirectInteraction || event.momentumPhase == .began || isDiscreteWheelEvent {
                // AppKit may begin a new touch with .mayBegin, or resume with
                // .changed while the previous momentum stream is still ending.
                // Always rebase raw tracking on the current visual offset so a
                // tiny follow-up gesture cannot jump back to the prior release point.
                _isTracking = true
                _isBouncing = false
                // Do not clear _ignoresMomentumEvents here. AppKit can deliver the
                // old momentum tail after a new direct touch has already started.
                cancelCurrentScrolling()
                // Initialize raw offset from current visual position.
                // If out of bounds (e.g. grabbed during bounce-back animation),
                // invert the rubber-band to recover the raw position for continuity.
                let currentY = contentOffset.y
                if currentY < min.y {
                    let visualOverscroll = min.y - currentY
                    _trackingRawOffsetY = min.y - inverseRubberBand(visualOverscroll, dimension: bounds.height)
                } else if currentY > max.y {
                    let visualOverscroll = currentY - max.y
                    _trackingRawOffsetY = max.y + inverseRubberBand(visualOverscroll, dimension: bounds.height)
                } else {
                    _trackingRawOffsetY = currentY
                }
                _scrollVelocityY = 0
                _prevScrollTime = event.timestamp
                _lastVelocitySampleTime = event.timestamp
            }

            let deltaY = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10)
            let previousRawOffsetY = _trackingRawOffsetY
            _trackingRawOffsetY -= deltaY

            // Apply rubber-band only for display
            var visualY = _trackingRawOffsetY
            if visualY < min.y {
                let overscroll = min.y - visualY
                visualY = min.y - rubberBand(overscroll, dimension: bounds.height)
            } else if visualY > max.y {
                let overscroll = visualY - max.y
                visualY = max.y + rubberBand(overscroll, dimension: bounds.height)
            }

            // AppKit feeds the undamped gesture velocity into its snap-back
            // curve. The ended event commonly carries a zero delta, so retain
            // the last meaningful estimate rather than replacing it with zero.
            let now = event.timestamp
            let dt = now - _prevScrollTime
            let rawDisplacement = _trackingRawOffsetY - previousRawOffsetY
            if dt > 0 && dt < 0.1 && abs(rawDisplacement) > 0.5 {
                _scrollVelocityY = rawDisplacement / dt
                _lastVelocitySampleTime = now
            } else if now - _lastVelocitySampleTime >= 0.1 {
                _scrollVelocityY = 0
            }
            _prevScrollTime = now

            applyContentOffset(.init(x: contentOffset.x, y: visualY))

            // Once momentum carries the content past an edge, AppKit hands the
            // remaining motion to its rebound curve and consumes subsequent
            // momentum events from that gesture.
            if !event.momentumPhase.isEmpty {
                let clamped = nearestScrollLocationInBounds(offset: contentOffset)
                if clamped != contentOffset {
                    _ignoresMomentumEvents = true
                    startRubberBandAnimation(to: clamped, velocityY: _scrollVelocityY)
                    return
                }
            }

            // Traditional mouse wheels do not report gesture phases. Treat every
            // event as a complete interaction so the next delta starts from the
            // current offset and programmatic scrolling is never left blocked.
            if isDiscreteWheelEvent {
                _isTracking = false
                let clamped = nearestScrollLocationInBounds(offset: contentOffset)
                if clamped != contentOffset {
                    scroll(to: clamped, preserveVelocity: false)
                }
                return
            }

            // Finger lifted while out of bounds → immediately rebound with velocity.
            // Do not wait for momentum; AppKit's decay curve owns the handoff.
            if event.phase == .ended || event.phase == .cancelled {
                _isTracking = false
                let clamped = nearestScrollLocationInBounds(offset: contentOffset)
                if clamped != contentOffset {
                    _ignoresMomentumEvents = true
                    startRubberBandAnimation(to: clamped, velocityY: _scrollVelocityY)
                    return
                }
                if event.phase == .ended, startMomentumAnimation(velocityY: _scrollVelocityY) {
                    return
                }
                // A cancelled gesture stops in place.
            }

            // Momentum ended while out of bounds (e.g. momentum carried past bounds)
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                _isTracking = false
                let clamped = nearestScrollLocationInBounds(offset: contentOffset)
                if clamped != contentOffset {
                    scroll(to: clamped, preserveVelocity: false)
                }
            }
        }

        private func rubberBand(_ offset: CGFloat, dimension: CGFloat) -> CGFloat {
            AppKitScrollPhysics.elasticDelta(forReboundDelta: offset, dimension: dimension)
        }

        private func inverseRubberBand(_ offset: CGFloat, dimension: CGFloat) -> CGFloat {
            AppKitScrollPhysics.reboundDelta(forElasticDelta: offset, dimension: dimension)
        }

        private func startRubberBandAnimation(to target: CGPoint, velocityY: CGFloat) {
            _isTracking = false
            _isBouncing = true
            _momentumAnimation = nil
            _rubberBandAnimation = .init(
                targetOffset: target,
                initialPositionY: contentOffset.y - target.y,
                // AppKit's function uses the opposite sign from visual velocity.
                initialVelocityY: -velocityY
            )
            scrollingTarget = target

            guard scrollingDisplayLink == nil else { return }
            let link = DisplayLink()
            link.delegatingObject(self)
            scrollingDisplayLink = link
            scrollingTik = CACurrentMediaTime()
        }

        @discardableResult
        private func startMomentumAnimation(velocityY: CGFloat) -> Bool {
            let duration = AppKitScrollPhysics.momentumDuration(initialVelocity: velocityY)
            guard duration > 0 else { return false }

            _isTracking = false
            _isBouncing = false
            _ignoresMomentumEvents = true
            _rubberBandAnimation = nil
            _momentumAnimation = .init(
                initialOffset: contentOffset,
                initialVelocityY: velocityY,
                duration: duration
            )
            scrollingTarget = nil

            guard scrollingDisplayLink == nil else { return true }
            let link = DisplayLink()
            link.delegatingObject(self)
            scrollingDisplayLink = link
            scrollingTik = CACurrentMediaTime()
            return true
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
            _rubberBandAnimation = nil
            _momentumAnimation = nil
            _isBouncing = false
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
            _isBouncing = false
            _rubberBandAnimation = nil
            _momentumAnimation = nil
            // Do not clear _ignoresMomentumEvents here. AppKit may still be
            // sending native momentum from a gesture owned by a local animation.
            scrollingContext.setTarget(.init(x: currentContentOffset.x, y: currentContentOffset.y))
            scrollingDisplayLink?.delegatingObject(nil)
            scrollingDisplayLink = nil
        }

        /// Shifts the current offset and every piece of in-flight scroll state
        /// by `dy` without cancelling tracking, momentum, rebound, or
        /// programmatic scrolling. Deferred height correction uses this so
        /// rows above the viewport can change size while visible rows stay
        /// visually stationary.
        func compensateScrollOffset(by dy: CGFloat) {
            guard dy != 0 else { return }
            _contentOffset.y += dy
            // The whole point of this shift is that the reader cannot see it.
            // Animating it is exactly how it becomes visible.
            withoutListAnimation { setBoundsOrigin(_contentOffset) }
            needsLayout = true
            _trackingRawOffsetY += dy
            _momentumAnimation?.initialOffset.y += dy
            _rubberBandAnimation?.targetOffset.y += dy
            if var target = scrollingTarget {
                target.y += dy
                scrollingTarget = target
                scrollingContext.setCurrent(
                    .init(x: scrollingContext.x.value, y: scrollingContext.y.value + dy),
                    vel: .init(
                        x: scrollingContext.x.context.currentVel,
                        y: scrollingContext.y.context.currentVel
                    )
                )
                scrollingContext.setTarget(.init(x: ceil(target.x), y: ceil(target.y)))
            }
        }

        func handleScrollingAnimation(_ context: DisplayLinkCallbackContext) {
            if _isTracking || _isVerticalScrollerTracking {
                cancelCurrentScrolling()
                return
            }

            if var rubberBandAnimation = _rubberBandAnimation {
                rubberBandAnimation.elapsedTime += min(1 / 30, context.duration)
                let displacement = AppKitScrollPhysics.elasticDelta(
                    initialPosition: rubberBandAnimation.initialPositionY,
                    initialVelocity: rubberBandAnimation.initialVelocityY,
                    elapsedTime: rubberBandAnimation.elapsedTime
                )
                let roundedDisplacement = AppKitScrollPhysics.roundToDevicePixelTowardZero(displacement)
                let animationComplete = roundedDisplacement == 0
                    && rubberBandAnimation.elapsedTime > 0.024

                if animationComplete {
                    applyContentOffset(rubberBandAnimation.targetOffset)
                    cancelCurrentScrolling()
                } else {
                    _rubberBandAnimation = rubberBandAnimation
                    applyContentOffset(.init(
                        x: rubberBandAnimation.targetOffset.x,
                        y: rubberBandAnimation.targetOffset.y + roundedDisplacement
                    ))
                }
                return
            }

            if var momentumAnimation = _momentumAnimation {
                momentumAnimation.elapsedTime += min(1 / 30, context.duration)
                let displacement = AppKitScrollPhysics.momentumDisplacement(
                    initialVelocity: momentumAnimation.initialVelocityY,
                    elapsedTime: momentumAnimation.elapsedTime,
                    duration: momentumAnimation.duration
                )
                let proposedOffset = CGPoint(
                    x: momentumAnimation.initialOffset.x,
                    y: momentumAnimation.initialOffset.y + displacement
                )
                let clampedOffset = nearestScrollLocationInBounds(offset: proposedOffset)

                if proposedOffset != clampedOffset {
                    let rawOverscroll = proposedOffset.y - clampedOffset.y
                    let visualOverscroll = AppKitScrollPhysics.elasticDelta(
                        forReboundDelta: rawOverscroll,
                        dimension: bounds.height
                    )
                    let velocity = AppKitScrollPhysics.momentumVelocity(
                        initialVelocity: momentumAnimation.initialVelocityY,
                        elapsedTime: momentumAnimation.elapsedTime,
                        duration: momentumAnimation.duration
                    )
                    applyContentOffset(.init(
                        x: clampedOffset.x,
                        y: clampedOffset.y + visualOverscroll
                    ))
                    startRubberBandAnimation(to: clampedOffset, velocityY: velocity)
                } else if momentumAnimation.elapsedTime >= momentumAnimation.duration {
                    applyContentOffset(proposedOffset)
                    cancelCurrentScrolling()
                } else {
                    _momentumAnimation = momentumAnimation
                    applyContentOffset(proposedOffset)
                }
                return
            }

            if scrollingContext.completed {
                cancelCurrentScrolling()
                return
            }
            let delta = min(1 / 30, context.duration)
            scrollingContext.update(withDeltaTime: delta)
            let loc = CGPoint(
                x: scrollingContext.x.value,
                y: scrollingContext.y.value
            )
            applyContentOffset(loc)
        }

        open func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
            if animated {
                scroll(to: contentOffset)
            } else {
                cancelCurrentScrolling()
                applyContentOffset(contentOffset)
            }
        }

        /// The funnel for every offset this class owns: display-link ticks, the
        /// clamp after a content-size change, and the unanimated branch of
        /// `setContentOffset`. None of those is a scroll anyone asked for, so
        /// none may ride an animation the caller happens to have open. The
        /// scrolls this class does animate run off the display link, which the
        /// suppression never touches; the open setter is left alone, since
        /// animating that one is a fair thing for a host to ask for.
        private func applyContentOffset(_ contentOffset: CGPoint) {
            withoutListAnimation { self.contentOffset = contentOffset }
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

public extension ListScrollView {
    /// Whether direct user scrolling or platform momentum is currently active.
    ///
    /// Consumers can use this to avoid retargeting programmatic scrolling while
    /// the user is inspecting earlier content. Programmatic spring scrolling is
    /// intentionally not reported as user interaction.
    var isUserInteractingWithScroll: Bool {
        #if canImport(UIKit)
            isTracking || isDragging || isDecelerating
        #elseif canImport(AppKit)
            isTracking
        #endif
    }

    /// Returns whether the vertical offset is at the bottom edge, allowing a
    /// small tolerance for fractional layout and display-scale differences.
    ///
    /// Bottom overscroll also returns `true`. A negative or non-finite
    /// tolerance is treated as zero.
    func isScrolledToBottom(tolerance: CGFloat = 1) -> Bool {
        let normalizedTolerance = tolerance.isFinite ? max(0, tolerance) : 0
        return maximumContentOffset.y - contentOffset.y <= normalizedTolerance
    }
}
