//
//  ListRowAnimatorShapeTests.swift
//  ListViewKit
//

#if canImport(UIKit)
// UIKit platforms (including Mac Catalyst) are exercised by the UIKit suites.
#elseif canImport(AppKit)
import AppKit
import Testing
@testable import ListViewKit

private struct ShapeItem: Identifiable, Hashable {
    let id: Int
}

/// A second implementation, written to find out whether the protocol is a
/// protocol or a description of one animator.
///
/// Deliberately unlike the spring in every way that could have been baked in
/// by accident: it has no state that advances with time, so it never asks for
/// a frame and never sees `willUpdate`; it is driven purely by where a row
/// sits in the viewport; and it displaces rows on both sides of centre, which
/// the spring's geometry forbids itself.
private struct ParallaxAnimator: ListRowAnimator {
    var depth: CGFloat = 10

    /// Records what the list called, so the contract can be asserted rather
    /// than assumed. A reference so that copies of the value share it.
    final class Journal {
        var willUpdateCount = 0
        var updateCount = 0
        var rebasedBy: [CGFloat] = []
        var resetCount = 0
        var indices: [Int] = []
        var viewports: [CGRect] = []
    }

    let journal = Journal()
    /// Content-space state, which is what `rebase` exists for.
    private(set) var origin: CGFloat = 0

    var maximumDisplacement: CGFloat { depth }

    mutating func willUpdate(_ context: ListAnimatorContext) {
        journal.willUpdateCount += 1
        journal.viewports.append(context.viewportRect)
    }

    @MainActor
    func update(row: ListRowView, at index: Int, frame: CGRect, in context: ListAnimatorContext) {
        journal.updateCount += 1
        journal.indices.append(index)
        let viewport = context.viewportRect
        guard viewport.height > 0 else { return }
        let fromCentre = (frame.midY - viewport.midY) / viewport.height
        row.setPresentationOffset(fromCentre * depth)
    }

    mutating func rebase(byContentOffset delta: CGFloat) {
        journal.rebasedBy.append(delta)
        origin += delta
    }

    mutating func reset() {
        journal.resetCount += 1
        origin = 0
    }
}

/// The smallest thing that can be called an animator.
private struct DoNothingAnimator: ListRowAnimator {}

@Suite(.serialized)
@MainActor
struct ListRowAnimatorShapeTests {
    private static let rowHeight: CGFloat = 100

