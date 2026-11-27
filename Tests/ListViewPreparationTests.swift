//
//  ListViewPreparationTests.swift
//  ListViewKit
//
//  Rows made ready before the scroll reaches them: which rows, in what
//  order, at what pace, and what the layout pass is left to do for one.
//
//  Runs on both platforms; the UIKit half needs
//  `xcodebuild test -scheme ListViewKit-Package -destination 'platform=iOS Simulator,…'`.
//

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import QuartzCore
import Testing
@testable import ListViewKit

private struct PreparedItem: Identifiable, Hashable {
    let id: Int
    var revision = 0
}

/// What the list asked of the rows, in the order it asked.
@MainActor
private final class PreparationProbe {
    enum Event: Equatable {
        case measure(Int)
        case configure(Int)
    }

    var events: [Event] = []

    var measured: [Int] {
        events.compactMap { if case let .measure(id) = $0 { id } else { nil } }
    }

    var configured: [Int] {
        events.compactMap { if case let .configure(id) = $0 { id } else { nil } }
    }
}

@MainActor
private final class PreparedRow: ListRowView {
    var revision = -1
    var layoutCount = 0

    #if canImport(UIKit)
        override func layoutSubviews() {
            super.layoutSubviews()
            layoutCount += 1
        }
    #else
        override func layout() {
            super.layout()
            layoutCount += 1
        }
    #endif
}

/// Hands each item its own row back, as a list that keeps expensive rows
/// instead of pooling them does.
@MainActor
private final class RetainingList: ListView<PreparedItem> {
    var retained: [Int: ListRowView] = [:]
    var mountCount = 0
    private var mounting: Int?
    private var recycling: Int?

    override func mountRowView(at index: Int) {
        mounting = content[index].id
        defer { mounting = nil }
        mountCount += 1
        super.mountRowView(at: index)
    }

    override func dequeueReusableRowView(forRegistrationAt _: Int) -> ListRowView? {
        mounting.flatMap { retained.removeValue(forKey: $0) }
    }

    override func recycleRow(with identifier: Int) -> ListRowView? {
        recycling = identifier
        defer { recycling = nil }
        return super.recycleRow(with: identifier)
    }

    override func enqueueReusableRowView(_ view: ListRowView, forRegistrationAt registrationIndex: Int) {
        guard let recycling else {
            super.enqueueReusableRowView(view, forRegistrationAt: registrationIndex)
            return
        }
        retained[recycling] = view
    }
}

@Suite(.serialized)
@MainActor
struct ListViewPreparationTests {
    private static let rowHeight: CGFloat = 100
    private static let viewport = CGSize(width: 200, height: 300)

    private func makeListView(
        _ listView: ListView<PreparedItem> = .init(frame: CGRect(origin: .zero, size: viewport)),
        count: Int = 40,
        range: ListPreparationRange = .points(200),
        probe: PreparationProbe = .init(),
        claims: @escaping @MainActor (PreparedItem) -> Bool = { _ in true }
    ) -> ListView<PreparedItem> {
        listView.estimatedRowHeight = Self.rowHeight
        listView.rows {
            ListRow(PreparedRow.self)
                .when(claims)
                .height { item, _ in
                    probe.events.append(.measure(item.id))
                    return Self.rowHeight
                }
                .configure { row, item, _ in
                    probe.events.append(.configure(item.id))
                    row.revision = item.revision
                }
        }
        listView.preparationRange = range
        // One step to a travelling pass, however fast these rows are.
        listView.preparationBudget.travelling = 0
        listView.apply((0 ..< count).map { PreparedItem(id: $0) })
        layout(listView)
        return listView
    }

    private func layout(_ listView: ListView<PreparedItem>) {
        #if canImport(UIKit)
            listView.setNeedsLayout()
            listView.layoutIfNeeded()
        #elseif canImport(AppKit)
            listView.needsLayout = true
            listView.layoutSubtreeIfNeeded()
        #endif
    }

