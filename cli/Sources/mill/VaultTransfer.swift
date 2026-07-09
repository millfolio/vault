import Foundation
import Darwin
import Security
import ArgumentParser

// mill export / mill import — move the WHOLE vault between Macs as ONE
// encrypted file: the derived state (the data dir: manifest.tsv,
// transactions.tsv, chunks.tsv, index.db, categories.txt, the JSONL
// histories) AND the indexed source documents.
//
// Archive layout (inside the DMG):
//   data/       — the filtered data dir
//   documents/  — every file the manifest indexes, at its HOME-RELATIVE path
//                 (documents/vault/st1.pdf ← ~/vault/st1.pdf), so import can
//                 restore them under the other Mac's home and the doc viewer +
//                 re-index find them at the paths the manifest expects.
//
// Design:
//   • The archive is an AES-256 encrypted DMG made with `hdiutil` — Apple's
//     crypto, no new dependency, mountable anywhere for inspection.
//   • Documents are copied MANIFEST-DRIVEN (exactly the indexed files, never a
//     whole folder walk), and only from under $HOME — a source dir outside the
//     home folder is warned about and skipped (its rows keep their absolute
//     path and still resolve if that path exists on the other Mac).
//   • The passphrase lives in the Keychain (generic password, service
//     app.millfolio.vault-export), created random on first export and marked
//     synchronizable so iCloud Keychain carries it to the second Mac. If the
//     synchronizable add is refused (unsigned binary / no iCloud), it falls
//     back to a local item and `--show-passphrase` prints it for manual entry.
//   • MACHINE-LOCAL files never travel: .anthropic-key / .reveal-secret are
//     excluded from export AND preserved on import; the transient work queue
//     and lock/scratch files are excluded.
//   • Paths inside the state are home-relative (`~/…`) as of the same change
//     that added these commands; import also normalizes LEGACY absolute
//     `/Users/<name>/…` values in manifest.tsv + indexed-paths.json so old
//     exports land correctly under a different username.

// ── shared bits ───────────────────────────────────────────────────────────────

/// $HOME first, like the Mojo side's `contract_home`/`expand_home` (they read
/// `getenv("HOME")`) — NSHomeDirectory() ignores the env var, and the two
/// sides MUST resolve `~/…` identically. Also what makes tests hermetic.
private func homeDir() -> String {
    if let h = ProcessInfo.processInfo.environment["HOME"], !h.isEmpty { return h }
    return NSHomeDirectory()
}

/// The on-device data dir — mirrors the Mojo side's `_storage_config_dir()`
/// ($MILLFOLIO_DATA_DIR override, else ~/Library/Application Support/Millfolio/data).
private func dataDir() -> String {
    if let d = ProcessInfo.processInfo.environment["MILLFOLIO_DATA_DIR"],
       !d.trimmingCharacters(in: .whitespaces).isEmpty {
        return d.trimmingCharacters(in: .whitespaces)
    }
    return homeDir() + "/Library/Application Support/Millfolio/data"
}

/// Files that must NOT travel between machines: local secrets (each Mac mints
/// its own), the transient work queue, and lock/scratch files.
private let transferExcludes = [
    ".anthropic-key", ".reveal-secret",
    "work_queue.jsonl", "work_queue.jsonl.lock", "*.lock",
    ".index.pid", ".gpu_util", ".mem_bytes", ".mem_used", ".disk_used", ".dl_du",
    "demo-vault",
]

private enum TransferError: Error, CustomStringConvertible {
    case step(String, String)
    var description: String {
        switch self { case .step(let what, let why): return "\(what): \(why)" }
    }
}

/// Run a tool, feeding `stdin` if given; returns combined output + exit code.
@discardableResult
private func runTool(_ launch: String, _ args: [String], stdin: String? = nil)
    -> (out: String, code: Int32)
{
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launch)
    p.arguments = args
    let outPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = outPipe
    if let s = stdin {
        let inPipe = Pipe()
        p.standardInput = inPipe
        guard (try? p.run()) != nil else { return ("", -1) }
        inPipe.fileHandleForWriting.write(Data(s.utf8))
        try? inPipe.fileHandleForWriting.close()
    } else {
        guard (try? p.run()) != nil else { return ("", -1) }
    }
    let d = outPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(data: d, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
        p.terminationStatus)
}

