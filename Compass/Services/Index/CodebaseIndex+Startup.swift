import Foundation

extension CodebaseIndex {
    public func hasPersistedIndexData() async -> Bool {
        let allowed = AppConstantsIndexing.allowedExtensions
        let indexedCount = (try? await database.getIndexedResourceCountScoped(
            projectRoot: projectRoot,
            allowedExtensions: allowed
        )) ?? 0
        return indexedCount > 0
    }
}
