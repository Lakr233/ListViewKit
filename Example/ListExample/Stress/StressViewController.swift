//
//  StressViewController.swift
//  ListExample
//
//  Runs stress scenarios one after another, each on a fresh list, and reports
//  frame pacing and main-thread cost for each.
//
//  Launch arguments, for unattended runs under Instruments:
//    -LVKStress all | <name>[,<name>…]   which scenarios to run
//    -LVKStressExit YES                  quit once the last one finishes
//

import ListViewKit
import os
import UIKit

@MainActor
enum StressLog {
    static let signposter = OSSignposter(subsystem: "wiki.qaq.ListExample", category: .pointsOfInterest)
    static let logger = Logger(subsystem: "wiki.qaq.ListExample", category: "stress")

    /// Scenarios named on the command line, if any.
    static var requestedScenarios: [StressScenario]? {
        guard let value = UserDefaults.standard.string(forKey: "LVKStress") else { return nil }
        if value == "all" { return StressScenario.all }
        let names = Set(value.split(separator: ",").map(String.init))
        return StressScenario.all.filter { names.contains($0.name) }
    }

    static var exitsWhenDone: Bool {
        UserDefaults.standard.bool(forKey: "LVKStressExit")
    }
}

final class StressRow: ListRowView {
    static let font = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    static let padding: CGFloat = 12

    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = Self.font
        label.numberOfLines = 0
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 16, dy: Self.padding)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        label.text = nil
    }

    static func height(lines: Int) -> CGFloat {
        ceil(CGFloat(lines) * font.lineHeight) + padding * 2
    }
}

/// Frame pacing, from a display link's own callbacks: a callback that comes
/// late is a frame the main thread was too busy to start.
struct FrameStats {
    private(set) var intervals: [CFTimeInterval] = []
    private(set) var budgets: [CFTimeInterval] = []

    mutating func record(interval: CFTimeInterval, budget: CFTimeInterval) {
        intervals.append(interval)
        budgets.append(budget)
    }

    var seconds: CFTimeInterval { intervals.reduce(0, +) }

    /// Refreshes that passed without a new frame.
    var droppedFrames: Int {
        zip(intervals, budgets).reduce(0) { $0 + max(0, Int(($1.0 / $1.1).rounded()) - 1) }
    }

    /// Milliseconds late per second, Apple's hitch time ratio. A frame counts
    /// once it is half a refresh late, which keeps scheduling jitter out.
    var hitchRatio: Double {
        guard seconds > 0 else { return 0 }
        var late: CFTimeInterval = 0
        for (interval, budget) in zip(intervals, budgets) where interval > budget * 1.5 {
            late += interval - budget
        }
        return late * 1000 / seconds
    }
}

struct StressResult {
    let name: String
    let frames: FrameStats
    let operations: [CFTimeInterval]

    private func percentile(_ p: Double) -> Double {
        guard !operations.isEmpty else { return 0 }
        let sorted = operations.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] * 1000
    }

    var line: String {
        let fps = frames.seconds > 0 ? Double(frames.intervals.count) / frames.seconds : 0
        let worst = (frames.intervals.max() ?? 0) * 1000
        return String(
            format: "%-8@ fps %5.1f  dropped %4d  hitch %6.1f ms/s  worst %6.1f ms  ops %4d  p50 %6.2f  p95 %6.2f  max %7.2f ms",
            name, fps, frames.droppedFrames, frames.hitchRatio, worst,
            operations.count, percentile(0.5), percentile(0.95), percentile(1)
        )
    }
}

final class StressViewController: UIViewController {
    private let scenarios: [StressScenario]
    private var results: [StressResult] = []
    private var list: ListView<StressItem>?
    private let report = UITextView()

    private var displayLink: CADisplayLink?
    private var run: (any StressRun)?
    private var context: StressContext?
    private var scenario: StressScenario?
    private var frames = FrameStats()
    private var frameIndex = 0
    private var startTime: CFTimeInterval = 0
    private var lastTimestamp: CFTimeInterval = 0
    private var interval: OSSignpostIntervalState?

    init(scenarios: [StressScenario]) {
        self.scenarios = scenarios
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Stress"
        edgesForExtendedLayout = []
        view.backgroundColor = .systemBackground
        report.isEditable = false
        report.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        report.isHidden = true
        view.addSubview(report)
        report.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            report.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            report.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            report.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            report.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard results.isEmpty, run == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.start(at: 0) }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        displayLink?.invalidate()
        displayLink = nil
    }

    private func makeList() -> ListView<StressItem> {
        let list = ListView<StressItem>()
        list.rowAnimator = ListBouncyAnimator()
        list.rows {
            ListRow(StressRow.self)
                .height { item, _ in StressRow.height(lines: item.lines) }
                .configure { row, item, context in
                    row.label.text = item.text
                    row.backgroundColor = context.index.isMultiple(of: 2)
                        ? .clear
                        : .systemGray.withAlphaComponent(0.025)
                }
        }
        view.addSubview(list)
        list.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: view.topAnchor),
            list.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        view.layoutIfNeeded()
        return list
    }

    private func start(at index: Int) {
        guard index < scenarios.count else { return finish() }
        let scenario = scenarios[index]
        list?.removeFromSuperview()
        additionalSafeAreaInsets = .zero
        let list = makeList()
        self.list = list
        let context = StressContext(list: list, host: self)
        let run = scenario.make()
        title = scenario.name
        run.prepare(context)

        // Let the setup's own frames pass before measuring.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            self.scenario = scenario
            self.context = context
            self.run = run
            frames = FrameStats()
            frameIndex = 0
            startTime = 0
            interval = StressLog.signposter.beginInterval("scenario", "\(scenario.name)")
            let link = CADisplayLink(target: self, selector: #selector(step(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            displayLink = link
            nextScenarioIndex = index + 1
        }
    }

    private var nextScenarioIndex = 0

    @objc private func step(_ link: CADisplayLink) {
        guard let run, let context, let scenario else { return }
        if startTime == 0 {
            startTime = link.timestamp
        } else {
            frames.record(interval: link.timestamp - lastTimestamp, budget: link.targetTimestamp - link.timestamp)
        }
        lastTimestamp = link.timestamp
        let elapsed = link.timestamp - startTime
        guard elapsed < scenario.duration else {
            return complete(scenario, context)
        }
        run.tick(context, frame: frameIndex, elapsed: elapsed)
        frameIndex += 1
    }

    private func complete(_ scenario: StressScenario, _ context: StressContext) {
        displayLink?.invalidate()
        displayLink = nil
        if let interval { StressLog.signposter.endInterval("scenario", interval) }
        let result = StressResult(name: scenario.name, frames: frames, operations: context.operations)
        results.append(result)
        print("LVKSTRESS \(result.line)")
        StressLog.logger.notice("LVKSTRESS \(result.line, privacy: .public)")
        run = nil
        self.context = nil
        self.scenario = nil
        start(at: nextScenarioIndex)
    }

    private func finish() {
        list?.removeFromSuperview()
        list = nil
        title = "Stress results"
        report.text = results.map(\.line).joined(separator: "\n\n")
        report.isHidden = false
        print("LVKSTRESS done")
        if StressLog.exitsWhenDone {
            exit(0)
        }
    }
}
