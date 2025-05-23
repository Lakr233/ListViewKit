//
//  ViewController.swift
//  ListExample
//
//  Created by 秋星桥 on 5/21/25.
//

import ListViewKit
import UIKit

class ViewController: UIViewController {
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

        listView.translatesAutoresizingMaskIntoConstraints = false
        listView.verticalExtendingSpacer = 233

        NSLayoutConstraint.activate([
            listView.topAnchor.constraint(equalTo: view.topAnchor),
            listView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            listView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
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

        navigationItem.leftBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .compose, target: self, action: #selector(compose)),
        ]
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(shuffle)),
            UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addItem)),
        ]
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

    @objc func compose() {
        var snapshot = dataSource.snapshot()
        var composeItem = ViewModel()
        snapshot.append(composeItem)
        dataSource.applySnapshot(snapshot, animatingDifferences: true)

        let text = """
        Eiusmod officia consequat reprehenderit Lorem eu ut id exercitation veniam veniam nulla. Nisi et reprehenderit nostrud. Cillum aliqua dolore reprehenderit non cupidatat velit Lorem. Laborum dolor voluptate aliquip labore aliquip et aliqua proident quis magna cupidatat minim labore. Qui in cupidatat aliqua et dolor minim ullamco est veniam consectetur cillum ad. Nulla nisi Lorem labore ullamco in sunt non laborum enim aliquip.
        """
        DispatchQueue.global().async {
            for char in text {
                composeItem.text += String(char)
                DispatchQueue.main.async {
                    var snapshot = self.dataSource.snapshot()
                    snapshot.updateItem(composeItem)
                    self.dataSource.applySnapshot(snapshot, animatingDifferences: true)
                    self.listView.scroll(to: self.listView.maximumContentOffset)
                }
                usleep(5000)
            }
        }
    }
}
