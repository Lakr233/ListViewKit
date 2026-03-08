//
//  ViewController.swift
//  ListExampleMac
//

import AppKit
import ListViewKit

class ViewController: NSViewController {
    let listView: ListView
    let dataSource: ListViewDiffableDataSource<ViewModel>

    init() {
        let listView = ListView(frame: .zero)
        self.listView = listView
        dataSource = .init(listView: listView)
        super.init(nibName: nil, bundle: nil)
        listView.adapter = self
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 600))
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        listView.topInset = 0
        listView.bottomInset = 0

        let animationBlockView = AnimationBlockView(install: listView)
        view.addSubview(animationBlockView)
        animationBlockView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            animationBlockView.topAnchor.constraint(equalTo: view.topAnchor),
            animationBlockView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            animationBlockView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            animationBlockView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        var snapshot = dataSource.snapshot()
        for content in [
            ViewModel(text: "若遗憾是遗憾"),
            ViewModel(text: "若故事没说完"),
            ViewModel(text: "回头看"),
            ViewModel(text: "梨花已落千山"),
        ] {
            snapshot.append(content)
        }
        dataSource.applySnapshot(snapshot, animatingDifferences: false)
    }

    @objc func addItem() {
        let content = [
            "我至少听过",
            "你说的喜欢",
            "像涓涓温柔途经过百川",
            "若遗憾是遗憾",
            "若故事没说完",
        ].randomElement()!
        let vm = ViewModel(text: content)
        var snapshot = dataSource.snapshot()
        let index = (0 ..< snapshot.count).randomElement() ?? 0
        snapshot.insert(vm, at: index)
        dataSource.applySnapshot(snapshot, animatingDifferences: true)
        print("[*] inserted at \(index)")
        listView.scrollToRow(at: index, at: .none)
    }

    @objc func shuffle() {
        var snapshot = dataSource.snapshot()
        var items: [ViewModel] = []
        while true {
            if let item = snapshot.remove(at: 0) {
                items.append(item)
            } else {
                break
            }
        }
        assert(snapshot.isEmpty)
        for item in items.shuffled() {
            snapshot.append(item)
        }
        dataSource.applySnapshot(snapshot, animatingDifferences: true)
    }

    @objc func compose() {
        var snapshot = dataSource.snapshot()
        var composeItem = ViewModel()
        snapshot.append(composeItem)
        dataSource.applySnapshot(snapshot, animatingDifferences: true)

        let text = """
        Eiusmod officia consequat reprehenderit Lorem eu ut id exercitation veniam veniam nulla. Nisi et reprehenderit nostrud. Cillum aliqua dolore reprehenderit non cupidatat velit Lorem. Laborum dolor voluptate aliquip labore aliquip et aliqua proident quis magna cupidatat minim labore. Qui in cupidatat aliqua et dolor minim ullamco est veniam consectetur cillum ad. Nulla nisi Lorem labore ullamco in sunt non laborum enim aliquip.
        """
        let itemID = composeItem.id
        Task.detached {
            for char in text {
                try? await Task.sleep(nanoseconds: 5_000_000)
                await MainActor.run {
                    composeItem.text += String(char)
                    var snapshot = self.dataSource.snapshot()
                    snapshot.updateItem(composeItem)
                    self.dataSource.applySnapshot(snapshot, animatingDifferences: true)
                    self.listView.scroll(to: self.listView.maximumContentOffset)
                }
            }
            _ = itemID
        }
    }
}

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
        rowView.layer?.backgroundColor = index % 2 == 1
            ? NSColor.systemGray.withAlphaComponent(0.025).cgColor
            : NSColor.clear.cgColor
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
