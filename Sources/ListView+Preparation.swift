//
//  ListView+Preparation.swift
//  ListViewKit
//
//  Rows made ready before the scroll reaches them.
//
//  A row coming into view costs its measurement, its view, its
//  configuration, its layout and its drawing, and without a range all of
//  that lands in the frame that uncovers it. With one, the rows within the
//  range are taken through the same steps beforehand, one step at a time
//  between frames, nearest the viewport first. The layout pass is unchanged:
//  it still measures and mounts whatever the viewport needs and finds nothing
//  left to do for a row that was ready.
//
//  The work is not made smaller, only moved to where there is room for it:
//  into the frames of a scroll that had nothing else to do, a step each, and
//  into the time the list stands still. A scroll fast enough to need a row
//  in every frame leaves no such room, and costs what it cost before.
//

import Foundation
import QuartzCore

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#else
    #error("ListViewKit requires UIKit or AppKit")
#endif

extension ListView {
    /// How long after the offset last moved the list still counts as
    /// travelling, and a pass keeps to the smaller of its two budgets.
    static var preparationTravelWindow: CFTimeInterval { 0.1 }

    /// How far past the mounted area rows are made ready while the list
    /// travels, in viewport heights. Far enough for a row's steps to come
    /// before the row does; the rest of the range waits for the list to
    /// stop.
    static var preparationTravelBand: CGFloat { 0.5 }

    /// How long a row must hold still before it is made ready again. A reply
    /// being written changes many times a second; readying it past the
    /// viewport after every change would typeset text nobody is looking at.
    static var preparationQuietPeriod: CFTimeInterval { 0.25 }

    /// How long the width must hold still before rows are made ready again,
    /// the same wait the deferred measurement keeps.
    private static var preparationWidthHoldOff: CFTimeInterval { 0.15 }

    final var isPreparationEnabled: Bool { !preparationRange.isEmpty }

    /// Whether rows are kept ready past the mounted area right now.
    final var isPreparing: Bool { preparationReach.ahead > 0 || preparationReach.behind > 0 }

    // MARK: - Geometry

    /// Re-reads how far past the mounted area rows are kept ready.
    ///
    /// Zero while the width is changing. Every mounted row is laid out again
    /// on each step of a resize, so rows kept past the viewport would
    /// multiply the cost of the one thing a resize is slow at. They are let
    /// go for its length and made ready again once the width holds.
    final func refreshPreparationReach(now: CFTimeInterval = CACurrentMediaTime()) {
        guard isPreparationEnabled, bounds.width > 0, bounds.height > 0, !isWidthChanging(now: now) else {
            preparationReach = (0, 0)
            return
        }
        preparationReach = preparationRange.reach(viewportHeight: bounds.height)
        turnPreparationRoundAtAnEdge()
    }

    /// Turns the heading round for a list standing at the edge it was
    /// heading for: it has nowhere to go but back, and a conversation opened
    /// at its end is read upwards.
    ///
    /// The heading itself is turned, not only how it is read here. A list
    /// that then leaves the edge by a few points is still heading back, and
    /// the rows made ready that way are not let go for a waver.
    private final func turnPreparationRoundAtAnEdge() {
        let mounted = mountRect
        let atStart = mounted.minY <= 0
        let atEnd = mounted.maxY >= rowLayout.contentHeight
        guard atStart != atEnd else { return }
        let heading = atEnd ? -1 : 1
        guard preparationHeading != heading else { return }
        preparationHeading = heading
        preparationReverseTravel = 0
    }

    /// How far rows are kept ready above the mounted area and below it: the
    /// longer reach on the side the list is heading for, towards the end
    /// until it has scrolled at all.
    private final var preparationReachBySide: (above: CGFloat, below: CGFloat) {
        let reach = preparationReach
        return preparationHeading >= 0 ? (reach.behind, reach.ahead) : (reach.ahead, reach.behind)
    }

    private final func isWidthChanging(now: CFTimeInterval) -> Bool {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            if inLiveResize { return true }
        #endif
        return now - lastWidthChangeAt < Self.preparationWidthHoldOff
    }

    /// The rectangle rows are made ready over, in the same space as
    /// ``viewportRect``: the mounted area and the range either side of it,
    /// no further than the content goes.
    final var preparationRect: CGRect {
        guard isPreparing else { return mountRect }
        let reach = preparationReachBySide
        return widened(mountRect, above: reach.above, below: reach.below)
    }

    /// The rectangle a mounted row has to leave before it is recycled.
    ///
    /// A quarter of a viewport past ``preparationRect``, so a row at the edge
    /// of the range is not let go and made ready again each time the reader
    /// reverses over it. Equal to ``mountRect`` without a range.
    final var retentionRect: CGRect {
        guard isPreparing else { return mountRect }
        let reach = preparationReachBySide
        let margin = bounds.height / 4
        return widened(mountRect, above: reach.above + margin, below: reach.below + margin)
    }

