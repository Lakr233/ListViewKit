#if canImport(UIKit)
// UIKit platforms (including Mac Catalyst) are exercised by the UIKit suites.
#elseif canImport(AppKit)
import AppKit
import Testing
@testable import ListViewKit

/// The window that keeps a host from scrolling a list the reader just moved.
@Suite(.serialized)
@MainActor
struct ListAutoScrollSuppressionAppKitTests {
    private func makeScrollView() -> ListScrollView {
        let scrollView = ListScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        scrollView.contentSize = CGSize(width: 200, height: 2_000)
        // Mid-content, so a wheel event in a test is a wheel event rather than
        // an overscroll into a rebound.
        scrollView.setContentOffset(CGPoint(x: 0, y: 500), animated: false)
        // The first layout pass establishes the viewport size, so a resize in
        // a test is a resize rather than the list appearing.
        scrollView.layoutSubtreeIfNeeded()
        return scrollView
    }

    private func makeWheelEvent(
        deltaY: Int32,
        phase: CGScrollPhase? = nil,
        momentumPhase: CGScrollPhase? = nil
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
        return try #require(NSEvent(cgEvent: cgEvent))
    }

    /// Runs the run loop long enough for a pending suppression to expire.
    private func waitOutSuppressionWindow() {
        RunLoop.main.run(until: Date().addingTimeInterval(
            ListScrollView.autoScrollSuppressionWindow * 3
        ))
    }

    // MARK: - Wheel

    @Test
    func aWheelEventSuppressesAutoScrollAndTheWindowExpires() throws {
        let scrollView = makeScrollView()
        #expect(!scrollView.isUserInteractingWithScroll)

        scrollView.scrollWheel(with: try makeWheelEvent(deltaY: 1))
        #expect(scrollView.isAutoScrollSuppressed)
        #expect(scrollView.isUserInteractingWithScroll)

        waitOutSuppressionWindow()
        #expect(!scrollView.isAutoScrollSuppressed)
        #expect(!scrollView.isUserInteractingWithScroll)
        scrollView.cancelCurrentScrolling()
    }

    /// A discrete wheel reports no phases at all, so it has no end to hang the
    /// window off: the debounce is what makes one.
    @Test
    func eachWheelEventRestartsTheWindow() throws {
        let scrollView = makeScrollView()

        for _ in 0 ..< 4 {
            scrollView.scrollWheel(with: try makeWheelEvent(deltaY: 1))
            RunLoop.main.run(until: Date().addingTimeInterval(
                ListScrollView.autoScrollSuppressionWindow * 0.5
            ))
            #expect(scrollView.isAutoScrollSuppressed, "a mid-gesture gap cleared the window")
        }

        waitOutSuppressionWindow()
        #expect(!scrollView.isAutoScrollSuppressed)
        scrollView.cancelCurrentScrolling()
    }

    /// The gesture already reports itself while a finger is down; the window is
    /// only interesting for what it adds after the lift.
    @Test
    func theWindowOutlivesTheGestureItFollows() throws {
        let scrollView = makeScrollView()

        scrollView.scrollWheel(with: try makeWheelEvent(deltaY: 1, phase: .began))
        scrollView.scrollWheel(with: try makeWheelEvent(deltaY: 0, phase: .ended))
        #expect(!scrollView.isScrollOffsetOwnedByUser, "the gesture never ended")
        #expect(scrollView.isUserInteractingWithScroll, "the lift dropped the gate immediately")

        waitOutSuppressionWindow()
        #expect(!scrollView.isUserInteractingWithScroll)
        scrollView.cancelCurrentScrolling()
    }

    /// Once momentum has been handed off to the local rebound, AppKit goes on
    /// delivering its own momentum tail for about a second. The view discards
    /// those, and a window they kept re-arming would outlast a list that has
    /// visibly come to rest.
    @Test
    func momentumTheViewDiscardsDoesNotExtendTheWindow() throws {
        let scrollView = makeScrollView()
        scrollView.scrollWheel(with: try makeWheelEvent(deltaY: 100, momentumPhase: .began))
        #expect(scrollView.isAutoScrollSuppressed)

        waitOutSuppressionWindow()
        #expect(!scrollView.isAutoScrollSuppressed)

        scrollView.scrollWheel(with: try makeWheelEvent(deltaY: 100, momentumPhase: .changed))
        #expect(!scrollView.isAutoScrollSuppressed, "a discarded event re-armed the window")
        scrollView.cancelCurrentScrolling()
    }

    /// A bounce runs several times longer than the window. The gate has to
    /// cover it: a host that scrolls into one cuts it off mid-flight, since
    /// `scroll(to:)` clears the rebound on its first line.
    @Test
    func aReboundHoldsTheGateForAsLongAsItRuns() throws {
        let scrollView = makeScrollView()
        scrollView.scrollWheel(with: try makeWheelEvent(deltaY: 100, momentumPhase: .began))
        #expect(scrollView.isReboundingFromOverscroll, "the overscroll never handed off")

        waitOutSuppressionWindow()
        #expect(!scrollView.isAutoScrollSuppressed, "the window should have expired")
        #expect(scrollView.isUserInteractingWithScroll, "the gate dropped while the bounce ran")
        scrollView.cancelCurrentScrolling()
    }

    // MARK: - Resize

