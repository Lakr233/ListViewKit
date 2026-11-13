#if canImport(UIKit)
// UIKit platforms (including Mac Catalyst) scroll by touch through UIScrollView.
#elseif canImport(AppKit)
import AppKit
import Testing
@testable import ListViewKit

/// A finger on a touch display. No test can put one there, so these drive the
/// three steps the pan recognizer reports, and check the wiring separately.
/// A pan whose state and location the test dictates, in the scroll view's own
/// coordinates, the way the real one answers `location(in:)`.
private final class ScriptedPan: NSPanGestureRecognizer {
    var scriptedLocation: CGPoint = .zero
    var scriptedState: NSGestureRecognizer.State = .possible

    // The stored state only moves while AppKit is delivering events.
    override var state: NSGestureRecognizer.State {
        get { scriptedState }
        set { scriptedState = newValue }
    }

    override func location(in _: NSView?) -> NSPoint {
        scriptedLocation
    }
}

private final class MouseTrackingRow: NSView {
    override func mouseDown(with _: NSEvent) {}
}

@Suite(.serialized)
@MainActor
struct ListScrollViewTouchAppKitTests {
    private func makeScrollView(offsetY: CGFloat = 500) -> ListScrollView {
        let scrollView = ListScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        scrollView.contentSize = CGSize(width: 200, height: 2_000)
        scrollView.contentOffset = CGPoint(x: 0, y: offsetY)
        return scrollView
    }

