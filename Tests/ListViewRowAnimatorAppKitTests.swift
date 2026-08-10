//
//  ListViewRowAnimatorAppKitTests.swift
//  ListViewKit
//

#if canImport(UIKit)
// UIKit platforms (including Mac Catalyst) are exercised by the UIKit suites.
#elseif canImport(AppKit)
import AppKit
import Testing
@testable import ListViewKit

private struct AnimatorItem: Identifiable, Hashable {
    let id: Int
}

/// The built-in animator, when that is what is installed.
///
/// The list holds `any ListRowAnimator`, which is the point of the protocol;
/// the assertions here are about what the spring in particular did.
private extension ListView {
    var spring: ListScrollSpring? { rowAnimator as? ListScrollSpring }
}

/// Never settles, which the list has to tolerate: a continuous effect is a
/// legitimate thing to write, so the link is not forced off.
private struct NeverSettlingAnimator: ListRowAnimator {
    var wantsNextFrame: Bool { true }
}

/// Ticks are driven by hand rather than by a display link.
///
/// A link needs a window and delivers frames on the system's schedule, which
/// would make every assertion here a race. What the link decides is *whether*
/// to tick; what a tick does is the part worth pinning down, and that is a
/// function call.
@Suite(.serialized)
@MainActor
struct ListViewRowAnimatorAppKitTests {
    private static let rowHeight: CGFloat = 100
    private static let frame: TimeInterval = 1.0 / 120.0

    private func makeListView(
        count: Int = 60,
        size: CGSize = CGSize(width: 200, height: 400)
    ) -> ListView<AnimatorItem> {
        let listView = ListView<AnimatorItem>(frame: CGRect(origin: .zero, size: size))
        listView.rows {
            ListRow(ListRowView.self)
                .height { _, _ in Self.rowHeight }
                .configure { _, _, _ in }
        }
        listView.apply((0 ..< count).map { AnimatorItem(id: $0) })
        drain(listView)
        // The spread only exists under the hand, so these tests hold one down
        // for the duration. Individual tests lift it where the lift is the
        // point.
        listView._isTracking = true
        return listView
    }

