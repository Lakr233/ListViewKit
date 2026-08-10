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
/// the assertions here are about what the attachments in particular did.
private extension ListView {
    var bouncy: ListBouncyAnimator? { rowAnimator as? ListBouncyAnimator }
    /// Every attachment's displacement, keyed the way the board keys them.
    var attachmentValues: [Int: Double]? {
        bouncy.map { $0.board.attachments.mapValues(\.spring.value) }
    }
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
        // Deliberately no hand held down: the original pumps every bounds
        // change through the same formula, momentum included, so the effect
        // must not need one.
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
        listView.rowAnimator = ListBouncyAnimator()

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
        listView.rowAnimator = ListBouncyAnimator()

        scroll(listView, by: 200)
        listView.tickRowAnimator(duration: Self.frame)

        for row in listView.visibleRowViews {
            #expect(row.frame.minY == row.placedFrame.minY + row.presentationOffset)
        }
    }

    // MARK: - Rest

    /// Nothing is left on screen once the springs settle.
    @Test
    func displacementReturnsToZeroAndTheLedgerEmpties() {
        let listView = makeListView()
        listView.rowAnimator = ListBouncyAnimator()
        // The original's `prepare()` runs before the first bounds change, so
        // the rows are on springs before the travel arrives.
        listView.layoutSubtreeIfNeeded()

        scroll(listView, by: 300)
        listView.tickRowAnimator(duration: Self.frame)
        #expect(displacements(listView).contains { $0 != 0 })

        for _ in 0 ..< 400 {
            listView.tickRowAnimator(duration: Self.frame)
        }

        #expect(listView.bouncy?.wantsNextFrame == false)
        #expect(displacements(listView).allSatisfy { $0 == 0 })
        #expect(listView.scrollLedger.pending == 0)
        for row in listView.visibleRowViews {
            #expect(row.frame == row.placedFrame)
        }
    }

    // MARK: - What counts as travel

    /// Compensation moves the offset precisely so that nothing appears to
    /// move, so it may not reach the attachments.
    @Test
    func compensationIsNotFedToTheAttachments() {
        let listView = makeListView()
        listView.rowAnimator = ListBouncyAnimator()
        listView.layoutSubtreeIfNeeded()
        listView.tickRowAnimator(duration: Self.frame)

        let before = listView.attachmentValues
        listView.compensateScrollOffset(by: 250)
        listView.tickRowAnimator(duration: Self.frame)

        #expect(listView.attachmentValues == before)
        #expect(listView.scrollLedger.pending == 0)
    }

    /// A jump relocates the reader instead of carrying them.
    @Test
    func anUnanimatedOffsetJumpIsNotTravel() {
        let listView = makeListView()
        listView.rowAnimator = ListBouncyAnimator()
        listView.layoutSubtreeIfNeeded()
        listView.tickRowAnimator(duration: Self.frame)

        listView.setContentOffset(CGPoint(x: 0, y: 2000), animated: false)
        listView.layoutSubtreeIfNeeded()
        listView.tickRowAnimator(duration: Self.frame)

        #expect(listView.bouncy?.wantsNextFrame == false)
        #expect(displacements(listView).allSatisfy { $0 == 0 })
    }

    /// Dragging is travel, and it reaches the attachments whether or not a
    /// layout pass happened to run first.
    @Test
    func scrollingIsTravelAndIsCountedExactlyOnce() {
        let listView = makeListView()
        listView.rowAnimator = ListBouncyAnimator()
        listView.layoutSubtreeIfNeeded()
        listView.tickRowAnimator(duration: Self.frame)

        // No layout between the write and the tick.
        listView.contentOffset.y += 50
        listView.tickRowAnimator(duration: Self.frame)
        let key = try! #require(
            listView.attachmentValues?.max { abs($0.value) < abs($1.value) }?.key
        )
        let afterFirst = try! #require(listView.attachmentValues?[key])
        #expect(afterFirst > 0)

        // Laying out afterwards must not deliver the same travel again.
        listView.layoutSubtreeIfNeeded()
        let valueBefore = try! #require(listView.attachmentValues?[key])
        listView.tickRowAnimator(duration: Self.frame)
        let afterSecond = try! #require(listView.attachmentValues?[key])
        // With nothing new arriving the spring only decays.
        #expect(afterSecond < valueBefore)
    }

    // MARK: - Frames

    /// A layout pass is not a frame. Several can run for one.
    @Test
    func repeatedLayoutInOneFrameAdvancesTheSpringsOnce() {
        let listView = makeListView()
        listView.rowAnimator = ListBouncyAnimator()
        listView.layoutSubtreeIfNeeded()
        listView.tickRowAnimator(duration: Self.frame)

        listView.contentOffset.y += 60
        listView.tickRowAnimator(duration: Self.frame)
        let afterTick = try! #require(listView.attachmentValues)
        let ticks = listView.animatorTickCount

        for _ in 0 ..< 5 {
            listView.needsLayout = true
            listView.layoutSubtreeIfNeeded()
        }

        #expect(listView.animatorTickCount == ticks)
        // The passes may attach rows the moved offset mounted — undisplaced,
        // which is where a new attachment starts — but no spring in flight
        // may have advanced.
        for (key, value) in afterTick {
            #expect(listView.attachmentValues?[key] == value)
        }
        for (key, value) in listView.attachmentValues ?? [:] where afterTick[key] == nil {
            #expect(value == 0)
        }
    }

    /// An idle list must not cost a frame.
    @Test
    func anIdleListNeverTicks() {
        let listView = makeListView()
        listView.rowAnimator = ListBouncyAnimator()
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
        listView.rowAnimator = ListBouncyAnimator()

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
        listView.rowAnimator = ListBouncyAnimator()

        for _ in 0 ..< 10 {
            scroll(listView, by: 40)
            listView.tickRowAnimator(duration: Self.frame)
        }
        #expect(displacements(listView).contains { $0 != 0 })

        let before = Set(listView.visibleRows.keys)
        // Layout only. No tick follows, so nothing else can fix this up.
        scroll(listView, by: 250)
        #expect(!Set(listView.visibleRows.keys).subtracting(before).isEmpty)

        let bouncy = try! #require(listView.bouncy)
        for row in listView.visibleRowViews {
            let index = try! #require(listView.visibleRows.first { $0.value.view === row }.flatMap { listView.index(of: $0.key) })
            // Re-querying is idempotent — the board is only pumped by a
            // frame — so this reads the exact value the pass landed. A row
            // this pass attached reads zero, which is where the original
            // anchors a cell entering the buffered viewport.
            #expect(row.presentationOffset == bouncy.displacement(forKey: index))
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
        listView.rowAnimator = ListBouncyAnimator()

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
        listView.rowAnimator = ListBouncyAnimator()
        listView.layoutSubtreeIfNeeded()

        scroll(listView, by: 300)
        listView.tickRowAnimator(duration: Self.frame)
        #expect(displacements(listView).contains { $0 != 0 })

        listView.resetRowAnimator()

        #expect(listView.bouncy?.board.attachments.isEmpty == true)
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

        listView.rowAnimator = ListBouncyAnimator()
        listView.layoutSubtreeIfNeeded()
        #expect(listView.rowAnimatorLink == nil)

        // Accruing travel is what lights the first frame: at rest with an
        // empty ledger nothing would ever ask for one.
        scroll(listView, by: 200)
        #expect(listView.rowAnimatorLink != nil)

        for _ in 0 ..< 400 {
            listView.tickRowAnimator(duration: Self.frame)
        }
        #expect(listView.bouncy?.wantsNextFrame == false)
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

    /// The lag is graded by distance from the touch, in the direction of the
    /// travel.
    ///
    /// The original's resistance is `|touch − anchor| / 1000`: a row under
    /// the hand rides the scroll rigidly, a row 400pt away sheds 40% of every
    /// frame's travel onto its spring. With no hand observed the touch
    /// defaults to the viewport's bottom edge, so scrolling down must
    /// displace the top rows further than the bottom ones — and downward,
    /// which is what trailing an upward-moving content looks like.
    ///
    /// Ordering is deliberately not asserted: rows on independent springs
    /// bunch together ahead of the motion — the original overlaps cells on
    /// purpose — and the DEBUG overlap assertion checks placements, not
    /// displacements.
    @Test
    func theLagIsGradedByDistanceFromTheTouch() {
        let listView = makeListView()
        listView.rowAnimator = ListBouncyAnimator()

        for _ in 0 ..< 12 {
            scroll(listView, by: 30)
            listView.tickRowAnimator(duration: Self.frame)
        }

        let rows = listView.visibleRowViews.sorted { $0.placedFrame.minY < $1.placedFrame.minY }
        let top = try! #require(rows.first)
        let bottom = try! #require(rows.last)
        #expect(top.presentationOffset > 0)
        #expect(top.presentationOffset > bottom.presentationOffset)
    }

    /// Gaps open behind the motion and close ahead of it, and a reversal
    /// swaps the two.
    ///
    /// Dragging the content up, every row above the hand lags downward by
    /// more the further up it sits — so each gap's upper row closes on its
    /// lower one, and the spacing bunches toward the hand. Dragging back
    /// down mirrors it: the upper row of each pair now lags upward by more,
    /// and the gaps above the hand open. That is the reference's shape —
    /// spreading behind the motion, bunching ahead of it — produced here by
    /// nothing but the original's per-row resistance.
    @Test
    func gapsOpenBehindTheMotionAndCloseAheadOfIt() {
        let listView = makeListView()
        listView.rowAnimator = ListBouncyAnimator()
        // Deep enough that the reversal never reaches the top of the content,
        // where the clamp would eat the travel. A jump, so nothing is pumped.
        listView.setContentOffset(CGPoint(x: 0, y: 2000), animated: false)
        listView.layoutSubtreeIfNeeded()

        var sawBunching = false
        for _ in 0 ..< 20 {
            scroll(listView, by: 30)
            listView.tickRowAnimator(duration: Self.frame)
        }
        var rows = listView.visibleRowViews.sorted { $0.placedFrame.minY < $1.placedFrame.minY }
        for (previous, next) in zip(rows, rows.dropFirst())
            where next.frame.minY < previous.frame.maxY - 1e-6 {
            sawBunching = true
        }
        #expect(sawBunching, "scrolling down should bunch the rows above the hand")

        var sawAGap = false
        for _ in 0 ..< 30 {
            scroll(listView, by: -30)
            listView.tickRowAnimator(duration: Self.frame)
        }
        rows = listView.visibleRowViews.sorted { $0.placedFrame.minY < $1.placedFrame.minY }
        for (previous, next) in zip(rows, rows.dropFirst())
            where next.frame.minY > previous.frame.maxY + 1e-6 {
            sawAGap = true
        }
        #expect(sawAGap, "the reversal should open gaps above the hand")
    }
}
#endif