// ── Keychain-backed archive passphrase ────────────────────────────────────────

private enum ArchiveKey {
    static let service = "app.millfolio.vault-export"
    static let account = "vault-archive"

    /// $MILLFOLIO_EXPORT_PASSPHRASE overrides (tests / headless), else Keychain.
    static func find() -> String? {
        if let env = ProcessInfo.processInfo.environment["MILLFOLIO_EXPORT_PASSPHRASE"],
           !env.isEmpty { return env }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8), !s.isEmpty
        else { return nil }
        return s
    }

    /// Create + store a fresh random passphrase. Tries a SYNCHRONIZABLE item
    /// first (iCloud Keychain carries it to the other Mac); falls back to a
    /// local item if the platform refuses. Returns (passphrase, synced).
    static func create() throws -> (pass: String, synced: Bool) {
        let pass = randomPassphrase()
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "millfolio vault export",
            kSecValueData as String: Data(pass.utf8),
            kSecAttrSynchronizable as String: true,
        ]
        if SecItemAdd(q as CFDictionary, nil) == errSecSuccess {
            return (pass, true)
        }
        q[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw TransferError.step("keychain",
                "could not store the archive passphrase (OSStatus \(status)); "
                + "set MILLFOLIO_EXPORT_PASSPHRASE to supply your own")
        }
        return (pass, false)
    }

    /// 4×5 chars from an unambiguous alphabet (no 0/O/1/l/i) — ~96 bits.
    private static func randomPassphrase() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        var bytes = [UInt8](repeating: 0, count: 20)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        var out = ""
        for (i, b) in bytes.enumerated() {
            if i > 0 && i % 5 == 0 { out += "-" }
            out.append(alphabet[Int(b) % alphabet.count])
        }
        return out
    }
}

// ── mill export ───────────────────────────────────────────────────────────────

