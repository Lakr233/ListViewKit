//
//  ListScrollViewUIKitTests.swift
//  ListViewKit
//

#if canImport(UIKit)
import Testing
import UIKit
@testable import ListViewKit

/// The UIKit programmatic scroll, which runs on a display link bound to the
/// view rather than on a `CADisplayLink` aimed at the view.
@Suite(.serialized)
@MainActor
struct ListScrollViewUIKitTests {
    private func makeScrollView() -> ListScrollView {
        let scrollView = ListScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        scrollView.contentSize = CGSize(width: 200, height: 2_000)
        // A window's safe area would otherwise move the offset on arrival,
        // which is UIKit's doing rather than the scroll's.
        scrollView.contentInsetAdjustmentBehavior = .never
        return scrollView
    }

    private func tick(_ scrollView: ListScrollView, at time: TimeInterval) {
        let period = 1.0 / 120.0
        scrollView.handleScrollingAnimation(.init(timestamp: time, targetTimestamp: time + period))
    }

    /// Content shrinking under an offset at its end leaves the offset past
    /// the new end, and the correction scrolls back to it over frames. Each
    /// step used to be held to the bounds, so the first step was the whole
    /// way: a chat's typing row leaving the bottom moved every row 36 pt at
    /// once. From out there the scroll only ever heads in.
    @Test
    func aScrollBackFromPastTheEndTravelsInsteadOfCutting() {
        let scrollView = makeScrollView()
        scrollView.contentOffset = CGPoint(x: 0, y: 1_800)
        #expect(scrollView.maximumContentOffset.y == 1_800)

        // A row leaving the end, inside the list's animated apply.
        scrollView.animatesContentSizeCorrection = true
        scrollView.contentSize = CGSize(width: 200, height: 1_964)
        scrollView.animatesContentSizeCorrection = false
        #expect(scrollView.maximumContentOffset.y == 1_764)
        #expect(scrollView.contentOffset.y == 1_800)
        #expect(scrollView.scrollingDisplayLink != nil)

        var offsets: [CGFloat] = []
        var time: TimeInterval = 1_000
        for _ in 0 ..< 600 where scrollView.scrollingDisplayLink != nil {
            time += 1.0 / 120.0
            tick(scrollView, at: time)
            offsets.append(scrollView.contentOffset.y)
        }

        #expect(scrollView.contentOffset.y == 1_764)
        #expect(scrollView.scrollingDisplayLink == nil)
        // Over frames, every one of them heading in.
        #expect(offsets.filter { $0 > 1_764 }.count >= 5)
        #expect(zip(offsets, offsets.dropFirst()).allSatisfy { $1 <= $0 })
        #expect(offsets.allSatisfy { $0 <= 1_800 && $0 >= 1_764 })
    }

    /// A scroll retargeted onto a nearer edge keeps its velocity, and one
    /// with velocity to spare runs past the target. Past an edge that is
    /// blank space: the frames stop at it, as on AppKit.
    @Test
    func aRetargetedScrollDoesNotOvershootTheContentEdge() {
        let scrollView = makeScrollView()
        scrollView.scroll(to: CGPoint(x: 0, y: 1_800), preserveVelocity: false)
        var time: TimeInterval = 1_000
        for _ in 0 ..< 8 {
            time += 1.0 / 120.0
            tick(scrollView, at: time)
        }
        #expect(scrollView.scrollingContext.y.velocity > 3_000)

        // The content shrinks to end just ahead of the scroll.
        scrollView.contentSize = CGSize(
            width: 200,
            height: scrollView.contentOffset.y + 50 + scrollView.bounds.height
        )
        let edge = scrollView.maximumContentOffset.y
        #expect(scrollView.scrollingContext.y.target == edge)

        var furthest = scrollView.contentOffset.y
        for _ in 0 ..< 600 where scrollView.scrollingDisplayLink != nil {
            time += 1.0 / 120.0
            tick(scrollView, at: time)
            furthest = max(furthest, scrollView.contentOffset.y)
        }
        #expect(furthest <= edge)
        #expect(scrollView.contentOffset.y == edge)
    }

