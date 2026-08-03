#if canImport(UIKit)
// UIKit platforms (including Mac Catalyst) are exercised by the UIKit suites.
#elseif canImport(AppKit)
import AppKit
import Testing
@testable import ListViewKit

private struct TypedAdapterItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case text
    }

    let id: Int
    let text: String
}

@MainActor
private final class TypedAdapterRow: ListRowView {
    var configuredText: String?
}

@Suite(.serialized)
@MainActor
struct ListViewTypedAdapterTests {
    @Test
    func registeredRowUsesTypedConfiguration() throws {
        let listView = ListView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        let adapter = ListViewTypedAdapter<TypedAdapterItem, TypedAdapterItem.Kind> {
            _, _, _ in .text
        }
        adapter.register(
            .text,
            makeRow: TypedAdapterRow.init,
            height: { _, item, _ in
                item.text.isEmpty ? 44 : 64
            },
            configure: { _, row, item, _ in
                row.configuredText = item.text
            }
        )
        let dataSource = ListViewDiffableDataSource<TypedAdapterItem>(listView: listView)
        listView.adapter = adapter

        var snapshot = dataSource.snapshot()
        snapshot.append(TypedAdapterItem(id: 1, text: "Typed row"))
        dataSource.applySnapshot(snapshot)
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()

        let row = try #require(listView.rowView(at: 0) as? TypedAdapterRow)
        #expect(row.configuredText == "Typed row")
        #expect(listView.rectForRow(at: 0).height == 64)
    }
}
#endif
