import XCTest
@testable import Compass

/// Full-stack agentic refactor: converts a real ReactJS todo app (multi-file,
/// JSX components + module imports) into TypeScript. Exercises file renames
/// (bash mv), typed rewrites (write), config edits (package.json/tsconfig),
/// and compile verification (npm install + tsc --noEmit) through the real
/// agent pipeline.
@MainActor
final class ReactTSTodoHarnessTests: XCTestCase {

    /// Copies the fixture app (CompassHarnessTests/Fixtures/ReactJSTodo) into
    /// the runtime's temp project root.
    private func makeTodoProject() async throws -> HarnessRuntime.Runtime {
        let runtime = try await HarnessRuntime.makeRuntime()
        runtime.manager.currentMode = .coder

        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ReactJSTodo")

        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw NSError(domain: "ReactTSTodoHarnessTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Fixture missing at \(fixture.path)"])
        }

        try copyDirectory(from: fixture, to: runtime.projectRoot)
        return runtime
    }

    private func copyDirectory(from source: URL, to destination: URL) throws {
        let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil)!
        for case let fileURL as URL in enumerator {
            let relative = fileURL.path.replacingOccurrences(of: source.path, with: "")
            let target = destination.appendingPathComponent(relative)
            let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: fileURL, to: target)
            }
        }
    }

    func testRefactorReactTodoToTypeScript() async throws {
        let runtime = try await makeTodoProject()
        let manager = runtime.manager
        defer {
            // Keep the project when the run produced no tool activity so the
            // failure (trace + app log) can be inspected.
            let toolCount = manager.messages.filter { $0.isToolExecution }.count
            if toolCount > 0, !hasFailures() {
                try? FileManager.default.removeItem(at: runtime.projectRoot)
            } else {
                print("[HARNESS] project kept for inspection: \(runtime.projectRoot.path)")
            }
        }

        let prompt = """
        Refactor this ReactJS todo app from JavaScript to TypeScript:
        1. Convert every .js file under src/ to TypeScript: .tsx for files that contain JSX, .ts for plain JS. Rename the files, then rewrite them with proper types — a Todo type (id, text, done), typed props for every component (TodoList, TodoItem, AddTodo), and typed event handlers.
        2. Update package.json: add typescript, @types/react and @types/react-dom as devDependencies, and make the build script run the TypeScript compiler before building (e.g. "tsc && react-scripts build" or "tsc --noEmit && react-scripts build").
        3. Create tsconfig.json with "jsx": "react-jsx", "noEmit": true, and include src.
        4. Verify the refactor compiles: run npm install (if needed), then npx tsc --noEmit, and fix every type error until it passes with no errors.
        5. When everything compiles, summarize exactly what you changed and confirm tsc passes.
        """

        let completed = try await HarnessRuntime.sendAndWait(prompt, manager: manager, timeout: 1200)
        XCTAssertTrue(completed, "Refactor run must complete within the deadline")

        logTelemetry(manager, runtime: runtime)

        let src = runtime.projectRoot.appendingPathComponent("src")

        // 1. Every source file converted — no JS left.
        let jsLeft = (try? HarnessRuntime.listAllFiles(under: src).filter { $0.hasSuffix(".js") || $0.hasSuffix(".jsx") }) ?? []
        XCTAssertTrue(jsLeft.isEmpty, "JavaScript files must all be converted, remaining: \(jsLeft)")

        // 2. TS/TSX equivalents exist for every module.
        let expected = [
            "App.tsx", "index.tsx", "components/TodoList.tsx",
            "components/TodoItem.tsx", "components/AddTodo.tsx", "utils/storage.ts"
        ]
        for rel in expected {
            let exists = FileManager.default.fileExists(
                atPath: src.appendingPathComponent(rel).path
            )
            XCTAssertTrue(exists, "Expected converted file src/\(rel) is missing")
            HarnessRuntime.logCheck(exists, label: "src/\(rel) exists")
        }

        // 3. Real types were added (not a mechanical extension rename).
        let appPath = src.appendingPathComponent("App.tsx")
        let appContent = FileManager.default.fileExists(atPath: appPath.path) ? (try? String(contentsOf: appPath, encoding: .utf8)) ?? "" : ""
        let hasTodoType = appContent.contains("interface Todo") || appContent.contains("type Todo")
        XCTAssertTrue(hasTodoType, "App.tsx must define a Todo type")
        HarnessRuntime.logCheck(hasTodoType, label: "Todo type defined")

        let listPath = src.appendingPathComponent("components/TodoList.tsx")
        let listContent = FileManager.default.fileExists(atPath: listPath.path) ? (try? String(contentsOf: listPath, encoding: .utf8)) ?? "" : ""
        let typedProps = listContent.contains(": Todo") || listContent.contains("Todo[]") || listContent.contains(": Todo[]")
        XCTAssertTrue(typedProps, "TodoList props must be typed")
        HarnessRuntime.logCheck(typedProps, label: "TodoList props typed")

        let itemPath = src.appendingPathComponent("components/TodoItem.tsx")
        let itemContent = FileManager.default.fileExists(atPath: itemPath.path) ? (try? String(contentsOf: itemPath, encoding: .utf8)) ?? "" : ""
        XCTAssertTrue(itemContent.contains("Todo"), "TodoItem must reference the Todo type")

        // 4. Config updated.
        let pkg = try String(contentsOf: runtime.projectRoot.appendingPathComponent("package.json"), encoding: .utf8)
        XCTAssertTrue(pkg.contains("typescript"), "package.json must include typescript")
        XCTAssertTrue(pkg.contains("@types/react"), "package.json must include @types/react")
        HarnessRuntime.logCheck(true, label: "package.json has typescript + @types")

        let tsconfigExists = FileManager.default.fileExists(
            atPath: runtime.projectRoot.appendingPathComponent("tsconfig.json").path
        )
        XCTAssertTrue(tsconfigExists, "tsconfig.json must exist")
        if tsconfigExists {
            let tsconfig = try String(contentsOf: runtime.projectRoot.appendingPathComponent("tsconfig.json"), encoding: .utf8)
            XCTAssertTrue(tsconfig.contains("react-jsx"), "tsconfig must use react-jsx")
        }

        HarnessRuntime.assertNoRawToolMarkup(manager)
        logTelemetry(manager, runtime: runtime)
    }

    private var failures: [String] = []

    private func hasFailures() -> Bool {
        !failures.isEmpty
    }

    private func check(_ condition: Bool, _ label: String) {
        if condition {
            print("[HARNESS] \(checkMark) \(label)")
        } else {
            failures.append(label)
            print("[HARNESS] \(crossMark) \(label)")
        }
    }

    private var checkMark: String { "\u{2713}" }
    private var crossMark: String { "\u{2717}" }

    private func logTelemetry(_ manager: ConversationManager, runtime: HarnessRuntime.Runtime) {
        let store = runtime.container.settingsStore
        let model = store.string(forKey: "OpenRouterModel") ?? "(default)"
        let offline = store.bool(forKey: "AI.OfflineModeEnabled", default: false)
        print("[HARNESS] mode=\(manager.currentMode.rawValue) provider=\(offline ? "local-mlx" : "cloud") model=\(model)")
        print("[HARNESS] apiKeyConfigured=\(!(store.string(forKey: "OpenRouterAPIKey")?.isEmpty ?? true))")
        let toolMsgs = manager.messages.filter { $0.isToolExecution }
        let names = Dictionary(grouping: toolMsgs, by: { $0.toolName ?? "?" }).mapValues { $0.count }
        print("\n[HARNESS] messages=\(manager.messages.count) tools=\(toolMsgs.count)")
        for (n, c) in names.sorted(by: { $0.value > $1.value }) { print("[HARNESS]   \(n): \(c)") }
        for m in manager.messages.filter({ $0.role == .assistant && !$0.isDraft }).suffix(2) {
            print("[HARNESS]   assistant: \"\(m.content.prefix(400))\"")
        }
        let files = HarnessRuntime.listAllFiles(under: runtime.projectRoot)
        print("[HARNESS] final project files:\n  \(files.joined(separator: "\n  "))")
        print("\n[HARNESS] transcript:")
        for m in manager.messages {
            let role = m.role.rawValue
            if m.isToolExecution {
                let out = m.content.prefix(200)
                print("  [\(role):\(m.toolName ?? "?")] target=\(m.targetFile ?? "") out=\(out)")
            } else if role == "assistant" {
                print("  [assistant] draft=\(m.isDraft) len=\(m.content.count) \(m.content.prefix(400))")
            } else {
                print("  [\(role)] \(m.content.prefix(300))")
            }
        }
        let runsDir = runtime.projectRoot.appendingPathComponent(".ide/orchestration/runs")
        if let runs = try? FileManager.default.contentsOfDirectory(atPath: runsDir.path) {
            for run in runs {
                print("\n[HARNESS] RUN \(run):")
                if let lines = try? String(contentsOf: runsDir.appendingPathComponent(run), encoding: .utf8) {
                    for line in lines.split(separator: "\n") {
                        if let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                            let phase = d["phase"] as? String ?? "?"
                            let iter = d["iteration"] as? Int ?? 0
                            let calls = (d["toolCalls"] as? [[String: Any]]) ?? []
                            let names = calls.compactMap { $0["name"] as? String }.joined(separator: ",")
                            let failure = d["failureReason"] as? String ?? ""
                            let draft = (d["assistantDraft"] as? String ?? "").prefix(120)
                            print("  iter \(iter) \(phase) calls=\(names) failure=\(failure) draft=\(draft)")
                        }
                    }
                }
            }
        }
    }
}
