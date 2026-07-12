// Vault view — indexed files + LanceDB stats + semantic search. Mirrors
// web/src/lib/components/VaultPanel.svelte: a search box (results replace the file
// list), stat cards, a dir-mismatch warning, and a per-file table.

import SwiftUI

struct VaultView: View {
    @Bindable var model: VaultViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.loading && model.info == nil {
                    Text("Loading…").foregroundStyle(Theme.textDim)
                } else if let error = model.error {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Couldn't load the vault: \(error)").foregroundStyle(Theme.err)
                        Text("Is the app server running? Set its address in Settings.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                    }
                } else if let info = model.info {
                    if model.isMock {
                        banner("Sample data — set a server in Settings to see your real vault.", warn: false)
                    }
                    if info.dirMismatch {
                        banner("⚠ Indexed from \(info.sourceDir) but serving \(info.vaultDir). "
                               + "Chat & Ask read the served folder — re-index it, or point the app at the indexed one.",
                               warn: true)
                    }
                    searchBar
                    if let searchError = model.searchError {
                        banner("Search failed: \(searchError)", warn: true)
                    }
                    if let hits = model.hits {
                        results(hits)
                    } else {
                        stats(info)
                        paths(info)
                        files(info)
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.surface)
        .task { if model.info == nil { await model.load() } }
        .refreshable { await model.load() }
    }

    // MARK: search

    private var searchBar: some View {
        HStack(spacing: 8) {
            TextField("Search your vault…", text: $model.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { Task { await model.runSearch() } }
                .padding(9)
                .background(Theme.bg)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border))
                .foregroundStyle(Theme.text)
            Button { Task { await model.runSearch() } } label: {
                Text(model.searching ? "…" : "Search").fontWeight(.semibold)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Theme.accent).foregroundStyle(Theme.onAccent)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            }
            .disabled(model.searching || model.query.trimmingCharacters(in: .whitespaces).isEmpty)
            if model.hits != nil {
                Button("Clear") { model.clearSearch() }
                    .foregroundStyle(Theme.textDim)
            }
        }
    }

    private func results(_ hits: [SearchHit]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if hits.isEmpty {
                Text("No matches.").foregroundStyle(Theme.textDim)
            } else {
                ForEach(hits) { h in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(model.name(for: h.alias)).fontWeight(.semibold).foregroundStyle(Theme.text)
                            Spacer()
                            Text(String(format: "%.3f", h.score))
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textDim)
                        }
                        Text(h.text).font(.system(size: 12.5)).foregroundStyle(Theme.textDim)
                            .lineLimit(6)
                    }
                    .padding(10)
                    .background(Theme.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border))
                }
            }
        }
    }

    // MARK: stats / paths / files

    private func stats(_ info: VaultInfo) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
            stat("Files", "\(info.fileCount)")
            stat("Indexed chunks", "\(info.chunkCount)")
            stat("Index size", fmtBytes(info.dbSizeBytes))
            stat("Embedding dim", "\(info.embeddingDim)")
            statStatus(info.indexed)
            stat("Indexed files", "\(info.indexedFileCount)")
        }
    }

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(k.uppercased()).font(.system(size: 10)).foregroundStyle(Theme.textDim)
            Text(v).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10).background(Theme.surface2)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border))
    }

    private func statStatus(_ indexed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("STATUS").font(.system(size: 10)).foregroundStyle(Theme.textDim)
            HStack(spacing: 6) {
                Circle().fill(indexed ? Theme.ok : Theme.warn).frame(width: 8, height: 8)
                Text(indexed ? "indexed" : "not indexed").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10).background(Theme.surface2)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border))
    }

    private func paths(_ info: VaultInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            pathRow("Indexed from", info.sourceDir.isEmpty ? info.vaultDir : info.sourceDir, warn: false)
            pathRow("Serving", info.vaultDir, warn: info.dirMismatch)
            pathRow("Index", "\(info.configDir)/index.db", warn: false)
        }
    }

    private func pathRow(_ k: String, _ v: String, warn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k.uppercased()).font(.system(size: 10)).foregroundStyle(Theme.textDim)
            Text(v).font(.system(size: 12, design: .monospaced))
                .foregroundStyle(warn ? Theme.warn : Theme.textDim)
        }
    }

    @ViewBuilder
    private func files(_ info: VaultInfo) -> some View {
        if info.files.isEmpty {
            Text("No indexable files yet. Add .csv / .pdf / .md to the vault, then run `mill index`.")
                .font(.system(size: 13)).foregroundStyle(Theme.textDim).padding(.top, 8)
        } else {
            VStack(spacing: 0) {
                ForEach(info.files) { f in
                    HStack {
                        Text(f.name).foregroundStyle(Theme.text).lineLimit(1)
                        Spacer()
                        Text(f.kind.uppercased()).font(.system(size: 10))
                            .padding(.horizontal, 7).padding(.vertical, 1)
                            .background(Theme.surface2).clipShape(Capsule())
                            .foregroundStyle(kindColor(f.kind))
                        Text(fmtBytes(f.sizeBytes)).font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.textDim).frame(width: 64, alignment: .trailing)
                        Text("\(f.chunks)").font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.textDim).frame(width: 44, alignment: .trailing)
                    }
                    .padding(.vertical, 8)
                    Divider().overlay(Theme.border)
                }
            }
        }
    }

    // MARK: helpers

    private func banner(_ text: String, warn: Bool) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(warn ? Theme.warn : Theme.textDim)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(warn ? Color.clear : Theme.surface2)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius)
                .stroke(warn ? Theme.warn : Color.clear))
    }

    private func kindColor(_ kind: String) -> Color {
        switch kind {
        case "csv": return Theme.accent
        case "pdf": return Theme.warn
        case "md": return Theme.ok
        default: return Theme.textDim
        }
    }

    private func fmtBytes(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var v = Double(n) / 1024, i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        return String(format: v < 10 ? "%.1f %@" : "%.0f %@", v, units[i])
    }
}