    private final func widened(_ rect: CGRect, above: CGFloat, below: CGFloat) -> CGRect {
        let minY = min(rect.minY, max(0, rect.minY - above))
        let maxY = max(rect.maxY, min(rowLayout.contentHeight, rect.maxY + below))
        return CGRect(x: rect.minX, y: minY, width: rect.width, height: maxY - minY)
    }

    /// Whether the row at `index` is mounted only because it is kept ready:
    /// it stands outside the mounted area, it will after this layout, and no
    /// animation is still showing it.
    final func isKeptOnlyForPreparation(_ view: ListRowView, at index: Int, identifier: Item.ID) -> Bool {
        guard isPreparing, heldRows[identifier] == nil else { return false }
        let mounted = mountRect
        guard let frame = rowLayout.frame(for: index), !frame.intersects(mounted) else { return false }
        return !view.placedFrame.offsetBy(dx: 0, dy: -topInset).intersects(mounted)
    }

    // MARK: - Travel

    /// Notes which way the offset moved since the last pass, and when.
    ///
    /// Read from the offset rather than from the scroll ledger, which leaves
    /// out a stepped mouse wheel: that is travel a row effect should not
    /// spring on, but it uncovers rows like any other.
    final func notePreparationTravel() {
        let travel = contentOffset.y - preparationReferenceOffsetY
        preparationReferenceOffsetY = contentOffset.y
        // Under a device pixel is rounding in a compensation, not a scroll.
        guard abs(travel) > 0.1 else { return }
        lastPreparationTravelAt = CACurrentMediaTime()
        let direction = travel > 0 ? 1 : -1
        guard direction != preparationHeading, preparationHeading != 0 else {
            preparationHeading = direction
            preparationReverseTravel = 0
            return
        }
        // The other way, but not yet a change of mind: a rubber band
        // settling, a finger wavering. The sides trade reach, and the rows
        // past the shorter one are let go, only once it has gone somewhere.
        preparationReverseTravel += abs(travel)
        if preparationReverseTravel >= Self.preparationTurnDistance {
            preparationHeading = direction
            preparationReverseTravel = 0
        }
    }

    /// How far the list has to travel the other way before the side ahead
    /// changes.
    private static var preparationTurnDistance: CGFloat { 48 }

    private final func isTravelling(now: CFTimeInterval) -> Bool {
        now - lastPreparationTravelAt < Self.preparationTravelWindow
    }

    // MARK: - Changes

    /// Notes that an item changed while no row was mounted for it, so it is
    /// not made ready until it has held still.
    final func notePreparationChange(of identifier: Item.ID) {
        guard isPreparationEnabled else { return }
        // Whatever was prepared was prepared for the item as it was.
        preparationSlices[identifier] = nil
        guard visibleRows[identifier] == nil else { return }
        let now = CACurrentMediaTime()
        // Normally emptied by the passes. A list with nothing to make ready
        // runs none, so the notes of items long gone are dropped here.
        if preparationChangedAt.count > 64 {
            preparationChangedAt = preparationChangedAt.filter { now - $0.value < Self.preparationQuietPeriod }
        }
        preparationChangedAt[identifier] = now
    }

    /// The same for the changed items of an apply that lie within reach.
    final func notePreparationChanges(of identifiers: [Item.ID]) {
        guard isPreparationEnabled, !identifiers.isEmpty else { return }
        if !preparationSlices.isEmpty {
            for identifier in identifiers {
                preparationSlices[identifier] = nil
            }
        }
        let kept = rowLayout.indices(intersecting: retentionRect)
        guard !kept.isEmpty else { return }
        let now = CACurrentMediaTime()
        for identifier in identifiers where visibleRows[identifier] == nil {
            guard let index = indexByID[identifier], kept.contains(index) else { continue }
            preparationChangedAt[identifier] = now
        }
    }

    // MARK: - Scheduling

    /// What a pass would do next, and when to look again if that is nothing
    /// for now.
    private struct Outlook {
        enum Step {
            case measure(Int)
            /// One more call of the row's ``ListRow/prepare(_:)``.
            case slice(Int, registration: Int)
            case mount(Int)
        }

        var step: Step?
        /// Set when rows are waiting on the clock: one that changed a moment
        /// ago, the far side while the list travels, a width still settling.
        var retryAfter: CFTimeInterval?

        mutating func retry(after delay: CFTimeInterval) {
            retryAfter = min(retryAfter ?? delay, delay)
        }
    }

