//
//  Created by ktiays on 2025/1/14.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import OrderedCollections
import UIKit

public class ListViewDataSource {
    public typealias ItemType = Hashable & Identifiable

    init() {}

    public func numberOfItems(in _: ListView) -> Int {
        fatalError()
    }

    public func item(at _: Int, in _: ListView) -> (any ItemType)? {
        fatalError()
    }

    func itemIndex(for _: any Hashable, in _: ListView) -> Int? {
        fatalError()
    }

    func itemIdentifier(at index: Int, in listView: ListView) -> (any Hashable)? {
        item(at: index, in: listView)?.id
    }
}
