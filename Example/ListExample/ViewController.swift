//
//  ViewController.swift
//  ListExample
//
//  Created by 秋星桥 on 5/21/25.
//

import ListViewKit
import UIKit

final class ViewController: UIViewController {
    private let listView = ListView<ViewModel>()

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "ListView Example"
        edgesForExtendedLayout = []
        view.backgroundColor = .systemBackground

        listView.rowAnimator = ListBouncyAnimator()

        listView.rows {
            ListRow(SimpleRow.self)
                .height { item, context in
                    SimpleRow.height(for: Self.text(for: item, index: context.index), width: context.width)
                }
                .configure { [weak self] row, item, context in
                    row.configure(with: Self.text(for: item, index: context.index))
                    row.backgroundColor = context.index.isMultiple(of: 2)
                        ? .clear
                        : .systemGray.withAlphaComponent(0.025)
                    // Menus only matter for a row the reader can touch.
                    guard context.purpose == .display else { return }
                    row.contextMenu = UIMenu(children: [
                        UIAction(title: "Copy", image: UIImage(systemName: "document.on.document")) { _ in
                            UIPasteboard.general.string = item.text
                        },
                        UIAction(title: "Delete", image: UIImage(systemName: "trash")) { _ in
                            guard let self else { return }
                            self.listView.apply(
                                self.listView.content.filter { $0.id != item.id },
                                animated: true
                            )
                        },
                    ])
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

        navigationItem.leftBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .compose, target: self, action: #selector(compose)),
        ]
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(shuffle)),
            UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addItem)),
        ]
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
        let index = Int.random(in: 0 ... items.count)
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
            var follower = TailFollower(listView)
            for character in text {
                try? await Task.sleep(for: .milliseconds(5))
                item.text.append(character)
                follower.observe(listView)
                listView.update(item)
                // A reader who has scrolled away is left where they are.
                if follower.isFollowing, !listView.isUserInteractingWithScroll {
                    listView.scrollToBottom(animated: false)
                    follower.didFollow(listView)
                }
            }
        }
    }
}

/// Decides whether a stream keeps the list pinned to its tail.
///
/// "Within a few points of the bottom" cannot tell the reader scrolling away
/// from the row growing past the edge while a token was not followed — during
/// a gesture, say — and it drops the tail for good the first time that
/// happens. The viewport's bottom edge in content coordinates tells them
/// apart: growth below it and a bottom-pinned resize leave it where it is,
/// and only scrolling moves it.
@MainActor
struct TailFollower {
    private var followedEdge: CGFloat?

    init(_ listView: ListView<ViewModel>) {
        if listView.isScrolledToBottom(tolerance: 4) {
            followedEdge = Self.bottomEdge(of: listView)
        }
    }

    var isFollowing: Bool { followedEdge != nil }

    /// Call before the update that grows the row.
    mutating func observe(_ listView: ListView<ViewModel>) {
        let edge = Self.bottomEdge(of: listView)
        if let followedEdge, edge < followedEdge - 4 {
            self.followedEdge = nil
        } else if followedEdge == nil, listView.isScrolledToBottom(tolerance: 4) {
            followedEdge = edge
        }
    }

    /// Call after scrolling to the bottom.
    mutating func didFollow(_ listView: ListView<ViewModel>) {
        followedEdge = Self.bottomEdge(of: listView)
    }

    private static func bottomEdge(of listView: ListView<ViewModel>) -> CGFloat {
        listView.contentOffset.y + listView.frame.height
    }
}