    /// Queues a pass if a row within the range is not ready.
    ///
    /// Called at the end of every layout pass, which is what paces the work
    /// while the list travels: the block runs when the run loop comes round
    /// after that pass's commit, in what is left of the frame.
    ///
    /// Unless that frame has already paid for a row. A scroll that outran
    /// the range had its layout pass measure or mount what came into view,
    /// and a step on top of that would make the frame longer than it was
    /// without a range. The steps resume with the first frame that has room.
    final func schedulePreparation() {
        guard isPreparationEnabled, !isPreparationScheduled else { return }
        let now = CACurrentMediaTime()
        let outlook = preparationOutlook(now: now)
        guard outlook.step != nil else {
            if let delay = outlook.retryAfter {
                wakePreparation(after: delay)
            }
            return
        }
        if layoutContentDepth > 0, layoutPassWorkedOnRows, isTravelling(now: now) {
            // For the scroll that stops here, with no next frame to ask.
            wakePreparation(after: Self.preparationTravelWindow)
            return
        }
        isPreparationScheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                self?.prepareRows()
            }
        }
    }

    /// Looks again after `delay`, unless something is already due sooner.
    private final func wakePreparation(after delay: CFTimeInterval) {
        let fireDate = Date(timeIntervalSinceNow: max(delay, 0.01))
        if let pending = preparationWake, pending.isValid, pending.fireDate <= fireDate { return }
        preparationWake?.invalidate()
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.preparationWake = nil
                self?.schedulePreparation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        preparationWake = timer
    }

    /// Drops everything a range left behind, for when it is switched off.
    final func endPreparation() {
        preparationWake?.invalidate()
        preparationWake = nil
        preparationChangedAt.removeAll()
        preparationSlices.removeAll()
        preparationReach = (0, 0)
    }

    /// The most slices a row is given before it is mounted regardless, so a
    /// row that never says it is done still gets mounted, and a pass does
    /// not spin on it.
    static var mostPreparationSlices: Int { 16 }

    /// The registration whose ``ListRow/prepare(_:)`` the row at `index` is
    /// still owed a call of, or nil when it has none or is done.
    private final func registrationOwedASlice(at index: Int) -> Int? {
        let item = items[index]
        guard (preparationSlices[item.id] ?? 0) < Self.mostPreparationSlices,
              let registrationIndex = registrationIndex(for: item),
              registration(registrationIndex).prepare != nil
        else { return nil }
        return registrationIndex
    }

    // MARK: - The pass

    /// Takes the rows within the range that are not ready a step nearer.
    ///
    /// A step is one row's measurement, one slice of what its registration
    /// prepares ahead (``ListRow/prepare(_:)``), or its mount, and they are
    /// separate steps on purpose: a row that costs a frame to measure and a
    /// frame to build then costs two frames one at a time, not two at once.
    /// A pass always takes one step and keeps stepping until its budget is
    /// spent, see ``preparationBudget``.
    final func prepareRows() {
        isPreparationScheduled = false
        preparationPassCount &+= 1
        // A pass reached from inside a layout would mount under it.
        guard isPreparationEnabled, layoutContentDepth == 0 else { return }

        // The width has to be current first, as for any measurement.
        rowLayout.prepareForLayout()
        var now = CACurrentMediaTime()
        refreshPreparationReach(now: now)
        if !preparationChangedAt.isEmpty {
            preparationChangedAt = preparationChangedAt.filter { now - $0.value < Self.preparationQuietPeriod }
        }

        let deadline = now + (isTravelling(now: now) ? preparationBudget.travelling : preparationBudget.resting)
        var measuredAny = false
        var mountedAny = false
        var outlook = preparationOutlook(now: now)
        while let step = outlook.step {
            switch step {
            case let .measure(index):
                let dy = rowLayout.measureRow(at: index, anchoredAt: viewportRect)
                if dy != 0 {
                    compensateScrollOffset(by: dy)
                }
                measuredAny = true
            case let .slice(index, registrationIndex):
                let item = items[index]
                let given = preparationSlices[item.id] ?? 0
                let context = context(at: index, purpose: .display, willMount: true)
                let wantsMore = registration(registrationIndex).prepare?(item, context) ?? false
                preparationSlices[item.id] = wantsMore ? given + 1 : .max
                if preparationSlices.count > 256 {
                    // Items long gone, which no mount or change ever cleared.
                    let indexByID = indexByID
                    preparationSlices = preparationSlices.filter { indexByID[$0.key] != nil }
                }
            case let .mount(index):
                let identifier = items[index].id
                ensureRowView(at: index)
                // Laid out here rather than left to the commit, so what the
                // row costs is spent, and counted, inside this step.
                settleNewlyPlacedRows()
                if visibleRows[identifier] == nil {
                    // Nothing mounted it. Asked again later rather than at
                    // once, or the pass would spin on it.
                    preparationChangedAt[identifier] = CACurrentMediaTime()
                } else {
                    mountedAny = true
                    preparedRowCount &+= 1
                }
            }
            now = CACurrentMediaTime()
            outlook = preparationOutlook(now: now)
            if now >= deadline { break }
        }

        if measuredAny {
            // Rows already mounted past the measured one have moved.
            contentSize = supposedContentSize
            requestLayout()
        } else if mountedAny, rowAnimator != nil {
            // A row mounted now takes the displacement its neighbours carry.
            requestLayout()
        }

        if outlook.step != nil {
            if isTravelling(now: now) {
                // The next layout pass queues the next step. This is for the
                // scroll that stops with rows still owed.
                wakePreparation(after: Self.preparationTravelWindow)
            } else {
                schedulePreparation()
            }
        } else if let delay = outlook.retryAfter {
            wakePreparation(after: delay)
        }
    }

    /// The row a pass would take a step nearer next: the nearest one past the
    /// mounted area that is not mounted, on the side the list is heading for
    /// first.
    private final func preparationOutlook(now: CFTimeInterval) -> Outlook {
        var outlook = Outlook()
        guard isPreparing else {
            if isPreparationEnabled, isWidthChanging(now: now) {
                outlook.retry(after: Self.preparationWidthHoldOff)
            }
            return outlook
        }
        // Rows are sliding: an apply, a remeasure, or a host's animation
        // around a pass. A row mounted now would stand at its place at once
        // beside rows still on their way, and its step would land in the
        // frames of that animation.
        if let lastRelease = heldRows.values.max(), lastRelease > now {
            outlook.retry(after: lastRelease - now)
            return outlook
        }
        let mounted = mountRect
        var target = preparationRect
        let travelling = isTravelling(now: now)
        if travelling {
            // A step taken while the list travels lands between two frames
            // of the scroll, and a row far ahead costs as long there as it
            // would in view. Only the rows about to come into view are
            // worth that; the rest of the range is for when the list stops,
            // which is when a reader does, between one scroll and the next.
            let band = bounds.height * Self.preparationTravelBand
            let near = CGRect(
                x: target.minX, y: mounted.minY - band, width: target.width, height: mounted.height + band * 2
            )
            if !near.contains(target) {
                target = target.intersection(near)
                outlook.retry(after: Self.preparationTravelWindow)
            }
        }

        func nearest(in indices: some Sequence<Int>) -> Int? {
            for index in indices {
                let item = items[index]
                if visibleRows[item.id] != nil { continue }
                if let changedAt = preparationChangedAt[item.id] {
                    let wait = Self.preparationQuietPeriod - (now - changedAt)
                    if wait > 0 {
                        outlook.retry(after: wait)
                        continue
                    }
                }
                // Last, because it runs the caller's conditions.
                if registrationIndex(for: item) == nil { continue }
                return index
            }
            return nil
        }

        let below = target.maxY > mounted.maxY
            ? nearest(in: rowLayout.indices(intersecting: CGRect(
                x: 0, y: mounted.maxY, width: 1, height: target.maxY - mounted.maxY
            )))
            : nil
        let above = target.minY < mounted.minY
            ? nearest(in: rowLayout.indices(intersecting: CGRect(
                x: 0, y: target.minY, width: 1, height: mounted.minY - target.minY
            )).reversed())
            : nil

        let chosen: Int?
        switch (below, above) {
        case (nil, nil):
            chosen = nil
        case let (below?, above?) where preparationHeading == 0:
            // No travel seen yet: whichever is nearer.
            let distanceBelow = (rowLayout.frame(for: below)?.minY ?? mounted.maxY) - mounted.maxY
            let distanceAbove = mounted.minY - (rowLayout.frame(for: above)?.maxY ?? mounted.minY)
            chosen = distanceBelow <= distanceAbove ? below : above
        default:
            let ahead = preparationHeading < 0 ? above : below
            let behind = preparationHeading < 0 ? below : above
            if let ahead {
                chosen = ahead
            } else if travelling, preparationHeading != 0 {
                // The side being left can wait for the scroll to end.
                chosen = nil
                outlook.retry(after: Self.preparationTravelWindow)
            } else {
                chosen = behind
            }
        }
        if let chosen {
            if rowLayout.isPending(at: chosen) {
                outlook.step = .measure(chosen)
            } else if let registrationIndex = registrationOwedASlice(at: chosen) {
                outlook.step = .slice(chosen, registration: registrationIndex)
            } else {
                outlook.step = .mount(chosen)
            }
        }
        return outlook
    }
}