    private func drain(_ listView: ListView<AnimatorItem>) {
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()
        for _ in 0 ..< 200 where listView.rowLayout.hasPendingRows {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()
    }

    private func scroll(_ listView: ListView<AnimatorItem>, by dy: CGFloat) {
        listView.contentOffset.y += dy
        listView.layoutSubtreeIfNeeded()
    }

    private func displacements(_ listView: ListView<AnimatorItem>) -> [CGFloat] {
        listView.visibleRowViews
            .sorted { $0.placedFrame.minY < $1.placedFrame.minY }
            .map(\.presentationOffset)
    }

    // MARK: - The truth channel

    /// Layout keeps its own record of where rows go, so a displacement cannot
    /// be mistaken for one.
    @Test
    func placedFrameTracksTheLayoutAndIgnoresDisplacement() {
        let listView = makeListView()
        listView.rowAnimator = ListScrollSpring()

        for _ in 0 ..< 20 {
            scroll(listView, by: 40)
            listView.tickRowAnimator(duration: Self.frame)

            for (identifier, entry) in listView.visibleRows {
                let index = try! #require(listView.index(of: identifier))
                #expect(entry.view.placedFrame == listView.rectForRow(at: index))
            }
        }
        #expect(displacements(listView).contains { $0 != 0 })
    }

    /// Rows are displaced away from where they were placed, by exactly what
    /// the model says.
    @Test
    func rowsAreShownAtTheirPlacementPlusTheDisplacement() {
        let listView = makeListView()
        listView.rowAnimator = ListScrollSpring()

        scroll(listView, by: 200)
        listView.tickRowAnimator(duration: Self.frame)

        for row in listView.visibleRowViews {
            #expect(row.frame.minY == row.placedFrame.minY + row.presentationOffset)
        }
    }

    // MARK: - Rest

    /// Nothing is left on screen once the spring settles.
    @Test
    func displacementReturnsToZeroAndTheLedgerEmpties() {
        let listView = makeListView()
        listView.rowAnimator = ListScrollSpring()

        scroll(listView, by: 300)
        listView.tickRowAnimator(duration: Self.frame)
        #expect(displacements(listView).contains { $0 != 0 })

        for _ in 0 ..< 400 {
            listView.tickRowAnimator(duration: Self.frame)
        }

        #expect(listView.spring?.isAtRest == true)
        #expect(displacements(listView).allSatisfy { $0 == 0 })
        #expect(listView.scrollLedger.pending == 0)
        for row in listView.visibleRowViews {
            #expect(row.frame == row.placedFrame)
        }
    }

    // MARK: - What counts as travel

    /// Compensation moves the offset precisely so that nothing appears to
    /// move, so it may not reach the spring.
    @Test
    func compensationIsNotFedToTheSpring() {
        let listView = makeListView()
        listView.rowAnimator = ListScrollSpring()
        listView.layoutSubtreeIfNeeded()
        listView.tickRowAnimator(duration: Self.frame)

        let before = listView.spring?.stretch
        listView.compensateScrollOffset(by: 250)
        listView.tickRowAnimator(duration: Self.frame)

        #expect(listView.spring?.stretch == before)
        #expect(listView.scrollLedger.pending == 0)
    }

    /// A jump relocates the reader instead of carrying them.
    @Test
    func anUnanimatedOffsetJumpIsNotTravel() {
        let listView = makeListView()
        listView.rowAnimator = ListScrollSpring()
        listView.layoutSubtreeIfNeeded()
        listView.tickRowAnimator(duration: Self.frame)

        listView.setContentOffset(CGPoint(x: 0, y: 2000), animated: false)
        listView.layoutSubtreeIfNeeded()
        listView.tickRowAnimator(duration: Self.frame)

        #expect(listView.spring?.isAtRest == true)
        #expect(displacements(listView).allSatisfy { $0 == 0 })
    }

    /// Dragging is travel, and it reaches the spring whether or not a layout
    /// pass happened to run first.
    @Test
    func scrollingIsTravelAndIsCountedExactlyOnce() {
        let listView = makeListView()
        listView.rowAnimator = ListScrollSpring()
        listView.layoutSubtreeIfNeeded()
        listView.tickRowAnimator(duration: Self.frame)

        // No layout between the write and the tick.
        listView.contentOffset.y += 50
        listView.tickRowAnimator(duration: Self.frame)
        let afterFirst = try! #require(listView.spring?.stretch)
        #expect(afterFirst > 0)

        // Laying out afterwards must not deliver the same travel again.
        listView.layoutSubtreeIfNeeded()
        let stretchBefore = try! #require(listView.spring?.stretch)
        listView.tickRowAnimator(duration: Self.frame)
        let afterSecond = try! #require(listView.spring?.stretch)
        // With nothing new arriving the spring only decays.
        #expect(afterSecond < stretchBefore)
    }

    // MARK: - Frames

    /// A layout pass is not a frame. Several can run for one.
    @Test
    func repeatedLayoutInOneFrameAdvancesTheSpringOnce() {
        let listView = makeListView()
        listView.rowAnimator = ListScrollSpring()
        listView.layoutSubtreeIfNeeded()
        listView.tickRowAnimator(duration: Self.frame)

        listView.contentOffset.y += 60
        listView.tickRowAnimator(duration: Self.frame)
        let afterTick = try! #require(listView.spring?.stretch)
        let ticks = listView.animatorTickCount

        for _ in 0 ..< 5 {
            listView.needsLayout = true
            listView.layoutSubtreeIfNeeded()
        }

        #expect(listView.animatorTickCount == ticks)
        #expect(listView.spring?.stretch == afterTick)
    }

    /// An idle list must not cost a frame.
    @Test
    func anIdleListNeverTicks() {
        let listView = makeListView()
        listView.rowAnimator = ListScrollSpring()
        listView.animatorTickCount = 0

        for _ in 0 ..< 10 {
            listView.needsLayout = true
            listView.layoutSubtreeIfNeeded()
        }
        #expect(listView.animatorTickCount == 0)
        #expect(listView.rowAnimatorLink == nil)
    }

    /// With no animator the list does not read the ledger, run a link, or
    /// touch a row.
    @Test
    func noAnimatorMeansNoWorkAtAll() {
        let listView = makeListView()
        scroll(listView, by: 400)

        #expect(listView.rowAnimatorLink == nil)
        #expect(listView.animatorTickCount == 0)
        for row in listView.visibleRowViews {
            #expect(row.presentationOffset == 0)
            #expect(row.frame == row.placedFrame)
        }
    }

    // MARK: - Reuse

    /// A recycled row must not carry the previous item's displacement to the
    /// next one.
    ///
    /// Asserted with the animator gone, because that is the case nothing
    /// corrects: while one is installed the landing pass overwrites a stale
    /// displacement on the way past, and the test would pass either way.
    @Test
    func aPooledRowDoesNotCarryDisplacementIntoAListWithNoAnimator() {
        let listView = makeListView()
        listView.rowAnimator = ListScrollSpring()

        for _ in 0 ..< 10 {
            scroll(listView, by: 40)
            listView.tickRowAnimator(duration: Self.frame)
        }
        #expect(displacements(listView).contains { $0 != 0 })

        // Far enough that every mounted row is recycled into the pool.
        scroll(listView, by: 3000)
        listView.rowAnimator = nil
        // Back again, which mounts those same views for new items.
        scroll(listView, by: -3000)

        #expect(!listView.visibleRowViews.isEmpty)
        for row in listView.visibleRowViews {
            #expect(row.presentationOffset == 0)
            #expect(row.frame == row.placedFrame)
        }
    }

    /// A row mounted by a layout pass has to be displaced by that same pass.
    ///
    /// Scrolling mounts rows at the leading edge, and it is a layout pass that
    /// does it — not a tick. A row placed without the displacement its
    /// neighbours are carrying sits a full stretch away from where it belongs
    /// for as long as it takes the next frame to arrive.
    @Test
    func rowsMountedByALayoutPassAreDisplacedByIt() {
        let listView = makeListView()
        listView.rowAnimator = ListScrollSpring()

        for _ in 0 ..< 10 {
            scroll(listView, by: 40)
            listView.tickRowAnimator(duration: Self.frame)
        }
        #expect(displacements(listView).contains { $0 != 0 })

        let before = Set(listView.visibleRows.keys)
        // Layout only. No tick follows, so nothing else can fix this up.
        scroll(listView, by: 250)
        #expect(!Set(listView.visibleRows.keys).subtracting(before).isEmpty)

        let spring = try! #require(listView.spring)
        for row in listView.visibleRowViews {
            #expect(row.presentationOffset == spring.displacement(forRowCenteredAt: row.placedFrame.midY))
            #expect(row.frame.minY == row.placedFrame.minY + row.presentationOffset)
        }
    }

    /// A reorder arriving mid-displacement animates the travel, not the
    /// displacement.
    ///
    /// The additive slide contributes the distance a row still has to cover.
    /// Measuring that from the layer would fold in the displacement the row is
    /// carrying, and the reorder would spend its curve undoing an offset that
    /// is not going anywhere.
    @Test
    func aReorderAnimatesPlacementTravelAndNotTheDisplacement() throws {
        let listView = makeListView(count: 8)
        listView.rowAnimator = ListScrollSpring()

        for _ in 0 ..< 10 {
            scroll(listView, by: 30)
            listView.tickRowAnimator(duration: Self.frame)
        }

        let row = try #require(listView.visibleRowViews.first { $0.presentationOffset != 0 })
        let displacement = row.presentationOffset
        let before = row.placedFrame
        let after = before.offsetBy(dx: 0, dy: 100)

        setRowFrame(after, on: row, animated: true)

        let keys = try #require(row.layer?.animationKeys())
        let slideKey = try #require(keys.last { $0.hasPrefix("listRowSlide") })
        let slide = try #require(row.layer?.animation(forKey: slideKey) as? CASpringAnimation)
        let from = try #require(slide.fromValue as? CGPoint)

        // The row has 100pt of placement to cover. Measuring the slide off the
        // layer would ask it to cover the displacement as well.
        #expect(abs(from.y - (before.midY - after.midY)) < 1e-6)
        #expect(abs(from.y - (before.midY - after.midY + displacement)) > 1e-6)
    }

    /// Resetting drops the state and everything it put on screen.
    @Test
    func resetLeavesNoResidue() {
        let listView = makeListView()
        listView.rowAnimator = ListScrollSpring()

        scroll(listView, by: 300)
        listView.tickRowAnimator(duration: Self.frame)
        #expect(displacements(listView).contains { $0 != 0 })

        listView.resetRowAnimator()

        #expect(listView.spring?.isAtRest == true)
        #expect(listView.scrollLedger.pending == 0)
        #expect(listView.rowAnimatorLink == nil)
        #expect(displacements(listView).allSatisfy { $0 == 0 })
    }

    // MARK: - The link

    /// Puts the list in a real window, which is what the link requires.
    ///
    /// Everything above drives ticks by hand and so never reaches this branch.
    /// Whether a link is running is a separate question from what a tick does,
    /// and it needs a host to be asked at all.
    private func windowed(_ listView: ListView<AnimatorItem>) -> NSWindow {
        let window = NSWindow(
            contentRect: listView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = listView
        listView.frame = window.contentView?.bounds ?? listView.frame
        drain(listView)
        return window
    }

    @Test
    func travelStartsALinkAndRestStopsIt() {
        let listView = makeListView()
        let window = windowed(listView)
        defer { window.contentView = nil }

        listView.rowAnimator = ListScrollSpring()
        #expect(listView.rowAnimatorLink == nil)

        // Accruing travel is what lights the first frame: at rest with an
        // empty ledger nothing would ever ask for one.
        scroll(listView, by: 200)
        #expect(listView.rowAnimatorLink != nil)

        for _ in 0 ..< 400 {
            listView.tickRowAnimator(duration: Self.frame)
        }
        #expect(listView.spring?.isAtRest == true)
        #expect(listView.rowAnimatorLink == nil)
    }

    /// An animator that never settles keeps its link, and that is allowed.
    @Test
    func anAnimatorThatAlwaysWantsFramesKeepsItsLink() {
        let listView = makeListView()
        let window = windowed(listView)
        defer { window.contentView = nil }

        listView.rowAnimator = NeverSettlingAnimator()
        scroll(listView, by: 100)
        #expect(listView.rowAnimatorLink != nil)

        for _ in 0 ..< 50 {
            listView.tickRowAnimator(duration: Self.frame)
        }
        #expect(listView.rowAnimatorLink != nil)
    }

    /// Leaving the window drops the link whatever the animator wants.
    @Test
    func leavingTheWindowStopsTheLink() {
        let listView = makeListView()
        let window = windowed(listView)

        listView.rowAnimator = NeverSettlingAnimator()
        scroll(listView, by: 100)
        #expect(listView.rowAnimatorLink != nil)

        window.contentView = nil
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()
        #expect(listView.rowAnimatorLink == nil)
    }

    /// Taking the animator away stops the link too.
    @Test
    func clearingTheAnimatorStopsTheLink() {
        let listView = makeListView()
        let window = windowed(listView)
        defer { window.contentView = nil }

        listView.rowAnimator = NeverSettlingAnimator()
        scroll(listView, by: 100)
        #expect(listView.rowAnimatorLink != nil)

        listView.resetRowAnimator()
        listView.rowAnimator = nil
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()
        #expect(listView.rowAnimatorLink == nil)
    }

    // MARK: - Shape on screen

    /// Rows spread apart, and approach each other only within the falloff's
    /// slope.
    ///
    /// Not "never into each other": the Messages trace closes gaps below rest
    /// in every gesture, and forbidding it is what the retired sign gate did —
    /// at the price of collapsing the whole field to zero the frame a
    /// direction changed. The bound that replaced the gate is the slope,
    /// `maximumStretch / resistanceFactor` of the rows' separation, which the
    /// defaults keep under 2% — invisible, where the gate's pop was measured
    /// on a device as a 12px gap snapping shut between two frames.
    @Test
    func displacedRowsStayInOrderAndOpenGaps() {
        let listView = makeListView()
        let spring = ListScrollSpring()
        listView.rowAnimator = spring
        let slope = spring.maximumStretch / spring.resistanceFactor

        var sawAGap = false
        for pass in 0 ..< 90 {
            // Down, then caught and dragged back up: the reversal is where
            // the retired gate snapped and where closing happens at all.
            scroll(listView, by: pass < 60 ? 25 : -25)
            listView.tickRowAnimator(duration: Self.frame)

            let rows = listView.visibleRowViews.sorted { $0.placedFrame.minY < $1.placedFrame.minY }
            for (previous, next) in zip(rows, rows.dropFirst()) {
                // Contiguous before displacement, so any daylight is opened,
                // and any overlap is bounded by the slope.
                let separation = next.placedFrame.midY - previous.placedFrame.midY
                #expect(next.frame.minY >= previous.frame.maxY - separation * slope - 1e-6)
                if next.frame.minY > previous.frame.maxY + 1e-6 { sawAGap = true }
            }
        }
        #expect(sawAGap, "scrolling should have opened at least one gap")
    }
}
#endif
