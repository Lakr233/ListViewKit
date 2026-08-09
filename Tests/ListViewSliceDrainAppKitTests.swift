#if canImport(UIKit)
// UIKit platforms (including Mac Catalyst) are exercised by the UIKit suites.
#elseif canImport(AppKit)
import AppKit
import Testing
@testable import ListViewKit

private struct DrainItem: Identifiable, Hashable {
    let id: Int
}

/// What the deferred-measurement drain costs while it cannot run.
///
/// The drain has two branches that decline to measure and come back later: a
/// drag in progress, and an AppKit live resize. Both are about *when* to
/// spend the budget, so the thing worth testing is not what they measure but
/// what they cost while measuring nothing.
@Suite(.serialized)
@MainActor
struct ListViewSliceDrainAppKitTests {
    /// Long enough that most rows are still estimates, so `hasPendingRows`
    /// stays true for the whole window and the drain keeps re-arming.
    private func makePendingListView(count: Int = 4000) -> ListView<DrainItem> {
        let listView = ListView<DrainItem>(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        listView.rows {
            ListRow(ListRowView.self)
                .height { _, _ in 100 }
                .configure { _, _, _ in }
        }
        listView.apply((0 ..< count).map { DrainItem(id: $0) })
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()
        return listView
    }

    private func wheelEvent(phase: CGScrollPhase) throws -> NSEvent {
        let cgEvent = try #require(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: 1,
            wheel2: 0,
            wheel3: 0
        ))
        cgEvent.setIntegerValueField(
            .scrollWheelEventScrollPhase,
            value: Int64(phase.rawValue)
        )
        return try #require(NSEvent(cgEvent: cgEvent))
    }

    /// A drag that holds the drain off must not spin the run loop.
    ///
    /// Both hold-off branches re-armed through `scheduleSliceDrain()`, which
    /// posts the next pass onto the run loop — so the pass re-queued itself as
    /// fast as the loop could drain it and the main thread never slept, for
    /// the whole of every drag on any list with a row still unmeasured. The
    /// cost is invisible in a frame-by-frame trace and shows up only as the
    /// offset arriving in bursts.
    ///
    /// Asserted as a rate rather than a total, since what makes it a defect is
    /// that the count is bounded by run-loop speed rather than by wall clock.
    @Test
    func aDragHoldsTheDrainOffWithoutSpinningTheRunLoop() throws {
        let listView = makePendingListView()
        #expect(listView.rowLayout.hasPendingRows)

        listView.scrollWheel(with: try wheelEvent(phase: .began))
        #expect(listView.isUserInteractingWithScroll, "the drag never started")

        let window = 0.2
        listView.sliceDrainPassCount = 0
        listView.scheduleSliceDrain()
        RunLoop.main.run(until: Date().addingTimeInterval(window))
        let passes = listView.sliceDrainPassCount

        // One per frame at 60Hz is 12 across this window; the timer floor and
        // a busy machine can stretch that, so the bound is loose. It is three
        // orders of magnitude under what a spinning loop reaches.
        #expect(passes <= 60, "\(passes) drain passes in \(window)s — the run loop is spinning")
        #expect(passes >= 1, "the drain stopped re-arming entirely")
        #expect(listView.rowLayout.hasPendingRows, "the drag should have held measurement off")
    }

    /// And once the finger lifts, measurement actually resumes.
    ///
    /// The fix replaces an immediate re-arm with a delayed one, so the way to
    /// get it wrong is to stop re-arming: the hold-off would then be permanent
    /// and the rows would stay estimates until something else asked for a
    /// layout.
    @Test
    func measurementResumesAfterTheDragEnds() throws {
        let listView = makePendingListView(count: 200)
        listView.scrollWheel(with: try wheelEvent(phase: .began))
        listView.scheduleSliceDrain()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(listView.rowLayout.hasPendingRows, "the drag should have held measurement off")

        listView.scrollWheel(with: try wheelEvent(phase: .ended))
        #expect(!listView.isUserInteractingWithScroll, "the drag never ended")

        for _ in 0 ..< 100 where listView.rowLayout.hasPendingRows {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        #expect(!listView.rowLayout.hasPendingRows, "measurement never resumed")
    }
}
#endif
