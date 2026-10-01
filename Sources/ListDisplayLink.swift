//
//  ListDisplayLink.swift
//  ListViewKit
//

import DisplayLink
import Foundation

extension DisplayLinkFrameRateRange {
    /// The rate every display link the list runs asks for.
    ///
    /// Stated once so the scrolling link and the row animator's link cannot
    /// drift apart. Links that ask for the same rate on the same display share
    /// one system link, so a programmatic scroll under a row animator costs one
    /// link rather than two, and the two are called in a fixed order.
    ///
    /// Minimum 60, not 80: a 60 Hz display cannot satisfy an 80 floor, and the
    /// range should always contain a rate the hardware has.
    static let list = DisplayLinkFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
}

/// Measures how much time each frame of a display link covers.
///
/// `duration` is the display's nominal period, not the time that passed: on
/// UIKit it is quoted at the fastest rate the display has, so a link the
/// system runs slower, or a frame the main thread missed, would advance an
/// animation by less than elapsed and slow it down in wall time. The gap
/// between timestamps is what actually passed. The nominal period stands in
/// only for the first frame, which has nothing to measure from, and for a
/// timestamp that did not move forward.
struct DisplayLinkClock {
    private var lastTimestamp: TimeInterval?

    mutating func elapsed(at frame: DisplayLinkFrame) -> TimeInterval {
        defer { lastTimestamp = frame.timestamp }
        if let lastTimestamp {
            let gap = frame.timestamp - lastTimestamp
            if gap.isFinite, gap > 0 { return gap }
        }
        return frame.duration.isFinite ? max(0, frame.duration) : 0
    }
}