    private func makeWheelEvent(deltaY: Int32, phase: CGScrollPhase) throws -> NSEvent {
        let cgEvent = try #require(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: deltaY,
            wheel2: 0,
            wheel3: 0
        ))
        cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        return try #require(NSEvent(cgEvent: cgEvent))
    }

    @Test
    func touchPanRecognizerHearsOnlyDirectTouches() throws {
        guard #available(macOS 27.0, *) else { return }
        let scrollView = makeScrollView()
        let pans = scrollView.gestureRecognizers.compactMap { $0 as? NSPanGestureRecognizer }
        let pan = try #require(pans.first)

        #expect(pans.count == 1)
        // No button in the mask: the mouse and the trackpad never begin it.
        #expect(pan.buttonMask == 0)
        #expect(pan.allowedTouchTypes == .direct)
        #expect(pan.delegate != nil)
    }

    /// Through the recognizer's own report, so the conversion from its
    /// coordinates is what decides the direction.
    @Test
    func recognizerReportsCarryTheContentWithTheFinger() {
        let scrollView = makeScrollView()
        #expect(scrollView.isFlipped)
        let pan = ScriptedPan(target: nil, action: nil)

        // Content coordinates: the viewport's top edge sits at the offset.
        pan.scriptedLocation = CGPoint(x: 50, y: scrollView.contentOffset.y + 100)
        pan.state = .began
        scrollView.touchPanDidChange(pan)
        #expect(scrollView.contentOffset.y == 500)

        // 30 points down the display. The bounds have not moved yet, so the
        // same content now reads 30 points further along.
        pan.scriptedLocation = CGPoint(x: 50, y: scrollView.contentOffset.y + 130)
        pan.state = .changed
        scrollView.touchPanDidChange(pan)
        #expect(scrollView.contentOffset.y == 470)

        // The finger holds still on the display while the report repeats.
        pan.scriptedLocation = CGPoint(x: 50, y: scrollView.contentOffset.y + 130)
        scrollView.touchPanDidChange(pan)
        #expect(scrollView.contentOffset.y == 470)

        pan.state = .cancelled
        scrollView.touchPanDidChange(pan)
        #expect(!scrollView.isScrollOffsetOwnedByUser)
    }

    @Test
    func overlayScrollViewLeavesTouchScrollingToTheList() throws {
        guard #available(macOS 27.0, *) else { return }
        let scrollView = makeScrollView()
        let overlay = try #require(scrollView.subviews.compactMap { $0 as? NSScrollView }.first)
        #expect(overlay.value(forKey: "touchScrollingEnabled") as? Bool == false)
    }

    @Test
    func emulatedMouseDragInARowWaitsForTheScroll() {
        let scrollView = makeScrollView()
        let row = MouseTrackingRow(frame: CGRect(x: 0, y: 500, width: 200, height: 50))
        scrollView.addSubview(row)

        // What AppKit hands a view that overrides `mouseDown(with:)`.
        let emulated = NSPanGestureRecognizer(target: row, action: Selector(("_panForLeftMouseRecognized:")))
        emulated.buttonMask = 0
        row.addGestureRecognizer(emulated)
        #expect(scrollView.touchScrollTakesPrecedence(over: emulated))

        // A pan the row asked for keeps its finger.
        let own = NSPanGestureRecognizer(target: row, action: #selector(NSView.layout))
        row.addGestureRecognizer(own)
        #expect(!scrollView.touchScrollTakesPrecedence(over: own))

        // Nor anything outside the list.
        let outsider = MouseTrackingRow(frame: .zero)
        let foreign = NSPanGestureRecognizer(target: outsider, action: Selector(("_panForLeftMouseRecognized:")))
        outsider.addGestureRecognizer(foreign)
        #expect(!scrollView.touchScrollTakesPrecedence(over: foreign))
    }

    @Test
    func contentFollowsTheFinger() {
        let scrollView = makeScrollView()

        scrollView.touchScrollBegan(atViewportY: 100, timestamp: 10)
        #expect(scrollView.isScrollOffsetOwnedByUser)

        // Up the display: later content comes into view.
        scrollView.touchScrollMoved(toViewportY: 60, timestamp: 10.01)
        #expect(scrollView.contentOffset.y == 540)

        // And back down past where it started.
        scrollView.touchScrollMoved(toViewportY: 130, timestamp: 10.02)
        #expect(scrollView.contentOffset.y == 470)
        #expect(scrollView.interactionLocationInViewportY == 130)

        scrollView.touchScrollEnded(cancelled: true, timestamp: 10.03)
        #expect(!scrollView.isScrollOffsetOwnedByUser)
        #expect(scrollView.contentOffset.y == 470)
    }

    @Test
    func flickGlidesAfterTheFingerLifts() {
        let scrollView = makeScrollView()

        scrollView.touchScrollBegan(atViewportY: 150, timestamp: 10)
        scrollView.touchScrollMoved(toViewportY: 130, timestamp: 10.01)
        scrollView.touchScrollMoved(toViewportY: 110, timestamp: 10.02)
        scrollView.touchScrollEnded(cancelled: false, timestamp: 10.025)

        // Momentum owns the offset now, on the display link.
        #expect(scrollView.isScrollOffsetOwnedByUser)
        #expect(scrollView.scrollingDisplayLink != nil)
        scrollView.cancelCurrentScrolling()
    }

    @Test
    func fingerThatRestedBeforeLiftingDoesNotGlide() {
        let scrollView = makeScrollView()

        scrollView.touchScrollBegan(atViewportY: 150, timestamp: 10)
        scrollView.touchScrollMoved(toViewportY: 130, timestamp: 10.01)
        scrollView.touchScrollMoved(toViewportY: 110, timestamp: 10.02)
        // The recognizer says nothing while the finger holds still.
        scrollView.touchScrollEnded(cancelled: false, timestamp: 10.5)

        #expect(!scrollView.isScrollOffsetOwnedByUser)
        #expect(scrollView.scrollingDisplayLink == nil)
        #expect(scrollView.contentOffset.y == 540)
    }

    @Test
    func draggingPastAnEdgeRubberBandsThenRebounds() {
        let scrollView = makeScrollView(offsetY: 0)

        scrollView.touchScrollBegan(atViewportY: 20, timestamp: 10)
        scrollView.touchScrollMoved(toViewportY: 120, timestamp: 10.2)

        // Past the top, but by less than the finger travelled, and by more
        // than a trackpad would give for the same distance.
        let overscroll = -scrollView.contentOffset.y
        let trackpadOverscroll = AppKitScrollPhysics.elasticDelta(forReboundDelta: 100, dimension: 200)
        #expect(overscroll > trackpadOverscroll)
        #expect(overscroll < 100)

        scrollView.touchScrollEnded(cancelled: false, timestamp: 10.5)
        #expect(scrollView.isReboundingFromOverscroll)
        #expect(scrollView.scrollingDisplayLink != nil)
        scrollView.cancelCurrentScrolling()
    }

    @Test
    func grabbingAnOverscrolledListDoesNotJump() {
        let scrollView = makeScrollView(offsetY: 0)

        scrollView.touchScrollBegan(atViewportY: 20, timestamp: 10)
        scrollView.touchScrollMoved(toViewportY: 120, timestamp: 10.2)
        scrollView.touchScrollEnded(cancelled: false, timestamp: 10.5)
        let held = scrollView.contentOffset.y

        // Caught mid-rebound: the content stays under the new finger.
        scrollView.touchScrollBegan(atViewportY: 50, timestamp: 10.6)
        #expect(scrollView.contentOffset.y == held)
        scrollView.touchScrollMoved(toViewportY: 50, timestamp: 10.61)
        #expect(abs(scrollView.contentOffset.y - held) < 0.001)
        scrollView.touchScrollEnded(cancelled: true, timestamp: 10.62)
        scrollView.cancelCurrentScrolling()
    }

    @Test
    func wheelIsIgnoredWhileAFingerDragsTheList() throws {
        let scrollView = makeScrollView()

        scrollView.touchScrollBegan(atViewportY: 100, timestamp: 10)
        scrollView.touchScrollMoved(toViewportY: 90, timestamp: 10.01)
        scrollView.scrollWheel(with: try makeWheelEvent(deltaY: 5, phase: .changed))
        #expect(scrollView.contentOffset.y == 510)

        scrollView.touchScrollEnded(cancelled: true, timestamp: 10.02)

        // And heard again once the finger is gone.
        scrollView.scrollWheel(with: try makeWheelEvent(deltaY: 1, phase: .began))
        #expect(scrollView.contentOffset.y != 510)
        scrollView.scrollWheel(with: try makeWheelEvent(deltaY: 0, phase: .cancelled))
    }

    @Test
    func touchScrollSuppressesAutoScroll() {
        let scrollView = makeScrollView()
        #expect(!scrollView.isAutoScrollSuppressed)

        scrollView.touchScrollBegan(atViewportY: 100, timestamp: 10)
        #expect(scrollView.isAutoScrollSuppressed)
        scrollView.touchScrollEnded(cancelled: true, timestamp: 10.01)
    }

    @Test
    func strayStepsWithoutABeginAreIgnored() {
        let scrollView = makeScrollView()

        scrollView.touchScrollMoved(toViewportY: 10, timestamp: 10)
        scrollView.touchScrollEnded(cancelled: false, timestamp: 10.01)

        #expect(scrollView.contentOffset.y == 500)
        #expect(!scrollView.isScrollOffsetOwnedByUser)
    }
}
#endif
