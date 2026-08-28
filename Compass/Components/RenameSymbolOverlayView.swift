import SwiftUI
import Foundation

struct RenameSymbolOverlayView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var fileEditor: FileEditorStateManager
    @Binding var isPresented: Bool

    @State private var newName: String = ""
    @State private var previewReplacements: Int = 0

    init(appState: AppState, isPresented: Binding<Bool>) {
        self.appState = appState
        self._fileEditor = ObservedObject(wrappedValue: appState.fileEditor)
        self._isPresented = isPresented
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Text(String(format: localized("rename_symbol.title_format"), appState.renameSymbolIdentifier))
                    .font(.headline)

                Spacer()

                Button(localized("common.close")) {
                    close()
                }
            }

            TextField(localized("rename_symbol.new_name_placeholder"), text: $newName)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: AppConstants.Overlay.textFieldMinWidth)
                .onSubmit {
                    applyRename()
                }

            HStack {
                Text(String(format: localized("rename_symbol.replacements_format"), previewReplacements))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button(localized("rename_symbol.rename")) {
                    applyRename()
                }
                .keyboardShortcut(.defaultAction)
            }
        .padding(AppConstants.Overlay.containerPadding)
        .nativeGlassBackground(.popover, cornerRadius: AppConstants.Overlay.containerCornerRadius)
        .shadow(radius: AppConstants.Overlay.containerShadowRadius)
        .onAppear {
            newName = appState.renameSymbolIdentifier
            previewReplacements = computePreviewReplacements()
        }
        .onChange(of: newName) { _, _ in
            previewReplacements = computePreviewReplacements()
        }
        .onExitCommand {
            close()
        }
        }
    }

    private func computePreviewReplacements() -> Int {
        let old = appState.renameSymbolIdentifier
        if old.isEmpty { return 0 }
        if !WorkspaceNavigationService.isValidIdentifier(
            newName.trimmingCharacters(in: .whitespacesAndNewlines)
        ) { return 0 }

        let content = fileEditor.editorContent
        let escaped = NSRegularExpression.escapedPattern(for: old)
        let pattern = "\\b\(escaped)\\b"
        let regex = try? NSRegularExpression(pattern: pattern)
        let ns = content as NSString
        return regex?.numberOfMatches(in: content, range: NSRange(location: 0, length: ns.length)) ?? 0
    }

    private func applyRename() {
        do {
            let result = try WorkspaceNavigationService.renameInCurrentBuffer(
                content: fileEditor.editorContent,
                identifier: appState.renameSymbolIdentifier,
                newName: newName
            )
            fileEditor.editorContent = result.updated
            close()
        } catch {
            appState.lastError = error.localizedDescription
        }
    }

    private func close() {
        isPresented = false
        appState.renameSymbolIdentifier = ""
        newName = ""
        previewReplacements = 0
    }
}
