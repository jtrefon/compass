import Foundation
import SwiftUI
import Combine

@MainActor
public protocol StatePublisherProtocol: AnyObject, ObservableObject {
    var statePublisher: AnyPublisher<Void, Never> { get }
}
