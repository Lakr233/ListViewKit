//
//  ListViewRowAnimatorUIKitTests.swift
//  ListViewKit
//

#if canImport(UIKit)
import Testing
import UIKit
@testable import ListViewKit

private struct AnimatorItem: Identifiable, Hashable {
    let id: Int
}

/// The half of the displacement story that only exists here.
///
/// Displacement lands on the transform under UIKit, and a view with a
/// transform has no meaningful `frame` — the documented behaviour is that it
/// is undefined. Everything the list decides from a row's geometry therefore
/// has to come from ``ListRowView/placedFrame`` instead, and that swap cannot
/// be observed on AppKit, where the two agree.
@Suite(.serialized)
@MainActor
struct ListViewRowAnimatorUIKitTests {
    private static let rowHeight: CGFloat = 100
    private static let frame: TimeInterval = 1.0 / 120.0

    private func makeListView(count: Int = 60) -> ListView<AnimatorItem> {
        let listView = ListView<AnimatorItem>(
            frame: CGRect(x: 0, y: 0, width: 200, height: 400)
        )
        listView.rows {
            ListRow(ListRowView.self)
                .height { _, _ in Self.rowHeight }
                .configure { _, _, _ in }
        }
        listView.apply((0 ..< count).map { AnimatorItem(id: $0) })
        drain(listView)
        return listView
    }

    private func drain(_ listView: ListView<AnimatorItem>) {
        listView.setNeedsLayout()
        listView.layoutIfNeeded()
        for _ in 0 ..< 200 where listView.rowLayout.hasPendingRows {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        listView.setNeedsLayout()
        listView.layoutIfNeeded()
    }

    private func scroll(_ listView: ListView<AnimatorItem>, by dy: CGFloat) {
        listView.contentOffset.y += dy
        listView.layoutIfNeeded()
    }

    private func displace(_ listView: ListView<AnimatorItem>) {
        for _ in 0 ..< 10 {
            scroll(listView, by: 40)
            listView.tickRowAnimator(duration: Self.frame)
        }
    }

    /// Displacement is a transform, and the placement underneath it is
    /// untouched.
    @Test
    func displacementLandsOnTheTransformAndLeavesThePlacementAlone() {
        let listView = makeListView()
        listView.scrollSpring = ListScrollSpring()
        displace(listView)

        var sawDisplacement = false
        for (identifier, entry) in listView.visibleRows {
            let index = try! #require(listView.index(of: identifier))
            #expect(entry.view.placedFrame == listView.rectForRow(at: index))
            #expect(entry.view.transform.ty == entry.view.presentationOffset)
            if entry.view.presentationOffset != 0 { sawDisplacement = true }
        }
        #expect(sawDisplacement)
    }

    /// Layout decides whether a row moved from the placement, not the frame.
    ///
    /// A displaced row's `frame` is a derived rectangle that grows to cover
    /// the transformed bounds, so comparing against it would answer a question
    /// about the transform when the question was about the layout.
    @Test
    func layoutComparesPlacementsRatherThanFrames() {
        let listView = makeListView()
        listView.scrollSpring = ListScrollSpring()
        displace(listView)

        let displaced = listView.visibleRowViews.filter { $0.presentationOffset != 0 }
        #expect(!displaced.isEmpty)
        for row in displaced {
            // The premise: these disagree while a displacement is applied, so
            // which one layout reads is a real choice and not a formality.
            #expect(row.frame != row.placedFrame)
            #expect(row.bounds.size == row.placedFrame.size)
        }

        // Laying out again with nothing changed must not move anything.
        let placements = listView.visibleRowViews.map(\.placedFrame)
        listView.setNeedsLayout()
        listView.layoutIfNeeded()
        #expect(listView.visibleRowViews.map(\.placedFrame) == placements)
    }

    /// A displaced row answers touches where it is drawn.
    @Test
    func hitTestingFollowsTheDisplacement() throws {
        let listView = makeListView()
        listView.scrollSpring = ListScrollSpring()
        displace(listView)

        let row = try #require(listView.visibleRowViews.first { $0.presentationOffset > 1 })
        let drawnCentre = CGPoint(
            x: row.placedFrame.midX,
            y: row.placedFrame.midY + row.presentationOffset
        )
        let hit = listView.hitTest(drawnCentre, with: nil)
        #expect(hit === row || hit?.isDescendant(of: row) == true)
    }

    /// Returning to rest leaves no transform behind.
    @Test
    func restClearsTheTransform() {
        let listView = makeListView()
        listView.scrollSpring = ListScrollSpring()
        displace(listView)

        for _ in 0 ..< 400 {
            listView.tickRowAnimator(duration: Self.frame)
        }
        for row in listView.visibleRowViews {
            #expect(row.transform == .identity)
            #expect(row.frame == row.placedFrame)
        }
    }
}
#endif
