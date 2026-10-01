//
//  ListRow.swift
//  ListViewKit
//

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#else
    #error("ListViewKit requires UIKit or AppKit")
#endif

/// Why a row is being filled in.
public enum ListRowPurpose: Sendable {
    /// The row is going on screen.
    case display
    /// The row is a hidden prototype being measured. Work that cannot change
    /// the height — image loading, animation, analytics — should be skipped,
    /// or a full measurement pass fires one of each per row in the list.
    case measurement
}

/// Where a row is being used.
public struct ListRowContext: Sendable {
    public let index: Int
    /// Width the row will be laid out at. Height calculations must use this
    /// rather than reading the list's bounds, which may already have moved on.
    ///
    /// A mounted row is resized, not reconfigured, when the width changes, so
    /// layout inside a row belongs to its own `bounds`, not to this value.
    public let width: CGFloat
    public let purpose: ListRowPurpose
}

/// One row type, and how to size and fill it.
///
/// Declared inside ``ListView/rows(_:)``:
///
/// ```swift
/// list.rows {
///     ListRow(TextRow.self)
///         .height { message, ctx in TextRow.height(for: message.text, width: ctx.width) }
///         .configure { row, message, _ in row.show(message.text) }
/// }
/// ```
///
/// Omitting ``height(_:)`` measures the row from its own Auto Layout
/// constraints instead. That costs one or two orders of magnitude more per
/// row, so give a ``estimatedHeight(_:)`` close to the truth and prefer a
/// height closure for lists in the thousands.
public struct ListRow<Item: Identifiable & Hashable & SendableMetatype, RowView: ListRowView> {
    var registration: ListRowRegistration<Item>

    public init(_: RowView.Type = RowView.self) {
        registration = .init(
            makeRow: { RowView() },
            configure: { view, item, context in
                guard let row = view as? RowView else {
                    preconditionFailure(
                        "Expected \(RowView.self) but got \(type(of: view))."
                    )
                }
                _ = (row, item, context)
            }
        )
    }

    /// Limits this row to items it can display. Registrations are tried in
    /// declaration order and the first match wins, so a row without a
    /// condition is the catch-all and belongs last.
    public func when(_ predicate: @escaping @MainActor (Item) -> Bool) -> Self {
        map { $0.matches = predicate }
    }

    /// Computes the row height without building a view. Always prefer this.
    public func height(_ height: @escaping @MainActor (Item, ListRowContext) -> CGFloat) -> Self {
        map { $0.height = height }
    }

    /// Height assumed until this row is measured. Only the content size and
    /// the scroller proportion depend on it, and only until measurement
    /// catches up.
    public func estimatedHeight(_ height: CGFloat) -> Self {
        map { $0.estimatedHeight = height }
    }

    /// Declares that this row's height reads `context.index`, so a row that
    /// only moved has to be measured again.
    ///
    /// Without it, an item that keeps its value keeps its measured height
    /// wherever it moves to. That is what lets a page of history go in above
    /// twenty thousand rows without measuring them all again. A mounted row
    /// that moves is still configured again, with its new index, either way;
    /// this is only about the height. Self-sizing rows follow the same rule:
    /// declare it when something the configuration derives from the index
    /// changes the row's constraints.
    public func heightDependsOnIndex() -> Self {
        map { $0.heightDependsOnIndex = true }
    }

    public func configure(
        _ configure: @escaping @MainActor (RowView, Item, ListRowContext) -> Void
    ) -> Self {
        map { registration in
            registration.configure = { view, item, context in
                guard let row = view as? RowView else {
                    preconditionFailure(
                        "Expected \(RowView.self) but got \(type(of: view))."
                    )
                }
                configure(row, item, context)
            }
        }
    }

    private func map(_ transform: (inout ListRowRegistration<Item>) -> Void) -> Self {
        var copy = self
        transform(&copy.registration)
        return copy
    }
}

/// A ``ListRow`` with its view type erased, as the list stores it.
///
/// Rows are views, so every closure here runs on the main actor. Saying so in
/// the type lets a caller's closure touch main-actor state without ceremony,
/// and lets `makeRow` call a view initializer at all.
public struct ListRowRegistration<Item: Identifiable & Hashable & SendableMetatype> {
    /// Nil for a row without a condition, which claims every item. Kept nil
    /// rather than an always-true closure so finding an item's row — once
    /// per item on every apply — skips the call for the common list of one
    /// unconditional row.
    var matches: (@MainActor (Item) -> Bool)?
    var makeRow: @MainActor () -> ListRowView
    var height: (@MainActor (Item, ListRowContext) -> CGFloat)?
    var estimatedHeight: CGFloat?
    var heightDependsOnIndex = false
    var configure: @MainActor (ListRowView, Item, ListRowContext) -> Void
}

/// Every component is a list of registrations — a single row is a list of
/// one — so the blocks of `if`, `if`/`else` and `for` compose with plain rows.
@resultBuilder
public enum ListRowsBuilder<Item: Identifiable & Hashable & SendableMetatype> {
    public static func buildExpression<RowView: ListRowView>(
        _ row: ListRow<Item, RowView>
    ) -> [ListRowRegistration<Item>] {
        [row.registration]
    }

    public static func buildBlock(
        _ registrations: [ListRowRegistration<Item>]...
    ) -> [ListRowRegistration<Item>] {
        registrations.flatMap(\.self)
    }

    public static func buildArray(
        _ registrations: [[ListRowRegistration<Item>]]
    ) -> [ListRowRegistration<Item>] {
        registrations.flatMap(\.self)
    }

    public static func buildOptional(
        _ registrations: [ListRowRegistration<Item>]?
    ) -> [ListRowRegistration<Item>] {
        registrations ?? []
    }

    public static func buildEither(
        first registrations: [ListRowRegistration<Item>]
    ) -> [ListRowRegistration<Item>] {
        registrations
    }

    public static func buildEither(
        second registrations: [ListRowRegistration<Item>]
    ) -> [ListRowRegistration<Item>] {
        registrations
    }
}
