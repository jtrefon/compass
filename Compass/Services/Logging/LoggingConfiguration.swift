import Foundation

public struct LoggingConfiguration: Sendable {
    public var minimumLevel: LogLevel
    public var enableConsole: Bool

    public init(minimumLevel: LogLevel = .info, enableConsole: Bool = true) {
        self.minimumLevel = minimumLevel
        self.enableConsole = enableConsole
    }
}
