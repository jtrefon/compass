import SwiftUI
import Foundation

struct CommandPaletteItem: Identifiable {
    let id: String
    let command: CommandID
    let title: String
    let subtitle: String
}

enum CommandPaletteScoring {
    static func score(candidate: String, query: String) -> Int {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if needle.isEmpty { return 0 }

        let hay = candidate.lowercased()
        if hay == needle { return 1_000 }
        if hay.hasPrefix(needle) { return 800 }
        if hay.contains(needle) { return 600 }

        // Substring match on last path component-ish segment (after '.')
        let lastSegment = hay.split(separator: ".").last.map(String.init) ?? hay
        if lastSegment == needle { return 700 }
        if lastSegment.hasPrefix(needle) { return 500 }
        if lastSegment.contains(needle) { return 350 }

        return 0
    }
}

struct CommandPaletteOverlayView: View {
    let commandRegistry: CommandRegistry
    @Binding var isPresented: Bool

    @State private var query: String = ""
    @State private var items: [CommandPaletteItem] = []

    var body: some View {
        OverlayScaffold(
            configuration: OverlayScaffoldConfiguration(
                title: localized("command_palette.title"),
                placeholder: localized("command_palette.placeholder"),
                textFieldMinWidth: AppConstants.Overlay.textFieldMinWidth,
                showsProgress: false,
                onSubmit: {
                    runFirstMatch()
                },
                onClose: {
                    close()
                }
            ),
            query: $query
        ) {
            List {
                ForEach(items) { item in
                    Button(action: {
                        run(item.command)
                    }) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .lineLimit(1)
                            Text(item.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(minWidth: AppConstants.Overlay.listMinWidth, minHeight: AppConstants.Overlay.listMinHeight)
        }
        .onAppear {
            query = ""
            refreshItems()
        }
        .onChange(of: query) { _, _ in
            refreshItems()
        }
        .onExitCommand {
            close()
        }
    }

    private func refreshItems() {
        let all = commandRegistry.registeredCommandIDs()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            items = all.prefix(60).map { id in
                CommandPaletteItem(
                    id: id.value,
                    command: id,
                    title: prettyTitle(for: id.value),
                    subtitle: id.value
                )
            }
            return
        }

        var scored: [(CommandID, Int)] = []
        scored.reserveCapacity(all.count)

        for command in all {
            let score = CommandPaletteScoring.score(candidate: command.value, query: trimmed)
            if score > 0 {
                scored.append((command, score))
            }
        }

        scored.sort { left, right in
            if left.1 != right.1 { return left.1 > right.1 }
            return left.0.value < right.0.value
        }

        items = scored.prefix(60).map { (cmd, _) in
            CommandPaletteItem(
                id: cmd.value,
                command: cmd,
                title: prettyTitle(for: cmd.value),
                subtitle: cmd.value
            )
        }
    }

    private func prettyTitle(for command: String) -> String {
        let parts = command.split(separator: ".")
        guard let last = parts.last else { return command }
        return last.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func runFirstMatch() {
        guard let first = items.first else { return }
        run(first.command)
    }

    private func run(_ command: CommandID) {
        Task {
            try? await commandRegistry.execute(command)
            close()
        }
    }

    private func close() {
        isPresented = false
        query = ""
        items = []
    }
}
