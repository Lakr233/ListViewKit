#if canImport(UIKit)
// UIKit platforms (including Mac Catalyst) are exercised by the UIKit suites.
#elseif canImport(AppKit)
import AppKit
import Testing
@testable import ListViewKit

private struct AnchorItem: Identifiable, Hashable {
    let id: Int
}

/// Row heights the test rewrites between passes, so a remeasure can be made to
/// shrink or grow by a known amount.
@MainActor
private final class AnchorProbe {
    var height: CGFloat = 100
    /// Overrides for individual rows, so a pass can shrink one row and grow
    /// another by the same amount.
    var heights: [Int: CGFloat] = [:]
    var widthScale = false

    func height(of item: AnchorItem, width: CGFloat) -> CGFloat {
        let height = heights[item.id] ?? height
        return widthScale ? (height * 400 / max(width, 1)).rounded() : height
    }
}

@Suite(.serialized)
@MainActor
struct ListViewAnchorAppKitTests {
    private typealias Context = (listView: ListView<AnchorItem>, probe: AnchorProbe)

    private func makeContext(count: Int = 100, height: CGFloat = 400) -> Context {
        let probe = AnchorProbe()
        let listView = ListView<AnchorItem>(frame: CGRect(x: 0, y: 0, width: 400, height: height))
        listView.rows {
            ListRow(ListRowView.self)
                .height { item, ctx in probe.height(of: item, width: ctx.width) }
                .configure { _, _, _ in }
        }
        listView.apply((0 ..< count).map { AnchorItem(id: $0) })
        drain(listView)
        return (listView, probe)
    }

