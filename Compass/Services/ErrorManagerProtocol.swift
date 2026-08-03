import Foundation

@MainActor
public protocol ErrorManagerProtocol: AnyObject, StatePublisherProtocol {
    var currentError: AppError? { get }
    var showErrorAlert: Bool { get set }
    func handle(_ error: AppError)
    func handle(_ error: Error, context: String)
    func dismissError()
}
