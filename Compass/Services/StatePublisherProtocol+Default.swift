import Foundation
import SwiftUI
import Combine

@MainActor
public extension StatePublisherProtocol {
    var statePublisher: AnyPublisher<Void, Never> {
        objectWillChange
            .map { _ in () }
            .eraseToAnyPublisher()
    }
}