    private func drain(_ listView: ListView<AnchorItem>, sourceLocation: SourceLocation = #_sourceLocation) {
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()
        for _ in 0 ..< 400 {
            guard listView.rowLayout.hasPendingRows else {
                listView.layoutSubtreeIfNeeded()
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            listView.layoutSubtreeIfNeeded()
        }
        Issue.record("slice drain did not converge", sourceLocation: sourceLocation)
    }

    private func screenY(_ listView: ListView<AnchorItem>, of index: Int) -> CGFloat {
        listView.rectForRow(at: index).minY - listView.contentOffset.y
    }

    /// REPRO 1: the viewport top lands inside a row. That row is measured, is
    /// shorter than it was, and everything below it slides up.
    @Test
    func shrinkingAStraddlingRowKeepsTheRowsBelowStationary() {
        let context = makeContext()
        let listView = context.listView
        // Row 2 spans 200..<300; the viewport starts halfway through it.
        listView.setContentOffset(.init(x: 0, y: 250), animated: false)
        listView.layoutSubtreeIfNeeded()
        let before = screenY(listView, of: 3)
        #expect(before == 50)

        context.probe.height = 40
        listView.invalidateLayout()
        drain(listView)

        #expect(screenY(listView, of: 3) == before)
    }

    /// REPRO 2: same shape, driven by a width change instead of an explicit
    /// invalidation. This is the resize jitter.
    @Test
    func widthChangeKeepsTheRowsBelowAStraddlerStationary() {
        let context = makeContext()
        context.probe.widthScale = true
        let listView = context.listView
        listView.invalidateLayout()
        drain(listView)

        listView.setContentOffset(.init(x: 0, y: 250), animated: false)
        listView.layoutSubtreeIfNeeded()
        let before = screenY(listView, of: 3)

        listView.frame = CGRect(x: 0, y: 0, width: 500, height: 400)
        drain(listView)

        #expect(screenY(listView, of: 3) == before)
    }

    /// REPRO 3: content shrinking under a near-bottom viewport has to clamp,
    /// but the clamp must land immediately rather than spring there.
    @Test
    func clampingAfterContentShrinksDoesNotAnimate() {
        let context = makeContext()
        let listView = context.listView
        listView.setContentOffset(listView.maximumContentOffset, animated: false)
        listView.layoutSubtreeIfNeeded()

        context.probe.height = 40
        listView.invalidateLayout()
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()

        // Whatever the offset ends up being, it must already be there.
        #expect(listView.contentOffset == listView.nearestScrollLocationInBounds(offset: listView.contentOffset))
        #expect(listView.scrollingDisplayLink == nil)
    }

    /// Compensation deliberately puts the offset past an edge on its way to
    /// the anchor. When the content cannot honour it — holding this anchor
    /// would need the list scrolled above its own top — the offset has to
    /// settle back in bounds instead of sticking there.
    @Test
    func compensationPastTheTopEdgeSettlesInBounds() {
        let context = makeContext()
        let listView = context.listView
        listView.setContentOffset(.init(x: 0, y: 50), animated: false)
        listView.layoutSubtreeIfNeeded()

        context.probe.height = 1
        listView.invalidateLayout()
        drain(listView)

        #expect(listView.contentOffset.y == listView.minimumContentOffset.y)
        #expect(screenY(listView, of: 0) == 0)
    }

    /// The last row can straddle the viewport top and still leave most of the
    /// viewport empty, when a bottom inset holds the list open below it. It is
    /// not a viewport-covering row, so its reflow belongs in the offset.
    @Test
    func aPartlyVisibleLastRowIsStillCompensated() {
        let context = makeContext(count: 2)
        let listView = context.listView
        listView.bottomInset = 500
        listView.setContentOffset(.init(x: 0, y: 150), animated: false)
        listView.layoutSubtreeIfNeeded()
        // Row 1 spans 100..<200: it starts above the viewport and ends 50
        // points into it, with inset space filling the rest.
        let bottomScreenY = listView.rectForRow(at: 1).maxY - listView.contentOffset.y
        #expect(bottomScreenY == 50)

        context.probe.height = 40
        listView.invalidateLayout()
        drain(listView)

        #expect(listView.rectForRow(at: 1).maxY - listView.contentOffset.y == bottomScreenY)
    }

    /// An animated update springs every row to its new frame. When the shorter
    /// content pulls the offset off an edge, the viewport has to travel with
    /// the rows rather than cut straight to the destination.
    @Test
    func anAnimatedApplyAnimatesTheOffsetCorrection() {
        let context = makeContext(count: 20)
        let listView = context.listView
        listView.setContentOffset(listView.maximumContentOffset, animated: false)
        listView.layoutSubtreeIfNeeded()
        let offsetBefore = listView.contentOffset.y

        listView.apply(Array(listView.content.prefix(6)), animated: true)

        #expect(listView.maximumContentOffset.y < offsetBefore)
        #expect(listView.contentOffset.y == offsetBefore)
        #expect(listView.scrollingDisplayLink != nil)
        listView.cancelCurrentScrolling()
    }

    /// Compensation can leave the offset out of bounds while the total height
    /// is unchanged: one row shrinks above the anchor and another grows below
    /// it by the same amount. Nothing is left to notice unless the offset is
    /// reconciled regardless of whether the content size moved.
    @Test
    func compensationPastAnEdgeSettlesEvenWhenTheHeightIsUnchanged() {
        let context = makeContext()
        let listView = context.listView
        let heightBefore = listView.contentSize.height
        // Row 0 spans 0..<100 and straddles the viewport top, so it anchors on
        // row 1 and its shrink is absorbed by the offset.
        listView.setContentOffset(.init(x: 0, y: 50), animated: false)
        listView.layoutSubtreeIfNeeded()

        context.probe.heights = [0: 40, 1: 160]
        listView.invalidateLayout()
        drain(listView)

        #expect(listView.contentSize.height == heightBefore)
        #expect(listView.contentOffset.y == listView.minimumContentOffset.y)
    }

    /// REPRO 4: a bottom-pinned list that shrinks stays pinned to the bottom
    /// instead of drifting away from it.
    @Test
    func shrinkingKeepsABottomPinnedListAtTheBottom() {
        let context = makeContext()
        let listView = context.listView
        listView.setContentOffset(listView.maximumContentOffset, animated: false)
        listView.layoutSubtreeIfNeeded()
        #expect(listView.isScrolledToBottom())

        context.probe.height = 40
        listView.invalidateLayout()
        drain(listView)

        #expect(listView.isScrolledToBottom())
    }
}
#endif
