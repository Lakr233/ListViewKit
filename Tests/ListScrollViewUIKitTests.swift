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
}
#endif
