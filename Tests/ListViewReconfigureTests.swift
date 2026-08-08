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

@Suite(.serialized)
@MainActor
struct ListViewReconfigureTests {
    private func makeListView() -> ListView<ReconfigureItem> {
        let listView = ListView<ReconfigureItem>(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        listView.rows {
            ListRow(ReconfigureRow.self)
                .height { _, _ in 44 }
                .configure { row, item, _ in row.configuredText = item.text }
        }
        return listView
    }

    @Test("update reconfigures in place without resetting the row")
    func updateSkipsPrepareForReuse() throws {
        let listView = makeListView()
        listView.apply([ReconfigureItem(id: 1, text: "hello")])

        let row = try #require(listView.rowView(for: 1) as? ReconfigureRow)
        let reuseCountAfterInitialConfigure = row.prepareForReuseCount

        listView.update(ReconfigureItem(id: 1, text: "hello world"))

        #expect(listView.rowView(for: 1) === row)
        // A streaming update must not blank the row: the reset that comes
        // with prepareForReuse is only for rows returning from the pool.
        #expect(row.prepareForReuseCount == reuseCountAfterInitialConfigure)
        #expect(row.configuredText == "hello world")
    }

    @Test("applying a changed value reconfigures in place without resetting the row")
    func applySkipsPrepareForReuse() throws {
        let listView = makeListView()
        listView.apply([ReconfigureItem(id: 1, text: "hello")])

        let row = try #require(listView.rowView(for: 1) as? ReconfigureRow)
        let reuseCountAfterInitialConfigure = row.prepareForReuseCount

        listView.apply([ReconfigureItem(id: 1, text: "hello world")])

        #expect(listView.rowView(for: 1) === row)
        #expect(row.prepareForReuseCount == reuseCountAfterInitialConfigure)
        #expect(row.configuredText == "hello world")
    }

    /// A row coming back from the pool is showing someone else's content, so
    /// it does get reset.
    @Test("a recycled row is reset before it is filled in again")
    func recycledRowIsPreparedForReuse() throws {
        let listView = makeListView()
        listView.apply((0 ..< 40).map { ReconfigureItem(id: $0, text: "row \($0)") })
        let firstRow = try #require(listView.rowView(for: 0) as? ReconfigureRow)
        let reuseCountBefore = firstRow.prepareForReuseCount

        listView.contentOffset.y = listView.maximumContentOffset.y
        listView.layoutSubtreeIfNeeded()
        #expect(listView.rowView(for: 0) == nil)

        listView.contentOffset.y = 0
        listView.layoutSubtreeIfNeeded()
        let reusedRow = try #require(listView.rowView(for: 0) as? ReconfigureRow)
        #expect(reusedRow.prepareForReuseCount > reuseCountBefore)
        #expect(reusedRow.configuredText == "row 0")
    }
}
#endif
