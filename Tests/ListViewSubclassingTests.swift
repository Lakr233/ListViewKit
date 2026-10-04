//
//  ListViewSubclassingTests.swift
//  ListViewKit
//

// A plain import on purpose: this file only compiles while every member it
// overrides is still `open`, so closing one again breaks the build here.
import ListViewKit
import Testing

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

private struct SubclassItem: Identifiable, Hashable {
    let id: Int
    var text: String
}

private final class SubclassRow: ListRowView {
    var text: String?
    var resetCount = 0
    var animatedBlocks = 0

    override func prepareForReuse() {
        super.prepareForReuse()
        resetCount += 1
        text = nil
    }

    override func withAnimation(_ block: @escaping () -> Void) {
        animatedBlocks += 1
        super.withAnimation(block)
    }
}

/// Counts every hook it can override, and keeps the rows it is told to retain
/// mounted however far the viewport moves away from them.
private final class RecordingList: ListView<SubclassItem> {
    var calls: [String: Int] = [:]
    var made: [ListRowView] = []
    var dequeued: [ListRowView] = []
    var enqueued: [ListRowView] = []
    var configured: [(view: ListRowView, item: SubclassItem)] = []
    var retained: Set<Int> = []
    var poolsRows = true

    /// A designated initializer of the subclass's own, which a subclass of a
    /// generic `NSView`/`UIView` subclass has to be able to declare.
    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    private func record(_ name: String = #function) {
        calls[name, default: 0] += 1
    }

    func count(_ name: String) -> Int {
        calls[name, default: 0]
    }

    override var frame: CGRect {
        get { super.frame }
        set {
            record()
            super.frame = newValue
        }
    }

    override func rows(@ListRowsBuilder<SubclassItem> _ build: () -> [ListRowRegistration<SubclassItem>]) {
        record()
        super.rows(build)
    }

    override func apply(_ newItems: [SubclassItem], animated: Bool = false) {
        record()
        super.apply(newItems, animated: animated)
    }

    override func append(contentsOf newItems: some Sequence<SubclassItem>) {
        record()
        super.append(contentsOf: newItems)
    }

    override func append(_ item: SubclassItem) {
        record()
        super.append(item)
    }

    @discardableResult
    override func update(_ item: SubclassItem) -> Bool {
        record()
        return super.update(item)
    }

    override func reloadData() {
        record()
        super.reloadData()
    }

    override func invalidateLayout() {
        record()
        super.invalidateLayout()
    }

    override func invalidateLayout(forRowWith identifier: Int) {
        record()
        super.invalidateLayout(forRowWith: identifier)
    }

    override func layoutContent() {
        record()
        super.layoutContent()
    }

    override func windowDidChange() {
        record()
        super.windowDidChange()
    }

    override func compensateScrollOffset(by dy: CGFloat) {
        record()
        super.compensateScrollOffset(by: dy)
    }

    override func mountRowView(at index: Int) {
        record()
        super.mountRowView(at: index)
    }

    override func reconfigureRow(with identifier: Int) {
        record()
        super.reconfigureRow(with: identifier)
    }

    override func configureRowView(
        _ view: ListRowView,
        with item: SubclassItem,
        at index: Int,
        registrationIndex: Int
    ) {
        configured.append((view, item))
        super.configureRowView(view, with: item, at: index, registrationIndex: registrationIndex)
    }

    override func makeRowView(forRegistrationAt registrationIndex: Int) -> ListRowView {
        let view = super.makeRowView(forRegistrationAt: registrationIndex)
        made.append(view)
        return view
    }

    override func dequeueReusableRowView(forRegistrationAt registrationIndex: Int) -> ListRowView? {
        let view = super.dequeueReusableRowView(forRegistrationAt: registrationIndex)
        if let view { dequeued.append(view) }
        return view
    }

