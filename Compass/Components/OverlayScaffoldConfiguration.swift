import SwiftUI

struct OverlayScaffoldConfiguration {
    let title: String
    let placeholder: String
    let textFieldMinWidth: CGFloat
    let showsProgress: Bool
    let onSubmit: () -> Void
    let onClose: () -> Void
}
