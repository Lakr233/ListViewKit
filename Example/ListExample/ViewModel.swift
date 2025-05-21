//
//  ViewModel.swift
//  ListExample
//
//  Created by 秋星桥 on 5/22/25.
//

import Foundation

struct ViewModel: Identifiable, Hashable {
    var id: UUID = .init()
    var text: String = ""

    enum RowKind: Hashable {
        case text
    }
}
