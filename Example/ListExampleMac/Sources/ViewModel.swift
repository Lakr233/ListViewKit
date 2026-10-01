//
//  ViewModel.swift
//  ListExampleMac
//

import Foundation

struct ViewModel: Identifiable, Hashable {
    var id: UUID = .init()
    var text: String = ""
}
