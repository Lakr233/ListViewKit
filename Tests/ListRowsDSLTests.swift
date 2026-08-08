#if canImport(UIKit)
// UIKit platforms (including Mac Catalyst) are exercised by the UIKit suites.
#elseif canImport(AppKit)
import AppKit
import Testing
@testable import ListViewKit

private struct DSLItem: Identifiable, Hashable {
    let id: Int
    var isWide = false
}

@MainActor private final class NarrowRow: ListRowView {
    var configuredID: Int?
}

@MainActor private final class WideRow: ListRowView {
    var configuredID: Int?
}

/// A row that sizes itself from its own constraints instead of a closure.
@MainActor private final class SelfSizingRow: ListRowView {
    let label = NSTextField(labelWithString: "")

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
}

@Suite(.serialized)
@MainActor
struct ListRowsDSLTests {
    /// Registrations are tried in declaration order, so a conditional row wins
    /// over the catch-all that follows it.
    @Test
    func theFirstMatchingRegistrationClaimsTheItem() throws {
        let listView = ListView<DSLItem>(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        listView.rows {
            ListRow(WideRow.self)
                .when(\.isWide)
                .height { _, _ in 80 }
                .configure { row, item, _ in row.configuredID = item.id }
            ListRow(NarrowRow.self)
                .height { _, _ in 20 }
                .configure { row, item, _ in row.configuredID = item.id }
        }

        listView.apply([
            DSLItem(id: 0),
            DSLItem(id: 1, isWide: true),
            DSLItem(id: 2),
        ])

        #expect(listView.rowView(for: 0) is NarrowRow)
        #expect(listView.rowView(for: 1) is WideRow)
        #expect(listView.rowView(for: 2) is NarrowRow)
        #expect((listView.rowView(for: 1) as? WideRow)?.configuredID == 1)
        #expect(listView.rectForRow(at: 1).height == 80)
        #expect(listView.rectForRow(at: 2).height == 20)
    }

    /// An item that changes into a different row type gets a different view,
    /// and the old one goes back to its own pool rather than the new one's.
    @Test
    func changingRowTypeSwapsTheView() throws {
        let listView = ListView<DSLItem>(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        listView.rows {
            ListRow(WideRow.self)
                .when(\.isWide)
                .height { _, _ in 80 }
                .configure { row, item, _ in row.configuredID = item.id }
            ListRow(NarrowRow.self)
                .height { _, _ in 20 }
                .configure { row, item, _ in row.configuredID = item.id }
        }
        listView.apply([DSLItem(id: 0)])
        #expect(listView.rowView(for: 0) is NarrowRow)

        listView.apply([DSLItem(id: 0, isWide: true)])

        let swapped = try #require(listView.rowView(for: 0))
        #expect(swapped is WideRow)
        #expect((swapped as? WideRow)?.configuredID == 0)
        #expect(listView.rectForRow(at: 0).height == 80)
    }

    /// Registering without a height closure measures the row from its own
    /// constraints, on a hidden prototype rather than on a displayed row.
    @Test
    func aRowWithoutAHeightClosureSizesItself() {
        let listView = ListView<DSLItem>(frame: CGRect(x: 0, y: 0, width: 200, height: 400))
        listView.rows {
            ListRow(SelfSizingRow.self)
                .estimatedHeight(30)
                .configure { row, item, _ in
                    row.label.stringValue = String(repeating: "word ", count: item.id + 1)
                }
        }
        listView.apply([DSLItem(id: 0), DSLItem(id: 40)])
        listView.layoutSubtreeIfNeeded()

        let short = listView.rectForRow(at: 0).height
        let long = listView.rectForRow(at: 1).height
        // Both measured, and the wrapped one is taller than the single line.
        #expect(short > 0)
        #expect(long > short)
        // Displayed rows stay frame-driven; only the prototype uses Auto Layout.
        for row in listView.visibleRowViews {
            #expect(row.translatesAutoresizingMaskIntoConstraints)
        }
    }

    @Test
    func theEstimateComesFromTheRegistrationWhenItGivesOne() {
        let listView = ListView<DSLItem>(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        listView.rows {
            ListRow(NarrowRow.self)
                .estimatedHeight(250)
                .height { _, _ in 25 }
                .configure { _, _, _ in }
        }
        listView.apply((0 ..< 20).map { DSLItem(id: $0) })

        // The viewport is measured; everything past it sits at the estimate.
        #expect(listView.rowLayout.pendingRowCount > 0)
        let measuredRows = 20 - listView.rowLayout.pendingRowCount
        #expect(
            listView.rowLayout.contentHeight
                == CGFloat(measuredRows) * 25 + CGFloat(listView.rowLayout.pendingRowCount) * 250
        )
    }
}
#endif
