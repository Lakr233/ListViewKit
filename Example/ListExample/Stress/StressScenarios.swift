//
//  StressScenarios.swift
//  ListExample
//
//  Each scenario pushes one path of the list as hard as a real app plausibly
//  would, from a fixed random seed so a baseline and a change are measured on
//  the same work.
//

import ListViewKit
import UIKit

struct StressItem: Identifiable, Hashable {
    let id: Int
    var text: String
    /// Kept beside the text so a height costs arithmetic, not text layout:
    /// these scenarios measure the list, not the host's measuring.
    var lines: Int

    init(id: Int, text: String) {
        self.id = id
        self.text = text
        lines = text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    private static let words = [
        "list", "row", "frame", "layout", "scroll", "diff", "apply", "reuse",
        "measure", "slice", "spring", "anchor", "offset", "height", "update",
    ]

    /// Up to 30 characters a line, so no line wraps at phone width.
    static func make(id: Int, using rng: inout SplitMix64) -> StressItem {
        let lineCount = Int.random(in: 1 ... 4, using: &rng)
        let lines = (0 ..< lineCount).map { line in
            let words = (0 ..< 3).map { _ in Self.words.randomElement(using: &rng)! }
            return (line == 0 ? "#\(id) " : "") + words.joined(separator: " ")
        }
        return StressItem(id: id, text: lines.joined(separator: "\n"))
    }

    /// One streamed word, starting a new line once this one is full.
    mutating func appendWord(using rng: inout SplitMix64) {
        let word = Self.words.randomElement(using: &rng)!
        let currentLine = text.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        if currentLine.count + word.count + 1 > 30 {
            text += "\n" + word
            lines += 1
        } else {
            text += (currentLine.isEmpty ? "" : " ") + word
        }
    }
}

/// A deterministic generator, so every run of a scenario does the same work.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// What a scenario sees on every frame.
@MainActor
final class StressContext {
    let list: ListView<StressItem>
    let host: UIViewController
    var rng = SplitMix64(seed: 0x4C56_4B21)
    private(set) var nextID = 0
    /// Main-thread time of each timed operation, layout included.
    private(set) var operations: [CFTimeInterval] = []

    init(list: ListView<StressItem>, host: UIViewController) {
        self.list = list
        self.host = host
    }

    func makeItems(_ count: Int) -> [StressItem] {
        (0 ..< count).map { _ in makeItem() }
    }

    func makeItem() -> StressItem {
        defer { nextID += 1 }
        return StressItem.make(id: nextID, using: &rng)
    }

    /// Runs `body` and the layout it causes, and records how long both took.
    func time(_ body: () -> Void) {
        let state = StressLog.signposter.beginInterval("operation")
        let start = CACurrentMediaTime()
        body()
        list.layoutIfNeeded()
        operations.append(CACurrentMediaTime() - start)
        StressLog.signposter.endInterval("operation", state)
    }

    /// Settles a list loaded during `prepare`, outside any measurement.
    func load(_ items: [StressItem], atBottom: Bool = false) {
        list.apply(items)
        list.layoutIfNeeded()
        if atBottom {
            list.scrollToBottom(animated: false)
            list.layoutIfNeeded()
        }
    }
}

@MainActor
protocol StressRun: AnyObject {
    /// Untimed setup, before the first measured frame.
    func prepare(_ context: StressContext)
    /// Called once a frame with the seconds since the first one.
    func tick(_ context: StressContext, frame: Int, elapsed: CFTimeInterval)
}

@MainActor
struct StressScenario {
    let name: String
    let summary: String
    let duration: CFTimeInterval
    let make: () -> any StressRun

