#if canImport(UIKit)
// UIKit platforms (including Mac Catalyst) are exercised by the UIKit suites.
#elseif canImport(AppKit)
import AppKit
import Testing
@testable import ListViewKit

@Suite(.serialized)
@MainActor
struct ListScrollViewAppKitTests {
    private func makeWheelEvent(
        deltaY: Int32,
        phase: CGScrollPhase? = nil,
        momentumPhase: CGScrollPhase? = nil,
        timestamp: CGEventTimestamp? = nil
    ) throws -> NSEvent {
        let cgEvent = try #require(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: deltaY,
            wheel2: 0,
            wheel3: 0
        ))
        cgEvent.setIntegerValueField(
            .scrollWheelEventScrollPhase,
            value: Int64(phase?.rawValue ?? 0)
        )
        cgEvent.setIntegerValueField(
            .scrollWheelEventMomentumPhase,
            value: Int64(momentumPhase?.rawValue ?? 0)
        )
        if let timestamp {
            cgEvent.timestamp = timestamp
        }
        return try #require(NSEvent(cgEvent: cgEvent))
    }

    @Test
    func rubberBandCurveMatchesAppKitStiffness() {
        let elastic = AppKitScrollPhysics.elasticDelta(forReboundDelta: 200, dimension: 600)
        #expect(abs(elastic - 14.634_146_341_463_415) < 0.000_001)
        #expect(abs(AppKitScrollPhysics.reboundDelta(forElasticDelta: elastic, dimension: 600) - 200) < 0.000_001)
    }

    @Test
    func rubberBandSnapBackMatchesAppKitTimingCurve() {
        let zeroVelocity = AppKitScrollPhysics.elasticDelta(
            initialPosition: 100,
            initialVelocity: 0,
            elapsedTime: 0.1
        )
        let outwardVelocity = AppKitScrollPhysics.elasticDelta(
            initialPosition: 100,
            initialVelocity: 1_000,
            elapsedTime: 0.1
        )

        #expect(abs(zeroVelocity - 28.650_479_686_019_008) < 0.000_001)
        #expect(abs(outwardVelocity - 19.768_830_983_353_116) < 0.000_001)
    }

    @Test
    func momentumCurveMatchesAppKitCalculator() {
        let duration = AppKitScrollPhysics.momentumDuration(initialVelocity: 1_000)
        let displacement = AppKitScrollPhysics.momentumDisplacement(
            initialVelocity: 1_000,
            elapsedTime: 0.1,
            duration: duration
        )

        #expect(abs(duration - 0.629_960_524_947_436_6) < 0.000_001)
        #expect(abs(displacement - 78.608_826_320_266_8) < 0.000_001)
    }

    @Test
    func verticalScrollerTracksViewportAndContent() throws {
        let scrollView = ListScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        scrollView.contentSize = CGSize(width: 200, height: 1_000)
        scrollView.layoutSubtreeIfNeeded()

        let scroller = try #require(
            scrollView.subviews
                .flatMap(\.subviews)
                .compactMap { $0 as? NSScroller }
                .first
        )
        let scrollerContainer = try #require(scroller.superview)
        #expect(!scrollerContainer.isHidden)
        #expect(scroller.scrollerStyle == .overlay)
        #expect(scroller.isEnabled)
        #expect(scroller.usableParts.rawValue == 2)
        #expect(!scroller.rect(for: .knob).isEmpty)
        #expect(abs(scroller.knobProportion - 0.2) < 0.000_001)

        scrollView.contentOffset = CGPoint(x: 0, y: 400)

        #expect(abs(scroller.doubleValue - 0.5) < 0.000_001)
        let frameInScrollView = scroller.convert(scroller.bounds, to: scrollView)
        let endpointInset = ceil(NSScroller.scrollerWidth(
            for: .regular,
            scrollerStyle: .overlay
        ) / 2)
        #expect(frameInScrollView.minY == scrollView.bounds.minY + endpointInset)
        #expect(frameInScrollView.maxY == scrollView.bounds.maxY - endpointInset)
        #expect(frameInScrollView.maxX == scrollView.bounds.maxX)

        let nativeScrollView = try #require(scrollerContainer as? NSScrollView)
        scrollView.contentOffset = scrollView.maximumContentOffset
        nativeScrollView.contentView.scroll(to: .zero)
        nativeScrollView.reflectScrolledClipView(nativeScrollView.contentView)

        // Wheel observation may move the native driver's clip view internally,
        // but only an actual scroller interaction may update ListScrollView.
        #expect(scrollView.contentOffset == scrollView.maximumContentOffset)

        scrollView.nativeScrollerDidScroll(to: 600)
        #expect(scrollView.contentOffset.y == 600)
        #expect(abs(scroller.doubleValue - 0.75) < 0.000_001)
    }

    @Test
    func verticalScrollerDoesNotDoubleUnderlappingWindowSafeArea() throws {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        let scrollView = ListScrollView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = scrollView
        scrollView.contentSize = CGSize(width: 400, height: 1_000)
        scrollView.layoutSubtreeIfNeeded()

        let safeAreaTop = scrollView.safeAreaInsets.top
        let scroller = try #require(
            scrollView.subviews
                .flatMap(\.subviews)
                .compactMap { $0 as? NSScroller }
                .first
        )
        let frameInScrollView = scroller.convert(scroller.bounds, to: scrollView)
        let endpointInset = ceil(NSScroller.scrollerWidth(
            for: .regular,
            scrollerStyle: .overlay
        ) / 2)

        #expect(safeAreaTop > 0)
        #expect(frameInScrollView.minY == max(safeAreaTop, endpointInset))
    }

    @Test
    func verticalScrollerHidesWhenContentFitsOrItIsDisabled() throws {
        let scrollView = ListScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let scroller = try #require(
            scrollView.subviews
                .flatMap(\.subviews)
                .compactMap { $0 as? NSScroller }
                .first
        )
        let scrollerContainer = try #require(scroller.superview)

        scrollView.contentSize = CGSize(width: 200, height: 100)
        #expect(scrollerContainer.isHidden)
        #expect(scrollerContainer.frame == scrollView.bounds)
        let hiddenScrollerFrame = scroller.convert(scroller.bounds, to: scrollView)
        #expect(hiddenScrollerFrame.maxX == scrollView.bounds.maxX)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.5
            context.allowsImplicitAnimation = true
            scrollView.contentSize = CGSize(width: 200, height: 1_000)
        }
        #expect(!scrollerContainer.isHidden)
        #expect(scrollerContainer.frame == scrollView.bounds)

        scrollView.hasVerticalScroller = false
        #expect(scrollerContainer.isHidden)
    }

    @Test
    func overscrollPreservesNativeScrollerElasticState() throws {
        let scrollView = ListScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        scrollView.contentSize = CGSize(width: 200, height: 800)
        scrollView.layoutSubtreeIfNeeded()

        let nativeScrollView = try #require(
            scrollView.subviews.compactMap { $0 as? NSScrollView }.first
        )
        scrollView.contentOffset = scrollView.maximumContentOffset
        nativeScrollView.contentView.scroll(to: CGPoint(x: 0, y: 400))
        let nativeElasticOffset = nativeScrollView.contentView.bounds.origin

        scrollView.contentOffset.y += 40

        #expect(nativeScrollView.contentView.bounds.origin == nativeElasticOffset)
    }

    @Test
    func phaseLessWheelContinuesFromCurrentOffset() throws {
        let scrollView = ListScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        scrollView.contentSize = CGSize(width: 200, height: 2_000)
        scrollView.contentOffset = CGPoint(x: 0, y: 500)

        let event = try makeWheelEvent(deltaY: 1)
        #expect(event.phase.isEmpty)
        #expect(event.momentumPhase.isEmpty)

        scrollView.scrollWheel(with: event)

        #expect(scrollView.contentOffset.y == 490)
    }

    @Test
    func directGestureEndDoesNotBlockProgrammaticScrolling() throws {
        let scrollView = ListScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        scrollView.contentSize = CGSize(width: 200, height: 2_000)
        scrollView.contentOffset = CGPoint(x: 0, y: 500)

        scrollView.scrollWheel(with: try makeWheelEvent(deltaY: 1, phase: .began))
        #expect(scrollView.isUserInteractingWithScroll)
        scrollView.scrollWheel(with: try makeWheelEvent(deltaY: 0, phase: .ended))

        #expect(!scrollView.isUserInteractingWithScroll)
        scrollView.scroll(to: CGPoint(x: 0, y: 800), preserveVelocity: false)
        #expect(scrollView.scrollingDisplayLink != nil)
        scrollView.cancelCurrentScrolling()
    }

    @Test
    func directGestureReleaseStartsMomentumAnimation() throws {
        let scrollView = ListScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        scrollView.contentSize = CGSize(width: 200, height: 2_000)
        scrollView.contentOffset = CGPoint(x: 0, y: 500)

        let initialTimestamp: CGEventTimestamp = 1_000_000_000
        scrollView.scrollWheel(with: try makeWheelEvent(
            deltaY: 1,
            phase: .began,
            timestamp: initialTimestamp
        ))
        scrollView.scrollWheel(with: try makeWheelEvent(
            deltaY: 1,
            phase: .changed,
            timestamp: initialTimestamp + 10_000_000
        ))
        scrollView.scrollWheel(with: try makeWheelEvent(
            deltaY: 0,
            phase: .ended,
            timestamp: initialTimestamp + 11_000_000
        ))

        #expect(scrollView.isUserInteractingWithScroll)
        #expect(scrollView.scrollingDisplayLink != nil)
        scrollView.cancelCurrentScrolling()
    }

    @Test
    func followUpGestureRebasesFromInFlightMomentumOffset() throws {
        let scrollView = ListScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        scrollView.contentSize = CGSize(width: 200, height: 10_000)
        scrollView.contentOffset = CGPoint(x: 0, y: 5_000)

        let initialTimestamp: CGEventTimestamp = 1_000_000_000
        scrollView.scrollWheel(with: try makeWheelEvent(
            deltaY: 1,
            phase: .began,
            timestamp: initialTimestamp
        ))
        scrollView.scrollWheel(with: try makeWheelEvent(
            deltaY: 1,
            phase: .changed,
            timestamp: initialTimestamp + 10_000_000
        ))
        scrollView.scrollWheel(with: try makeWheelEvent(
            deltaY: 0,
            phase: .ended,
            timestamp: initialTimestamp + 11_000_000
        ))
        #expect(scrollView.scrollingDisplayLink != nil)

        // Model the visual offset reached by the local momentum calculator before
        // AppKit delivers a light follow-up touch.
        scrollView.contentOffset.y += 300
        let offsetAtFollowUpTouch = scrollView.contentOffset

        scrollView.scrollWheel(with: try makeWheelEvent(
            deltaY: 0,
            phase: .mayBegin,
            timestamp: initialTimestamp + 500_000_000
        ))
        #expect(scrollView.contentOffset == offsetAtFollowUpTouch)
        #expect(scrollView.scrollingDisplayLink == nil)

        // AppKit can deliver the previous gesture's momentum tail after the new
        // touch begins. A changed tail must not move the new interaction, and a
        // terminal tail must not make its next direct delta jump.
        scrollView.scrollWheel(with: try makeWheelEvent(
            deltaY: 50,
            momentumPhase: .changed,
            timestamp: initialTimestamp + 501_000_000
        ))
        #expect(scrollView.contentOffset == offsetAtFollowUpTouch)
        #expect(scrollView.isUserInteractingWithScroll)
        scrollView.scrollWheel(with: try makeWheelEvent(
            deltaY: 0,
            momentumPhase: .ended,
            timestamp: initialTimestamp + 502_000_000
        ))
        #expect(scrollView.contentOffset == offsetAtFollowUpTouch)

        scrollView.scrollWheel(with: try makeWheelEvent(
            deltaY: 1,
            phase: .changed,
            timestamp: initialTimestamp + 510_000_000
        ))
        #expect(scrollView.contentOffset.y == offsetAtFollowUpTouch.y - 10)

        scrollView.scrollWheel(with: try makeWheelEvent(
            deltaY: 0,
            phase: .cancelled,
            timestamp: initialTimestamp + 511_000_000
        ))

        // Some trackpad sequences resume directly with .changed while the old
        // momentum stream is terminating; that path needs the same rebase.
        let resumedTimestamp = initialTimestamp + 1_000_000_000
        scrollView.scrollWheel(with: try makeWheelEvent(
            deltaY: 1,
            phase: .began,
            timestamp: resumedTimestamp
        ))
        scrollView.scrollWheel(with: try makeWheelEvent(
            deltaY: 1,
            phase: .changed,
            timestamp: resumedTimestamp + 10_000_000
        ))
        scrollView.scrollWheel(with: try makeWheelEvent(
            deltaY: 0,
            phase: .ended,
            timestamp: resumedTimestamp + 11_000_000
        ))
        scrollView.contentOffset.y += 300
        let offsetBeforeChangedOnlyGesture = scrollView.contentOffset

        scrollView.scrollWheel(with: try makeWheelEvent(
            deltaY: 1,
            phase: .changed,
            timestamp: resumedTimestamp + 500_000_000
        ))
        #expect(scrollView.contentOffset.y == offsetBeforeChangedOnlyGesture.y - 10)
        scrollView.cancelCurrentScrolling()
    }

    @Test
    func animatedContentOffsetUsesSpringScrolling() {
        let scrollView = ListScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        scrollView.contentSize = CGSize(width: 200, height: 2_000)

        scrollView.setContentOffset(CGPoint(x: 0, y: 800), animated: true)

        #expect(scrollView.scrollingDisplayLink != nil)
        scrollView.cancelCurrentScrolling()
    }

    @Test
    func immediateContentOffsetCancelsSpringScrolling() {
        let scrollView = ListScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        scrollView.contentSize = CGSize(width: 200, height: 2_000)
        scrollView.scroll(to: CGPoint(x: 0, y: 800), preserveVelocity: false)
        #expect(scrollView.scrollingDisplayLink != nil)

        scrollView.setContentOffset(CGPoint(x: 0, y: 300), animated: false)

        #expect(scrollView.scrollingDisplayLink == nil)
        #expect(scrollView.contentOffset == CGPoint(x: 0, y: 300))
    }

    @Test
    func momentumOverscrollHandsOffToAppKitReboundImmediately() throws {
        let scrollView = ListScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        scrollView.contentSize = CGSize(width: 200, height: 2_000)

        scrollView.scrollWheel(with: try makeWheelEvent(
            deltaY: 100,
            momentumPhase: .began
        ))

        #expect(!scrollView.isUserInteractingWithScroll)
        #expect(scrollView.scrollingDisplayLink != nil)
        let offsetAtHandoff = scrollView.contentOffset

        scrollView.scrollWheel(with: try makeWheelEvent(
            deltaY: 100,
            momentumPhase: .changed
        ))
        #expect(scrollView.contentOffset == offsetAtHandoff)
        scrollView.cancelCurrentScrolling()
    }

    @Test
    func bounceHandoffContinuesIgnoringSystemMomentumAfterCancellation() throws {
        let scrollView = ListScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        scrollView.contentSize = CGSize(width: 200, height: 2_000)

        scrollView.scrollWheel(with: try makeWheelEvent(deltaY: 100, phase: .began))
        scrollView.scrollWheel(with: try makeWheelEvent(deltaY: 0, phase: .ended))
        scrollView.cancelCurrentScrolling()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        let offsetAfterCancellation = scrollView.contentOffset

        let momentumEvent = try makeWheelEvent(
            deltaY: -10,
            momentumPhase: .changed
        )
        #expect(momentumEvent.momentumPhase == .changed)
        scrollView.scrollWheel(with: momentumEvent)

        #expect(scrollView.contentOffset == offsetAfterCancellation)
        scrollView.scrollWheel(with: try makeWheelEvent(
            deltaY: 0,
            momentumPhase: .ended
        ))
    }
}
#endif