struct Export: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Export the vault — derived state + indexed documents — as an encrypted archive.",
        discussion: """
        Packages the data dir (index, transactions, tags, histories) AND every \
        document the index covers into an AES-256 encrypted disk image you can \
        copy to another Mac and restore with `mill import`. The passphrase is \
        generated once and kept in your Keychain (synced via iCloud Keychain \
        when available, so the other Mac can import without typing it). \
        Machine-local secrets and the transient work queue are not included. \
        Documents are taken from the manifest — exactly the indexed files, at \
        their home-relative paths.
        """)
    @Option(name: .long, help: "Output path for the archive (default: ./millfolio-vault-<date>.dmg).")
    var out: String?

    @Flag(name: .long, help: "Print the archive passphrase (to type on a Mac without iCloud Keychain).")
    var showPassphrase = false

    @Flag(name: .long, help: "Derived state only; leave the source documents out of the archive.")
    var noDocuments = false

    @MainActor func run() async throws {
        let fm = FileManager.default
        let src = dataDir()
        guard fm.fileExists(atPath: src) else {
            throw TransferError.step("mill export", "no data dir at \(src) — nothing to export")
        }

        // Passphrase: reuse the stored one so every export opens with the same
        // key; create (and store) on first use.
        var synced = true
        let fromEnv = ProcessInfo.processInfo
            .environment["MILLFOLIO_EXPORT_PASSPHRASE"]?.isEmpty == false
        let pass: String
        if let existing = ArchiveKey.find() {
            pass = existing
        } else {
            let created = try ArchiveKey.create()
            pass = created.pass
            synced = created.synced
        }

        // Stage: data/ = a filtered copy of the data dir (rsync so the LanceDB
        // dir tree copies intact); documents/ = the manifest's files.
        let stage = fm.temporaryDirectory
            .appendingPathComponent("mill-export-\(UUID().uuidString)")
        try fm.createDirectory(
            at: stage.appendingPathComponent("data"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        var rsync = ["-a"]
        for e in transferExcludes { rsync += ["--exclude", e] }
        rsync += [src + "/", stage.appendingPathComponent("data").path + "/"]
        let rs = runTool("/usr/bin/rsync", rsync)
        guard rs.code == 0 else {
            throw TransferError.step("mill export", "staging copy failed: \(rs.out)")
        }

        var docsNote = "no documents (--no-documents)"
        if !noDocuments {
            docsNote = try stageDocuments(
                manifest: src + "/manifest.tsv",
                into: stage.appendingPathComponent("documents").path)
        }

        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd"
        let dest = out ?? "millfolio-vault-\(df.string(from: Date())).dmg"
        let destAbs = URL(fileURLWithPath: dest).standardizedFileURL.path
        if fm.fileExists(atPath: destAbs) { try fm.removeItem(atPath: destAbs) }

        print("Encrypting \(src)")
        let hd = runTool("/usr/bin/hdiutil", [
            "create", "-quiet", "-encryption", "AES-256", "-stdinpass",
            "-srcfolder", stage.path, "-volname", "MillfolioVault",
            "-format", "UDZO", destAbs,
        ], stdin: pass)
        guard hd.code == 0 else {
            throw TransferError.step("mill export", "hdiutil create failed: \(hd.out)")
        }

        let size = (try? fm.attributesOfItem(atPath: destAbs)[.size] as? Int64) ?? nil
        let mb = size.map { String(format: "%.1f MB", Double($0) / 1e6) } ?? "?"
        print("✓ exported → \(destAbs) (\(mb), AES-256; \(docsNote))")
        if fromEnv {
            print("  passphrase: from $MILLFOLIO_EXPORT_PASSPHRASE (not stored)")
        } else {
            print(synced
                ? "  passphrase: in your Keychain (iCloud Keychain carries it to your other Mac)"
                : "  passphrase: in this Mac's LOCAL Keychain only — run `mill export --show-passphrase` and enter it on the other Mac")
        }
        if showPassphrase { print("  passphrase: \(pass)") }
        print("  restore with: mill import \(dest)")
    }
}

/// Stage the manifest's indexed files under `into`/<home-relative source_dir>/…
/// — MANIFEST-DRIVEN (exactly the indexed files, never a folder walk). Returns a
/// human summary ("N document(s)", plus skip notes). A source dir outside $HOME
/// is skipped with a warning; a listed file missing on disk is counted, not fatal.
private func stageDocuments(manifest: String, into: String) throws -> String {
    let fm = FileManager.default
    guard let text = try? String(contentsOfFile: manifest, encoding: .utf8) else {
        return "no documents (no manifest)"
    }
    // Parse: #meta \t next_id \t next_alias \t source_dir \t next_gen, then
    // per-file rows whose col 1 is the name RELATIVE to source_dir (TSV-escaped).
    var sourceDir = ""
    var names: [String] = []
    for line in text.components(separatedBy: "\n") {
        let cols = line.components(separatedBy: "\t")
        if cols.first == "#meta" {
            if cols.count >= 4 { sourceDir = tsvUnescape(cols[3]) }
            continue
        }
        if cols.count >= 7 { names.append(tsvUnescape(cols[1])) }
    }
    if names.isEmpty { return "no documents (empty index)" }

    // The stored dir is `~/…` (or a legacy absolute). Resolve for reading and
    // derive the home-relative root the copies keep inside the archive.
    let home = homeDir()
    let absDir = sourceDir.hasPrefix("~")
        ? home + String(sourceDir.dropFirst()) : sourceDir
    let relRoot: String
    if absDir == home {
        relRoot = ""
    } else if absDir.hasPrefix(home + "/") {
        relRoot = String(absDir.dropFirst(home.count + 1))
    } else {
        print("  ⚠ source dir \(absDir) is outside your home folder — documents not exported")
        return "no documents (source outside home)"
    }

    var copied = 0
    var missing = 0
    for name in names {
        let srcFile = absDir + "/" + name
        guard fm.fileExists(atPath: srcFile) else {
            missing += 1
            continue
        }
        let destFile = into + "/" + (relRoot.isEmpty ? "" : relRoot + "/") + name
        let destDir = (destFile as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        try? fm.removeItem(atPath: destFile)
        try fm.copyItem(atPath: srcFile, toPath: destFile)
        copied += 1
    }
    if missing > 0 {
        print("  ⚠ \(missing) indexed file(s) no longer on disk — exported without them")
    }
    return "\(copied) document(s)"
}

/// Inverse of the Mojo side's `_tsv_escape` (left-to-right, so escapes don't
/// compound): \\ \t \n \r → the literal characters.
private func tsvUnescape(_ s: String) -> String {
    var out = ""
    var it = s.makeIterator()
    while let c = it.next() {
        guard c == "\\" else { out.append(c); continue }
        switch it.next() {
        case "t": out.append("\t")
        case "n": out.append("\n")
        case "r": out.append("\r")
        case "\\": out.append("\\")
        case let other?: out.append("\\"); out.append(other)
        case nil: out.append("\\")
        }
    }
    return out
}

// ── mill import ───────────────────────────────────────────────────────────────

struct Import: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Restore a vault archive made by `mill export` (`mill import <file.dmg>`).",
        discussion: """
        REPLACES this machine's derived vault state with the archive's (this \
        Mac's own API key and Touch-ID secret are kept), and restores the \
        archived documents under your home folder at the same relative paths \
        (existing files are never overwritten). The passphrase comes from the \
        Keychain (synced from the exporting Mac via iCloud Keychain) or is \
        prompted for. Stop the server first (`mill stop`).
        """)
    @Argument(help: "The .dmg archive produced by `mill export`.")
    var archive: String

    @Flag(name: .long, help: "Replace an existing data dir without asking.")
    var force = false

    @MainActor func run() async throws {
        let fm = FileManager.default
        let arcAbs = URL(fileURLWithPath: archive).standardizedFileURL.path
        guard fm.fileExists(atPath: arcAbs) else {
            throw TransferError.step("mill import", "no such file: \(archive)")
        }

        // A live server mid-replace corrupts both sides — refuse while :10000
        // or :8000 is listening. Only guards the DEFAULT data dir: with a
        // MILLFOLIO_DATA_DIR override the running server is serving a
        // different dir (and hermetic tests import under an override).
        if ProcessInfo.processInfo.environment["MILLFOLIO_DATA_DIR"] == nil {
            for port in [10000, 8000] {
                if runTool("/usr/sbin/lsof", ["-ti", ":\(port)"]).out.isEmpty == false {
                    throw TransferError.step("mill import",
                        "a millfolio server is running on :\(port) — run `mill stop` first")
                }
            }
        }

        let dst = dataDir()
        if fm.fileExists(atPath: dst),
           let entries = try? fm.contentsOfDirectory(atPath: dst), !entries.isEmpty, !force {
            print("The data dir \(dst) is not empty; import REPLACES it (local secrets are kept).")
            print("Continue? [y/N] ", terminator: "")
            let ans = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard ans == "y" || ans == "yes" else {
                print("aborted")
                throw ExitCode.failure
            }
        }

        // Passphrase: env → Keychain → prompt (getpass, no echo).
        let pass: String
        if let found = ArchiveKey.find() {
            pass = found
        } else if let entered = getpass("Archive passphrase (from `mill export --show-passphrase`): "),
                  case let s = String(cString: entered), !s.isEmpty {
            pass = s
        } else {
            throw TransferError.step("mill import", "no passphrase")
        }

        let mount = fm.temporaryDirectory
            .appendingPathComponent("mill-import-\(UUID().uuidString)")
        let at = runTool("/usr/bin/hdiutil", [
            "attach", "-quiet", "-stdinpass", "-readonly", "-nobrowse",
            "-mountpoint", mount.path, arcAbs,
        ], stdin: pass)
        guard at.code == 0 else {
            throw TransferError.step("mill import",
                "could not open the archive (wrong passphrase?): \(at.out)")
        }
        defer { _ = runTool("/usr/bin/hdiutil", ["detach", "-quiet", mount.path]) }

        let dataSrc = mount.appendingPathComponent("data").path
        guard fm.fileExists(atPath: dataSrc) else {
            throw TransferError.step("mill import",
                "not a mill export archive (no data/ inside)")
        }
        try fm.createDirectory(atPath: dst, withIntermediateDirectories: true)
        // Replace, preserving this machine's own secrets + transient queue: the
        // excludes protect them from BOTH copying and --delete.
        var rsync = ["-a", "--delete"]
        for e in transferExcludes { rsync += ["--exclude", e] }
        rsync += [dataSrc + "/", dst + "/"]
        let rs = runTool("/usr/bin/rsync", rsync)
        guard rs.code == 0 else {
            throw TransferError.step("mill import", "restore copy failed: \(rs.out)")
        }

        // Documents: restore under $HOME at the archived home-relative paths.
        // NEVER clobber a file the user already has (--ignore-existing) — the
        // manifest's `~/…` source_dir resolves to the same spots either way.
        var docsNote = "no documents in the archive"
        let docsSrc = mount.appendingPathComponent("documents").path
        if fm.fileExists(atPath: docsSrc) {
            // -i itemizes; a transferred FILE line starts ">f" — count those so
            // the summary reports what actually landed vs. what already existed.
            let dr = runTool("/usr/bin/rsync",
                ["-ai", "--ignore-existing", docsSrc + "/", homeDir() + "/"])
            guard dr.code == 0 else {
                throw TransferError.step("mill import", "document restore failed: \(dr.out)")
            }
            let copied = dr.out.components(separatedBy: "\n")
                .filter { $0.hasPrefix(">f") }.count
            docsNote = "\(copied) document(s) restored under ~ (files you already had were kept)"
        }

        let rewrites = normalizeLegacyPaths(in: dst)
        print("✓ imported \(arcAbs) → \(dst)")
        print("  \(docsNote)")
        if rewrites > 0 {
            print("  normalized \(rewrites) legacy absolute path(s) from the exporting Mac")
        }
        print("  start it up with: mill start")
    }
}

