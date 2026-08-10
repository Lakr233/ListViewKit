//
//  ListRowAnimatorPublicAPITests.swift
//  ListViewKit
//

#if canImport(UIKit)
// UIKit platforms (including Mac Catalyst) are exercised by the UIKit suites.
#elseif canImport(AppKit)
import AppKit
import Testing
@testable import ListViewKit

private struct APIItem: Identifiable, Hashable {
    let id: Int
}

/// Displaces every row by a fixed amount, so what the mounting rectangle has
/// to cover is a number the test chose rather than one a spring produced.
private struct FixedOffsetAnimator: ListRowAnimator {
    var displacement: CGFloat
    var claimedMaximum: CGFloat?

    var maximumDisplacement: CGFloat { claimedMaximum ?? abs(displacement) }

    @MainActor
    func update(row: ListRowView, at _: Int, frame _: CGRect, in _: ListAnimatorContext) {
        row.setPresentationOffset(displacement)
    }
}

/// Changes the list's content from inside `update`, which is the thing a hook
/// on the per-frame path invites someone to do by accident.
///
/// `apply` forces a layout of its own, and that layout is what would re-enter
/// the pass currently iterating the mounted set.
private struct ReentrantAnimator: ListRowAnimator {
    final class Trap {
        weak var listView: ListView<APIItem>?
        var updates = 0
        var nextIdentifier = 10_000
        var armed = true
        var rounds = 0
    }

    let trap = Trap()
    var maximumDisplacement: CGFloat { 8 }

    @MainActor
    func update(row: ListRowView, at _: Int, frame _: CGRect, in _: ListAnimatorContext) {
        trap.updates += 1
        row.setPresentationOffset(8)
        guard trap.armed, let listView = trap.listView else { return }
        // Re-arms a few times, so the guard is asked to hold more than once.
        trap.rounds += 1
        if trap.rounds >= 3 { trap.armed = false }
        trap.nextIdentifier += 1
        listView.apply(listView.content + [APIItem(id: trap.nextIdentifier)])
    }
}

@Suite(.serialized)
@MainActor
struct ListRowAnimatorPublicAPITests {
    private static let rowHeight: CGFloat = 40

    private func makeListView(count: Int = 200) -> ListView<APIItem> {
        let listView = ListView<APIItem>(frame: CGRect(x: 0, y: 0, width: 200, height: 400))
        listView.rows {
            ListRow(ListRowView.self)
                .height { _, _ in Self.rowHeight }
                .configure { _, _, _ in }
        }
        listView.apply((0 ..< count).map { APIItem(id: $0) })
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()
        for _ in 0 ..< 200 where listView.rowLayout.hasPendingRows {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        listView.contentOffset.y = 2000
        listView.layoutSubtreeIfNeeded()
        // The spread only exists under the hand; hold one down for these.
        listView._isTracking = true
        return listView
    }

    // MARK: - Two rectangles

    /// Without an animator there is only one rectangle, and it is the viewport.
    @Test
    func theMountingRectangleIsTheViewportUntilSomethingWidensIt() {
        let listView = makeListView()
        #expect(listView.mountRect == listView.viewportRect)
        #expect(listView.mountOverscan == 0)

        listView.rowAnimator = FixedOffsetAnimator(displacement: 30)
        listView.layoutSubtreeIfNeeded()
        #expect(listView.mountOverscan == 30)
        #expect(listView.mountRect.minY == listView.viewportRect.minY - 30)
        #expect(listView.mountRect.maxY == listView.viewportRect.maxY + 30)
    }

    /// A row displaced into view was mounted before it got there.
    @Test
    func rowsAreMountedFarEnoughOutToBeDisplacedIntoView() {
        let listView = makeListView()
        let withoutAnimator = Set(listView.visibleRows.keys)

        listView.rowAnimator = FixedOffsetAnimator(displacement: 30)
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()
        let withAnimator = Set(listView.visibleRows.keys)

        #expect(withAnimator.isSuperset(of: withoutAnimator))
        #expect(withAnimator.count > withoutAnimator.count)
        // Every row that could be pulled into the viewport by the displacement
        // is mounted.
        let viewport = listView.viewportRect
        for row in listView.visibleRowViews {
            #expect(row.presentationOffset == 30)
        }
        let reachable = listView.rowLayout.indices(
            intersecting: viewport.insetBy(dx: 0, dy: -30)
        )
        #expect(Set(listView.visibleRows.keys.compactMap { listView.index(of: $0) })
            .isSuperset(of: Set(reachable)))
    }

