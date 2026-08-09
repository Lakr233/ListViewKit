//
//  AppDelegate.swift
//  ListExampleMac
//

import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var viewController: ViewController!

    func applicationDidFinishLaunching(_: Notification) {
        viewController = ViewController()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ListView Example"
        window.contentViewController = viewController
        window.center()

        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        window.makeKeyAndOrderFront(nil)
    }
}

extension NSToolbarItem.Identifier {
    static let addItem = NSToolbarItem.Identifier("AddItem")
    static let shuffle = NSToolbarItem.Identifier("Shuffle")
    static let compose = NSToolbarItem.Identifier("Compose")
    static let autoScrollGate = NSToolbarItem.Identifier("AutoScrollGate")
}

extension AppDelegate: NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.addItem, .shuffle, .compose, .autoScrollGate, .flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.compose, .autoScrollGate, .flexibleSpace, .addItem, .shuffle]
    }

    func toolbar(_: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar _: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case .addItem:
            item.label = "Add"
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")
            item.target = viewController
            item.action = #selector(ViewController.addItem)
        case .shuffle:
            item.label = "Shuffle"
            item.image = NSImage(systemSymbolName: "arrow.2.squarepath", accessibilityDescription: "Shuffle")
            item.target = viewController
            item.action = #selector(ViewController.shuffle)
        case .autoScrollGate:
            item.label = "Gate"
            item.image = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: "Auto-scroll gate")
            item.target = viewController
            item.action = #selector(ViewController.toggleAutoScrollGate(_:))
        case .compose:
            item.label = "Compose"
            item.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Compose")
            item.target = viewController
            item.action = #selector(ViewController.compose)
        default:
            return nil
        }
        return item
    }
}
