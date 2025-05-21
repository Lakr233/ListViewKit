//
//  Created by ktiays on 2025/1/15.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import Foundation

@propertyWrapper
final class Reference<T> {
    var wrappedValue: T

    init(wrappedValue: T) {
        self.wrappedValue = wrappedValue
    }

    init(_ wrappedValue: T) {
        self.wrappedValue = wrappedValue
    }

    func modifying<R>(_ modifier: (inout T) throws -> R) rethrows -> R {
        try modifier(&wrappedValue)
    }
}

extension Reference: Identifiable where T: Identifiable {
    var id: T.ID {
        wrappedValue.id
    }
}

extension Reference: Equatable where T: Equatable {
    static func == (lhs: Reference<T>, rhs: Reference<T>) -> Bool {
        lhs.wrappedValue == rhs.wrappedValue
    }
}

extension Reference: Hashable where T: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(wrappedValue)
    }
}
