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

    /// A scroll that starts inside the content stays inside it.
    @Test
    func aScrollFromInsideTheContentStaysInside() {
        let scrollView = makeScrollView()
        scrollView.contentOffset = CGPoint(x: 0, y: 1_700)
        scrollView.scroll(to: CGPoint(x: 0, y: 1_800), preserveVelocity: false)

        var time: TimeInterval = 1_000
        for _ in 0 ..< 600 where scrollView.scrollingDisplayLink != nil {
            time += 1.0 / 120.0
            tick(scrollView, at: time)
            #expect(scrollView.contentOffset.y <= scrollView.maximumContentOffset.y)
        }
        #expect(scrollView.contentOffset.y == 1_800)
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
        override var isTracking: Bool { finger || super.isTracking }
        override var isDragging: Bool { finger || super.isDragging }
        override var isDecelerating: Bool { momentum || super.isDecelerating }
    }

    private func makeHandledScrollView() -> HandledScrollView {
        let scrollView = HandledScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        scrollView.contentSize = CGSize(width: 200, height: 2_000)
        scrollView.contentInsetAdjustmentBehavior = .never
        return scrollView
    }

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
