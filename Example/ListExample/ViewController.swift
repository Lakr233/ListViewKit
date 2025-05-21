//
//  ViewController.swift
//  ListExample
//
//  Created by 秋星桥 on 5/21/25.
//

import ListViewKit
import UIKit

class ViewController: UIViewController {
    struct ViewModel: Identifiable, Hashable {
        var id: UUID = .init()
        var text: String = ""

        enum RowKind: Hashable {
            case text
        }
    }

    let listView: ListView
    let dataSource: ListViewDiffableDataSource<ViewModel>

    init() {
        fatalError()
    }

    required init?(coder _: NSCoder) {
        let listView = ListView(frame: .zero)
        self.listView = listView
        dataSource = .init(listView: listView)
        super.init(nibName: nil, bundle: nil)
        title = "ListView Example"
        listView.adapter = self
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        edgesForExtendedLayout = []
        view.backgroundColor = .systemBackground
        view.addSubview(listView)

        listView.dataSource = dataSource
        listView.verticalExtendingSpacer = 500

        var snapshot = dataSource.snapshot()
        for content in [
            ViewModel(text: "若遗憾是遗憾"),
            ViewModel(text: "若故事没说完"),
            ViewModel(text: "回头看"),
            ViewModel(text: "梨花已落千山"),
            ViewModel(text: "我至少听过"),
            ViewModel(text: "你说的喜欢"),
            ViewModel(text: "像涓涓温柔途经过百川"),
            ViewModel(text: "若遗憾是遗憾"),
            ViewModel(text: "若故事没说完"),
        ] {
            snapshot.append(content)
        }
        dataSource.applySnapshot(snapshot, animatingDifferences: false)

        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(shuffle)),
            UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addItem)),
            UIBarButtonItem(barButtonSystemItem: .trash, target: self, action: #selector(removeItem)),
        ]
    }

    @objc func addItem() {
        let content = [
            "若遺憾遺憾",
            "若心酸心酸",
            "又不是非要圓滿",
            "來年秋風亂",
            "笑看紅葉轉",
            "深情",
            "只好",
            "淺談",
        ].randomElement()!
        let vm = ViewModel(text: content)
        var snapshot = dataSource.snapshot()
        snapshot.insert(vm, at: (0 ..< snapshot.count).randomElement() ?? 0)
        dataSource.applySnapshot(snapshot, animatingDifferences: true)
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

    @objc func removeItem() {
        var snapshot = dataSource.snapshot()
        snapshot.remove(at: (0 ..< snapshot.count).randomElement() ?? 0)
        dataSource.applySnapshot(snapshot, animatingDifferences: true)
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        listView.frame = view.bounds
    }
}

extension ViewController: ListViewAdapter {
    func listView(_: ListView, heightFor _: ItemType, at _: Int) -> CGFloat {
        64
    }

    func listView(_: ListView, configureRowView rowView: ListRowView, for item: ItemType, at index: Int) {
        let vm = item as! ViewModel
        let label = rowView.subviews.first?.subviews.first as! UILabel
        label.text = vm.text
        rowView.backgroundColor = index % 2 == 1 ? .systemGray.withAlphaComponent(0.025) : .clear
    }

    func listView(_: ListView, rowKindFor _: ItemType, at _: Int) -> RowKind {
        ViewModel.RowKind.text
    }

    func listViewMakeRow(for _: RowKind) -> ListRowView {
        let textView = ListRowView(frame: .init(x: 0, y: 0, width: 50, height: 50))
        let label = UILabel(frame: textView.bounds.insetBy(dx: 16, dy: 16))
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .left
        label.textColor = .label
        label.numberOfLines = 0
        textView.contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: textView.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: textView.topAnchor, constant: 16),
            label.bottomAnchor.constraint(equalTo: textView.bottomAnchor, constant: -16),
        ])
        return textView
    }

    func listView(_ listView: ListView, onEvent event: ListViewEvent) {
        _ = listView
        _ = event
//        print("[*] listView \(listView.id.uuidString.components(separatedBy: "-").first!) received an event \(event)")
    }
}
