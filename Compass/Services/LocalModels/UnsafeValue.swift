import Foundation

struct UnsafeValue<T>: @unchecked Sendable {
    let value: T
}
