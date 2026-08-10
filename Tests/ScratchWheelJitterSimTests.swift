//
//  ScratchWheelJitterSimTests.swift
//  Temporary diagnostic — drives ListScrollSpring exactly the way the view
//  layer does for wheel input and looks for visible reversals.
//

@testable import ListViewKit
import Testing
import Foundation

@MainActor
struct ScratchWheelJitterSim {
    /// One display frame at 120Hz.
    static let dt: TimeInterval = 1.0 / 120.0

    /// Simulates the view's drive: event layout passes feed travel with
    /// deltaTime 0, display ticks relax with deltaTime dt. Returns per-frame
    /// visible motion samples of rows sitting far above the grip.
    static func run(
        eventEveryNFrames: Int,
        deltaPerEvent: CGFloat,
        frames: Int,
        interactingAtConsume: Bool = true,
        label: String
    ) {
        var spring = ListScrollSpring()
        let rowPitch: CGFloat = 44
        let viewportH: CGFloat = 900
        let gripViewportY: CGFloat = 650
        var offset: CGFloat = 5000

        func context(delta: CGFloat, dt: TimeInterval) -> ListAnimatorContext {
            .init(
                viewportRect: .init(x: 0, y: offset, width: 800, height: viewportH),
                contentRect: .init(x: 0, y: 0, width: 800, height: 100_000),
                interactionAnchorY: offset + gripViewportY,
                scrollDelta: delta,
                deltaTime: dt,
                isUserInteracting: interactingAtConsume
            )
        }

        // visible = (rowCenter - offset) + followed displacement
        func visible(_ row: Int) -> CGFloat {
            let center = CGFloat(row) * rowPitch
            return center - offset + spring.followedDisplacement(forRowCenteredAt: center, key: row)
        }

        var reversals: [(frame: Int, amount: CGFloat)] = []
        var maxReversal: CGFloat = 0
        var prevSample: (row: Int, y: CGFloat)? = nil

        for f in 0 ..< frames {
            if f % eventEveryNFrames == 0 {
                // Event: offset moves, layout consumes the travel with dt 0.
                offset += deltaPerEvent
                spring.willUpdate(context(delta: deltaPerEvent, dt: 0))
                // Layout also re-lands every mounted row.
                let first = Int((offset / rowPitch).rounded(.down))
                for r in first ..< first + Int(viewportH / rowPitch) { _ = visible(r) }
            }
            // Display tick: relax, no new travel.
            spring.willUpdate(context(delta: 0, dt: dt))

            // Track the row currently nearest 100pt from the viewport top —
            // far side of the falloff, where the video measured the jitter.
            let trackedRow = Int(((offset + 100) / rowPitch).rounded())
            let y = visible(trackedRow)
            if let prev = prevSample, prev.row == trackedRow {
                let motion = y - prev.y
                // Scroll direction: content moves toward -y when offset grows.
                let expected: CGFloat = deltaPerEvent > 0 ? -1 : 1
                if motion * expected < -0.5 {
                    reversals.append((f, motion))
                    maxReversal = max(maxReversal, abs(motion))
                }
            }
            prevSample = (trackedRow, y)
        }
        print("SIM[\(label)] stretch=\(spring.stretch) reversals=\(reversals.count) maxReversal=\(maxReversal)")
        for r in reversals.prefix(12) { print("   frame \(r.frame): \(r.amount)") }
    }

    @Test
    func wheelDrivePatterns() {
        Self.run(eventEveryNFrames: 1, deltaPerEvent: 15, frames: 240, label: "A: every frame 15px")
        Self.run(eventEveryNFrames: 2, deltaPerEvent: 30, frames: 240, label: "B: every 2nd frame 30px")
        Self.run(eventEveryNFrames: 3, deltaPerEvent: 45, frames: 240, label: "C: every 3rd frame 45px")
        Self.run(eventEveryNFrames: 5, deltaPerEvent: 40, frames: 300, label: "D: every 5th frame 40px")
        Self.run(eventEveryNFrames: 8, deltaPerEvent: 30, frames: 400, label: "E: notchy 8 frames apart")
    }
}
