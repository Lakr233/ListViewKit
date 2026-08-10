//
//  ListViewWheelInputAppKitTests.swift
//  ListViewKit
//

#if canImport(UIKit)
// UIKit platforms (including Mac Catalyst) are exercised by the UIKit suites.
#elseif canImport(AppKit)
import AppKit
import MSDisplayLink
import Testing
@testable import ListViewKit

private struct WheelItem: Identifiable, Hashable { let id: Int }

/// Drives the real AppKit list with synthetic wheel event streams, the way a
/// mouse or trackpad delivers them, and asserts the one property every stream
/// has to keep: a row on screen never visibly moves against the scroll.
///
/// This is the harness that reproduced the wheel-scroll jitter from the
/// 2026-08-10 screen recording — single-frame ~30pt excursions against the
/// travel — before the pump gain, follower, and attack-envelope fixes landed.
/// Each scenario here read tens of reversals then; the suite pins them at
/// zero. The discrete-wheel scenarios additionally pin that phase-less
/// events engage the effect at all, which is what
/// ``ListScrollView/wheelInteractionWindow`` exists for: with no gesture
/// phases there is no lift to end a grip, so between notches the hand is a
/// debounce, not a flag.
@Suite(.serialized)
@MainActor
struct ListViewWheelInputAppKitTests {
    private static let frameDT: TimeInterval = 1.0 / 120.0
    private static let frameNS: UInt64 = 8_333_333

