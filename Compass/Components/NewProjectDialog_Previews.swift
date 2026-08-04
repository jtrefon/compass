import SwiftUI

struct NewProjectDialog_Previews: PreviewProvider {
    static var previews: some View {
        NewProjectDialog(
            fileDialogService: MockFileDialogService(),
            onCreateProject: { _, _ in _ = () }
        )
    }
}