    override func enqueueReusableRowView(_ view: ListRowView, forRegistrationAt registrationIndex: Int) {
        enqueued.append(view)
        guard poolsRows else { return }
        super.enqueueReusableRowView(view, forRegistrationAt: registrationIndex)
    }

    @discardableResult
    override func recycleRow(with identifier: Int) -> ListRowView? {
        // A row kept out of the pool while its item is retained: the seam a
        // streaming row needs to keep its view across scrolls.
        if retained.contains(identifier) { return nil }
        return super.recycleRow(with: identifier)
    }

    override func scrollToRow(at index: Int, at position: ListRowPosition, animated: Bool = true) {
        record()
        super.scrollToRow(at: index, at: position, animated: animated)
    }

    override func scrollToRow(with identifier: Int, at position: ListRowPosition, animated: Bool = true) {
        record()
        super.scrollToRow(with: identifier, at: position, animated: animated)
    }

    override func scrollToBottom(animated: Bool = true) {
        record()
        super.scrollToBottom(animated: animated)
    }

    override func scroll(to offset: CGPoint, angularFrequency: Double? = nil, preserveVelocity: Bool = true) {
        record()
        super.scroll(to: offset, angularFrequency: angularFrequency, preserveVelocity: preserveVelocity)
    }

    override func cancelCurrentScrolling() {
        record()
        super.cancelCurrentScrolling()
    }

    #if canImport(AppKit) && !canImport(UIKit)
        override func flashScrollers() {
            record()
            super.flashScrollers()
        }
    #endif
}

/// A subclass that stays generic over its item.
private final class GenericList<Element: Identifiable & Hashable & SendableMetatype>: ListView<Element> {
    var layoutPasses = 0

    override func layoutContent() {
        layoutPasses += 1
        super.layoutContent()
    }
}

/// A scroll view used on its own, without the list.
private final class PlainScrollView: ListScrollView {
    var layoutPasses = 0

    override func layoutContent() {
        layoutPasses += 1
        super.layoutContent()
    }
}

@MainActor
private func layOut(_ view: ListScrollView) {
    #if canImport(UIKit)
        view.setNeedsLayout()
        view.layoutIfNeeded()
    #elseif canImport(AppKit)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
    #endif
}

@MainActor
private func scroll(_ list: ListScrollView, toY y: CGFloat) {
    list.setContentOffset(CGPoint(x: 0, y: y), animated: false)
    layOut(list)
}

@Suite(.serialized)
@MainActor
struct ListViewSubclassingTests {
    private func makeList(count: Int = 40) -> RecordingList {
        let list = RecordingList()
        #if canImport(UIKit)
            list.contentInsetAdjustmentBehavior = .never
        #endif
        list.rows {
            ListRow(SubclassRow.self)
                .height { _, _ in 44 }
                .configure { row, item, _ in row.text = item.text }
        }
        list.apply((0 ..< count).map { SubclassItem(id: $0, text: "row \($0)") })
        layOut(list)
        return list
    }

    @Test("mounting goes through the overridden hooks")
    func mountingUsesTheHooks() throws {
        let list = makeList()

        #expect(list.count("rows(_:)") == 1)
        #expect(list.count("apply(_:animated:)") == 1)
        #expect(list.count("layoutContent()") >= 1)
        #expect(list.count("mountRowView(at:)") == list.visibleRowViews.count)
        // Nothing was in the pool yet, so every mounted row was made.
        #expect(list.made.count == list.visibleRowViews.count)
        #expect(list.dequeued.isEmpty)

        let row = try #require(list.rowView(for: 0) as? SubclassRow)
        #expect(row.text == "row 0")
        #expect(list.configured.contains { $0.view === row && $0.item.id == 0 })
        row.withAnimation {}
        #expect(row.animatedBlocks == 1)
    }

