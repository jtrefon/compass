import Foundation

/// Published during a FIM completion model download to drive the status bar.
public struct ModelDownloadProgressEvent: Event {
    public let fractionCompleted: Double
    public let currentFileName: String?

    public init(fractionCompleted: Double, currentFileName: String? = nil) {
        self.fractionCompleted = fractionCompleted
        self.currentFileName = currentFileName
    }
}

/// Published when a FIM completion model download finishes.
public struct ModelDownloadCompletedEvent: Event {
    public let modelId: String
    public let displayName: String

    public init(modelId: String, displayName: String) {
        self.modelId = modelId
        self.displayName = displayName
    }
}