    /// Scrolls to `offsetY` and lays out, as one frame of a scroll does.
    private func scroll(_ listView: ListView<PreparedItem>, to offsetY: CGFloat) {
        listView.contentOffset.y = offsetY
        layout(listView)
    }

    /// Makes the list count as standing still, whatever just moved it.
    private func rest(_ listView: ListView<PreparedItem>) {
        listView.lastPreparationTravelAt = 0
    }

    /// Runs passes until the list queues no more, as an idle run loop would,
    /// or as the frames of a scroll would while the list travels.
    private func settle(_ listView: ListView<PreparedItem>, travelling: Bool = false) {
        layout(listView)
        for _ in 0 ..< 500 {
            listView.lastPreparationTravelAt = travelling ? CACurrentMediaTime() : 0
            listView.schedulePreparation()
            guard listView.isPreparationScheduled else { return }
            listView.prepareRows()
            layout(listView)
        }
        Issue.record("the list never finished making rows ready")
    }

    private func mounted(_ listView: ListView<PreparedItem>) -> [Int] {
        listView.content.map(\.id).filter { listView.rowView(for: $0) != nil }
    }

    // MARK: - Which rows

    @Test("without a range nothing is made ready and no pass is ever queued")
    func withoutARangeNothingIsMadeReady() {
        let listView = makeListView(range: .none)
        scroll(listView, to: 500)
        scroll(listView, to: 0)

        #expect(mounted(listView) == [0, 1, 2])
        #expect(listView.preparationPassCount == 0)
        #expect(!listView.isPreparationScheduled)
        #expect(listView.retentionRect == listView.mountRect)
    }

    @Test("the rows within the range are mounted past the viewport")
    func rowsWithinTheRangeAreMounted() {
        let listView = makeListView()
        #expect(mounted(listView) == [0, 1, 2], "the layout pass itself mounts only the viewport")

        settle(listView)
        #expect(mounted(listView) == [0, 1, 2, 3, 4])
        #expect(listView.preparedRowCount == 2)
        #expect(listView.indicesForVisibleRows == [0, 1, 2], "what is visible is still the viewport")
    }

    @Test("a range in viewport heights follows the viewport")
    func aRangeInViewportsFollowsTheViewport() {
        let listView = makeListView(range: .viewports(1))
        settle(listView)
        #expect(mounted(listView) == [0, 1, 2, 3, 4, 5])

        listView.frame.size.height = 100
        settle(listView)
        // One row shows, one more is within a viewport of it, and the
        // retention reaches a quarter of a viewport further.
        #expect(mounted(listView) == [0, 1, 2])
    }

    @Test("a range that asks for everything stops at the content")
    func anUnboundedRangeStopsAtTheContent() {
        let listView = makeListView(count: 12, range: .viewports(.infinity))
        settle(listView)
        #expect(mounted(listView) == Array(0 ..< 12))
    }

    @Test("a range that is not a number, or is negative, is no range", arguments: [
        ListPreparationRange.points(.nan), .points(-50), .viewports(-1), .viewports(.nan),
    ])
    func aMeaninglessRangeIsNoRange(range: ListPreparationRange) {
        let listView = makeListView(range: range)
        settle(listView)
        #expect(mounted(listView) == [0, 1, 2])
        #expect(listView.preparedRowCount == 0)
    }

    @Test("rows are made ready above the viewport as well as below")
    func rowsAreMadeReadyOnBothSides() {
        let listView = makeListView()
        scroll(listView, to: 1000)
        settle(listView)
        #expect(mounted(listView) == [8, 9, 10, 11, 12, 13, 14])
    }

    @Test("a row no registration claims is passed over")
    func anUnclaimedRowIsPassedOver() {
        let listView = makeListView(claims: { $0.id != 3 })
        settle(listView)
        #expect(mounted(listView) == [0, 1, 2, 4])
    }

    // MARK: - What a scroll is left to do

