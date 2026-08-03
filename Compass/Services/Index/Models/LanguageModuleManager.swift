import Foundation
import Combine

/// Manages registration and activation of language modules.
@MainActor
public final class LanguageModuleManager: ObservableObject {
    public static let shared: LanguageModuleManager = {
        let modules: [LanguageModule] = [
            SimpleLanguageModule(id: .swift, fileExtensions: ["swift"]),
            SimpleLanguageModule(id: .javascript, fileExtensions: ["js", "jsx"]),
            SimpleLanguageModule(id: .typescript, fileExtensions: ["ts"]),
            SimpleLanguageModule(id: .tsx, fileExtensions: ["tsx"]),
            SimpleLanguageModule(id: .python, fileExtensions: ["py"]),
            SimpleLanguageModule(id: .php, fileExtensions: ["php", "phtml"]),
            SimpleLanguageModule(id: .html, fileExtensions: ["html", "htm"]),
            SimpleLanguageModule(id: .css, fileExtensions: ["css"]),
            SimpleLanguageModule(id: .json, fileExtensions: ["json"]),
        ]
        return LanguageModuleManager(
            modules: modules,
            settingsStore: SettingsStore(userDefaults: AppRuntimeEnvironment.userDefaults)
        )
    }()

    @Published private(set) var enabledModules: [CodeLanguage: LanguageModule] = [:]
    private var allModules: [CodeLanguage: LanguageModule] = [:]
    private var disabledCapabilitiesByLanguage: [CodeLanguage: Set<LanguageModuleCapability>] = [:]
    private let settingsStore: SettingsStore

    init(modules: [LanguageModule], settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        for module in modules {
            allModules[module.id] = module
        }
        setupInitialEnabledState()
    }

    public func register(_ module: LanguageModule) {
        allModules[module.id] = module
        updateEnabledModules()
    }

    public func getModule(for language: CodeLanguage) -> LanguageModule? {
        enabledModules[language]
    }

    public func getModule(forExtension ext: String) -> LanguageModule? {
        let normalized = ext.lowercased()
        return enabledModules.values.first { $0.fileExtensions.contains(normalized) }
    }

    public func isEnabled(_ language: CodeLanguage) -> Bool {
        enabledModules[language] != nil
    }

    public func toggleModule(_ language: CodeLanguage, enabled: Bool) {
        var enabledLangs = settingsStore.stringArray(
            forKey: AppConstantsStorage.enabledLanguageModulesKey
        ) ?? allModules.keys.map { $0.rawValue }

        if enabled {
            if !enabledLangs.contains(language.rawValue) {
                enabledLangs.append(language.rawValue)
            }
        } else {
            enabledLangs.removeAll { $0 == language.rawValue }
        }

        settingsStore.set(enabledLangs, forKey: AppConstantsStorage.enabledLanguageModulesKey)
        updateEnabledModules()
    }

    public func isCapabilityEnabled(_ capability: LanguageModuleCapability, for language: CodeLanguage) -> Bool {
        guard let module = allModules[language] else { return false }
        guard module.capabilities.contains(capability) else { return false }
        let disabled = disabledCapabilitiesByLanguage[language] ?? []
        return !disabled.contains(capability)
    }

    public func toggleCapability(
        _ capability: LanguageModuleCapability,
        for language: CodeLanguage,
        enabled: Bool
    ) {
        guard let module = allModules[language], module.capabilities.contains(capability) else { return }

        var disabled = disabledCapabilitiesByLanguage[language] ?? []
        if enabled {
            disabled.remove(capability)
        } else {
            disabled.insert(capability)
        }
        disabledCapabilitiesByLanguage[language] = disabled
        persistDisabledCapabilities()
    }

    public var availableLanguages: [CodeLanguage] {
        allModules.keys.sorted { $0.rawValue < $1.rawValue }
    }

    private func loadDisabledCapabilities() {
        guard let stored = settingsStore.dictionary(forKey: AppConstantsStorage.disabledLanguageModuleCapabilitiesKey) else {
            disabledCapabilitiesByLanguage = [:]
            return
        }
        var mapped: [CodeLanguage: Set<LanguageModuleCapability>] = [:]
        for (languageRaw, value) in stored {
            guard let language = CodeLanguage(rawValue: languageRaw) else { continue }
            guard let names = value as? [String] else { continue }
            mapped[language] = Set(names.compactMap { LanguageModuleCapability(rawValue: $0) })
        }
        disabledCapabilitiesByLanguage = mapped
    }

    private func persistDisabledCapabilities() {
        var serialized: [String: [String]] = [:]
        for (language, capabilities) in disabledCapabilitiesByLanguage {
            serialized[language.rawValue] = capabilities.map(\.rawValue).sorted()
        }
        settingsStore.set(serialized, forKey: AppConstantsStorage.disabledLanguageModuleCapabilitiesKey)
    }

    private func setupInitialEnabledState() {
        loadDisabledCapabilities()
        let allLangs = allModules.keys.map { $0.rawValue }
        if let stored = settingsStore.stringArray(forKey: AppConstantsStorage.enabledLanguageModulesKey) {
            var updated = stored
            var changed = false
            for lang in allLangs {
                if !updated.contains(lang) {
                    updated.append(lang)
                    changed = true
                }
            }
            if changed {
                settingsStore.set(updated, forKey: AppConstantsStorage.enabledLanguageModulesKey)
            }
        } else {
            settingsStore.set(allLangs, forKey: AppConstantsStorage.enabledLanguageModulesKey)
        }
        updateEnabledModules()
    }

    private func updateEnabledModules() {
        let enabledLangs = settingsStore.stringArray(
            forKey: AppConstantsStorage.enabledLanguageModulesKey
        ) ?? allModules.keys.map { $0.rawValue }
        enabledModules = allModules.filter { enabledLangs.contains($0.key.rawValue) }
    }
}

private struct SimpleLanguageModule: LanguageModule {
    let id: CodeLanguage
    let fileExtensions: [String]

    func parseSymbols(content: String, resourceId: String) -> [Symbol] {
        switch id {
        case .swift:
            return SwiftParser.parse(content: content, resourceId: resourceId)
        case .javascript:
            return JavaScriptParser.parse(content: content, resourceId: resourceId)
        case .typescript, .tsx:
            return TypeScriptParser.parse(content: content, resourceId: resourceId)
        case .python:
            return PythonParser.parse(content: content, resourceId: resourceId)
        case .php:
            return PHPParser.parse(content: content, resourceId: resourceId)
        default:
            return []
        }
    }

    func format(_ code: String) -> String {
        CodeFormatter.format(code, language: id)
    }
}