    @Test
    func resizingTheViewportSuppressesAutoScroll() {
        let scrollView = makeScrollView()
        #expect(!scrollView.isAutoScrollSuppressed)

        scrollView.setFrameSize(CGSize(width: 200, height: 300))
        scrollView.layoutSubtreeIfNeeded()
        #expect(scrollView.isAutoScrollSuppressed)

        waitOutSuppressionWindow()
        #expect(!scrollView.isAutoScrollSuppressed)
    }

    /// Auto Layout lays a view out at zero before it lays it out for real. The
    /// second of those passes is the list appearing, and a list that suppressed
    /// itself there would decline the host's opening scroll to the end.
    @Test
    func aListGettingItsFirstRealSizeIsNotAResize() {
        let scrollView = ListScrollView(frame: .zero)
        scrollView.contentSize = CGSize(width: 200, height: 2_000)
        scrollView.layoutSubtreeIfNeeded()
        #expect(!scrollView.isAutoScrollSuppressed)

        scrollView.setFrameSize(CGSize(width: 200, height: 200))
        scrollView.layoutSubtreeIfNeeded()
        #expect(!scrollView.isAutoScrollSuppressed)

        // And it is a resize from there on.
        scrollView.setFrameSize(CGSize(width: 200, height: 300))
        scrollView.layoutSubtreeIfNeeded()
        #expect(scrollView.isAutoScrollSuppressed)
        waitOutSuppressionWindow()
    }

    /// A pane collapsed to nothing and reopened at the size it had shows the
    /// reader exactly what they left, so there is nothing to protect. Reopened
    /// at a different size there is.
    @Test
    func collapsingAndReopeningAPaneIsJudgedOnTheSizeItComesBackAt() {
        let scrollView = makeScrollView()

        scrollView.setFrameSize(CGSize(width: 200, height: 0))
        scrollView.layoutSubtreeIfNeeded()
        scrollView.setFrameSize(CGSize(width: 200, height: 200))
        scrollView.layoutSubtreeIfNeeded()
        #expect(!scrollView.isAutoScrollSuppressed, "reopening at the same size is not a resize")

        scrollView.setFrameSize(CGSize(width: 200, height: 0))
        scrollView.layoutSubtreeIfNeeded()
        scrollView.setFrameSize(CGSize(width: 200, height: 400))
        scrollView.layoutSubtreeIfNeeded()
        #expect(scrollView.isAutoScrollSuppressed, "reopening at a new size is")
        waitOutSuppressionWindow()
    }

    /// Scrolling moves the bounds origin through the same layout pass a resize
    /// reaches, and must not be mistaken for one.
    @Test
    func scrollingAloneIsNotAResize() {
        let scrollView = makeScrollView()

        scrollView.setContentOffset(CGPoint(x: 0, y: 400), animated: false)
        scrollView.layoutSubtreeIfNeeded()

        #expect(!scrollView.isAutoScrollSuppressed)
    }

    // MARK: - What the window must not touch

    /// The window says the host may not scroll the list. It says nothing about
    /// an offset left outside the content, which is wrong either way — and the
    /// clamp is the only thing still running that would notice.
    @Test
    func aSuppressedListStillClampsAnOffsetTheContentLeftBehind() throws {
        let scrollView = makeScrollView()
        scrollView.setContentOffset(scrollView.maximumContentOffset, animated: false)
        let wasAtBottom = scrollView.contentOffset.y

        scrollView.scrollWheel(with: try makeWheelEvent(deltaY: 0))
        #expect(scrollView.isAutoScrollSuppressed)

        scrollView.contentSize = CGSize(width: 200, height: 1_000)

        #expect(scrollView.contentOffset.y < wasAtBottom)
        #expect(scrollView.contentOffset.y == scrollView.maximumContentOffset.y)
        scrollView.cancelCurrentScrolling()
    }

    /// The expiry has to leave an out-of-bounds offset a layout pass to be
    /// clamped in — and has to leave everything else alone. Invalidating
    /// unconditionally closes a loop on UIKit, where the pass re-arms the
    /// window from `isTracking`.
    @Test
    func anExpiryWithNothingToClampSchedulesNoLayout() throws {
        let scrollView = makeScrollView()
        scrollView.scrollWheel(with: try makeWheelEvent(deltaY: 1))
        scrollView.layoutSubtreeIfNeeded()
        #expect(!scrollView.needsLayout)
        #expect(scrollView.isContentOffsetWithinBounds(offset: scrollView.contentOffset))

        waitOutSuppressionWindow()

        #expect(!scrollView.isAutoScrollSuppressed)
        #expect(!scrollView.needsLayout, "the expiry invalidated layout with nothing to clamp")
    }

    /// Nor does it block a scroll the host asks for outright: refusing that
    /// would strand a `scrollToRow` call made from a click.
    @Test
    func aSuppressedListStillAcceptsAProgrammaticScroll() throws {
        let scrollView = makeScrollView()

        scrollView.scrollWheel(with: try makeWheelEvent(deltaY: 1))
        #expect(scrollView.isAutoScrollSuppressed)

        scrollView.scroll(to: CGPoint(x: 0, y: 800), preserveVelocity: false)
        #expect(scrollView.scrollingDisplayLink != nil)
        scrollView.cancelCurrentScrolling()
    }
}
#endif
