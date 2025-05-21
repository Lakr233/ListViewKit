//
//  Created by ktiays on 2025/1/15.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import UIKit

public protocol ListViewAdapter: AnyObject {
    typealias ItemType = (any Identifiable)
    typealias RowKind = (any Hashable)

    /// Asks the adapater for the height to use for a row in a specified location.
    func listView(_ list: ListView, heightFor item: ItemType, at index: Int) -> CGFloat

    func listView(_ list: ListView, configureRowView rowView: ListRowView, for item: ItemType, at index: Int)

    func listView(_ list: ListView, rowKindFor item: ItemType, at index: Int) -> RowKind

    /// Asks the adapter for a new row view to insert in a particular location of the list view.
    func makeListRowView(for kind: RowKind) -> ListRowView

    /// Informs the adapter when a context menu will appear.
    func listView(_ list: ListView, willDisplayContextMenuAt point: CGPoint, for item: ItemType, at index: Int, view: ListRowView)
}
