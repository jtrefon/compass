import SwiftUI
import Combine

struct ProblemsView<Context: IDEContext>: View {
    @ObservedObject var store: DiagnosticsStore
    let context: Context
    @State private var clearSubscription: AnyCancellable?

    var body: some View {
        List {
            ForEach(store.diagnostics) { diagnostic in
                Button {
                    open(diagnostic)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: diagnostic.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                            .foregroundColor(diagnostic.severity == .error ? .red : .yellow)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(diagnostic.message)
                                .lineLimit(2)
                            Text(locationText(diagnostic))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, AppConstants.Layout.spacingXXS)
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear {
            clearSubscription = context.eventBus.subscribe(to: ProblemsClearRequestedEvent.self) { _ in
                store.clear()
            }
        }
        .onDisappear {
            clearSubscription = nil
        }
    }

    @MainActor
    private func open(_ diagnostic: Diagnostic) {
        guard let url = DiagnosticURLResolver.resolve(diagnostic, context: context) else { return }

        context.loadFile(from: url)
        context.fileEditor.selectLine(diagnostic.line)
    }

    private func locationText(_ diagnostic: Diagnostic) -> String {
        if let column = diagnostic.column {
            return "\(diagnostic.relativePath):\(diagnostic.line):\(column)"
        }
        return "\(diagnostic.relativePath):\(diagnostic.line)"
    }
}
