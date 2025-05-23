//
//  ViewController+ListViewAdapter.swift
//  ListExample
//
//  Created by 秋星桥 on 5/22/25.
//

import ListViewKit
import UIKit

extension ViewController: ListViewAdapter {
    func text(for vm: ViewModel, index: Int) -> String {
        "\(index)\n\n\(vm.text)"
    }

    func listView(_ listView: ListView, heightFor item: ItemType, at index: Int) -> CGFloat {
        SimpleRow.height(
            for: text(for: item as! ViewModel, index: index),
            width: listView.frame.width
        )
    }

    func listView(_: ListView, configureRowView rowView: ListRowView, for item: ItemType, at index: Int) {
        let vm = item as! ViewModel
        let textView = rowView as! SimpleRow
        textView.configure(with: text(for: vm, index: index))
        textView.contextMenu = .init(children: [
            UIAction(title: "Copy", image: UIImage(systemName: "document.on.document")) { _ in
                UIPasteboard.general.string = vm.text
            },
            UIAction(title: "Delete", image: UIImage(systemName: "trash")) { [weak self] _ in
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

    func listViewMakeRow(for rowKind: RowKind) -> ListRowView {
        switch rowKind as! ViewModel.RowKind {
        case .text: SimpleRow()
        }
    }
}
