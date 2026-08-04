import Foundation
import Combine

@MainActor
final class DiagnosticsStore: ObservableObject {
    @Published private(set) var diagnostics: [Diagnostic] = []
    @Published private(set) var selectedDiagnosticID: String?

    private var cancellables = Set<AnyCancellable>()

    init(eventBus: EventBusProtocol) {
        eventBus.subscribe(to: TerminalOutputProducedEvent.self) { [weak self] event in
            guard let self else { return }
            let new = DiagnosticsParser.parseOutputChunk(event.output)
            guard !new.isEmpty else { return }

            // Append and de-dupe by id (stable across runs), keep most recent last.
            var map: [String: Diagnostic] = Dictionary(uniqueKeysWithValues: self.diagnostics.map { ($0.id, $0) })
            for diagnostic in new {
                map[diagnostic.id] = diagnostic
            }
            self.diagnostics = Array(map.values).sorted { left, right in
                if left.relativePath != right.relativePath { return left.relativePath < right.relativePath }
                if left.line != right.line { return left.line < right.line }
                return (left.column ?? 0) < (right.column ?? 0)
            }

            if self.selectedDiagnosticID == nil {
                self.selectedDiagnosticID = self.diagnostics.first?.id
            }

            eventBus.publish(DiagnosticsUpdatedEvent(diagnostics: self.diagnostics))
        }.store(in: &cancellables)
    }

    func clear() {
        diagnostics = []
        selectedDiagnosticID = nil
    }

    func replace(with newDiagnostics: [Diagnostic]) {
        diagnostics = newDiagnostics.sorted { left, right in
            if left.relativePath != right.relativePath { return left.relativePath < right.relativePath }
            if left.line != right.line { return left.line < right.line }
            return (left.column ?? 0) < (right.column ?? 0)
        }
        selectedDiagnosticID = diagnostics.first?.id
    }

    func upsert(_ incomingDiagnostics: [Diagnostic], replacingPath relativePath: String) {
        var map: [String: Diagnostic] = Dictionary(uniqueKeysWithValues: diagnostics.map { ($0.id, $0) })

        for existing in diagnostics where existing.relativePath == relativePath {
            map.removeValue(forKey: existing.id)
        }
        for diagnostic in incomingDiagnostics {
            map[diagnostic.id] = diagnostic
        }

        diagnostics = Array(map.values).sorted { left, right in
            if left.relativePath != right.relativePath { return left.relativePath < right.relativePath }
            if left.line != right.line { return left.line < right.line }
            return (left.column ?? 0) < (right.column ?? 0)
        }
        if selectedDiagnosticID == nil {
            selectedDiagnosticID = diagnostics.first?.id
        }
    }

    func selectedDiagnostic() -> Diagnostic? {
        guard let id = selectedDiagnosticID else { return diagnostics.first }
        return diagnostics.first(where: { $0.id == id }) ?? diagnostics.first
    }

    func selectNext() -> Diagnostic? {
        guard !diagnostics.isEmpty else { return nil }
        let currentIndex: Int
        if let id = selectedDiagnosticID {
            if let idx = diagnostics.firstIndex(where: { $0.id == id }) {
                currentIndex = idx
            } else {
                currentIndex = 0
            }
        } else {
            currentIndex = 0
        }

        let nextIndex = min(diagnostics.count - 1, currentIndex + 1)
        selectedDiagnosticID = diagnostics[nextIndex].id
        return diagnostics[nextIndex]
    }

    func selectPrevious() -> Diagnostic? {
        guard !diagnostics.isEmpty else { return nil }
        let currentIndex: Int
        if let id = selectedDiagnosticID {
            if let idx = diagnostics.firstIndex(where: { $0.id == id }) {
                currentIndex = idx
            } else {
                currentIndex = 0
            }
        } else {
            currentIndex = 0
        }

        let prevIndex = max(0, currentIndex - 1)
        selectedDiagnosticID = diagnostics[prevIndex].id
        return diagnostics[prevIndex]
    }
}
