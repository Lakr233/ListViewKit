//
//  ListViewDataSourceSnapshot.swift
//  ListViewKit
//
//  Created by 秋星桥 on 5/22/25.
//

import Foundation
import OrderedCollections

public struct ListViewDataSourceSnapshot<Item> where Item: Identifiable {
    var elements: [Item]

    public var count: Int { elements.count }
    public var isEmpty: Bool { elements.isEmpty }

    init(elements: OrderedDictionary<Item.ID, Item>) {
        self.elements = elements.values.elements
    }

    public func item(at index: Int) -> Item? {
        if index < 0 || index >= elements.count {
            return nil
        }
        return elements[index]
    }

    public mutating func insert(_ item: Item, at index: Int) {
        if index < 0 || index > elements.count {
            return
        }

        elements.insert(item, at: index)
    }

    public mutating func append(_ item: Item) {
        elements.append(item)
    }

    public mutating func updateItem(_ item: Item) {
        let index = elements.firstIndex { $0.id == item.id }
        guard let index else { return }
        elements[index] = item
    }

    public mutating func updateItem(_ item: Item, at index: Int) {
        if index < 0 || index >= elements.count {
            assertionFailure()
            return
        }
        elements[index] = item
    }

    @discardableResult
    public mutating func remove(at index: Int) -> Item? {
        if index < 0 || index >= elements.count {
            return nil
        }
        return elements.remove(at: index)
    }

    public mutating func replace(with sequence: some Sequence<Item>) {
        elements = sequence.map(\.self)
    }
}
