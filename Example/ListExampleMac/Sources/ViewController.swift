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

        // Off unless a host asks for it, which is the whole point of the
        // extension point — so an example that does not ask shows nothing.
        listView.rowAnimator = ListBouncyAnimator()

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
        let index = Int.random(in: 0 ... items.count)
        items.insert(ViewModel(text: content), at: index)
        listView.apply(items, animated: true)
        listView.scrollToRow(at: index, at: .nearest)
    }

    @objc func shuffle() {
        listView.apply(listView.content.shuffled(), animated: true)
    }

    /// Whether the streaming scroll asks the list before following the tail.
    ///
    /// Off is what an ungated host does, and is here to be compared against:
    /// it follows the tail on every token, so scroll the wheel while a
    /// response streams and the two fight for the offset, a notch at a time.
    private var gatesAutoScroll = true

    @objc func toggleAutoScrollGate(_ sender: NSToolbarItem) {
        gatesAutoScroll.toggle()
        sender.image = NSImage(
            systemSymbolName: gatesAutoScroll ? "hand.raised.fill" : "hand.raised.slash",
            accessibilityDescription: "Auto-scroll gate"
        )
    }

    /// A streaming response: append once, then update that one row as tokens
    /// arrive. `update` never diffs the rest of the list.
    ///
    /// Long enough to scroll around in while it runs, which is the only way to
    /// see what the gate does.
    @objc func compose() {
        var item = ViewModel()
        listView.append(item)

        let paragraph = """
        Eiusmod officia consequat reprehenderit Lorem eu ut id exercitation veniam veniam nulla. \
        Nisi et reprehenderit nostrud. Cillum aliqua dolore reprehenderit non cupidatat velit Lorem. \
        Laborum dolor voluptate aliquip labore aliquip et aliqua proident quis magna cupidatat minim labore.
        """
        let text = ([String](repeating: paragraph, count: 8)).joined(separator: "\n\n")
        Task { @MainActor in
            var follower = TailFollower(listView)
            for character in text {
                try? await Task.sleep(for: .milliseconds(5))
                item.text.append(character)
                follower.observe(listView)
                listView.update(item)
                // A reader who has scrolled away — or who is scrolling, or
                // resizing the window — is left where they are.
                if gatesAutoScroll, !follower.isFollowing || listView.isUserInteractingWithScroll { continue }
                listView.scrollToBottom(animated: false)
                follower.didFollow(listView)
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
