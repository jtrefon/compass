import Foundation

enum FileToolParameterSchemaBuilder {
    static func modeProperty() -> [String: Any] {
        [
            "type": "string",
            "description": "One of: apply, propose. Default: apply.",
            "enum": ["apply", "propose"]
        ]
    }

    static func patchSetIdProperty() -> [String: Any] {
        [
            "type": "string",
            "description": "Patch set identifier to stage into when mode=propose."
        ]
    }

    static func pathProperty(description: String) -> [String: Any] {
        [
            "type": "string",
            "description": description
        ]
    }

    static func objectSchema(properties: [String: Any], required: [String]) -> [String: Any] {
        [
            "type": "object",
            "properties": properties,
            "required": required
        ]
    }
}
