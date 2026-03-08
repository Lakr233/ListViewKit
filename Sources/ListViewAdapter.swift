//
//  Created by ktiays on 2025/1/15.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#else
    #error("ListViewKit requires UIKit or AppKit")
#endif

@MainActor
public protocol ListViewAdapter: AnyObject {
    typealias ItemType = (any Identifiable)
    typealias RowKind = (any Hashable)

    func listView(_ list: ListView, rowKindFor item: ItemType, at index: Int) -> RowKind
    func listViewMakeRow(for kind: RowKind) -> ListRowView

    func listView(_ list: ListView, heightFor item: ItemType, at index: Int) -> CGFloat
    func listView(_ list: ListView, configureRowView rowView: ListRowView, for item: ItemType, at index: Int)
}