    /// The link holds the view weakly. A `CADisplayLink` retains its target,
    /// so a list dismissed mid-scroll used to live on until the scroll landed.
    @Test
    func aScrollInFlightDoesNotKeepTheViewAlive() {
        weak var released: ListScrollView?
        autoreleasepool {
            let scrollView = makeScrollView()
            scrollView.scroll(to: CGPoint(x: 0, y: 800), preserveVelocity: false)
            #expect(scrollView.scrollingDisplayLink != nil)
            released = scrollView
        }
        #expect(released == nil)
    }

    @Test
    func theScrollingLinkAsksForTheListRate() {
        let scrollView = makeScrollView()
        scrollView.scroll(to: CGPoint(x: 0, y: 800), preserveVelocity: false)

        #expect(scrollView.scrollingDisplayLink?.preferredFrameRateRange == .list)
        scrollView.cancelCurrentScrolling()
    }

    // A Mac Catalyst test bundle has no NSApplication, and creating a UIWindow
    // there raises. The window handling is the same code as on iOS.
    #if !targetEnvironment(macCatalyst)
    /// The link ticks only while the view is in a window. A scroll asked for
    /// before then lands as the view arrives.
    @Test
    func aScrollAskedForOutsideAWindowLandsAsTheViewEntersOne() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let scrollView = makeScrollView()
        scrollView.scroll(to: CGPoint(x: 0, y: 800), preserveVelocity: false)

        window.addSubview(scrollView)
        defer { scrollView.removeFromSuperview() }