    private func makeWheelEvent(
        pixelDeltaY: Double? = nil,
        lineDeltaY: Int32? = nil,
        phase: CGScrollPhase? = nil,
        momentumPhase: CGScrollPhase? = nil,
        timestamp: CGEventTimestamp
    ) throws -> NSEvent {
        let cgEvent: CGEvent
        if let pixelDeltaY {
            cgEvent = try #require(CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 1,
                wheel1: Int32(pixelDeltaY),
                wheel2: 0,
                wheel3: 0
            ))
            cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        } else {
            cgEvent = try #require(CGEvent(
                scrollWheelEvent2Source: nil,
                units: .line,
                wheelCount: 1,
                wheel1: lineDeltaY ?? 0,
                wheel2: 0,
                wheel3: 0
            ))
        }
        cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
        cgEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentumPhase?.rawValue ?? 0))
        cgEvent.timestamp = timestamp
        return try #require(NSEvent(cgEvent: cgEvent))
    }

    private func makeListView() -> ListView<WheelItem> {
        let listView = ListView<WheelItem>(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        listView.rows {
            ListRow(ListRowView.self)
                .height { _, _ in 100 }
                .configure { _, _, _ in }
        }
        listView.apply((0 ..< 100).map { WheelItem(id: $0) })
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()
        for _ in 0 ..< 300 where listView.rowLayout.hasPendingRows {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()
        listView.rowAnimator = ListScrollSpring()
        listView.contentOffset = .init(x: 0, y: 3000)
        listView.layoutSubtreeIfNeeded()
        return listView
    }

    private struct StreamReading {
        /// Single-frame visible motions against the scroll, by frame index.
        var reversals: [(frame: Int, motion: CGFloat)] = []
        /// Offset steps against the scroll.
        var offsetBackSteps = 0
        /// The deepest any row was displaced from its placement.
        var maxDisplacement: CGFloat = 0
    }

    /// Runs `frames` frames of the event-per-turn, layout, then animator-tick
    /// cadence the real run loop produces, watching the row nearest the top
    /// of the viewport — the far side of the falloff, where the recording
    /// measured the jitter.
    private func runStream(
        _ listView: ListView<WheelItem>,
        frames: Int,
        direction: CGFloat,
        skipTick: ((Int) -> Bool)? = nil,
        eventsForFrame: (Int, CGEventTimestamp) throws -> [NSEvent]
    ) throws -> StreamReading {
        var t: CGEventTimestamp = 1_000_000_000
        var prev: (id: Int, y: CGFloat)?
        var previousOffset = listView.contentOffset.y
        var reading = StreamReading()
        for f in 0 ..< frames {
            t += Self.frameNS
            for event in try eventsForFrame(f, t) {
                listView.scrollWheel(with: event)
            }
            // The scrolling animation link (momentum / rubber band), if alive.
            listView.synchronization(context: .init(
                duration: Self.frameDT,
                timestamp: Double(t) / 1e9,
                targetTimestamp: Double(t) / 1e9 + Self.frameDT
            ))
            listView.layoutSubtreeIfNeeded()
            if skipTick?(f) != true {
                listView.tickRowAnimator(duration: Self.frameDT)
            }

            let offset = listView.contentOffset.y
            if (offset - previousOffset) * direction < -0.5 {
                reading.offsetBackSteps += 1
            }
            previousOffset = offset

            var sample: (id: Int, y: CGFloat)?
            for (identifier, entry) in listView.visibleRows {
                reading.maxDisplacement = max(
                    reading.maxDisplacement,
                    abs(entry.view.presentationOffset)
                )
                let y = entry.view.placedFrame.minY - offset + entry.view.presentationOffset
                if sample == nil || abs(y - 60) < abs(sample!.y - 60) {
                    sample = (identifier.hashValue, y)
                }
            }
            if let sample {
                // Scrolling down moves rows up; a frame where the same row
                // moves the other way is the jitter the recording measured.
                if let prev, prev.id == sample.id, (sample.y - prev.y) * direction > 1.0 {
                    reading.reversals.append((f, sample.y - prev.y))
                }
                prev = sample
            }
        }
        return reading
    }

    // MARK: - Discrete wheels

    /// A notch every few frames is a hand on the content, so the field
    /// engages — and chunky 30pt notches still never move a row backward.
    @Test
    func discreteNotchesEngageTheSpreadWithoutReversals() throws {
        let listView = makeListView()
        let reading = try runStream(listView, frames: 240, direction: 1) { f, t in
            f % 3 == 0 ? [try makeWheelEvent(lineDeltaY: -3, timestamp: t)] : []
        }
        #expect(reading.reversals.isEmpty)
        #expect(reading.offsetBackSteps == 0)
        #expect(reading.maxDisplacement > 5, "phase-less wheel input engages the effect")
    }

    /// A wheel read deliberately, one notch at a time, leaves gaps the
    /// interaction window has to bridge: the spread must neither collapse
    /// between notches nor snap on the next one.
    @Test
    func slowNotchesRideTheInteractionWindow() throws {
        let listView = makeListView()
        let reading = try runStream(listView, frames: 400, direction: 1) { f, t in
            f % 8 == 0 ? [try makeWheelEvent(lineDeltaY: -3, timestamp: t)] : []
        }
        #expect(reading.reversals.isEmpty)
        #expect(reading.offsetBackSteps == 0)
        #expect(reading.maxDisplacement > 5)
    }

    /// The window is a debounce, not a latch: once it expires the hand is
    /// gone. Pinned through the state rather than a real-time sleep.
    @Test
    func theInteractionWindowExpires() throws {
        let listView = makeListView()
        var t: CGEventTimestamp = 1_000_000_000
        t += Self.frameNS
        listView.scrollWheel(with: try makeWheelEvent(lineDeltaY: -3, timestamp: t))
        #expect(listView.isReaderHoldingScroll)
        listView._lastDiscreteWheelUptime =
            ProcessInfo.processInfo.systemUptime - ListScrollView.wheelInteractionWindow - 0.01
        #expect(!listView.isReaderHoldingScroll)
    }

    // MARK: - Gesture streams

    /// Repeated Magic Mouse-style flicks, each interrupting the previous
    /// coast: the catch is where the recording jittered.
    @Test
    func repeatedFlicksNeverMoveARowBackward() throws {
        let listView = makeListView()
        var script: [Int: [(Double, CGScrollPhase)]] = [:]
        var frame = 0
        for _ in 0 ..< 4 {
            script[frame] = [(-10, .began)]
            for i in 1 ..< 12 { script[frame + i] = [(-25, .changed)] }
            script[frame + 12] = [(0, .ended)]
            frame += 32
        }
        let reading = try runStream(listView, frames: frame + 60, direction: 1) { f, t in
            try (script[f] ?? []).map {
                try self.makeWheelEvent(pixelDeltaY: $0.0, phase: $0.1, timestamp: t)
            }
        }
        #expect(reading.reversals.isEmpty)
        #expect(reading.offsetBackSteps == 0)
        #expect(reading.maxDisplacement > 5)
    }

    /// Event delivery off the frame rate — 90Hz events on 120Hz frames — so
    /// some frames see two deltas and some see none.
    @Test
    func offRateEventDeliveryStaysSmooth() throws {
        let listView = makeListView()
        var acc = 0.0
        let reading = try runStream(listView, frames: 240, direction: 1) { f, t in
            acc += 0.75
            var events: [NSEvent] = []
            while acc >= 1 {
                let phase: CGScrollPhase = (f == 0 && events.isEmpty) ? .began : .changed
                events.append(try self.makeWheelEvent(pixelDeltaY: -20, phase: phase, timestamp: t))
                acc -= 1
            }
            return events
        }
        #expect(reading.reversals.isEmpty)
        #expect(reading.offsetBackSteps == 0)
    }

    /// A stalled main thread queues events and misses animator ticks; the
    /// burst that lands afterwards must integrate as one frame of travel,
    /// not as a jolt.
    @Test
    func eventBurstsAfterAStallStaySmooth() throws {
        let listView = makeListView()
        let reading = try runStream(
            listView,
            frames: 240,
            direction: 1,
            skipTick: { f in f % 20 == 19 || f % 20 == 0 }
        ) { f, t in
            let phase: CGScrollPhase = f == 0 ? .began : .changed
            if f % 20 == 19 { return [] } // stalled: the event queues
            if f % 20 == 0, f > 0 {
                return [
                    try self.makeWheelEvent(pixelDeltaY: -20, phase: .changed, timestamp: t - Self.frameNS),
                    try self.makeWheelEvent(pixelDeltaY: -20, phase: .changed, timestamp: t),
                    try self.makeWheelEvent(pixelDeltaY: -20, phase: .changed, timestamp: t),
                ]
            }
            return [try self.makeWheelEvent(pixelDeltaY: -20, phase: phase, timestamp: t)]
        }
        #expect(reading.reversals.isEmpty)
        #expect(reading.offsetBackSteps == 0)
    }
}
#endif
