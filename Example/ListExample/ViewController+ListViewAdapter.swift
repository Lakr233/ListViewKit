//
//  ViewController+ListViewAdapter.swift
//  ListExample
//
//  Created by 秋星桥 on 5/22/25.
//

import ListViewKit
import UIKit

extension ViewController: ListViewAdapter {
    func listView(_ listView: ListView, heightFor item: ItemType, at _: Int) -> CGFloat {
        SimpleRow.height(for: (item as! ViewModel).text, width: listView.frame.width)
    }

    func listView(_: ListView, configureRowView rowView: ListRowView, for item: ItemType, at index: Int) {
        let vm = item as! ViewModel
        let textView = rowView as! SimpleRow
        textView.configure(with: vm.text)
        textView.contextMenu = .init(children: [
            UIAction(title: "Copy") { _ in
                UIPasteboard.general.string = vm.text
            },
            UIAction(title: "Delete") { [weak self] _ in
                guard let self else { return }
                var snapshot = dataSource.snapshot()
                snapshot.remove(at: index)
                dataSource.applySnapshot(snapshot, animatingDifferences: true)
            },
        ])
        rowView.backgroundColor = index % 2 == 1 ? .systemGray.withAlphaComponent(0.025) : .clear
    }

    func listView(_: ListView, rowKindFor _: ItemType, at _: Int) -> RowKind {
        ViewModel.RowKind.text
    }

    func listViewMakeRow(for _: RowKind) -> ListRowView {
        SimpleRow()
    }

    func listView(_ listView: ListView, onEvent event: ListViewEvent) {
        _ = listView
        _ = event
    }
}