    @Test("recycling goes through the pool hooks, and the pool hands rows back")
    func recyclingUsesThePoolHooks() throws {
        let list = makeList()
        let firstRow = try #require(list.rowView(for: 0))

        scroll(list, toY: list.maximumContentOffset.y)

        #expect(list.enqueued.contains { $0 === firstRow })
        #expect(list.dequeued.contains { $0 === firstRow })
        #expect(list.rowView(for: 0) == nil)
        // Rows came back out of the pool instead of being made again.
        #expect(list.made.count < 40)
    }

    @Test("a row kept out of recycling stays mounted and is refilled in place")
    func aRetainedRowSurvivesScrolling() throws {
        let list = makeList()
        list.retained = [0]
        let row = try #require(list.rowView(for: 0) as? SubclassRow)
        let resets = row.resetCount

        scroll(list, toY: list.maximumContentOffset.y)
        #expect(list.rowView(for: 0) === row)

        list.update(SubclassItem(id: 0, text: "streamed"))
        #expect(list.count("update(_:)") == 1)
        #expect(list.count("reconfigureRow(with:)") >= 1)
        #expect(row.text == "streamed")
        #expect(row.resetCount == resets)

        scroll(list, toY: 0)
        #expect(list.rowView(for: 0) === row)

        // Released, the row goes back to the pool once it is off screen.
        list.retained = []
        scroll(list, toY: list.maximumContentOffset.y)
        #expect(list.rowView(for: 0) == nil)
        #expect(list.enqueued.contains { $0 === row })
    }

    @Test("a row the subclass keeps out of the pool is not handed out again")
    func enqueueCanDropRows() throws {
        let list = makeList()
        list.poolsRows = false
        let firstRow = try #require(list.rowView(for: 0))
        let madeBefore = list.made.count

        scroll(list, toY: list.maximumContentOffset.y)

        #expect(list.dequeued.isEmpty)
        #expect(list.made.count > madeBefore)
        #expect(firstRow.superview == nil)
    }

    @Test("content, invalidation and scrolling calls reach the overrides")
    func contentAndScrollingCallsReachTheOverrides() {
        let list = makeList()

        list.append(SubclassItem(id: 100, text: "appended"))
        #expect(list.count("append(_:)") == 1)
        list.append(contentsOf: [SubclassItem(id: 101, text: "more")])
        #expect(list.count("append(contentsOf:)") == 1)

        list.invalidateLayout(forRowWith: 0)
        #expect(list.count("invalidateLayout(forRowWith:)") == 1)
        list.reloadData()
        #expect(list.count("reloadData()") == 1)
        #expect(list.count("invalidateLayout()") >= 1)

        list.scrollToRow(with: 20, at: .top, animated: false)
        #expect(list.count("scrollToRow(with:at:animated:)") == 1)
        #expect(list.count("scrollToRow(at:at:animated:)") == 1)
        #expect(list.count("cancelCurrentScrolling()") >= 1)

        list.scrollToBottom(animated: true)
        #expect(list.count("scrollToBottom(animated:)") == 1)
        #expect(list.count("scroll(to:angularFrequency:preserveVelocity:)") >= 1)
        list.cancelCurrentScrolling()

        list.frame = CGRect(x: 0, y: 0, width: 300, height: 240)
        #expect(list.count("frame") >= 1)
    }

    @Test("a generic subclass lays out through its override")
    func genericSubclass() {
        let list = GenericList<SubclassItem>(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        list.rows {
            ListRow(SubclassRow.self)
                .height { _, _ in 44 }
                .configure { row, item, _ in row.text = item.text }
        }
        list.apply((0 ..< 10).map { SubclassItem(id: $0, text: "row \($0)") })
        layOut(list)

        #expect(list.layoutPasses >= 1)
        #expect(!list.visibleRowViews.isEmpty)
    }

    @Test("the scroll view alone can be subclassed")
    func plainScrollViewSubclass() {
        let scrollView = PlainScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        scrollView.contentSize = CGSize(width: 200, height: 2_000)
        layOut(scrollView)
        #expect(scrollView.layoutPasses >= 1)
    }
}
