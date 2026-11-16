import Foundation
import NaturalLanguage

protocol EmbeddingProvider {
    var identifier: String { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}

// MARK: - Remote (OpenAI-compatible /embeddings)

final class RemoteEmbedding: EmbeddingProvider {
    let identifier: String
    private let config: ProviderConfig
    private let apiKey: String
    private let model: String

    init(config: ProviderConfig, apiKey: String, model: String) {
        self.config = config
        self.apiKey = apiKey
        self.model = model
        self.identifier = "remote.\(model)"
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        let url = try ProviderSupport.openAIEmbeddingURL(base: config.baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = ["model": model, "input": texts]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await HTTPClient.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw LLMError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }

        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rows = object["data"] as? [[String: Any]]
        else {
            throw LLMError.decoding("响应缺少 data 数组")
        }

        return rows.compactMap { row -> [Float]? in
            if let values = row["embedding"] as? [Double] {
                return values.map { Float($0) }
            }
            if let numbers = row["embedding"] as? [NSNumber] {
                return numbers.map { $0.floatValue }
            }
            return nil
        }
    }
}

// MARK: - Apple on-device sentence embedding

final class AppleSentenceEmbedding: EmbeddingProvider {
    let identifier: String
    private let embedding: NLEmbedding

    init?(language: NLLanguage) {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: language) else {
            return nil
        }
        self.embedding = embedding
        self.identifier = "apple.sentence.\(language.rawValue)"
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            (embedding.vector(for: text) ?? []).map { Float($0) }
        }
    }
}

// MARK: - Hybrid

/// Tries each provider in order and keeps the first one that returns usable
/// vectors. Remote first (better recall, especially for Chinese), on-device as
/// the offline fallback, and nil when neither works — recall then degrades to
/// keyword search rather than failing the message.
final class HybridEmbedder {
    private let providers: [EmbeddingProvider]

    init(providers: [EmbeddingProvider] = []) {
        self.providers = providers
    }

    var isAvailable: Bool { !providers.isEmpty }

    var activeIdentifier: String? { providers.first?.identifier }

    func embed(_ texts: [String]) async -> (vectors: [[Float]], identifier: String)? {
        guard !texts.isEmpty else { return ([], "none") }

        for provider in providers {
            guard let vectors = try? await provider.embed(texts) else { continue }
            guard vectors.count == texts.count else { continue }

            let dimension = vectors.first(where: { !$0.isEmpty })?.count ?? 0
            guard dimension > 0 else { continue }
            guard vectors.allSatisfy({ $0.isEmpty || $0.count == dimension }) else { continue }

            let normalized = vectors.map { vector -> [Float] in
                vector.isEmpty ? [Float](repeating: 0, count: dimension) : vector
            }
            return (normalized, provider.identifier)
        }
        return nil
    }
}