/// Rewrite LEGACY absolute `/Users/<name>/…` values written before paths went
/// home-relative: the manifest's `#meta` source_dir column and every
/// `folders[].path` in indexed-paths.json become `~/…`, so state exported from
/// an old install lands correctly under a different username. Values already
/// `~/…` (new exports) and non-home paths are untouched. Returns the number of
/// values rewritten.
private func normalizeLegacyPaths(in dir: String) -> Int {
    var rewrites = 0

    func contractUsers(_ p: String) -> String? {
        guard p.hasPrefix("/Users/") else { return nil }
        let parts = p.split(separator: "/", omittingEmptySubsequences: false)
        // ["", "Users", "<name>", rest…] — need at least a username component.
        guard parts.count > 3, !parts[2].isEmpty else { return nil }
        return "~/" + parts[3...].joined(separator: "/")
    }

    // manifest.tsv: only the #meta row's 4th column holds a path.
    let manifest = dir + "/manifest.tsv"
    if var text = try? String(contentsOfFile: manifest, encoding: .utf8) {
        var lines = text.components(separatedBy: "\n")
        for i in lines.indices where lines[i].hasPrefix("#meta\t") {
            var cols = lines[i].components(separatedBy: "\t")
            if cols.count >= 4, let contracted = contractUsers(cols[3]) {
                cols[3] = contracted
                lines[i] = cols.joined(separator: "\t")
                rewrites += 1
            }
        }
        text = lines.joined(separator: "\n")
        try? text.write(toFile: manifest, atomically: true, encoding: .utf8)
    }

    // indexed-paths.json: {"folders":[{path,lastIndexed}]}.
    let tracked = dir + "/indexed-paths.json"
    if let data = fileData(tracked),
       var j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
       var folders = j["folders"] as? [[String: Any]] {
        for i in folders.indices {
            if let p = folders[i]["path"] as? String, let contracted = contractUsers(p) {
                folders[i]["path"] = contracted
                rewrites += 1
            }
        }
        if rewrites > 0 {
            j["folders"] = folders
            // .withoutEscapingSlashes: keep `~/vault` literal — no `\/` escapes
            // for the vendored Mojo json reader to chew on.
            if let out = try? JSONSerialization.data(
                withJSONObject: j, options: [.withoutEscapingSlashes]) {
                try? out.write(to: URL(fileURLWithPath: tracked))
            }
        }
    }
    return rewrites
}

private func fileData(_ path: String) -> Data? {
    FileManager.default.contents(atPath: path)
}