    @Test("scrolling onto rows made ready measures and fills in nothing")
    func scrollingOntoReadyRowsDoesNoRowWork() {
        let probe = PreparationProbe()
        let listView = makeListView(probe: probe)
        settle(listView)
        let ready = [3, 4].map { listView.rowView(for: $0) }

        probe.events.removeAll()
        scroll(listView, to: 200)

        #expect(probe.events.isEmpty, "the pass that uncovered rows 3 and 4 had work to do: \(probe.events)")
        #expect([3, 4].map { listView.rowView(for: $0) } == ready, "the rows uncovered are the ones made ready")
    }

    @Test("a row made ready is laid out before it is uncovered")
    func aReadyRowIsLaidOutAhead() throws {
        let listView = makeListView()
        settle(listView)
        let row = try #require(listView.rowView(for: 4) as? PreparedRow)
        let layouts = row.layoutCount
        #expect(layouts > 0)

        scroll(listView, to: 200)
        layout(listView)
        #expect(row.layoutCount == layouts, "uncovering the row laid it out again")
    }

    @Test("a scroll the passes keep up with never works on a row in a layout pass")
    func aScrollPreparationKeepsUpWithDoesNoRowWorkInLayout() {
        let probe = PreparationProbe()
        let listView = makeListView(count: 200, probe: probe)
        settle(listView)

        var workInLayout: [PreparationProbe.Event] = []
        var offset: CGFloat = 0
        // 25 points a frame: a row every four frames, two steps a row.
        for _ in 0 ..< 400 {
            offset += 25
            probe.events.removeAll()
            scroll(listView, to: offset)
            workInLayout += probe.events
            // What is left of the frame: one pass, which takes one step.
            guard listView.isPreparationScheduled else { continue }
            probe.events.removeAll()
            listView.prepareRows()
            #expect(probe.events.count <= 1, "a pass of a scroll took \(probe.events)")
            probe.events.removeAll()
            layout(listView)
            workInLayout += probe.events
        }
        #expect(workInLayout.isEmpty, "\(workInLayout.count) row steps landed in layout passes")
    }

    @Test("without a range the same scroll works on every row in the pass that uncovers it")
    func theSameScrollWithoutARangeWorksInLayout() {
        let probe = PreparationProbe()
        let listView = makeListView(count: 200, range: .none, probe: probe)
        probe.events.removeAll()

        var offset: CGFloat = 0
        for _ in 0 ..< 400 {
            offset += 25
            scroll(listView, to: offset)
        }
        // A hundred rows came into view.
        #expect(probe.configured.count == 100)
    }

    @Test("a scroll that outruns the passes falls back to the layout pass")
    func aScrollThatOutrunsPreparationStillShowsEveryRow() {
        let listView = makeListView(count: 200)
        settle(listView)
        // Twenty rows in one frame, far past anything made ready.
        scroll(listView, to: 2000)
        #expect(Set(mounted(listView)).isSuperset(of: [20, 21, 22]))
    }

