//
//  ListAutoScrollSuppressionUIKitTests.swift
//  ListViewKit
//

#if canImport(UIKit)
import Testing
import UIKit
@testable import ListViewKit

/// The UIKit half of the window that keeps a host from scrolling a list the
/// reader just moved.
///
/// The arming branch this platform has and AppKit does not — `layoutSubviews`
/// arming from `isTracking || isDragging || isDecelerating` — cannot be
/// reached from a test: those are read-only and only a real touch sets them.
/// What is covered here is everything downstream of that branch, which is
/// where the platform-specific code lives.
@Suite(.serialized)
@MainActor
struct ListAutoScrollSuppressionUIKitTests {
    private func makeScrollView() -> ListScrollView {
        let scrollView = ListScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        scrollView.contentSize = CGSize(width: 200, height: 2_000)
        scrollView.setContentOffset(CGPoint(x: 0, y: 500), animated: false)
        // The first layout pass establishes the viewport size, so a resize in
        // a test is a resize rather than the list appearing.
        scrollView.layoutIfNeeded()
        return scrollView
    }

    private func waitOutSuppressionWindow() {
        RunLoop.main.run(until: Date().addingTimeInterval(
            ListScrollView.autoScrollSuppressionWindow * 3
        ))
    }

    @Test
    func resizingTheViewportSuppressesAutoScrollAndTheWindowExpires() {
        let scrollView = makeScrollView()
        #expect(!scrollView.isUserInteractingWithScroll)

        scrollView.frame = CGRect(x: 0, y: 0, width: 200, height: 300)
        scrollView.layoutIfNeeded()
        #expect(scrollView.isAutoScrollSuppressed)
        #expect(scrollView.isUserInteractingWithScroll)

        waitOutSuppressionWindow()
        #expect(!scrollView.isAutoScrollSuppressed)
        #expect(!scrollView.isUserInteractingWithScroll)
    }

    /// `UIScrollView` moves the bounds *origin* to scroll, through the very
    /// layout pass the resize check runs in.
    @Test
    func scrollingAloneIsNotAResize() {
        let scrollView = makeScrollView()

        scrollView.setContentOffset(CGPoint(x: 0, y: 400), animated: false)
        scrollView.layoutIfNeeded()

        #expect(!scrollView.isAutoScrollSuppressed)
    }

    @Test
    func aListGettingItsFirstRealSizeIsNotAResize() {
        let scrollView = ListScrollView(frame: .zero)
        scrollView.contentSize = CGSize(width: 200, height: 2_000)
        scrollView.layoutIfNeeded()
        #expect(!scrollView.isAutoScrollSuppressed)

        scrollView.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        scrollView.layoutIfNeeded()
        #expect(!scrollView.isAutoScrollSuppressed)

        scrollView.frame = CGRect(x: 0, y: 0, width: 200, height: 300)
        scrollView.layoutIfNeeded()
        #expect(scrollView.isAutoScrollSuppressed)
        waitOutSuppressionWindow()
    }

    /// The expiry may only invalidate layout when there is an offset to clamp.
    /// Unconditionally, it closes a loop with the ownership arm in
    /// `layoutSubviews`: a finger resting on the list would drive a full
    /// layout pass ten times a second.
    @Test
    func anExpiryWithNothingToClampSchedulesNoLayout() {
        let scrollView = makeScrollView()

        scrollView.frame = CGRect(x: 0, y: 0, width: 200, height: 300)
        scrollView.layoutIfNeeded()
        #expect(scrollView.isAutoScrollSuppressed)
        #expect(scrollView.isContentOffsetWithinBounds(offset: scrollView.contentOffset))
        #expect(!scrollView.layer.needsLayout())

        waitOutSuppressionWindow()

        #expect(!scrollView.isAutoScrollSuppressed)
        #expect(!scrollView.layer.needsLayout(), "the expiry invalidated layout with nothing to clamp")
    }

    /// The window says the host may not scroll the list. It says nothing about
    /// an offset left outside the content, which is wrong either way.
    @Test
    func aSuppressedListStillClampsAnOffsetTheContentLeftBehind() {
        let scrollView = makeScrollView()
        scrollView.setContentOffset(scrollView.maximumContentOffset, animated: false)
        let wasAtBottom = scrollView.contentOffset.y

        scrollView.frame = CGRect(x: 0, y: 0, width: 200, height: 300)
        scrollView.layoutIfNeeded()
        #expect(scrollView.isAutoScrollSuppressed)

        scrollView.contentSize = CGSize(width: 200, height: 1_000)

        #expect(scrollView.contentOffset.y < wasAtBottom)
        #expect(scrollView.contentOffset.y == scrollView.maximumContentOffset.y)
        scrollView.cancelCurrentScrolling()
    }
}
#endif