    private func makeListView(count: Int = 60) -> ListView<ShapeItem> {
        let listView = ListView<ShapeItem>(frame: CGRect(x: 0, y: 0, width: 200, height: 400))
        listView.rows {
            ListRow(ListRowView.self)
                .height { _, _ in Self.rowHeight }
                .configure { _, _, _ in }
        }
        listView.apply((0 ..< count).map { ShapeItem(id: $0) })
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()
        for _ in 0 ..< 200 where listView.rowLayout.hasPendingRows {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()
        return listView
    }

    private func scroll(_ listView: ListView<ShapeItem>, by dy: CGFloat) {
        listView.contentOffset.y += dy
        listView.layoutSubtreeIfNeeded()
    }

    /// An animator with nothing overridden is legal and inert.
    @Test
    func theDefaultsAloneMakeACompleteAnimator() {
        let listView = makeListView()
        listView.rowAnimator = DoNothingAnimator()
        scroll(listView, by: 400)

        #expect(listView.rowAnimator?.wantsNextFrame == false)
        #expect(listView.rowAnimator?.maximumDisplacement == 0)
        #expect(listView.rowAnimatorLink == nil)
        for row in listView.visibleRowViews {
            #expect(row.presentationOffset == 0)
            #expect(row.frame == row.placedFrame)
        }
    }

    /// An effect with no clock still works, and costs no frames.
    ///
    /// Displacement is recomputed by the layout pass, and scrolling is a
    /// layout pass, so a purely geometric animator needs no display link at
    /// all. If this needed one, the protocol would be describing the spring
    /// rather than animators.
    @Test
    func aStatelessAnimatorIsDrivenByLayoutAndNeverAsksForAFrame() {
        let listView = makeListView()
        let animator = ParallaxAnimator()
        listView.rowAnimator = animator

        scroll(listView, by: 250)

        #expect(animator.journal.willUpdateCount == 0)
        #expect(animator.journal.updateCount > 0)
        #expect(listView.animatorTickCount == 0)
        #expect(listView.rowAnimatorLink == nil)

        let viewport = listView.viewportRect
        for row in listView.visibleRowViews {
            let expected = (row.placedFrame.midY - viewport.midY) / viewport.height * animator.depth
            #expect(abs(row.presentationOffset - expected) < 1e-9)
        }
        // Both signs, which the spring never produces.
        #expect(listView.visibleRowViews.contains { $0.presentationOffset > 0 })
        #expect(listView.visibleRowViews.contains { $0.presentationOffset < 0 })
    }

    /// Every mounted row is offered, with the index it is mounted at.
    @Test
    func updateIsCalledForEveryMountedRowWithItsIndex() {
        let listView = makeListView()
        let animator = ParallaxAnimator()
        listView.rowAnimator = animator

        animator.journal.indices.removeAll()
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()

        let mounted = Set(listView.visibleRows.keys.compactMap { listView.index(of: $0) })
        #expect(Set(animator.journal.indices) == mounted)
        #expect(animator.journal.indices.count == mounted.count)
    }

    /// Content-space state is moved when the content space moves.
    ///
    /// The list pairs this with the compensation itself rather than at each
    /// call site, so an animator is told whichever path produced the shift.
    @Test
    func compensationRebasesTheAnimator() {
        let listView = makeListView()
        let animator = ParallaxAnimator()
        listView.rowAnimator = animator

        listView.compensateScrollOffset(by: 250)
        #expect(animator.journal.rebasedBy == [250])
        // Read back from the list, not from `animator`: the list stored a
        // copy, and only the journal is shared by reference.
        #expect((listView.rowAnimator as? ParallaxAnimator)?.origin == 250)

        // A shift of nothing is not an event.
        listView.compensateScrollOffset(by: 0)
        #expect(animator.journal.rebasedBy == [250])
    }

    /// Deferred measurement rebases too, and it is the same call.
    @Test
    func measurementDrivenCompensationAlsoRebases() {
        let listView = ListView<ShapeItem>(frame: CGRect(x: 0, y: 0, width: 200, height: 400))
        listView.rows {
            ListRow(ListRowView.self)
                // Taller than the estimate, so measuring rows above the
                // viewport shifts the content space.
                .height { _, _ in 240 }
                .configure { _, _, _ in }
        }
        listView.apply((0 ..< 400).map { ShapeItem(id: $0) })
        listView.contentOffset.y = 4000

        let animator = ParallaxAnimator()
        listView.rowAnimator = animator
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()
        for _ in 0 ..< 200 where listView.rowLayout.hasPendingRows {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        #expect(!animator.journal.rebasedBy.isEmpty)
        let stored = try! #require(listView.rowAnimator as? ParallaxAnimator)
        #expect(stored.origin == animator.journal.rebasedBy.reduce(0, +))
    }

    /// Resetting reaches the animator, and the list clears the rows itself.
    @Test
    func resetTellsTheAnimatorAndThenClearsEveryRow() {
        let listView = makeListView()
        let animator = ParallaxAnimator()
        listView.rowAnimator = animator
        scroll(listView, by: 250)
        #expect(listView.visibleRowViews.contains { $0.presentationOffset != 0 })

        listView.resetRowAnimator()

        #expect(animator.journal.resetCount == 1)
        #expect((listView.rowAnimator as? ParallaxAnimator)?.origin == 0)
        for row in listView.visibleRowViews {
            #expect(row.presentationOffset == 0)
            #expect(row.frame == row.placedFrame)
        }
    }

    /// The value in the box is mutated in place, not a copy of it.
    ///
    /// `willUpdate`, `rebase` and `reset` are mutating requirements reached
    /// through an existential, which is the part of the design that had to be
    /// true for a struct animator to be able to hold state at all.
    @Test
    func mutatingThroughTheExistentialKeepsTheState() {
        let listView = makeListView()
        listView.rowAnimator = ParallaxAnimator()

        listView.compensateScrollOffset(by: 100)
        listView.compensateScrollOffset(by: 40)

        let stored = try! #require(listView.rowAnimator as? ParallaxAnimator)
        #expect(stored.origin == 140)
    }
}
#endif
