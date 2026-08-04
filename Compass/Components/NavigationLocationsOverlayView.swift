import SwiftUI
import AppKit

struct NavigationLocationsOverlayView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var workspace: WorkspaceStateManager
    @ObservedObject private var fileEditor: FileEditorStateManager
    @Binding var isPresented: Bool

    init(appState: AppState, isPresented: Binding<Bool>) {
        self.appState = appState
        self._workspace = ObservedObject(wrappedValue: appState.workspace)
        self._fileEditor = ObservedObject(wrappedValue: appState.fileEditor)
        self._isPresented = isPresented
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Text(appState.navigationLocationsTitle)
                    .font(.headline)

                Spacer()

                Button(localized("common.close")) {
                    close()
                }
            }

            List {
                ForEach(appState.navigationLocations) { loc in
                    Button(action: {
                        open(loc, openToSide: NSEvent.modifierFlags.contains(.command))
                    }) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(loc.relativePath):\(loc.line)")
                                .font(.body.monospaced())
                            if !loc.snippet.isEmpty {
                                Text(loc.snippet)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(minWidth: AppConstants.Overlay.wideListMinWidth, minHeight: AppConstants.Overlay.wideListMinHeight)
        }
        .padding(AppConstants.Overlay.containerPadding)
        .nativeGlassBackground(.popover, cornerRadius: AppConstants.Overlay.containerCornerRadius)
        .shadow(radius: AppConstants.Overlay.containerShadowRadius)
        .onExitCommand {
            close()
        }
    }

    private func open(_ loc: WorkspaceCodeLocation, openToSide: Bool) {
        guard let root = workspace.currentDirectory?.standardizedFileURL else { return }

        do {
            let url = try appState.workspaceService
                .makePathValidator(projectRoot: root)
                .validateAndResolve(loc.relativePath)
            if openToSide {
                fileEditor.openInOtherPane(from: url)
            } else {
                appState.loadFile(from: url)
            }
            fileEditor.selectLine(loc.line)
            close()
        } catch {
            appState.lastError = error.localizedDescription
        }
    }

    private func close() {
        isPresented = false
        appState.navigationLocations = []
        appState.navigationLocationsTitle = ""
    }
}
