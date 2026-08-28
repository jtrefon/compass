import Foundation

struct FileTreeCoordinatorState {
    var rootURL: URL?
    var rootPath: String?
    var refreshToken: Int = 0
    var showHiddenFiles: Bool = false
    var fontSize: Double = 13
    var fontFamily: String = "SF Mono"
}
