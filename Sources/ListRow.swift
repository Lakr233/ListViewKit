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
public struct ListRow<Item: Identifiable & Hashable, RowView: ListRowView> {
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
    public func when(_ predicate: @escaping (Item) -> Bool) -> Self {
        map { $0.matches = predicate }
    }

    /// Computes the row height without building a view. Always prefer this.
    public func height(_ height: @escaping (Item, ListRowContext) -> CGFloat) -> Self {
        map { $0.height = height }
    }

    /// Height assumed until this row is measured. Only the content size and
    /// the scroller proportion depend on it, and only until measurement
    /// catches up.
    public func estimatedHeight(_ height: CGFloat) -> Self {
        map { $0.estimatedHeight = height }
    }

    public func configure(
        _ configure: @escaping (RowView, Item, ListRowContext) -> Void
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
public struct ListRowRegistration<Item: Identifiable & Hashable> {
    var matches: (Item) -> Bool = { _ in true }
    var makeRow: () -> ListRowView
    var height: ((Item, ListRowContext) -> CGFloat)?
    var estimatedHeight: CGFloat?
    var configure: (ListRowView, Item, ListRowContext) -> Void
}

@resultBuilder
public enum ListRowsBuilder<Item: Identifiable & Hashable> {
    public static func buildExpression<RowView: ListRowView>(
        _ row: ListRow<Item, RowView>
    ) -> ListRowRegistration<Item> {
        row.registration
    }

    public static func buildBlock(
        _ registrations: ListRowRegistration<Item>...
    ) -> [ListRowRegistration<Item>] {
        registrations
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
