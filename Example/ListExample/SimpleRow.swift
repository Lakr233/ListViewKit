//
//  SimpleRow.swift
//  ListExample
//
//  Created by 秋星桥 on 5/22/25.
//

import ListViewKit
import UIKit

class SimpleRow: ListRowView, UIContextMenuInteractionDelegate {
    let label = UILabel()
    var contextMenu: UIMenu = .init()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textAlignment = .left
        label.textColor = .label
        label.numberOfLines = 0
        addSubview(label)
        interactions.append(UIContextMenuInteraction(delegate: self))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 16, dy: 16)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        label.text = ""
        contextMenu = .init()
    }

    func configure(with text: String) {
        label.text = text
    }

    static func height(for text: String, width: CGFloat) -> CGFloat {
        let contentWidth = width - 32
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.preferredFont(forTextStyle: .body),
        ]
        let size = text.boundingRect(
            with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: attributes,
            context: nil
        )
        return size.height + 32
    }

    override func prepareForMove() {
        super.prepareForMove()
    }

    func contextMenuInteraction(
        _: UIContextMenuInteraction,
        configurationForMenuAtLocation _: CGPoint
    ) -> UIContextMenuConfiguration? {
        .init(actionProvider: { _ in self.contextMenu })
    }
}