    static let all: [StressScenario] = [
        StressScenario(
            name: "load",
            summary: "Apply 100k rows at once, then let the measuring drain run",
            duration: 4,
            make: { LoadRun(count: 100_000) }
        ),
        StressScenario(
            name: "sweep",
            summary: "Scroll 100k unmeasured rows at 6,000 pt/s",
            duration: 5,
            make: { SweepRun(count: 100_000, speed: 6000) }
        ),
        StressScenario(
            name: "jump",
            summary: "Animated scrolls to random rows in 100k, every half second",
            duration: 6,
            make: { JumpRun(count: 100_000) }
        ),
        StressScenario(
            name: "stream",
            summary: "Stream two words a frame into the last of 2k rows, following it",
            duration: 6,
            make: { StreamRun(count: 2000) }
        ),
        StressScenario(
            name: "flood",
            summary: "Append five rows a frame to 2k, following the tail",
            duration: 5,
            make: { FloodRun(count: 2000, perFrame: 5) }
        ),
        StressScenario(
            name: "prepend",
            summary: "Load 50 earlier rows above 20k every half second, as a chat's history does",
            duration: 6,
            make: { PrependRun(count: 20000, perPage: 50) }
        ),
        StressScenario(
            name: "churn",
            summary: "Animated apply of random edits to 2k rows every 6 frames, while scrolling",
            duration: 6,
            make: { ChurnRun(count: 2000) }
        ),
        StressScenario(
            name: "shuffle",
            summary: "Animated shuffle of 300 rows every 15 frames",
            duration: 6,
            make: { ShuffleRun(count: 300) }
        ),
        StressScenario(
            name: "resize",
            summary: "Keyboard-style viewport resizes on 2k rows at the bottom",
            duration: 6,
            make: { ResizeRun(count: 2000) }
        ),
    ]
}

// MARK: - Runs

private final class LoadRun: StressRun {
    let count: Int
    var items: [StressItem] = []

    init(count: Int) {
        self.count = count
    }

    func prepare(_ context: StressContext) {
        items = context.makeItems(count)
    }

    func tick(_ context: StressContext, frame: Int, elapsed _: CFTimeInterval) {
        guard frame == 0 else { return }
        context.time { context.list.apply(items) }
    }
}

private final class SweepRun: StressRun {
    let count: Int
    let speed: CGFloat
    var direction: CGFloat = 1
    var last: CFTimeInterval = 0

    init(count: Int, speed: CGFloat) {
        self.count = count
        self.speed = speed
    }

    func prepare(_ context: StressContext) {
        context.load(context.makeItems(count))
    }

    func tick(_ context: StressContext, frame _: Int, elapsed: CFTimeInterval) {
        let list = context.list
        let step = speed * CGFloat(elapsed - last) * direction
        last = elapsed
        context.time {
            var y = list.contentOffset.y + step
            if y >= list.maximumContentOffset.y {
                y = list.maximumContentOffset.y
                direction = -1
            } else if y <= list.minimumContentOffset.y {
                y = list.minimumContentOffset.y
                direction = 1
            }
            list.contentOffset.y = y
        }
    }
}

private final class JumpRun: StressRun {
    let count: Int

    init(count: Int) {
        self.count = count
    }

    func prepare(_ context: StressContext) {
        context.load(context.makeItems(count))
    }

    func tick(_ context: StressContext, frame: Int, elapsed _: CFTimeInterval) {
        guard frame.isMultiple(of: 30) else { return }
        let index = Int.random(in: 0 ..< count, using: &context.rng)
        context.time { context.list.scrollToRow(at: index, at: .middle, animated: true) }
    }
}

private final class StreamRun: StressRun {
    let count: Int
    var item: StressItem?

    init(count: Int) {
        self.count = count
    }

    func prepare(_ context: StressContext) {
        var items = context.makeItems(count)
        let streamed = StressItem(id: context.makeItem().id, text: "")
        items.append(streamed)
        item = streamed
        context.load(items, atBottom: true)
    }

    func tick(_ context: StressContext, frame _: Int, elapsed _: CFTimeInterval) {
        guard var item else { return }
        item.appendWord(using: &context.rng)
        item.appendWord(using: &context.rng)
        self.item = item
        let list = context.list
        context.time {
            list.update(item)
            if !list.isUserInteractingWithScroll {
                list.scrollToBottom(animated: false)
            }
        }
    }
}

private final class FloodRun: StressRun {
    let count: Int
    let perFrame: Int

