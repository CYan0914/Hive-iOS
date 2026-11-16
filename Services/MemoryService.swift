import Foundation

/// The three shared layers plus the scratchpad, and the retrieval that decides
/// what a model actually sees.
///
/// The important rule: "shared memory" never means "the whole table goes into
/// the prompt". Recall is scored and truncated; anything that does not fit is
/// simply not in this turn's context.
final class MemoryService {
    private let store: Store
    var embedder: HybridEmbedder

    init(store: Store, embedder: HybridEmbedder = HybridEmbedder()) {
        self.store = store
        self.embedder = embedder
    }

    @discardableResult
    func remember(
        content: String,
        layer: MemoryLayer,
        sessionID: String?,
        importance: Double = 0.5
    ) async -> MemoryRecord? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let record = MemoryRecord(
            layer: layer,
            sessionID: sessionID,
            content: trimmed,
            importance: importance
        )

        var vector: [Float]?
        var model: String?
        if let result = await embedder.embed([trimmed]) {
            vector = result.vectors.first
            model = result.identifier
        }

        do {
            try store.insertMemory(record, embedding: vector, embeddingModel: model)
            return record
        } catch {
            return nil
        }
    }

    func recall(query: String, sessionID: String?, limit: Int = 6) async -> [MemoryRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let candidates = (try? store.memoryCandidates(sessionID: sessionID)) ?? []

        if let queryVector = (await embedder.embed([trimmed]))?.vectors.first,
           !queryVector.isEmpty {
            var scored: [(record: MemoryRecord, score: Float)] = []
            for candidate in candidates {
                guard let vector = candidate.embedding,
                      vector.count == queryVector.count else { continue }
                let similarity = VectorMath.cosine(queryVector, vector)
                // Importance breaks ties between near-identical similarities;
                // it is a nudge, not a substitute for relevance.
                let score = similarity * 0.85 + Float(candidate.record.importance) * 0.15
                scored.append((candidate.record, score))
            }
            if !scored.isEmpty {
                return scored
                    .sorted { $0.score > $1.score }
                    .prefix(limit)
                    .map { $0.record }
            }
        }

        let keyword = Self.longestKeyword(trimmed)
        guard !keyword.isEmpty else { return [] }
        return (try? store.keywordMemorySearch(sessionID: sessionID, keyword: keyword, limit: limit)) ?? []
    }

    /// Rendered into the system prompt. Empty string when nothing is relevant,
    /// so the caller can skip the whole section.
    func contextBlock(query: String, sessionID: String?) async -> String {
        let records = await recall(query: query, sessionID: sessionID)
        guard !records.isEmpty else { return "" }
        return records
            .map { "- [\($0.layer.displayName)] \($0.content)" }
            .joined(separator: "\n")
    }

    private static func longestKeyword(_ text: String) -> String {
        let separators = " \n\t，。！？、；：,.!?;:\"'()[]【】"
        let pieces = text.split(whereSeparator: { separators.contains($0) })
        return pieces.max(by: { $0.count < $1.count }).map(String.init) ?? ""
    }
}