        #expect(scrollView.contentOffset.y == 800)
        #expect(scrollView.scrollingDisplayLink == nil)
    }

    /// A scroll the view carries out of its window would otherwise freeze
    /// halfway, waiting for frames that never come.
    @Test
    func leavingTheWindowMidScrollLandsTheScroll() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let scrollView = makeScrollView()
        window.addSubview(scrollView)
        scrollView.scroll(to: CGPoint(x: 0, y: 800), preserveVelocity: false)
        for frame in 0 ..< 10 {
            tick(scrollView, at: 1_000 + Double(frame) / 120)
        }
        try #require(scrollView.contentOffset.y > 0 && scrollView.contentOffset.y < 800)

        scrollView.removeFromSuperview()

        #expect(scrollView.contentOffset.y == 800)
        #expect(scrollView.scrollingDisplayLink == nil)
    }
    #endif

    /// Says the user owns the offset when the test says so: a real touch
    /// cannot be made in a unit test.
    private final class HandledScrollView: ListScrollView {
        var finger = false
        var momentum = false
        /// A finger down that has not dragged: a tap on a row.
        var touch = false
        override var isTracking: Bool { finger || touch || super.isTracking }
        override var isDragging: Bool { finger || super.isDragging }
        override var isDecelerating: Bool { momentum || super.isDecelerating }
    }

    private func makeHandledScrollView() -> HandledScrollView {
        let scrollView = HandledScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        scrollView.contentSize = CGSize(width: 200, height: 2_000)
        scrollView.contentInsetAdjustmentBehavior = .never
        return scrollView
    }

    /// Starts the scroll back a row leaving the end of the content asks
    /// for: offset 1 800 past a new end at 1 764.
    private func startScrollBackFromPastTheEnd(_ scrollView: HandledScrollView) {
        scrollView.contentOffset = CGPoint(x: 0, y: 1_800)
        scrollView.animatesContentSizeCorrection = true
        scrollView.contentSize = CGSize(width: 200, height: 1_964)
        scrollView.animatesContentSizeCorrection = false
    }

    /// A finger resting on the list while it scrolls back from past the
    /// end — a tap on a row — holds it where it is, and the scroll goes on
    /// once the finger lifts. Cancelled, it stayed past the end, blank
    /// beyond the last row: a touch that never drags gives UIKit nothing
    /// to bounce.
    @Test
    func aRestingFingerHoldsAScrollBackUntilItLifts() {
        let scrollView = makeHandledScrollView()
        startScrollBackFromPastTheEnd(scrollView)
        var time: TimeInterval = 3_000
        for _ in 0 ..< 3 {
            time += 1.0 / 120.0
            tick(scrollView, at: time)
        }
        let held = scrollView.contentOffset.y
        #expect(held > 1_764 && held < 1_800)

        scrollView.touch = true
        for _ in 0 ..< 30 {
            time += 1.0 / 120.0
            tick(scrollView, at: time)
        }
        #expect(scrollView.contentOffset.y == held)
        #expect(scrollView.scrollingDisplayLink != nil)

        scrollView.touch = false
        for _ in 0 ..< 600 where scrollView.scrollingDisplayLink != nil {
            time += 1.0 / 120.0
            tick(scrollView, at: time)
        }
        #expect(scrollView.contentOffset.y == 1_764)
    }

    /// A drag, or the momentum it leaves, takes a scroll back over: UIKit
    /// brings an offset past an edge back itself.
    @Test
    func aDragOrMomentumTakesAScrollBackOver() {
        for hand in 0 ..< 2 {
            let scrollView = makeHandledScrollView()
            startScrollBackFromPastTheEnd(scrollView)
            tick(scrollView, at: 4_000)
            if hand == 0 {
                scrollView.finger = true
            } else {
                scrollView.momentum = true
            }
            let offset = scrollView.contentOffset.y

            tick(scrollView, at: 4_000 + 1.0 / 120)

            #expect(scrollView.scrollingDisplayLink == nil)
            #expect(scrollView.contentOffset.y == offset)
        }
    }

    /// A scroll back stopped by the host leaves no blank beyond the end:
    /// nobody's hand holds the offset, so it is put back in.
    @Test
    func aCancelledScrollBackLeavesNoBlankBeyondTheEnd() {
        let scrollView = makeHandledScrollView()
        startScrollBackFromPastTheEnd(scrollView)
        tick(scrollView, at: 5_000)
        tick(scrollView, at: 5_000 + 1.0 / 120)
        #expect(scrollView.contentOffset.y > 1_764)

        scrollView.cancelCurrentScrolling()

        #expect(scrollView.contentOffset.y == 1_764)
        #expect(scrollView.scrollingDisplayLink == nil)
    }

    /// Cancelled inside an animated apply, the scroll back is put back in
    /// at once and starts no other scroll from there.
    @Test
    func aCancelInsideAnAnimatedApplyStartsNoScroll() {
        let scrollView = makeHandledScrollView()
        startScrollBackFromPastTheEnd(scrollView)
        tick(scrollView, at: 6_000)
        #expect(scrollView.contentOffset.y > 1_764)

        scrollView.animatesContentSizeCorrection = true
        scrollView.cancelCurrentScrolling()
        scrollView.animatesContentSizeCorrection = false

        #expect(scrollView.scrollingDisplayLink == nil)
        #expect(scrollView.contentOffset.y == 1_764)
    }

    /// An offset set outright mid scroll back lands there in one write,
    /// with no stop at the edge on the way.
    @Test
    func anOffsetSetMidScrollBackLandsThereInOneWrite() {
        final class Counter: NSObject, UIScrollViewDelegate {
            var offsets: [CGFloat] = []
            func scrollViewDidScroll(_ scrollView: UIScrollView) {
                offsets.append(scrollView.contentOffset.y)
            }
        }
        let scrollView = makeHandledScrollView()
        startScrollBackFromPastTheEnd(scrollView)
        tick(scrollView, at: 7_000)
        let counter = Counter()
        scrollView.delegate = counter

        scrollView.setContentOffset(CGPoint(x: 0, y: 500), animated: false)

        #expect(counter.offsets == [500])
        #expect(scrollView.scrollingDisplayLink == nil)
        scrollView.delegate = nil
    }

    /// A host cancelling the scroll back while a finger rests on the list
    /// leaves no blank beyond the end either: a resting finger is not a
    /// drag, and UIKit will not bounce it.
    @Test
    func aCancelUnderARestingFingerLeavesNoBlank() {
        let scrollView = makeHandledScrollView()
        startScrollBackFromPastTheEnd(scrollView)
        tick(scrollView, at: 8_000)
        scrollView.touch = true
        tick(scrollView, at: 8_000 + 1.0 / 120)

        scrollView.cancelCurrentScrolling()

        #expect(scrollView.contentOffset.y == 1_764)
        scrollView.touch = false
    }

    /// The content shrinking again while a finger rests on a scroll back
    /// moves its target to the new end: once the finger lifts it travels
    /// there, never cutting the last of the way.
    @Test
    func theContentShrinkingUnderARestingFingerMovesTheScrollBacksEnd() {
        let scrollView = makeHandledScrollView()
        startScrollBackFromPastTheEnd(scrollView)
        var time: TimeInterval = 9_000
        time += 1.0 / 120
        tick(scrollView, at: time)
        scrollView.touch = true
        time += 1.0 / 120
        tick(scrollView, at: time)

        scrollView.contentSize = CGSize(width: 200, height: 1_914)
        #expect(scrollView.maximumContentOffset.y == 1_714)
        scrollView.touch = false

        var previous = scrollView.contentOffset.y
        var largest: CGFloat = 0
        for _ in 0 ..< 600 where scrollView.scrollingDisplayLink != nil {
            time += 1.0 / 120
            tick(scrollView, at: time)
            largest = max(largest, previous - scrollView.contentOffset.y)
            previous = scrollView.contentOffset.y
        }
        #expect(scrollView.contentOffset.y == 1_714)
        #expect(largest < 20)
    }

    /// A tap on a list carried past an edge by a long scroll ends that
    /// scroll, as a tap does anywhere, and only brings the offset back to
    /// the edge it is past.
    @Test
    func aTapOnALongScrollFromPastAnEdgeStopsAtTheEdge() {
        let scrollView = makeHandledScrollView()
        startScrollBackFromPastTheEnd(scrollView)
        scrollView.scroll(to: CGPoint(x: 0, y: 0), preserveVelocity: false)
        scrollView.touch = true
        var time: TimeInterval = 10_000
        time += 1.0 / 120
        tick(scrollView, at: time)
        scrollView.touch = false

        for _ in 0 ..< 600 where scrollView.scrollingDisplayLink != nil {
            time += 1.0 / 120
            tick(scrollView, at: time)
        }
        #expect(scrollView.contentOffset.y == 1_764)
    }

    /// A row leaving the end of a list the reader's finger already rests on
    /// travels back once the finger lifts, rather than standing past the end
    /// until something lays the list out again.
    @Test
    func aRowLeavingTheEndUnderARestingFingerTravelsBackOnceItLifts() {
        let scrollView = makeHandledScrollView()
        scrollView.contentOffset = CGPoint(x: 0, y: 1_800)
        scrollView.touch = true
        scrollView.animatesContentSizeCorrection = true
        scrollView.contentSize = CGSize(width: 200, height: 1_964)
        scrollView.animatesContentSizeCorrection = false
        #expect(scrollView.contentOffset.y == 1_800)
        #expect(scrollView.scrollingDisplayLink != nil)

        var time: TimeInterval = 11_000
        for _ in 0 ..< 10 {
            time += 1.0 / 120
            tick(scrollView, at: time)
        }
        #expect(scrollView.contentOffset.y == 1_800)

        scrollView.touch = false
        var previous = scrollView.contentOffset.y
        var largest: CGFloat = 0
        for _ in 0 ..< 600 where scrollView.scrollingDisplayLink != nil {
            time += 1.0 / 120
            tick(scrollView, at: time)
            largest = max(largest, previous - scrollView.contentOffset.y)
            previous = scrollView.contentOffset.y
        }
        #expect(scrollView.contentOffset.y == 1_764)
        #expect(largest < 20)
    }

    #if !targetEnvironment(macCatalyst)
        /// Leaving the window mid scroll back lands where the scroll was
        /// going — inside the content — not where it stood. (UIKit pulls an
        /// offset past an edge to the edge as the view leaves its window,
        /// before the list lands it, so a stop of the list's own at the edge
        /// cannot be told apart here; ``anOffsetSetMidScrollBackLandsThereInOneWrite()``
        /// holds that for the cancel both paths share.)
        @Test
        func leavingTheWindowMidScrollBackLandsWhereItWasGoing() {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
            let scrollView = makeHandledScrollView()
            window.addSubview(scrollView)
            startScrollBackFromPastTheEnd(scrollView)
            scrollView.scroll(to: CGPoint(x: 0, y: 500), preserveVelocity: false)
            tick(scrollView, at: 12_000)
            #expect(scrollView.contentOffset.y > 1_764)

            scrollView.removeFromSuperview()

            #expect(scrollView.contentOffset.y == 500)
            #expect(scrollView.scrollingDisplayLink == nil)
        }
    #endif

    /// A busy main thread can deliver a whole drag between two ticks of the
    /// link. The drag takes the offset over as it moves it; the next tick
    /// used to find the finger lifted and put the offset back where the
    /// spring had it — the reader's scroll undone in one frame. The tick
    /// here stands for one already on its way when the link went.
    @Test
    func aDragBetweenTwoTicksTakesOverTheScroll() {
        let scrollView = makeHandledScrollView()
        scrollView.contentOffset = CGPoint(x: 0, y: 1_000)
        scrollView.scroll(to: CGPoint(x: 0, y: 1_600), preserveVelocity: false)
        tick(scrollView, at: 2_000)
        tick(scrollView, at: 2_000 + 1.0 / 120)
        let springing = scrollView.contentOffset.y

        scrollView.finger = true
        scrollView.contentOffset = CGPoint(x: 0, y: springing - 400)
        scrollView.finger = false
        tick(scrollView, at: 2_000 + 2.0 / 120)

        #expect(scrollView.contentOffset.y == springing - 400)
        #expect(scrollView.scrollingDisplayLink == nil)
    }

    /// The momentum a drag leaves behind is the reader's too.
    @Test
    func momentumTakesOverAScrollStartedUnderIt() {
        let scrollView = makeHandledScrollView()
        scrollView.contentOffset = CGPoint(x: 0, y: 1_000)
        scrollView.scroll(to: CGPoint(x: 0, y: 1_600), preserveVelocity: false)
        tick(scrollView, at: 3_000)

        scrollView.momentum = true
        scrollView.contentOffset = CGPoint(x: 0, y: 900)
        scrollView.momentum = false
        tick(scrollView, at: 3_000 + 1.0 / 120)

        #expect(scrollView.contentOffset.y == 900)
        #expect(scrollView.scrollingDisplayLink == nil)
    }

    /// Writes nobody's hand made — the list's own clamps and jumps — leave a
    /// scroll in flight alone; the link moves it on.
    @Test
    func anOffsetWrittenWithoutAHandLeavesTheScrollRunning() {
        let scrollView = makeHandledScrollView()
        scrollView.contentOffset = CGPoint(x: 0, y: 1_000)
        scrollView.scroll(to: CGPoint(x: 0, y: 1_600), preserveVelocity: false)
        tick(scrollView, at: 4_000)

        scrollView.contentOffset = CGPoint(x: 0, y: 1_010)

        #expect(scrollView.scrollingDisplayLink != nil)
        scrollView.cancelCurrentScrolling()
    }

    // MARK: - Destinations on estimated rows

    private struct Item: Identifiable, Hashable {
        let id: Int
    }

    /// 200 rows that are 150pt each and all still at the 44pt estimate.
    private func makeUnmeasuredListView() -> ListView<Item> {
        let listView = ListView<Item>(frame: CGRect(x: 0, y: 0, width: 200, height: 400))
        listView.contentInsetAdjustmentBehavior = .never
        listView.rows {
            ListRow(ListRowView.self)
                .height { _, _ in 150 }
                .configure { _, _, _ in }
        }
        listView.apply((0 ..< 200).map { Item(id: $0) })
        listView.setNeedsLayout()
        listView.layoutIfNeeded()
        return listView
    }

    private func flyScroll(_ listView: ListView<Item>) {
        let period = 1.0 / 60.0
        var now: TimeInterval = 1_000
        for _ in 0 ..< 2000 where listView.scrollingDisplayLink != nil {
            now += period
            listView.handleScrollingAnimation(.init(timestamp: now, targetTimestamp: now + period))
            listView.layoutIfNeeded()
        }
    }

    /// Rows measured on the way down push the row further than its estimate
    /// said, and compensation does not move the target for rows below the
    /// anchor. The scroll has to keep resolving the row to land on it.
    @Test
    func animatedScrollToAnEstimatedRowLandsOnIt() {
        let listView = makeUnmeasuredListView()

        listView.scrollToRow(at: 60, at: .top, animated: true)
        flyScroll(listView)

        #expect(listView.scrollingDisplayLink == nil)
        #expect(abs(listView.rectForRow(at: 60).minY - listView.contentOffset.y) < 1)
    }

    @Test
    func animatedScrollToTheBottomOfAnEstimatedListReachesIt() {
        let listView = makeUnmeasuredListView()

        listView.scrollToBottom(animated: true)
        flyScroll(listView)

        #expect(listView.scrollingDisplayLink == nil)
        #expect(listView.isScrolledToBottom())
    }
}
#endif
