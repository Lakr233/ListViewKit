//
//  ViewController.swift
//  ListExampleMac
//

import AppKit
import ListViewKit

final class ViewController: NSViewController {
    private let listView = ListView<ViewModel>()

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 600))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        listView.rows {
            ListRow(SimpleRow.self)
                .height { item, context in
                    SimpleRow.height(for: Self.text(for: item, index: context.index), width: context.width)
                }
                .configure { row, item, context in
                    row.configure(with: Self.text(for: item, index: context.index))
                    row.layer?.backgroundColor = context.index.isMultiple(of: 2)
                        ? NSColor.clear.cgColor
                        : NSColor.systemGray.withAlphaComponent(0.025).cgColor
                }
        }

        view.addSubview(listView)
        listView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            listView.topAnchor.constraint(equalTo: view.topAnchor),
            listView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            listView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        listView.apply([
            ViewModel(text: "若遗憾是遗憾"),
            ViewModel(text: "若故事没说完"),
            ViewModel(text: "回头看"),
            ViewModel(text: "梨花已落千山"),
        ])
    }

    private static func text(for item: ViewModel, index: Int) -> String {
        "\(index)\n\n\(item.text)"
    }

    @objc func addItem() {
        let content = [
            "我至少听过",
            "你说的喜欢",
            "像涓涓温柔途经过百川",
            "若遗憾是遗憾",
            "若故事没说完",
        ].randomElement()!
        var items = listView.content
        let index = (0 ..< max(items.count, 1)).randomElement() ?? 0
        items.insert(ViewModel(text: content), at: index)
        listView.apply(items, animated: true)
        listView.scrollToRow(at: index, at: .nearest)
    }

    @objc func shuffle() {
        listView.apply(listView.content.shuffled(), animated: true)
    }

    /// A streaming response: append once, then update that one row as tokens
    /// arrive. `update` never diffs the rest of the list.
    @objc func compose() {
        var item = ViewModel()
        listView.append(item)

        let text = """
        Eiusmod officia consequat reprehenderit Lorem eu ut id exercitation veniam veniam nulla. \
        Nisi et reprehenderit nostrud. Cillum aliqua dolore reprehenderit non cupidatat velit Lorem. \
        Laborum dolor voluptate aliquip labore aliquip et aliqua proident quis magna cupidatat minim labore.
        """
        Task { @MainActor in
            for character in text {
                try? await Task.sleep(for: .milliseconds(5))
                item.text.append(character)
                listView.update(item)
                listView.scrollToBottom(animated: false)
            }
        }
    }
}
