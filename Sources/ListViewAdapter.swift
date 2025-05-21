//
//  Created by ktiays on 2025/1/15.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import UIKit

public enum ListViewEvent {
    case didLongPressItem(location: CGPoint)
    case didUpdateContentOffset(offset: CGPoint)
}

public protocol ListViewAdapter: AnyObject {
    typealias ItemType = (any Identifiable)
    typealias RowKind = (any Hashable)

    func listView(_ list: ListView, rowKindFor item: ItemType, at index: Int) -> RowKind
    func listViewMakeRow(for kind: RowKind) -> ListRowView

    func listView(_ list: ListView, heightFor item: ItemType, at index: Int) -> CGFloat
    func listView(_ list: ListView, configureRowView rowView: ListRowView, for item: ItemType, at index: Int)

    func listView(_ list: ListView, onEvent event: ListViewEvent, for item: ItemType, at index: Int, rowView: ListRowView)
}
