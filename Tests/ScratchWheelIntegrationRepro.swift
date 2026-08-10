//
//  ScratchWheelIntegrationRepro.swift
//  Temporary diagnostic — drives the real AppKit ListView with synthetic
//  wheel event streams and watches for single-frame visible reversals.
//

#if canImport(AppKit) && !canImport(UIKit)
import AppKit
import Testing
import MSDisplayLink
@testable import ListViewKit

private struct ReproItem: Identifiable, Hashable { let id: Int }

@Suite(.serialized)
@MainActor
struct ScratchWheelIntegrationRepro {
    static let frameDT: TimeInterval = 1.0 / 120.0
    static let frameNS: UInt64 = 8_333_333

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

    private func makeListView() -> ListView<ReproItem> {
        let listView = ListView<ReproItem>(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        listView.rows {
            ListRow(ListRowView.self)
                .height { _, _ in 100 }
                .configure { _, _, _ in }
        }
        listView.apply((0 ..< 100).map { ReproItem(id: $0) })
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

    /// Visible screen position of the row nearest `screenY`, plus its id.
    private func sample(_ listView: ListView<ReproItem>, near screenY: CGFloat) -> (id: Int, y: CGFloat)? {
        var best: (id: Int, y: CGFloat)?
        for (identifier, entry) in listView.visibleRows {
            let y = entry.view.placedFrame.minY - listView.contentOffset.y + entry.view.presentationOffset
            if best == nil || abs(y - screenY) < abs(best!.y - screenY) {
                best = (identifier.hashValue, y)
            }
        }
        return best
    }

    private func runFrames(
        _ listView: ListView<ReproItem>,
        frames: Int,
        label: String,
        direction: CGFloat,
        eventsForFrame: (Int, CGEventTimestamp) throws -> [NSEvent]
    ) throws {
        var t: CGEventTimestamp = 1_000_000_000
        var prev: (id: Int, y: CGFloat)?
        var reversals: [(Int, CGFloat)] = []
        var offsets: [CGFloat] = []
        for f in 0 ..< frames {
            t += Self.frameNS
            for event in try eventsForFrame(f, t) {
                listView.scrollWheel(with: event)
            }
            // scrolling animation link (momentum / rubber band), if alive
            listView.synchronization(context: .init(
                duration: Self.frameDT,
                timestamp: Double(t) / 1e9,
                targetTimestamp: Double(t) / 1e9 + Self.frameDT
            ))
            listView.layoutSubtreeIfNeeded()
            listView.tickRowAnimator(duration: Self.frameDT)
            offsets.append(listView.contentOffset.y)
            if let s = sample(listView, near: 60) {
                if let p = prev, p.id == s.id {
                    let motion = s.y - p.y
                    // scrolling down (offset grows): rows move up (negative).
                    if motion * direction < -1.0 {
                        reversals.append((f, motion))
                    }
                }
                prev = s
            }
        }
        // offset backward steps
        var offsetReversals = 0
        var maxOffsetBack: CGFloat = 0
        for i in 1 ..< offsets.count {
            let d = offsets[i] - offsets[i - 1]
            if d * direction < -0.5 { offsetReversals += 1; maxOffsetBack = max(maxOffsetBack, abs(d)) }
        }
        print("REPRO[\(label)] rowReversals=\(reversals.count) maxRow=\(reversals.map { abs($0.1) }.max() ?? 0) offsetBackSteps=\(offsetReversals) maxOffsetBack=\(maxOffsetBack)")
        for r in reversals.prefix(10) { print("   frame \(r.0): \(r.1)") }
    }

    @Test
    func discreteWheelNotches() throws {
        let listView = makeListView()
        // one notch (3 lines = 30px) every 3rd frame
        try runFrames(listView, frames: 240, label: "discrete every 3", direction: 1) { f, t in
            f % 3 == 0 ? [try makeWheelEvent(lineDeltaY: -3, timestamp: t)] : []
        }
    }

    @Test
    func discreteWheelSlowNotches() throws {
        let listView = makeListView()
        try runFrames(listView, frames: 400, label: "discrete every 8", direction: 1) { f, t in
            f % 8 == 0 ? [try makeWheelEvent(lineDeltaY: -3, timestamp: t)] : []
        }
    }

    @Test
    func magicMouseRepeatedFlicks() throws {
        let listView = makeListView()
        // Three flicks: 12 frames of touch (began + changed), lift, 20 frames
        // of coasting, next flick starts during the coast.
        var script: [Int: [(Double?, CGScrollPhase?, CGScrollPhase?)]] = [:]
        var frame = 0
        for _ in 0 ..< 4 {
            script[frame] = [(-10, .began, nil)]
            for i in 1 ..< 12 { script[frame + i] = [(-25, .changed, nil)] }
            script[frame + 12] = [(0, .ended, nil)]
            frame += 32 // lift + coast, next flick interrupts the coast
        }
        try runFrames(listView, frames: frame + 60, label: "flicks", direction: 1) { f, t in
            try (script[f] ?? []).map { spec in
                try self.makeWheelEvent(
                    pixelDeltaY: spec.0,
                    phase: spec.1,
                    momentumPhase: spec.2,
                    timestamp: t
                )
            }
        }
    }

    @Test
    func continuousDragWithEventJitter() throws {
        let listView = makeListView()
        // 90Hz-ish events against 120Hz frames: some frames get 0 events, some 2.
        var script: [Int: [Double]] = [:]
        var acc = 0.0
        for f in 0 ..< 240 {
            acc += 0.75
            var deltas: [Double] = []
            while acc >= 1 { deltas.append(-20); acc -= 1 }
            script[f] = deltas
        }
        try runFrames(listView, frames: 240, label: "90Hz drag", direction: 1) { f, t in
            var events: [NSEvent] = []
            for (i, d) in (script[f] ?? []).enumerated() {
                let phase: CGScrollPhase = (f == 0 && i == 0) ? .began : .changed
                events.append(try self.makeWheelEvent(pixelDeltaY: d, phase: phase, timestamp: t))
            }
            return events
        }
    }
}
#endif
