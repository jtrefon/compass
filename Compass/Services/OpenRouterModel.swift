import Foundation

struct OpenRouterModel: Identifiable, Decodable, Hashable {
    struct Pricing: Decodable, Hashable {
        let prompt: String?
        let completion: String?
    }

    let id: String
    let name: String?
    let contextLength: Int?
    let pricing: Pricing?

    var displayName: String {
        name ?? id
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case contextLength = "context_length"
        case maxContextLength = "max_context_length"
        case pricing
    }

    init(id: String, name: String? = nil, contextLength: Int? = nil, pricing: Pricing? = nil) {
        self.id = id
        self.name = name
        self.contextLength = contextLength
        self.pricing = pricing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        pricing = try container.decodeIfPresent(Pricing.self, forKey: .pricing)
        // Some servers (Ollama, llama.cpp) use max_context_length instead of context_length
        if let maxCtx = try container.decodeIfPresent(Int.self, forKey: .maxContextLength) {
            contextLength = maxCtx
        } else {
            contextLength = try container.decodeIfPresent(Int.self, forKey: .contextLength)
        }
    }
}
