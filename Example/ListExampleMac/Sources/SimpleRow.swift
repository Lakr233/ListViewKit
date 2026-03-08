//
//  SimpleRow.swift
//  ListExampleMac
//

import AppKit
import ListViewKit

class SimpleRow: ListRowView {
    let label: NSTextField = {
        let field = NSTextField(wrappingLabelWithString: "")
        field.isEditable = false
        field.isSelectable = false
        field.isBordered = false
        field.drawsBackground = false
        field.textColor = .labelColor
        field.maximumNumberOfLines = 0
        return field
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(label)
    }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 16, dy: 16)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        label.stringValue = ""
    }

    func configure(with text: String) {
        label.stringValue = text
    }

    static func height(for text: String, width: CGFloat) -> CGFloat {
        let field = NSTextField(wrappingLabelWithString: text)
        field.isEditable = false
        field.isBordered = false
        field.maximumNumberOfLines = 0
        field.preferredMaxLayoutWidth = width - 32
        let size = field.sizeThatFits(NSSize(width: width - 32, height: CGFloat.greatestFiniteMagnitude))
        return size.height + 32
    }
}