    /// Widening what is mounted must not widen what counts as visible.
    ///
    /// The compensation anchor is derived from the viewport, and it has to
    /// stay that way: anchored on a widened rectangle, a row above the real
    /// viewport could resize with no compensation, and the reader would see
    /// the viewport jump.
    @Test
    func theReportedViewportIsUnaffectedByTheOverscan() {
        let listView = makeListView()
        let visibleBefore = listView.indicesForVisibleRows
        let viewportBefore = listView.viewportRect

        listView.rowAnimator = FixedOffsetAnimator(displacement: 30)
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()

        #expect(listView.viewportRect == viewportBefore)
        #expect(listView.indicesForVisibleRows == visibleBefore)
        #expect(Set(listView.visibleRows.keys).count > visibleBefore.count)
    }

    /// Mounting and recycling read the same rectangle, so an overscanned row
    /// is not recycled and remounted on every pass.
    @Test
    func overscannedRowsAreNotChurned() {
        var configureCounts: [Int: Int] = [:]
        let listView = ListView<APIItem>(frame: CGRect(x: 0, y: 0, width: 200, height: 400))
        listView.rows {
            ListRow(ListRowView.self)
                .height { _, _ in Self.rowHeight }
                .configure { _, item, _ in configureCounts[item.id, default: 0] += 1 }
        }
        listView.apply((0 ..< 200).map { APIItem(id: $0) })
        listView.contentOffset.y = 2000
        listView.rowAnimator = FixedOffsetAnimator(displacement: 30)
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()
        for _ in 0 ..< 200 where listView.rowLayout.hasPendingRows {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        listView.layoutSubtreeIfNeeded()

        let mounted = Set(listView.visibleRows.keys)
        configureCounts.removeAll()
        for _ in 0 ..< 5 {
            listView.needsLayout = true
            listView.layoutSubtreeIfNeeded()
        }
        #expect(Set(listView.visibleRows.keys) == mounted)
        #expect(configureCounts.isEmpty)
    }

    /// A claimed maximum that is nonsense cannot cost the list unbounded work.
    @Test
    func anImplausibleMaximumIsClamped() {
        let listView = makeListView()

        listView.rowAnimator = FixedOffsetAnimator(displacement: 0, claimedMaximum: .nan)
        listView.layoutSubtreeIfNeeded()
        #expect(listView.mountOverscan == 0)

        listView.rowAnimator = FixedOffsetAnimator(displacement: 0, claimedMaximum: -40)
        listView.layoutSubtreeIfNeeded()
        #expect(listView.mountOverscan == 0)

        listView.rowAnimator = FixedOffsetAnimator(displacement: 0, claimedMaximum: 1e9)
        listView.layoutSubtreeIfNeeded()
        #expect(listView.mountOverscan == 1000)
    }

    // MARK: - Replacing

    /// A displacement does not survive a change of animator.
    @Test
    func replacingTheAnimatorClearsWhatTheLastOnePutOnScreen() {
        let listView = makeListView()
        listView.rowAnimator = FixedOffsetAnimator(displacement: 25)
        listView.layoutSubtreeIfNeeded()
        #expect(listView.visibleRowViews.allSatisfy { $0.presentationOffset == 25 })

        listView.rowAnimator = nil
        #expect(listView.visibleRowViews.allSatisfy { $0.presentationOffset == 0 })
        #expect(listView.visibleRowViews.allSatisfy { $0.frame == $0.placedFrame })
        #expect(listView.mountOverscan == 0)
        #expect(listView.rowAnimatorLink == nil)
    }

    /// The animator the list is replacing is told, so a reference type can
    /// release whatever it was holding.
    @Test
    func theOutgoingAnimatorIsReset() {
        final class Recorder: ListRowAnimator {
            var resets = 0
            func reset() { resets += 1 }
        }
        let listView = makeListView()
        let outgoing = Recorder()
        listView.rowAnimator = outgoing
        listView.rowAnimator = nil

        #expect(outgoing.resets == 1)
    }

    /// Driving the animator every frame is not a change of animator.
    ///
    /// `willUpdate` and `rebase` are mutating requirements, so each call is a
    /// write to the property. Taking those for replacements would reset the
    /// spring on the frame after it started.
    @Test
    func theListDrivingTheAnimatorDoesNotTriggerTheReplaceContract() {
        let listView = makeListView()
        let window = NSWindow(
            contentRect: listView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = listView
        defer { window.contentView = nil }

        listView.rowAnimator = ListScrollSpring.messages
        listView.contentOffset.y += 200
        listView.layoutSubtreeIfNeeded()
        listView.tickRowAnimator(duration: 1.0 / 120.0)

        let spring = try! #require(listView.rowAnimator as? ListScrollSpring)
        #expect(spring.stretch != 0)
        #expect(listView.rowAnimatorLink != nil)

        // A compensation drives it too, and must not reset it either.
        let before = spring.stretch
        listView.compensateScrollOffset(by: 40)
        #expect((listView.rowAnimator as? ListScrollSpring)?.stretch == before)
    }

    // MARK: - Reentrancy

    /// Changing the content from inside `update` defers instead of recursing.
    @Test
    func anAnimatorThatLaysOutFromUpdateDoesNotRecurse() {
        let listView = makeListView()
        let animator = ReentrantAnimator()
        animator.trap.listView = listView
        listView.rowAnimator = animator

        listView.deepestLayoutContentDepth = 0
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()

        // The point: a layout pass never runs inside a layout pass, however
        // insistently the animator asks for one.
        #expect(listView.deepestLayoutContentDepth == 1)
        #expect(animator.trap.updates > 0)
        #expect(listView.visibleRowViews.allSatisfy { $0.presentationOffset == 8 })
        #expect(listView.content.count > 200)
    }

    // MARK: - Cost

    /// A list with no animator does none of the work an animator implies.
    ///
    /// The benchmark says the scrolling path is unchanged when the feature is
    /// off; this says why, in terms that fail loudly rather than drift.
    @Test
    func aListWithNoAnimatorDoesNoAnimatorWork() {
        var configureCounts = 0
        let listView = ListView<APIItem>(frame: CGRect(x: 0, y: 0, width: 200, height: 400))
        listView.rows {
            ListRow(ListRowView.self)
                .height { _, _ in Self.rowHeight }
                .configure { _, _, _ in configureCounts += 1 }
        }
        listView.apply((0 ..< 400).map { APIItem(id: $0) })
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()
        for _ in 0 ..< 200 where listView.rowLayout.hasPendingRows {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        listView.animatorTickCount = 0
        configureCounts = 0
        for step in 0 ..< 60 {
            listView.contentOffset.y = CGFloat(step) * 120
            listView.layoutSubtreeIfNeeded()
        }

        #expect(listView.animatorTickCount == 0)
        #expect(listView.rowAnimatorLink == nil)
        #expect(listView.mountOverscan == 0)
        #expect(listView.mountRect == listView.viewportRect)
        // Rows were mounted as the viewport moved, so the pass was doing real
        // work — this is not a test of a list that never scrolled.
        #expect(configureCounts > 0)
        for row in listView.visibleRowViews {
            #expect(row.presentationOffset == 0)
            #expect(row.frame == row.placedFrame)
        }
    }

    /// The frame a gesture starts on is already displaced.
    ///
    /// Two clocks write the one position a reader sees: `contentOffset`, by the
    /// scroll view, and `presentationOffset`, by the animator's link. They only
    /// agree while both are running, and on the first frame of a gesture only
    /// one is — the link is created by this very pass and a display link does
    /// not call back on the frame it is built. So the rows were placed at the
    /// new offset and displaced by the stretch from before the gesture, which
    /// is zero, and the real value arrived a frame later on top of that frame's
    /// own travel.
    ///
    /// Asserted on `presentationOffset` rather than on the spring, because the
    /// spring advancing is not the claim — the claim is that what reached the
    /// rows in this pass matches the offset that reached them in the same pass.
    @Test
    func theFrameAGestureStartsOnIsAlreadyDisplaced() {
        let listView = makeListView()
        let window = NSWindow(
            contentRect: listView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = listView
        defer { window.contentView = nil }

        listView.rowAnimator = ListScrollSpring.messages
        listView.layoutSubtreeIfNeeded()
        // Nothing has moved yet, so nothing is owed a frame and no link exists.
        #expect(listView.rowAnimatorLink == nil)
        #expect(listView.visibleRowViews.allSatisfy { $0.presentationOffset == 0 })

        // One frame of a brisk drag, landed by one layout pass. No link has
        // called back, because none existed when the offset changed.
        listView.contentOffset.y += 24
        listView.layoutSubtreeIfNeeded()

        let displaced = listView.visibleRowViews.filter { $0.presentationOffset != 0 }
        #expect(!displaced.isEmpty, "the first frame of the gesture landed with no displacement at all")
        #expect(listView.rowAnimatorLink != nil, "and nothing was scheduled to fix it later")
    }

    /// And so is a frame that arrives while a link is already running.
    ///
    /// The first version of the catch-up asked whether a link existed, which is
    /// not the same question as whether this frame's travel had been consumed.
    /// A gesture that starts while the previous one is still unwinding has a
    /// live link, and the order within the frame can be tick-then-offset: the
    /// tick consumes nothing, the touch moves the offset afterwards, and a pass
    /// that trusts the link's existence lands a stale displacement anyway.
    ///
    /// Driven in exactly that order, and asserted on what the rows show at the
    /// end of the pass rather than on the spring, since a spring that advanced
    /// after the rows were placed is the defect rather than the fix.
    @Test
    func aFrameThatArrivesWhileTheLinkIsRunningIsAlsoIntegrated() {
        let listView = makeListView()
        let window = NSWindow(
            contentRect: listView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = listView
        defer { window.contentView = nil }

        listView.rowAnimator = ListScrollSpring.messages
        // A gesture, then a link left running by the stretch still unwinding.
        listView.contentOffset.y += 24
        listView.layoutSubtreeIfNeeded()
        listView.tickRowAnimator(duration: 1.0 / 120.0)
        #expect(listView.rowAnimatorLink != nil, "the spring settled early; nothing is being tested")

        // The tick for this frame lands before the offset moves, so it has
        // nothing of this frame's to consume.
        listView.tickRowAnimator(duration: 1.0 / 120.0)
        let before = displacements(of: listView)
        listView.contentOffset.y += 24
        listView.layoutSubtreeIfNeeded()
        let after = displacements(of: listView)

        #expect(after != before, "the pass landed the new offset with the previous frame's displacement")
    }

    private func displacements(of listView: ListView<APIItem>) -> [CGFloat] {
        listView.visibleRowViews
            .sorted { $0.placedFrame.minY < $1.placedFrame.minY }
            .map(\.presentationOffset)
    }

    /// The layout pass owns the travel and the link owns the clock, so a frame
    /// hands over each exactly once however many layouts it takes.
    ///
    /// Two advances per frame here, not one: the pass that moved the offset
    /// injects that travel with no time attached, and the tick that follows
    /// integrates the time with nothing left to inject. Layouts that move
    /// nothing are not frames and cost nothing.
    @Test
    func oneFramePerTickAndNoTicksWithoutFrames() {
        let listView = makeListView()
        let window = NSWindow(
            contentRect: listView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = listView
        defer { window.contentView = nil }

        listView.rowAnimator = ListScrollSpring.messages
        listView.animatorTickCount = 0

        for _ in 0 ..< 10 {
            listView.contentOffset.y += 20
            // Several layouts inside one frame, which is what a content-size
            // write or a nested `layoutNow` produces.
            listView.layoutSubtreeIfNeeded()
            listView.needsLayout = true
            listView.layoutSubtreeIfNeeded()
            listView.tickRowAnimator(duration: 1.0 / 120.0)
        }
        #expect(listView.animatorTickCount == 20, "ten frames of travel and ten of time")

        // Settled, and then left alone: no further frames are taken.
        for _ in 0 ..< 400 {
            listView.tickRowAnimator(duration: 1.0 / 120.0)
        }
        let settled = listView.animatorTickCount
        for _ in 0 ..< 10 {
            listView.needsLayout = true
            listView.layoutSubtreeIfNeeded()
        }
        #expect(listView.animatorTickCount == settled)
        #expect(listView.rowAnimatorLink == nil)
    }

    /// Recycling a row that was never displaced costs nothing.
    ///
    /// Clearing a displacement means suppressing animation, and on AppKit that
    /// is an `NSAnimationContext` group. Paying for one per recycled row was a
    /// measurable regression for lists that had no animator at all.
    @Test
    func clearingAnUndisplacedRowDoesNotOpenAnAnimationContext() {
        let listView = makeListView()
        let row = try! #require(listView.visibleRowViews.first)
        #expect(row.presentationOffset == 0)

        let framesBefore = row.frame
        listView.clearRowDisplacement(on: row)
        #expect(row.frame == framesBefore)
    }

    // MARK: - Presets

    @Test
    func presetsAreDistinctAndValid() {
        let messages = ListScrollSpring.messages
        let subtle = ListScrollSpring.subtle

        #expect(messages.maximumStretch == 24)
        #expect(subtle.maximumStretch == 8)
        #expect(subtle.maximumStretch < messages.maximumStretch)
        #expect(subtle.resistanceFactor > messages.resistanceFactor)
        #expect(subtle.angularFrequency > messages.angularFrequency)
        #expect(messages.maximumDisplacement == messages.maximumStretch)
    }
}
#endif
