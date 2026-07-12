// Vault view state — fetches GET /api/vault + POST /api/search from the app
// server, deriving the HTTP base from the SAME persisted server URL the chat uses
// (ws://host:10000/chat → http://host:10000, wss → https). Mirrors VaultPanel.svelte.
// Blank server URL → in-app sample data, exactly like the web's dev/mock fallback.

import Foundation
import Observation

@MainActor
@Observable
final class VaultViewModel {
    var info: VaultInfo?
    var loading = false
    var error: String?
    var isMock = false

    var query = ""
    var hits: [SearchHit]?
    var searching = false
    var searchError: String?

    private static let serverKey = "serverURL"  // shared with ChatViewModel

    /// HTTP base from the persisted ws/wss server URL (ws→http, wss→https, no path).
    private var httpBase: URL? {
        let s = (UserDefaults.standard.string(forKey: Self.serverKey) ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, var c = URLComponents(string: s) else { return nil }
        c.scheme = (c.scheme == "wss") ? "https" : "http"
        c.path = ""
        c.query = nil
        return c.url
    }

    private static let mock = VaultInfo(
        vaultDir: "~/.config/millfolio/vault", sourceDir: "~/.config/millfolio/vault",
        dirMismatch: false, configDir: "~/.config/millfolio", indexed: true,
        embeddingDim: 1024, fileCount: 2, indexedFileCount: 2, chunkCount: 84,
        dbSizeBytes: 1_900_000,
        files: [
            VaultFile(alias: "file_0", name: "accounts.csv", kind: "csv", sizeBytes: 20_480, chunks: 18),
            VaultFile(alias: "file_1", name: "statement.pdf", kind: "pdf", sizeBytes: 482_000, chunks: 66),
        ])

    /// Resolve a hit's frontier-safe alias back to its real filename (from the manifest).
    func name(for alias: String) -> String {
        info?.files.first { $0.alias == alias }?.name ?? alias
    }

    func load() async {
        loading = true
        error = nil
        guard let base = httpBase else {
            info = Self.mock
            isMock = true
            loading = false
            return
        }
        isMock = false
        do {
            let (data, resp) = try await URLSession.shared.data(
                from: base.appendingPathComponent("api/vault"))
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            info = try JSONDecoder().decode(VaultInfo.self, from: data)
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { hits = nil; return }
        searching = true
        searchError = nil
        guard let base = httpBase else {
            hits = [SearchHit(alias: "file_0", score: 0.74,
                              text: "Sample hit — set a server in Settings to search your real vault.")]
            searching = false
            return
        }
        do {
            var req = URLRequest(url: base.appendingPathComponent("api/search"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try encodeSearchBody(query: q, k: 8)
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            hits = try decodeSearchHits(data)
        } catch {
            searchError = error.localizedDescription
            hits = nil
        }
        searching = false
    }

    func clearSearch() {
        query = ""
        hits = nil
        searchError = nil
    }
}
