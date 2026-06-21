// Vault view data — mirrors the GET /api/vault + POST /api/search JSON the app
// server returns (web/src/lib/components/VaultPanel.svelte). camelCase keys match
// the server payload, so no key strategy is needed.

import Foundation

struct VaultFile: Codable, Identifiable {
    let alias: String
    let name: String
    let kind: String
    let sizeBytes: Int
    let chunks: Int
    var id: String { alias }
}

struct VaultInfo: Codable {
    let vaultDir: String     // the dir the server serves (chat/ask read this)
    let sourceDir: String    // the dir the index was actually built from
    let dirMismatch: Bool    // sourceDir != vaultDir → chat/ask point at the wrong files
    let configDir: String
    let indexed: Bool
    let embeddingDim: Int
    let fileCount: Int
    let indexedFileCount: Int
    let chunkCount: Int
    let dbSizeBytes: Int
    let files: [VaultFile]
}

struct SearchHit: Codable, Identifiable {
    let alias: String
    let score: Double
    let text: String
    var id: String { "\(alias)-\(score)" }
}

private struct SearchRequest: Codable { let query: String; let k: Int }
private struct SearchResponse: Codable { let hits: [SearchHit] }

/// Encode a search request body. (Kept here so VaultModels owns the wire shapes.)
func encodeSearchBody(query: String, k: Int) throws -> Data {
    try JSONEncoder().encode(SearchRequest(query: query, k: k))
}

/// Decode a /api/search response into its hits.
func decodeSearchHits(_ data: Data) throws -> [SearchHit] {
    try JSONDecoder().decode(SearchResponse.self, from: data).hits
}
