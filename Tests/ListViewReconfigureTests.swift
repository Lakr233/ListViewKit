#if canImport(UIKit)
// UIKit platforms (including Mac Catalyst) are exercised by the UIKit suites.
#elseif canImport(AppKit)
import AppKit
import Testing
@testable import ListViewKit

private struct ReconfigureItem: Identifiable, Hashable {
    let id: Int
    let text: String
}

@MainActor
private final class ReconfigureRow: ListRowView {
    var configuredText: String?
    var prepareForReuseCount = 0

    override func prepareForReuse() {
        super.prepareForReuse()
        prepareForReuseCount += 1
        configuredText = nil
    }
}

@MainActor
private final class ReconfigureAdapter: ListViewAdapter {
    func listView(_: ListView, rowKindFor _: ItemType, at _: Int) -> RowKind {
        "row"
    }

    func listViewMakeRow(for _: RowKind) -> ListRowView {
        ReconfigureRow()
    }

    func listView(_: ListView, heightFor _: ItemType, at _: Int) -> CGFloat {
        44
    }

    func listView(_: ListView, configureRowView rowView: ListRowView, for item: ItemType, at _: Int) {
        guard let row = rowView as? ReconfigureRow, let item = item as? ReconfigureItem else { return }
        row.configuredText = item.text
    }
}

@Suite(.serialized)
@MainActor
struct ListViewReconfigureTests {
    private func makeListView() -> (ListView, ListViewDiffableDataSource<ReconfigureItem>, ReconfigureAdapter) {
        let listView = ListView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        let adapter = ReconfigureAdapter()
        let dataSource = ListViewDiffableDataSource<ReconfigureItem>(listView: listView)
        listView.adapter = adapter
        return (listView, dataSource, adapter)
    }

    @Test("updateItem reconfigures in place without resetting the row")
    func updateItemSkipsPrepareForReuse() throws {
        // The list view holds its adapter weakly; keep it alive here.
        let (listView, dataSource, adapter) = makeListView()
        defer { _ = adapter }
        dataSource.applySnapshot(using: [ReconfigureItem(id: 1, text: "hello")])
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()

        let row = try #require(listView.rowView(at: 0) as? ReconfigureRow)
        let reuseCountAfterInitialConfigure = row.prepareForReuseCount

        dataSource.updateItem(ReconfigureItem(id: 1, text: "hello world"))

        #expect(listView.rowView(at: 0) === row)
        // A streaming update must not blank the row: the reset that comes
        // with prepareForReuse is only for rows returning from the pool.
        #expect(row.prepareForReuseCount == reuseCountAfterInitialConfigure)
        #expect(row.configuredText == "hello world")
    }

    @Test("snapshot content update reconfigures in place without resetting the row")
    func applySnapshotUpdateSkipsPrepareForReuse() throws {
        // The list view holds its adapter weakly; keep it alive here.
        let (listView, dataSource, adapter) = makeListView()
        defer { _ = adapter }
        dataSource.applySnapshot(using: [ReconfigureItem(id: 1, text: "hello")])
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()

        let row = try #require(listView.rowView(at: 0) as? ReconfigureRow)
        let reuseCountAfterInitialConfigure = row.prepareForReuseCount

        dataSource.applySnapshot(using: [ReconfigureItem(id: 1, text: "hello world")])
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()

        #expect(listView.rowView(at: 0) === row)
        #expect(row.prepareForReuseCount == reuseCountAfterInitialConfigure)
        #expect(row.configuredText == "hello world")
    }
}
#endif