    @Test("a frame whose layout pass had to work on a row takes no step on top")
    func aFrameThatPaidForARowTakesNoStep() {
        let probe = PreparationProbe()
        let listView = makeListView(count: 200, probe: probe)
        settle(listView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        let passes = listView.preparationPassCount

        // A row a frame: each layout pass mounts the one that came into view.
        var offset: CGFloat = 2050
        for _ in 0 ..< 10 {
            offset += 100
            scroll(listView, to: offset)
            #expect(listView.layoutPassWorkedOnRows)
            #expect(!listView.isPreparationScheduled, "a step was queued behind a row the frame already paid for")
        }
        #expect(listView.preparationPassCount == passes)
        #expect(listView.preparationWake != nil, "nothing would look again once the scroll stops")

        // The scroll slows to a frame with nothing coming into view.
        scroll(listView, to: offset + 1)
        #expect(!listView.layoutPassWorkedOnRows)
        #expect(listView.isPreparationScheduled)
    }

    @Test("a travelling pass keeps stepping while its budget lasts")
    func aTravellingPassSpendsItsBudget() {
        let probe = PreparationProbe()
        let listView = makeListView(count: 200, probe: probe)
        // Far more than these rows cost.
        listView.preparationBudget.travelling = 1
        scroll(listView, to: 400)
        probe.events.removeAll()

        listView.lastPreparationTravelAt = CACurrentMediaTime()
        listView.schedulePreparation()
        listView.prepareRows()
        #expect(probe.events == [.measure(7), .configure(7), .measure(8), .configure(8)])
    }

    // MARK: - Pace and order

    @Test("while the list travels a pass takes one step: a measurement or a mount")
    func aTravellingPassTakesOneStep() {
        let probe = PreparationProbe()
        // An estimate that differs, so every row is still to be measured.
        let listView = makeListView(count: 200, probe: probe)
        settle(listView)
        listView.invalidateLayout()
        layout(listView)
        scroll(listView, to: 400)

        var steps: [PreparationProbe.Event] = []
        for _ in 0 ..< 6 {
            probe.events.removeAll()
            listView.lastPreparationTravelAt = CACurrentMediaTime()
            listView.schedulePreparation()
            guard listView.isPreparationScheduled else { break }
            listView.prepareRows()
            #expect(probe.events.count == 1, "one pass took \(probe.events)")
            steps += probe.events
            layout(listView)
        }
        // The two rows ahead, a step at a time; the two behind wait.
        #expect(steps == [.measure(7), .configure(7), .measure(8), .configure(8)])
    }

    @Test("a row is measured in one step and mounted in the next")
    func measurementAndMountAreSeparateSteps() {
        let probe = PreparationProbe()
        let listView = makeListView(count: 200, probe: probe)
        probe.events.removeAll()

        listView.lastPreparationTravelAt = CACurrentMediaTime()
        listView.schedulePreparation()
        listView.prepareRows()
        #expect(probe.events == [.measure(3)])

        layout(listView)
        listView.lastPreparationTravelAt = CACurrentMediaTime()
        listView.schedulePreparation()
        listView.prepareRows()
        #expect(probe.events == [.measure(3), .configure(3)])
    }

    @Test("the side the list is heading for is made ready first", arguments: [false, true])
    func theSideAheadComesFirst(headingUp: Bool) {
        let probe = PreparationProbe()
        let listView = makeListView(count: 200, probe: probe)
        // Arrive from one side, then stand still with both sides owed.
        scroll(listView, to: headingUp ? 6000 : 4000)
        scroll(listView, to: 5000)
        probe.events.removeAll()
        settle(listView)

        let ahead = headingUp ? [49, 48] : [53, 54]
        let behind = headingUp ? [53, 54] : [49, 48]
        #expect(probe.configured == ahead + behind)
    }

    @Test("while the list travels the side it is leaving waits")
    func theSideBehindWaitsForTheScrollToEnd() {
        let listView = makeListView(count: 200)
        scroll(listView, to: 4000)
        scroll(listView, to: 5000)
        settle(listView, travelling: true)
        // Travelling towards the end: only what lies ahead.
        #expect(mounted(listView) == [50, 51, 52, 53, 54])
        #expect(listView.preparationWake != nil, "nothing would look again once the scroll ends")

        settle(listView)
        #expect(mounted(listView) == [48, 49, 50, 51, 52, 53, 54])
    }

    @Test("before any travel the nearer row comes first")
    func beforeAnyTravelTheNearerRowComesFirst() {
        let probe = PreparationProbe()
        let listView = makeListView(count: 200, range: .none, probe: probe)
        listView.contentOffset.y = 5030
        layout(listView)
        listView.preparationRange = .points(200)
        probe.events.removeAll()
        settle(listView)
        // The viewport runs from 30 points into row 50 to 30 points into row
        // 53: row 49 is 30 points off, row 54 is 70, row 48 is 130 and row
        // 55 is 170.
        #expect(listView.preparationHeading == 0)
        #expect(probe.configured == [49, 54, 48, 55])
    }

    @Test("an idle list with everything ready queues nothing")
    func anIdleListQueuesNothing() {
        let listView = makeListView()
        settle(listView)
        // The blocks the passes above were queued as have yet to come round.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let passes = listView.preparationPassCount

        layout(listView)
        layout(listView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(listView.preparationPassCount == passes)
        #expect(!listView.isPreparationScheduled)
        #expect(listView.preparationWake == nil)
    }

    @Test("the run loop makes the rows ready without being asked")
    func theRunLoopMakesRowsReady() {
        let listView = makeListView()
        rest(listView)
        #expect(listView.isPreparationScheduled)

        let deadline = Date().addingTimeInterval(2)
        while mounted(listView).count < 5, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        #expect(mounted(listView) == [0, 1, 2, 3, 4])
    }

    // MARK: - Ahead and behind

    @Test("the longer reach goes to the side the list is heading for", arguments: [false, true])
    func theLongerReachGoesAhead(headingUp: Bool) {
        let listView = makeListView(count: 200, range: .points(ahead: 300, behind: 100))
        scroll(listView, to: headingUp ? 6000 : 4000)
        scroll(listView, to: 5000)
        settle(listView)
        // The viewport shows 50, 51 and 52.
        #expect(mounted(listView) == (headingUp ? Array(47 ... 53) : Array(49 ... 55)))
    }

    @Test("before the list has scrolled, ahead is towards the end")
    func beforeAnyTravelAheadIsTowardsTheEnd() {
        let listView = makeListView(count: 200, range: .none)
        listView.contentOffset.y = 5000
        layout(listView)
        listView.preparationRange = .points(ahead: 300, behind: 100)
        settle(listView)
        #expect(listView.preparationHeading == 0)
        #expect(mounted(listView) == Array(49 ... 55))
    }

    @Test("at the edge it was heading for, the list has only the other way to go")
    func atTheEdgeAheadTurnsRound() {
        let listView = makeListView(count: 40, range: .points(ahead: 300, behind: 100))
        // Opened at its end, as a conversation is.
        scroll(listView, to: listView.maximumContentOffset.y)
        settle(listView)
        #expect(listView.preparationHeading == 1)
        #expect(mounted(listView) == Array(34 ... 39))

        // And back at the start, having come up.
        scroll(listView, to: 0)
        settle(listView)
        #expect(listView.preparationHeading == -1)
        #expect(mounted(listView) == Array(0 ... 5))
    }

    @Test("a waver the other way does not turn the range round, a scroll does")
    func aWaverDoesNotTurnTheRange() {
        let listView = makeListView(count: 200, range: .points(ahead: 300, behind: 100))
        scroll(listView, to: 4000)
        scroll(listView, to: 5000)
        settle(listView)
        #expect(mounted(listView) == Array(49 ... 55))

        // A rubber band settling, a finger wavering.
        scroll(listView, to: 4990)
        scroll(listView, to: 4970)
        settle(listView)
        #expect(listView.preparationHeading == 1)
        #expect(listView.rowView(for: 55) != nil, "a waver let go of what was ready ahead")

        scroll(listView, to: 4940)
        settle(listView)
        #expect(listView.preparationHeading == -1)
        // 4940 to 5240 shows 49…52; 300 points above reaches 46, and the
        // rows below are kept a quarter of a viewport past their 100.
        #expect(mounted(listView) == Array(46 ... 54))
    }

    // MARK: - Letting go

    @Test("a row is kept until it is a quarter of a viewport past the range")
    func rowsAreKeptAQuarterViewportPastTheRange() throws {
        let listView = makeListView(count: 200)
        scroll(listView, to: 1000)
        settle(listView)
        let edge = try #require(listView.rowView(for: 8))

        // Row 8 ends at 900. The range ends at 1070 - 200, the retention 75
        // points further, at 795: still over the row.
        scroll(listView, to: 1070)
        #expect(listView.rowView(for: 8) === edge)
        scroll(listView, to: 1000)
        #expect(listView.rowView(for: 8) === edge)

        // At 1180 the retention starts at 905, past the row.
        scroll(listView, to: 1180)
        #expect(listView.rowView(for: 8) == nil)
    }

    @Test("turning the range off lets the rows past the viewport go")
    func turningTheRangeOffLetsRowsGo() {
        let listView = makeListView()
        settle(listView)
        #expect(mounted(listView).count == 5)

        listView.preparationRange = .none
        layout(listView)
        #expect(mounted(listView) == [0, 1, 2])
        #expect(!listView.isPreparationScheduled)
        #expect(listView.preparationWake == nil)
    }

    // MARK: - Changes

    @Test("a row that changes past the viewport is let go, and comes back once it holds still")
    func aChangedRowPastTheViewportWaitsUntilItHoldsStill() throws {
        let probe = PreparationProbe()
        let listView = makeListView(probe: probe)
        settle(listView)
        #expect(listView.rowView(for: 4) != nil)

        probe.events.removeAll()
        listView.update(PreparedItem(id: 4, revision: 1))
        #expect(listView.rowView(for: 4) == nil)
        #expect(probe.configured.isEmpty, "the change was filled in where nobody could see it")

        // Still changing: every pass leaves it alone.
        for revision in 2 ..< 6 {
            listView.update(PreparedItem(id: 4, revision: revision))
            settle(listView)
            #expect(listView.rowView(for: 4) == nil)
        }
        #expect(probe.events.isEmpty)
        #expect(listView.preparationWake != nil, "nothing would look again once the row holds still")

        // It held still.
        listView.preparationChangedAt[4] = CACurrentMediaTime() - 1
        settle(listView)
        let row = try #require(listView.rowView(for: 4) as? PreparedRow)
        #expect(row.revision == 5)
        #expect(probe.events == [.measure(4), .configure(4)])
    }

    @Test("a row that changes in the viewport is filled in where it stands")
    func aChangedRowInTheViewportIsFilledInInPlace() throws {
        let listView = makeListView()
        settle(listView)
        let row = try #require(listView.rowView(for: 1) as? PreparedRow)

        listView.update(PreparedItem(id: 1, revision: 7))
        #expect(listView.rowView(for: 1) === row)
        #expect(row.revision == 7)
    }

    @Test("an apply that changes a row past the viewport lets it go too")
    func anApplyThatChangesAReadyRowLetsItGo() {
        let probe = PreparationProbe()
        let listView = makeListView(probe: probe)
        settle(listView)

        var items = listView.content
        items[4].revision = 3
        probe.events.removeAll()
        listView.apply(items)
        #expect(listView.rowView(for: 4) == nil)
        #expect(probe.configured.isEmpty)
        #expect(listView.preparationChangedAt[4] != nil)
    }

    @Test("a row removed past the viewport leaves without a picture")
    func aRemovedReadyRowLeavesUnseen() {
        let listView = makeListView()
        settle(listView)
        #expect(listView.prepareDisposals(of: [4]).isEmpty)
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            #expect(listView.prepareDisposals(of: [1]).count == 1, "a row in the viewport still leaves in sight")
        #endif
    }

    @Test("while rows are still sliding nothing is made ready")
    func nothingIsMadeReadyWhileRowsSlide() {
        let listView = makeListView()
        // As an animated apply leaves them: mounted rows held for the slide.
        listView.holdMountedRows(for: 60)
        settle(listView)
        #expect(mounted(listView) == [0, 1, 2])
        #expect(listView.preparationWake != nil, "nothing would look again once the slide ends")

        listView.heldRows.removeAll()
        settle(listView)
        #expect(mounted(listView) == [0, 1, 2, 3, 4])
    }

    // MARK: - Measurement

    @Test("measuring a row above the viewport ahead of time leaves the viewport where it was")
    func measuringAboveKeepsTheViewportStill() {
        let probe = PreparationProbe()
        let listView = ListView<PreparedItem>(frame: CGRect(origin: .zero, size: Self.viewport))
        // Every row turns out more than twice its estimate.
        listView.estimatedRowHeight = 40
        listView.rows {
            ListRow(PreparedRow.self)
                .height { item, _ in
                    probe.events.append(.measure(item.id))
                    return Self.rowHeight
                }
                .configure { _, _, _ in }
        }
        listView.apply((0 ..< 200).map { PreparedItem(id: $0) })
        layout(listView)
        scroll(listView, to: 2000)
        let first = listView.indicesForVisibleRows[0]
        let onScreenBefore = listView.rectForRow(at: first).minY - listView.contentOffset.y

        listView.preparationRange = .points(200)
        probe.events.removeAll()
        settle(listView)

        #expect(!probe.measured.isEmpty)
        #expect(listView.indicesForVisibleRows[0] == first)
        #expect(listView.rectForRow(at: first).minY - listView.contentOffset.y == onScreenBefore)
        // Mounted where the measured heights put them, edge to edge.
        let frames = mounted(listView).compactMap { listView.rowView(for: $0)?.placedFrame }
        for (upper, lower) in zip(frames, frames.dropFirst()) {
            #expect(upper.maxY == lower.minY)
        }
    }

    @Test("a row is told whether its view is needed next")
    func aMeasurementSaysWhetherTheRowWillMount() {
        var willMount: [Int: Bool] = [:]
        var displayed: [Bool] = []
        let listView = ListView<PreparedItem>(frame: CGRect(origin: .zero, size: Self.viewport))
        listView.estimatedRowHeight = Self.rowHeight
        listView.rows {
            ListRow(PreparedRow.self)
                .height { item, context in
                    willMount[item.id] = context.willMount
                    return Self.rowHeight
                }
                .configure { _, _, context in displayed.append(context.willMount) }
        }
        listView.preparationRange = .points(200)
        listView.apply((0 ..< 40).map { PreparedItem(id: $0) })
        layout(listView)
        #expect(willMount == [0: true, 1: true, 2: true], "the rows in view are mounted in the same pass")

        settle(listView)
        #expect(willMount[3] == true && willMount[4] == true, "the rows within the range are mounted a step later")
        #expect(displayed.allSatisfy { $0 })

        // Everything else is measured between frames, ahead of any need.
        _ = listView.rowLayout.drainPendingRows(
            intersecting: listView.mountRect,
            anchoredAt: listView.viewportRect,
            deadline: CACurrentMediaTime() + 5
        )
        #expect(!listView.rowLayout.hasPendingRows)
        #expect(willMount.count == 40)
        #expect((5 ..< 40).allSatisfy { willMount[$0] == false })
    }

    @Test("rows that turn out far taller than their estimate are not all measured for one viewport")
    func aViewportOfEstimatesIsNotMeasuredWhole() {
        let probe = PreparationProbe()
        let listView = ListView<PreparedItem>(frame: CGRect(origin: .zero, size: Self.viewport))
        // Ten estimates to the viewport, three real rows.
        listView.estimatedRowHeight = 30
        listView.rows {
            ListRow(PreparedRow.self)
                .height { item, _ in
                    probe.events.append(.measure(item.id))
                    return Self.rowHeight
                }
                .configure { _, _, _ in }
        }
        listView.apply((0 ..< 200).map { PreparedItem(id: $0) })
        layout(listView)
        #expect(probe.measured == [0, 1, 2], "rows pushed out of view by the ones before them were measured anyway")
        #expect(mounted(listView) == [0, 1, 2])
    }

    @Test("scrolling to the end without animation lands on the end, measuring only what it shows there")
    func scrollingToTheEndLandsOnTheEnd() {
        let probe = PreparationProbe()
        let listView = ListView<PreparedItem>(frame: CGRect(origin: .zero, size: Self.viewport))
        listView.estimatedRowHeight = 30
        listView.rows {
            ListRow(PreparedRow.self)
                .height { item, _ in
                    probe.events.append(.measure(item.id))
                    return Self.rowHeight
                }
                .configure { _, _, _ in }
        }
        listView.apply((0 ..< 200).map { PreparedItem(id: $0) })
        layout(listView)
        probe.events.removeAll()

        listView.scrollToBottom(animated: false)
        layout(listView)

        #expect(listView.isScrolledToBottom())
        #expect(listView.indicesForVisibleRows == [197, 198, 199])
        #expect(probe.measured == [199, 198, 197])
        // And it stays there: nothing in view was left at an estimate.
        layout(listView)
        #expect(listView.isScrolledToBottom())
    }

    @Test("jumping to a row measures what it will show there, outwards from the row", arguments: [
        (ListRowPosition.top, [100, 101, 102]),
        (ListRowPosition.bottom, [100, 99, 98]),
        (ListRowPosition.middle, [100, 99, 101]),
    ])
    func jumpingToARowLandsOnIt(position: ListRowPosition, measured: [Int]) {
        let probe = PreparationProbe()
        let listView = ListView<PreparedItem>(frame: CGRect(origin: .zero, size: Self.viewport))
        listView.estimatedRowHeight = 30
        listView.rows {
            ListRow(PreparedRow.self)
                .height { item, _ in
                    probe.events.append(.measure(item.id))
                    return Self.rowHeight
                }
                .configure { _, _, _ in }
        }
        listView.apply((0 ..< 200).map { PreparedItem(id: $0) })
        layout(listView)
        probe.events.removeAll()

        listView.scrollToRow(at: 100, at: position, animated: false)
        layout(listView)

        #expect(probe.measured == measured)
        let row = listView.rectForRow(at: 100)
        let viewport = CGRect(origin: listView.contentOffset, size: listView.bounds.size)
        switch position {
        case .top: #expect(row.minY == viewport.minY)
        case .bottom: #expect(row.maxY == viewport.maxY)
        default: #expect(row.midY == viewport.midY)
        }
    }

    // MARK: - Width

    @Test("while the width changes the range is dropped, and comes back once it holds")
    func aChangingWidthDropsTheRange() {
        let probe = PreparationProbe()
        let listView = makeListView(probe: probe)
        settle(listView)
        #expect(mounted(listView).count == 5)

        probe.events.removeAll()
        listView.frame.size.width = 260
        layout(listView)
        #expect(mounted(listView) == [0, 1, 2], "rows past the viewport were laid out again by the resize")
        #expect(Set(probe.measured) == [0, 1, 2])

        // Still settling: nothing is made ready.
        listView.schedulePreparation()
        #expect(!listView.isPreparationScheduled)
        #expect(listView.preparationWake != nil, "nothing would look again once the width holds")

        listView.lastWidthChangeAt = 0
        settle(listView)
        #expect(mounted(listView) == [0, 1, 2, 3, 4])
    }

    // MARK: - Subclasses

    @Test("a list that keeps its rows is handed each one back when it is made ready again")
    func aRetainingSubclassSeesEveryPreparedMount() throws {
        let probe = PreparationProbe()
        let listView = RetainingList(frame: CGRect(origin: .zero, size: Self.viewport))
        _ = makeListView(listView, count: 200, probe: probe)
        settle(listView)
        #expect(listView.mountCount == 5, "rows made ready go through mountRowView")
        let row = try #require(listView.rowView(for: 4))

        scroll(listView, to: 3000)
        settle(listView)
        #expect(listView.rowView(for: 4) == nil)
        #expect(listView.retained[4] === row, "a row let go from the range goes through the reuse hooks")

        scroll(listView, to: 0)
        settle(listView)
        #expect(listView.rowView(for: 4) === row)
    }
}
