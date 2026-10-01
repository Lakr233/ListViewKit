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
    /// Floats on the keyboard. The list ends at the keyboard too, so opening
    /// and closing it resizes the list inside the keyboard's own animation.
    private let composer = ComposerBar()
    private static let composerMargin: CGFloat = 8

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
                // The text leads with the index, so a row that moves can wrap
                // differently and has to be measured again.
                .heightDependsOnIndex()
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

        listView.keyboardDismissMode = .interactive
        // Rows scroll on under the composer; the last one stops above it.
        listView.bottomInset = ComposerBar.height + Self.composerMargin * 2
        view.addSubview(listView)
        listView.translatesAutoresizingMaskIntoConstraints = false

        // Tapping the list puts the keyboard away without taking the tap from
        // the row under it.
        let dismiss = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        dismiss.cancelsTouchesInView = false
        listView.addGestureRecognizer(dismiss)

        composer.onSend = { [weak self] text in
            guard let self else { return }
            listView.apply(listView.content + [ViewModel(text: text)], animated: true)
            listView.scrollToBottom(animated: true)
        }
        view.addSubview(composer)
        composer.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            listView.topAnchor.constraint(equalTo: view.topAnchor),
            listView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            listView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            composer.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor,
                constant: Self.composerMargin * 1.5
            ),
            composer.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                constant: -Self.composerMargin * 1.5
            ),
            composer.bottomAnchor.constraint(
                equalTo: view.keyboardLayoutGuide.topAnchor,
                constant: -Self.composerMargin
            ),
        ])

        listView.apply([
            ViewModel(text: "若遗憾是遗憾"),
            ViewModel(text: "若故事没说完"),
            ViewModel(text: "回头看"),
            ViewModel(text: "梨花已落千山"),
        ])

        let stressActions = [UIAction(title: "All") { [weak self] _ in
            self?.stress(StressScenario.all)
        }] + StressScenario.all.map { scenario in
            UIAction(title: scenario.name, subtitle: scenario.summary) { [weak self] _ in
                self?.stress([scenario])
            }
        }
        navigationItem.leftBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .compose, target: self, action: #selector(compose)),
            UIBarButtonItem(
                title: "Stress",
                image: UIImage(systemName: "bolt"),
                menu: UIMenu(title: "Stress test", children: stressActions)
            ),
        ]
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let scenarios = StressLog.requestedScenarios, !didRunRequestedStress {
            didRunRequestedStress = true
            stress(scenarios)
        }
    }

    private var didRunRequestedStress = false

    private func stress(_ scenarios: [StressScenario]) {
        view.endEditing(true)
        navigationController?.pushViewController(StressViewController(scenarios: scenarios), animated: true)
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

    @objc func dismissKeyboard() {
        view.endEditing(true)
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
                try? await Task.sleep(nanoseconds: 5_000_000)
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