    init(count: Int, perFrame: Int) {
        self.count = count
        self.perFrame = perFrame
    }

    func prepare(_ context: StressContext) {
        context.load(context.makeItems(count), atBottom: true)
    }

    func tick(_ context: StressContext, frame _: Int, elapsed _: CFTimeInterval) {
        let items = context.makeItems(perFrame)
        let list = context.list
        context.time {
            list.append(contentsOf: items)
            list.scrollToBottom(animated: false)
        }
    }
}

private final class PrependRun: StressRun {
    let count: Int
    let perPage: Int

    init(count: Int, perPage: Int) {
        self.count = count
        self.perPage = perPage
    }

    func prepare(_ context: StressContext) {
        context.load(context.makeItems(count), atBottom: true)
    }

    func tick(_ context: StressContext, frame: Int, elapsed _: CFTimeInterval) {
        guard frame.isMultiple(of: 30) else { return }
        let items = context.makeItems(perPage) + context.list.content
        context.time { context.list.apply(items) }
    }
}

private final class ChurnRun: StressRun {
    let count: Int
    var last: CFTimeInterval = 0

    init(count: Int) {
        self.count = count
    }

    func prepare(_ context: StressContext) {
        context.load(context.makeItems(count))
        context.list.contentOffset.y = context.list.maximumContentOffset.y / 2
    }

    func tick(_ context: StressContext, frame: Int, elapsed: CFTimeInterval) {
        let list = context.list
        // A slow drift, so edits land on rows entering and leaving the screen.
        let drift = 300 * CGFloat(elapsed - last)
        last = elapsed
        guard frame.isMultiple(of: 6) else {
            context.time { list.contentOffset.y = min(list.maximumContentOffset.y, list.contentOffset.y + drift) }
            return
        }
        var items = list.content
        for _ in 0 ..< 20 where !items.isEmpty {
            items.remove(at: Int.random(in: 0 ..< items.count, using: &context.rng))
        }
        for _ in 0 ..< 20 {
            items.insert(context.makeItem(), at: Int.random(in: 0 ... items.count, using: &context.rng))
        }
        for _ in 0 ..< 10 {
            let moved = items.remove(at: Int.random(in: 0 ..< items.count, using: &context.rng))
            items.insert(moved, at: Int.random(in: 0 ... items.count, using: &context.rng))
        }
        context.time {
            list.contentOffset.y = min(list.maximumContentOffset.y, list.contentOffset.y + drift)
            list.apply(items, animated: true)
        }
    }
}

private final class ShuffleRun: StressRun {
    let count: Int

    init(count: Int) {
        self.count = count
    }

    func prepare(_ context: StressContext) {
        context.load(context.makeItems(count))
    }

    func tick(_ context: StressContext, frame: Int, elapsed _: CFTimeInterval) {
        guard frame.isMultiple(of: 15) else { return }
        let items = context.list.content.shuffled(using: &context.rng)
        context.time { context.list.apply(items, animated: true) }
    }
}

private final class ResizeRun: StressRun {
    let count: Int

    init(count: Int) {
        self.count = count
    }

    func prepare(_ context: StressContext) {
        context.load(context.makeItems(count), atBottom: true)
    }

    func tick(_ context: StressContext, frame: Int, elapsed _: CFTimeInterval) {
        guard frame.isMultiple(of: 30) else { return }
        let host = context.host
        let opening = host.additionalSafeAreaInsets.bottom == 0
        context.time {
            // The keyboard's own curve and duration.
            UIView.animate(withDuration: 0.35, delay: 0, options: UIView.AnimationOptions(rawValue: 7 << 16)) {
                host.additionalSafeAreaInsets.bottom = opening ? 336 : 0
                host.view.layoutIfNeeded()
            }
        }
    }
}
