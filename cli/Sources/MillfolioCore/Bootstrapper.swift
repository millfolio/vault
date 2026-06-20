import Foundation
import AppKit

/// Drives the local engine lifecycle, as three explicit steps:
///
///   1. **Install server** — fetch the official Mojo compiler+runtime from
///      Modular's conda channel (so the *user* accepts Modular's license — we
///      never redistribute it), unpack our engine source zip (inference-server +
///      jinja2.mojo + flare + a prebuilt libflare_tls.so), build the server with
///      `mojo build`, then download the default model's weights with the engine's
///      own native-Mojo downloader (no huggingface_hub).
///   2. **Start server** — launch the built server (via a launchd LaunchAgent, so
///      the CLI and the menu app share one managed process).
///   3. **Start opencode** — point opencode at the running server (new Terminal).
///
/// Everything lives under ~/Library/Application Support/Millfolio, including the
/// model weights (HF_HOME=<support>/hf), so uninstall is a single directory.
///
/// This type is UI-agnostic on purpose: the menu-bar app observes it as an
/// `ObservableObject` (via `phase`/`serverRunning`), while the `mill` CLI
/// drives the same methods and streams progress through `onProgress`.
///
/// NOTE: the Mojo fetch is "rattler-by-URL" — we don't link the rattler crate, we
/// GET the pinned `.conda` packages (a .conda is a zip of zstd tarballs) and
/// extract them with the system `unzip`/`tar`. Keep `mojoVersion` in sync with
/// inference-server/pixi.lock.
@MainActor
public final class Bootstrapper: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case running(String)
        case done
        case failed(String)

        public var message: String? {
            switch self {
            case .idle, .done: return nil
            case .running(let m): return m
            case .failed(let e): return "Failed: \(e)"
            }
        }
    }

    /// Progress of the long-running provisioning steps.
    @Published public var phase: Phase = .idle
    /// True while the engine server's LaunchAgent is loaded.
    @Published public var serverRunning = false

    /// Optional progress sink — every status message is forwarded here as well as
    /// to `phase`, so a non-UI driver (the CLI) can stream the same text.
    public var onProgress: ((String) -> Void)?

    public init() {
        refreshServerRunning()
    }

    public var isBusy: Bool { if case .running = phase { return true }; return false }

    // ── pinned manifest (keep in sync with inference-server/pixi.lock) ─────────────
    public static let mojoVersion = "1.0.0b3.dev2026061206"
    public static let condaChannel = "https://conda.modular.com/max-nightly"
    /// Default model served by the server. The 3B is int4-friendly and the
    /// quality target; its tokenizer.json is read directly by the engine.
    public static let model = "Qwen/Qwen2.5-3B-Instruct"
    public static let modelSlug = "Qwen--Qwen2.5-3B-Instruct"
    /// SECONDARY embedding model. The combined server resolves this from the HF
    /// cache to serve /v1/embeddings (else that endpoint 503s). millfolio's indexer
    /// + vault search hit it, so the installer fetches its weights too — via the
    /// same native-Mojo downloader, another HF id. Single-file safetensors (small).
    public static let embedModel = "Qwen/Qwen3-Embedding-0.6B"
    public static let embedModelSlug = "Qwen--Qwen3-Embedding-0.6B"

    private var mojoCompilerURL: URL {
        URL(string: "\(Self.condaChannel)/osx-arm64/mojo-compiler-\(Self.mojoVersion)-release.conda")!
    }
    private var mojoPythonURL: URL {
        URL(string: "\(Self.condaChannel)/noarch/mojo-python-\(Self.mojoVersion)-release.conda")!
    }
    // ── privacy_box (privacy harness) ─────────────────────────────────────────────
    // privacy_box builds on the SAME unified Mojo toolchain as the server + vault —
    // every repo pins one nightly now, so it shares the single `mojoPrefix` toolchain
    // (no separate download). It's a one-shot CLI (not a daemon), so "start" opens a
    // ready-to-use Terminal rather than launching a server.
    public static let privacy_boxMojoVersion = "1.0.0b3.dev2026061206"
    private var privacy_boxMojoCompilerURL: URL {
        URL(string: "\(Self.condaChannel)/osx-arm64/mojo-compiler-\(Self.privacy_boxMojoVersion)-release.conda")!
    }
    private var privacy_boxMojoPythonURL: URL {
        URL(string: "\(Self.condaChannel)/noarch/mojo-python-\(Self.privacy_boxMojoVersion)-release.conda")!
    }
    /// Unified toolchain: privacy_box shares the single `mojoPrefix` install (the
    /// staleness check dedupes, so the toolchain is downloaded once for all components).
    private var privacy_boxMojoPrefix: URL { mojoPrefix }
    private var privacy_boxRoot: URL { bundleRoot.appendingPathComponent("privacy_box", isDirectory: true) }
    /// privacy_box checkout inside the unpacked bundle (sibling of flare/json/jinja2.mojo).
    private var privacy_boxDir: URL { privacy_boxRoot.appendingPathComponent("privacy_box", isDirectory: true) }
    private var privacy_boxBin: URL { privacy_boxDir.appendingPathComponent("build/privacy_box") }
    /// The built privacy_box binary is present.
    public var isPrivacyBoxInstalled: Bool { FileManager.default.isExecutableFile(atPath: privacy_boxBin.path) }

    // ── millfolio (personal data vault) ───────────────────────────────────────────
    // millfolio is a one-shot vault CLI built on the SAME Mojo nightly as privacy_box.
    // Its bundle vendors the toolbox (flare/json + the LanceDB binding + pdftotext/
    // zlib readers) + prebuilt FFI shims, so the on-device build is
    // `mojo build src/millfolio.mojo -I ../flare -I … ` then installMillfolioShims().
    private var millfolioMojoCompilerURL: URL {
        URL(string: "\(Self.condaChannel)/osx-arm64/mojo-compiler-\(Self.privacy_boxMojoVersion)-release.conda")!
    }
    private var millfolioMojoPythonURL: URL {
        URL(string: "\(Self.condaChannel)/noarch/mojo-python-\(Self.privacy_boxMojoVersion)-release.conda")!
    }
    /// Unified toolchain: the vault build shares the single `mojoPrefix` install too.
    private var millfolioMojoPrefix: URL { mojoPrefix }
    private var millfolioRoot: URL { bundleRoot.appendingPathComponent("millfolio", isDirectory: true) }
    /// millfolio checkout inside the unpacked bundle.
    private var millfolioDir: URL { millfolioRoot.appendingPathComponent("millfolio", isDirectory: true) }
    private var millfolioBin: URL { millfolioDir.appendingPathComponent("build/millfolio") }
    /// The built millfolio binary is present.
    public var isMillfolioInstalled: Bool { FileManager.default.isExecutableFile(atPath: millfolioBin.path) }

    // ── app server (the streaming WS backend, from millfolio/app) ──────────────
    // Built ON-DEVICE against the privacy_box engine tree, reusing privacy_box's Mojo
    // toolchain + flare shims — so no new toolchain. See app/server/CUTOVER.md.
    private var appRoot: URL { bundleRoot.appendingPathComponent("app", isDirectory: true) }
    private var appWsBin: URL { appRoot.appendingPathComponent("build/millfolio-ws") }
    /// The built streaming WS server is present.
    public var isAppServerInstalled: Bool { FileManager.default.isExecutableFile(atPath: appWsBin.path) }

    // ── default config files (~/.config) ───────────────────────────────────────
    // Seeded with sensible defaults on install if absent, so a fresh setup has an
    // editable starting point. The engines read these (engine = the inference engine,
    // privacy_box = privacy_box); we NEVER overwrite an existing file.
    private var dotConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
    }
    private var engineConfigURL: URL { dotConfig.appendingPathComponent("millfolio/config.json") }
    private var privacy_boxConfigURL: URL { dotConfig.appendingPathComponent("privacy_box/config.json") }

    private static let engineConfigDefault = """
    {
      "port": 8000,
      "model": "Qwen/Qwen2.5-3B-Instruct",
      "q4": false,
      "kv_budget_mb": 8192
    }
    """
    private static let privacy_boxConfigDefault = """
    {
      "local_url": "http://127.0.0.1:8000/v1",
      "local_model": "Qwen2.5-0.5B-Instruct",
      "remote_base_url": "https://api.anthropic.com/v1",
      "remote_model": "claude-sonnet-4-6",
      "remote_token_budget": 200000,
      "mock": false,
      "use_local_summary": false,
      "data_dir": ""
    }
    """

    /// Create `path` with `json` if it doesn't exist (best-effort; never overwrites).
    private func ensureConfig(at path: URL, _ json: String) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: path.path) else { return }
        do {
            try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try json.write(to: path, atomically: true, encoding: .utf8)
            appendLog("wrote default config: \(path.path)\n")
        } catch {
            appendLog("could not write config \(path.path): \(error)\n")  // non-fatal
        }
    }

    // ── install locations ─────────────────────────────────────────────────────
    private var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Millfolio", isDirectory: true)
    }
    private var mojoPrefix: URL { support.appendingPathComponent("mojo", isDirectory: true) }
    private var cacheDir: URL { support.appendingPathComponent("cache", isDirectory: true) }

    // ── source bundle (one millfolio.zip from the vault repo) ────────────────────
    // All on-device-built source ships in ONE archive whose subtrees mirror the
    // former four zips: runner/ privacy_box/ millfolio/ app/. Downloaded once and
    // built per-component, so the per-component build steps below are unchanged.
    private let bundleURL =
        URL(string: "https://github.com/millfolio/vault/releases/latest/download/millfolio.zip")!
    private var bundleRoot: URL { support.appendingPathComponent("bundle", isDirectory: true) }
    private var bundleStamp: URL { bundleRoot.appendingPathComponent(".unpacked") }
    private var engineRoot: URL { bundleRoot.appendingPathComponent("runner", isDirectory: true) }
    /// HF cache root for the model weights (HF_HOME). Self-contained under support/.
    private var hfHome: URL { support.appendingPathComponent("hf", isDirectory: true) }
    /// inference-server checkout inside the unpacked engine zip.
    private var backendDir: URL { engineRoot.appendingPathComponent("inference-server", isDirectory: true) }
    private var serverBin: URL { backendDir.appendingPathComponent("build/server") }
    /// All subprocess output (mojo build, weights download, the running server)
    /// is appended here so errors that flash by in the menu can be read in full.
    public var logFileURL: URL { support.appendingPathComponent("Millfolio.log") }
    public var hasLog: Bool { FileManager.default.fileExists(atPath: logFileURL.path) }

    /// The built engine server binary is present.
    public var isServerInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: serverBin.path)
    }
    /// The default model's weights have been fully downloaded (refs/main is the
    /// downloader's last write, so its presence means the snapshot is complete).
    public var weightsPresent: Bool {
        FileManager.default.fileExists(
            atPath: hfHome.appendingPathComponent("hub/models--\(Self.modelSlug)/refs/main").path)
    }
    /// The embedding model's weights are fully downloaded (refs/main is the
    /// downloader's last write). When present, the combined server serves
    /// /v1/embeddings (so mill index/search work with no manual download).
    public var embedWeightsPresent: Bool {
        FileManager.default.fileExists(
            atPath: hfHome.appendingPathComponent("hub/models--\(Self.embedModelSlug)/refs/main").path)
    }
    /// Ready to launch: engine built and (chat) weights downloaded. The embedding
    /// weights are not required to start the chat server, so they don't gate this.
    public var canStartServer: Bool { isServerInstalled && weightsPresent && !serverRunning }

    // ── logging ──────────────────────────────────────────────────────────────
    /// Ensure the log file (and its directory) exist; returns the path.
    @discardableResult
    private func ensureLog() -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logFileURL.path) {
            fm.createFile(atPath: logFileURL.path, contents: nil)
        }
        return logFileURL
    }

    /// Append text to the log (best-effort; never throws).
    private func appendLog(_ text: String) {
        ensureLog()
        guard let fh = try? FileHandle(forWritingTo: logFileURL) else { return }
        defer { try? fh.close() }
        fh.seekToEndOfFile()
        if let d = text.data(using: .utf8) { fh.write(d) }
    }

    private func logHeader(_ what: String) {
        appendLog("\n===== \(what) — \(Self.stamp()) =====\n")
    }

    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    /// Open the log in the user's default viewer (Console/TextEdit).
    public func openLog() {
        NSWorkspace.shared.open(ensureLog())
    }

    // ── millfolio diagnostic log (~/Library/Logs/Millfolio/<date>.log) ──────────────
    // Separate from Millfolio.log: a per-day, user-facing diagnostic log for the
    // `millfolio` CLI itself (the ask/index runs + update), in the conventional
    // macOS ~/Library/Logs location so it's easy to find and attach to a report.
    public var millfolioLogDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Millfolio", isDirectory: true)
    }
    /// Today's log file, e.g. ~/Library/Logs/Millfolio/2026-06-17.log.
    public var millfolioLogURL: URL {
        millfolioLogDir.appendingPathComponent("\(Self.day()).log")
    }

    @discardableResult
    private func ensureMillfolioLog() -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: millfolioLogDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: millfolioLogURL.path) {
            fm.createFile(atPath: millfolioLogURL.path, contents: nil)
        }
        return millfolioLogURL
    }

    /// Append a line to today's millfolio log (best-effort; never throws).
    public func vlog(_ text: String) {
        ensureMillfolioLog()
        guard let fh = try? FileHandle(forWritingTo: millfolioLogURL) else { return }
        defer { try? fh.close() }
        fh.seekToEndOfFile()
        if let d = (text + "\n").data(using: .utf8) { fh.write(d) }
    }

    private static func day() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    // ── toolchain freshness ─────────────────────────────────────────────────────
    /// True if the Mojo toolchain at `prefix` is absent OR not the pinned `version`
    /// (recorded in a .mojo-version marker). Presence alone isn't enough: a stale
    /// nightly kept across a version bump can segfault on a newer macOS — so a
    /// version mismatch forces a re-download.
    private func mojoToolchainStale(_ prefix: URL, _ version: String) -> Bool {
        guard FileManager.default.isExecutableFile(
            atPath: prefix.appendingPathComponent("bin/mojo").path) else { return true }
        let have = (try? String(contentsOf: prefix.appendingPathComponent(".mojo-version"),
                                 encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return have != version
    }

    private func recordMojoVersion(_ prefix: URL, _ version: String) {
        try? version.write(to: prefix.appendingPathComponent(".mojo-version"),
                           atomically: true, encoding: .utf8)
    }

    // ── step 1: install server (+ weights) ──────────────────────────────────────
    /// Menu-app entry point: fire-and-forget, drives `phase`. The CLI calls the
    /// throwing `installServer()` directly.
    public func downloadServer() {
        guard !isBusy else { return }
        phase = .running("Starting…")
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do { try await self.installServer(); await self.set(done: true) }
            catch { await self.set(failed: humanError(error)) }
        }
    }

    // ── one-time migration: millrace → millfolio (pre-rename installs) ───────────
    /// Older versions installed under `~/Library/Application Support/Millrace`, with
    /// config/cache under `~/.config/millrace` + `~/.cache/millrace` and a
    /// `me.millrace.server` LaunchAgent. Move each to its `millfolio` location once,
    /// so upgraders keep their multi-GB model weights instead of re-downloading.
    ///
    /// Idempotent and best-effort: a path is moved only when the legacy location
    /// exists and the new one does not, so re-running (or a fresh install) is a
    /// no-op. After moving the tree, the stale engine *build* is dropped (weights
    /// under `hf/` are kept) so `installServer` rebuilds the binary against the new
    /// source + `~/.config/millfolio` config path.
    public func migrateLegacyLayout() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let appSup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

        // Boot out + remove the old LaunchAgent first; the new install writes the
        // me.millfolio.server agent, and leaving the old one loaded runs a stale
        // binary against a config path that no longer exists.
        let oldAgent = home.appendingPathComponent("Library/LaunchAgents/me.millrace.server.plist")
        if fm.fileExists(atPath: oldAgent.path) {
            _ = try? run("/bin/launchctl", ["bootout", "gui/\(getuid())/me.millrace.server"])
            try? fm.removeItem(at: oldAgent)
            appendLog("migrated: removed legacy LaunchAgent me.millrace.server\n")
        }

        let legacyTree = appSup.appendingPathComponent("Millrace", isDirectory: true)
        let migratedTree = fm.fileExists(atPath: legacyTree.path)
            && !fm.fileExists(atPath: support.path)

        let moves: [(URL, URL)] = [
            (legacyTree, support),
            (home.appendingPathComponent(".config/millrace", isDirectory: true),
             home.appendingPathComponent(".config/millfolio", isDirectory: true)),
            (home.appendingPathComponent(".cache/millrace", isDirectory: true),
             home.appendingPathComponent(".cache/millfolio", isDirectory: true)),
        ]
        for (old, new) in moves where fm.fileExists(atPath: old.path) && !fm.fileExists(atPath: new.path) {
            do {
                try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: old, to: new)
                appendLog("migrated: \(old.path) → \(new.path)\n")
            } catch {
                appendLog("migration skipped for \(old.lastPathComponent): \(humanError(error))\n")
            }
        }

        guard migratedTree else { return }
        // Keep the model weights (hf/) + cache; drop the unpacked source bundle so it
        // re-downloads + rebuilds fresh against the new layout + ~/.config/millfolio.
        try? fm.removeItem(at: bundleRoot)
        // The per-day diagnostic log inside the moved tree kept its old name.
        let oldLog = support.appendingPathComponent("Millrace.log")
        if fm.fileExists(atPath: oldLog.path) && !fm.fileExists(atPath: logFileURL.path) {
            try? fm.moveItem(at: oldLog, to: logFileURL)
        }
    }

    /// Provision the Mojo toolchain, engine source, build, and weights. Throws on
    /// the first failure (the CLI surfaces it; the menu wrapper maps it to `phase`).
    public func installServer() async throws {
        migrateLegacyLayout()   // upgrade an older millrace-layout install in place
        // Idempotent fast-path: everything (engine + both models' weights) already
        // present → nothing to do. Otherwise fall through; the steps below each
        // skip what's already done (toolchain, weights), so a partial install
        // resumes (e.g. just the missing embedding weights).
        if isServerInstalled && weightsPresent && embedWeightsPresent
            && !mojoToolchainStale(mojoPrefix, Self.mojoVersion) {
            set("engine already installed — skipping")
            return
        }
        let fm = FileManager.default
        for d in [support, mojoPrefix, engineRoot, cacheDir, hfHome] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        logHeader("Install server")

        if mojoToolchainStale(mojoPrefix, Self.mojoVersion) {
            set("Downloading Mojo compiler for engine (~70 MB)…")
            try? fm.removeItem(at: mojoPrefix)   // clear any stale nightly
            try fm.createDirectory(at: mojoPrefix, withIntermediateDirectories: true)
            let compiler = try await download(mojoCompilerURL, name: "mojo-compiler.conda")
            set("Extracting Mojo…")
            try extractConda(compiler, into: mojoPrefix)
            let py = try await download(mojoPythonURL, name: "mojo-python.conda")
            try extractConda(py, into: mojoPrefix)
            recordMojoVersion(mojoPrefix, Self.mojoVersion)
        }
        try relocateMojoPrefix(mojoPrefix)   // rewrite modular.cfg's baked placeholder prefix

        try await ensureBundle()

        let python = try findPython()

        set("Building engine (first run, ~1 min)…")
        try buildBinary(python: python, source: "src/server.mojo",
                        args: ["-I", "../jinja2.mojo/src", "-I", "../flare"], out: "build/server")
        signServerIdentity()

        if !weightsPresent || !embedWeightsPresent {
            set("Building downloader…")
            try buildBinary(python: python, source: "src/download.mojo",
                            args: ["-I", "../flare"], out: "build/download")
        }
        if !weightsPresent {
            set("Downloading model weights (\(Self.model), several GB)…")
            try downloadWeights(Self.model)
        }
        // The combined server resolves the embedding model from the HF cache to
        // serve /v1/embeddings (millfolio's indexer + vault search use it). Fetch its
        // weights with the same native downloader so the vault works out of the box.
        if !embedWeightsPresent {
            set("Downloading embedding model weights (\(Self.embedModel))…")
            try downloadWeights(Self.embedModel)
        }

        ensureConfig(at: engineConfigURL, Self.engineConfigDefault)
        await recordLatest("engine", repo: "millfolio/engine")
    }

    // ── step 2: start / stop server (launchd LaunchAgent) ────────────────────────
    // The server runs as a per-user LaunchAgent (me.millfolio.server) instead of a
    // child Process, so the `mill` CLI and the menu app's "Start
    // server" drive the SAME managed process — either surface can start/stop/see it.
    public static let serverLabel = "me.millfolio.server"
    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Self.serverLabel).plist")
    }
    private var guiDomain: String { "gui/\(getuid())" }

    /// Start the server LaunchAgent. Idempotent: re-bootstraps a fresh plist.
    public func startServer() throws {
        guard isServerInstalled, weightsPresent else {
            throw BootstrapError.step("start server", "engine not installed or weights missing — run install first")
        }
        try writeLaunchAgent()
        logHeader("Start server: \(Self.model)")
        // Replace any prior instance, then load (RunAtLoad starts it).
        _ = try? runStatus("/bin/launchctl", ["bootout", "\(guiDomain)/\(Self.serverLabel)"])
        try run("/bin/launchctl", ["bootstrap", guiDomain, launchAgentURL.path])
        serverRunning = true
    }

    /// Stop the server LaunchAgent (no-op if not loaded).
    public func stopServer() throws {
        let rc = try runStatus("/bin/launchctl", ["bootout", "\(guiDomain)/\(Self.serverLabel)"])
        if rc != 0 { appendLog("[launchctl bootout exited \(rc) — not loaded?]\n") }
        serverRunning = false
    }

    /// Non-throwing menu-button wrappers: surface any failure via `phase`.
    public func tryStartServer() {
        do { try startServer() } catch { phase = .failed(humanError(error)) }
    }
    public func tryStopServer() {
        do { try stopServer() } catch { phase = .failed(humanError(error)) }
    }

    /// Reconcile `serverRunning` with launchd's actual state (e.g. at app launch).
    public func refreshServerRunning() {
        let loaded = (try? runStatus("/bin/launchctl", ["print", "\(guiDomain)/\(Self.serverLabel)"])) == 0
        serverRunning = loaded
    }

    /// Write the LaunchAgent plist that runs the built server against the weights.
    private func writeLaunchAgent() throws {
        try FileManager.default.createDirectory(
            at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Minimal explicit env — launchd does NOT inherit the app's environment.
        // Keep CONDA_PREFIX unset so flare loads build/libflare_tls.so next to the
        // binary; HOME is provided by launchd (kv-cache lives under ~/.cache).
        var env: [String: String] = [
            "HF_HOME": hfHome.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        if FileManager.default.fileExists(atPath: "/etc/ssl/cert.pem") {
            env["SSL_CERT_FILE"] = "/etc/ssl/cert.pem"
        }
        let plist: [String: Any] = [
            "Label": Self.serverLabel,
            "ProgramArguments": [serverBin.path, Self.model],
            "WorkingDirectory": backendDir.path,   // hardcoded relative data paths resolve here
            "EnvironmentVariables": env,
            "StandardOutPath": logFileURL.path,
            "StandardErrorPath": logFileURL.path,
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: launchAgentURL)
    }

    // ── step 3: start opencode ──────────────────────────────────────────────────
    /// Generate an opencode config from the running server's /v1/models, then open
    /// opencode in a new Terminal window pointed at it. opencode is an interactive
    /// TUI, so it must run in a real terminal, not detached.
    public func startOpencode() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do { try await self.launchOpencode() }
            catch { await self.set(failed: "opencode: \(humanError(error))") }
        }
    }

    public func launchOpencode() async throws {
        let base = "http://127.0.0.1:8000/v1"
        let opencode = try findOpencode()
        let configPath = try await writeOpencodeConfig(baseURL: base)

        // A small launcher script avoids AppleScript quoting pitfalls.
        let script = support.appendingPathComponent("run-opencode.sh")
        let body = """
        #!/bin/bash
        export OPENCODE_CONFIG="\(configPath)"
        export OPENAI_BASE_URL="\(base)"
        export OPENAI_API_KEY="millfolio"
        # opencode's own dir + common bins on PATH (Terminal already sources the
        # user's profile, but be explicit in case it shells out to helpers).
        export PATH="\(URL(fileURLWithPath: opencode).deletingLastPathComponent().path):$PATH"
        exec "\(opencode)"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        // `do script` runs its text as a shell command line, so the script path
        // (which lives under "Application Support" — note the space) must be shell-
        // quoted, or zsh splits it at the space. Single-quote it (the path has no
        // single quotes).
        let cmd = "'\(script.path)'"
        try run("/usr/bin/osascript",
                ["-e", "tell application \"Terminal\" to activate",
                 "-e", "tell application \"Terminal\" to do script \"\(cmd)\""])
    }

    /// Build the opencode provider config the way inference-server/opencode_config.py
    /// does, but in-process (no Python): query /v1/models and declare each served id.
    private func writeOpencodeConfig(baseURL: String) async throws -> String {
        guard let url = URL(string: baseURL + "/models") else {
            throw BootstrapError.step("opencode", "bad base URL")
        }
        var req = URLRequest(url: url); req.timeoutInterval = 3
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]] else {
            throw BootstrapError.step("opencode", "server not reachable at \(baseURL)/models — start the server first")
        }
        let ids = arr.compactMap { $0["id"] as? String }
        guard let first = ids.first else { throw BootstrapError.step("opencode", "no models served") }
        var models: [String: Any] = [:]
        for id in ids { models[id] = ["name": id.components(separatedBy: "/").last ?? id] }
        let config: [String: Any] = [
            "$schema": "https://opencode.ai/config.json",
            "model": "millfolio/" + first,
            "provider": ["millfolio": [
                "npm": "@ai-sdk/openai-compatible",
                "name": "millfolio (local)",
                "options": ["baseURL": baseURL, "apiKey": "millfolio"],
                "models": models,
            ]],
        ]
        let out = cacheDir.appendingPathComponent("opencode.json")
        let blob = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted])
        try blob.write(to: out)
        return out.path
    }

    // ── steps ────────────────────────────────────────────────────────────────
    private func download(_ url: URL, name: String) async throws -> URL {
        let dest = cacheDir.appendingPathComponent(name)
        let (tmp, resp) = try await URLSession.shared.download(from: url)
        guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
            throw BootstrapError.step("download \(name)", "HTTP error fetching \(url.absoluteString)")
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// Download + unpack the one source bundle (millfolio.zip) once. Idempotent via
    /// the `.unpacked` stamp; each component (server/privacy_box/millfolio/app) calls
    /// this before building, so it runs once per install and is a no-op thereafter.
    /// `unpackZip` also sanity-checks the engine subtree is present.
    private func ensureBundle() async throws {
        if FileManager.default.fileExists(atPath: bundleStamp.path) { return }
        set("Downloading millfolio sources…")
        let zip = try await download(bundleURL, name: "millfolio.zip")
        set("Unpacking sources…")
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
        try unpackZip(zip, into: bundleRoot)
        FileManager.default.createFile(atPath: bundleStamp.path, contents: nil)
    }

    /// A `.conda` is a zip containing `pkg-*.tar.zst` (the files) + `info-*.tar.zst`.
    /// We unzip it (native), zstd-decompress each payload IN-PROCESS via the
    /// vendored decoder, then untar the resulting plain `.tar`. The two-step
    /// avoids `tar`'s zstd filter, which on macOS shells out to a `zstd` program
    /// that isn't installed (libarchive here is built without built-in zstd).
    private func extractConda(_ conda: URL, into prefix: URL) throws {
        let scratch = cacheDir.appendingPathComponent("conda-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try run("/usr/bin/unzip", ["-o", "-q", conda.path, "-d", scratch.path])
        let entries = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        let pkgs = entries.filter { $0.hasPrefix("pkg-") && $0.hasSuffix(".tar.zst") }
        guard !pkgs.isEmpty else { throw BootstrapError.step("extract", "no pkg tar in \(conda.lastPathComponent)") }
        for pkg in pkgs {
            let zst = scratch.appendingPathComponent(pkg)
            let tar = scratch.appendingPathComponent(String(pkg.dropLast(4)))   // strip ".zst"
            try Zstd.decompressFile(zst, to: tar)
            // Plain (uncompressed) tar — core libarchive, no optional filter.
            try run("/usr/bin/tar", ["-xf", tar.path, "-C", prefix.path])
        }
    }

    private func unpackZip(_ zip: URL, into dir: URL) throws {
        try run("/usr/bin/unzip", ["-o", "-q", zip.path, "-d", dir.path])
        guard FileManager.default.fileExists(atPath: backendDir.appendingPathComponent("src/server.mojo").path) else {
            throw BootstrapError.step("unpack", "engine zip missing inference-server/src/server.mojo")
        }
    }

    /// Find an existing Python >= 3.10 on the system (we do NOT download one).
    private func findPython() throws -> URL {
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            + (ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map { String($0) + "/python3" } ?? [])
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            if let v = try? run(path, ["-c", "import sys;print(sys.version_info[0],sys.version_info[1])"]) {
                let parts = v.split(separator: " ").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                if parts.count == 2, parts[0] == 3, parts[1] >= 10 { return URL(fileURLWithPath: path) }
            }
        }
        throw BootstrapError.step("python", "no Python >= 3.10 found on PATH (Mojo needs one; install one or add it to PATH)")
    }

    private func findOpencode() throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // A GUI app's PATH is minimal and excludes per-user install dirs, so check
        // the common ones explicitly (opencode installs to ~/.opencode/bin).
        let candidates = [
            "\(home)/.opencode/bin/opencode",
            "\(home)/.local/bin/opencode",
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
        ] + (ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map { String($0) + "/opencode" } ?? [])
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) { return path }
        throw BootstrapError.step("opencode", "opencode not found — install it (https://opencode.ai) or add it to PATH")
    }

    /// Env for invoking `mojo build`. What conda's activation script exports — the
    /// compiler reads $MODULAR_HOME/modular.cfg for its stdlib import path + libs.
    private func mojoEnv(python: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extraPath = "\(python.deletingLastPathComponent().path):\(mojoPrefix.appendingPathComponent("bin").path)"
        env["PATH"] = extraPath + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["CONDA_PREFIX"] = mojoPrefix.path
        env["MODULAR_HOME"] = mojoPrefix.appendingPathComponent("share/max").path
        return env
    }

    /// Env for *running* the compiled Mojo binaries (download) — the opposite of
    /// the build env: keep CONDA_PREFIX unset so flare loads `build/libflare_tls.so`
    /// next to the binary (cwd) rather than `$CONDA_PREFIX/lib`, and point OpenSSL
    /// at the system CA bundle (the bundled libssl's compiled-in cert path is the
    /// CI prefix, which is absent here).
    private func runtimeEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CONDA_PREFIX")
        env.removeValue(forKey: "MODULAR_HOME")
        if FileManager.default.fileExists(atPath: "/etc/ssl/cert.pem") {
            env["SSL_CERT_FILE"] = "/etc/ssl/cert.pem"
        }
        return env
    }

    /// conda packages bake a placeholder install path into `share/max/modular.cfg`
    /// (the value of `package_root`), normally rewritten by conda's prefix-
    /// replacement step — which we skip by extracting the `.conda` by hand. Rewrite
    /// it to our real prefix so the compiler can locate the stdlib (`import_path`)
    /// and link the runtime libs (rpath). Idempotent; safe to run every time.
    private func relocateMojoPrefix(_ prefix: URL) throws {
        let cfg = prefix.appendingPathComponent("share/max/modular.cfg")
        guard var text = try? String(contentsOf: cfg, encoding: .utf8) else {
            throw BootstrapError.step("relocate", "modular.cfg missing after extract")
        }
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("package_root") }),
              let eq = line.firstIndex(of: "=") else {
            throw BootstrapError.step("relocate", "no package_root in modular.cfg")
        }
        let placeholder = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        guard !placeholder.isEmpty, placeholder != prefix.path else { return }  // already done
        text = text.replacingOccurrences(of: placeholder, with: prefix.path)
        try text.write(to: cfg, atomically: true, encoding: .utf8)
        appendLog("relocated mojo prefix: \(placeholder) -> \(prefix.path)\n")
    }

    private func buildBinary(python: URL, source: String, args: [String], out: String) throws {
        let mojo = mojoPrefix.appendingPathComponent("bin/mojo").path
        // flare's libflare_tls.so ships at inference-server/build/ relative to cwd.
        try run(mojo, ["build", source] + args + ["-o", out], cwd: backendDir, env: mojoEnv(python: python))
    }

    /// `mojo build` ad-hoc "linker-signs" the server with the identifier "server".
    /// macOS's "<name> can run in the background" notification + Login Items entry
    /// for the LaunchAgent take that signing identifier as the name, so re-sign it
    /// (still ad-hoc) as "millfolio". Best-effort — purely cosmetic, so a failure
    /// never blocks the install.
    private func signServerIdentity() {
        do {
            try run("/usr/bin/codesign",
                    ["--force", "--sign", "-", "--identifier", "millfolio", serverBin.path])
        } catch {
            appendLog("could not re-sign server identity (cosmetic): \(humanError(error))\n")
        }
    }

    private func downloadWeights(_ modelID: String) throws {
        let dl = backendDir.appendingPathComponent("build/download").path
        var env = runtimeEnv()
        env["HF_HOME"] = hfHome.path
        try run(dl, [modelID], cwd: backendDir, env: env)
    }

    // ── privacy_box: install ──────────────────────────────────────────────────────
    /// Menu-app entry point: fire-and-forget, drives `phase`.
    public func installPrivacyBox() {
        guard !isBusy else { return }
        phase = .running("Starting…")
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do { try await self.installPrivacyBoxEngine(); await self.set(done: true) }
            catch { await self.set(failed: humanError(error)) }
        }
    }

    /// Download privacy_box's Mojo toolchain + source bundle and build it. Separate
    /// from the server: privacy_box is on a different nightly and ships its own
    /// vendored flare/json/jinja2.mojo + prebuilt FFI shims.
    public func installPrivacyBoxEngine() async throws {
        // Idempotent: skip the whole download+build if the binary is already there.
        if isPrivacyBoxInstalled
            && !mojoToolchainStale(privacy_boxMojoPrefix, Self.privacy_boxMojoVersion) {
            set("privacy_box already installed — skipping")
            return
        }
        let fm = FileManager.default
        for d in [support, privacy_boxMojoPrefix, privacy_boxRoot, cacheDir] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        logHeader("Install privacy_box")

        // 1. Mojo toolchain (privacy_box's nightly — distinct from the engine's).
        if mojoToolchainStale(privacy_boxMojoPrefix, Self.privacy_boxMojoVersion) {
            set("Downloading Mojo compiler for privacy_box (~70 MB)…")
            try? fm.removeItem(at: privacy_boxMojoPrefix)   // clear any stale nightly
            try fm.createDirectory(at: privacy_boxMojoPrefix, withIntermediateDirectories: true)
            let compiler = try await download(privacy_boxMojoCompilerURL, name: "privacy_box-mojo-compiler.conda")
            set("Extracting Mojo…")
            try extractConda(compiler, into: privacy_boxMojoPrefix)
            let py = try await download(privacy_boxMojoPythonURL, name: "privacy_box-mojo-python.conda")
            try extractConda(py, into: privacy_boxMojoPrefix)
            recordMojoVersion(privacy_boxMojoPrefix, Self.privacy_boxMojoVersion)
        }
        try relocateMojoPrefix(privacy_boxMojoPrefix)

        // 2. privacy_box source bundle (privacy_box + vendored flare/json/jinja2.mojo +
        //    prebuilt FFI shims), published by privacy_box CI.
        try await ensureBundle()
        guard fm.fileExists(atPath: privacy_boxDir.appendingPathComponent("src/privacy_box.mojo").path) else {
            throw BootstrapError.step("unpack", "privacy_box zip missing privacy_box/src/privacy_box.mojo")
        }

        // 3. Build privacy_box against its vendored siblings.
        let python = try findPython()
        set("Building privacy_box (first run, ~1 min)…")
        let mojo = privacy_boxMojoPrefix.appendingPathComponent("bin/mojo").path
        try run(mojo, ["build", "src/privacy_box.mojo",
                       "-I", "../flare", "-I", "../json", "-I", "../jinja2.mojo/src",
                       "-o", "build/privacy_box"],
                cwd: privacy_boxDir, env: privacy_boxMojoEnv(python: python))
        // The HTTP server for the web UI (serves web/dist + POST /chat on :10000).
        set("Building privacy_box web server…")
        try run(mojo, ["build", "src/server.mojo",
                       "-I", "../flare", "-I", "../json", "-I", "../jinja2.mojo/src",
                       "-o", "build/privacy_box-server"],
                cwd: privacy_boxDir, env: privacy_boxMojoEnv(python: python))

        // 4. Put the bundle's FFI shims under the toolchain's lib/, so flare finds
        //    them via $CONDA_PREFIX/lib at runtime — privacy_box runs WITH CONDA_PREFIX
        //    set (it shells `mojo build` for the sandboxed generated-code compile),
        //    unlike the always-serving server.
        try installPrivacyBoxShims()
        ensureConfig(at: privacy_boxConfigURL, Self.privacy_boxConfigDefault)
        await recordLatest("privacy_box", repo: "millfolio/privacy_box")
    }

    /// Copy the bundled relocatable FFI shims (+ their dylib deps) into the privacy_box
    /// Mojo prefix's lib/, where flare's `$CONDA_PREFIX/lib` lookup finds them.
    private func installPrivacyBoxShims() throws {
        let fm = FileManager.default
        let libDir = privacy_boxMojoPrefix.appendingPathComponent("lib", isDirectory: true)
        try fm.createDirectory(at: libDir, withIntermediateDirectories: true)
        let buildDir = privacy_boxDir.appendingPathComponent("build", isDirectory: true)
        for name in (try? fm.contentsOfDirectory(atPath: buildDir.path)) ?? []
        where name.hasSuffix(".so") || name.hasSuffix(".dylib") {
            let dst = libDir.appendingPathComponent(name)
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: buildDir.appendingPathComponent(name), to: dst)
        }
    }

    /// `mojo build` env for the privacy_box toolchain prefix.
    private func privacy_boxMojoEnv(python: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extraPath = "\(python.deletingLastPathComponent().path):\(privacy_boxMojoPrefix.appendingPathComponent("bin").path)"
        env["PATH"] = extraPath + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["CONDA_PREFIX"] = privacy_boxMojoPrefix.path
        env["MODULAR_HOME"] = privacy_boxMojoPrefix.appendingPathComponent("share/max").path
        return env
    }

    // ── privacy_box: start (open a ready-to-use Terminal) ──────────────────────────
    /// privacy_box is a one-shot CLI, so "start" opens a Terminal in the install dir
    /// with the toolchain env pre-set — the user sets ANTHROPIC_API_KEY, points it
    /// at their data, and runs `./build/privacy_box`.
    public func startPrivacyBox() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do { try await self.launchPrivacyBoxTerminal() }
            catch { await self.set(failed: "privacy_box: \(humanError(error))") }
        }
    }

    /// Write the `run-privacy_box.sh` launcher — sets the toolchain env (privacy_box
    /// shells `mojo build` for the sandboxed generated-code compile), cd's to the
    /// install dir, and execs the privacy_box binary, forwarding any args (`"$@"`) as
    /// the task. Shared by the menu app (runs it in a NEW Terminal) and the CLI
    /// (execs it in the CURRENT terminal so privacy_box takes over stdin/stdout — a
    /// one-shot run with a task, or an interactive REPL with none). Returns its path.
    @discardableResult
    public func writePrivacyBoxScript() throws -> URL {
        let mojoBin = privacy_boxMojoPrefix.appendingPathComponent("bin").path
        let modularHome = privacy_boxMojoPrefix.appendingPathComponent("share/max").path
        // Single-quote paths (they live under "Application Support" — note the space).
        let script = support.appendingPathComponent("run-privacy_box.sh")
        let body = """
        #!/bin/bash
        cd '\(privacy_boxDir.path)'
        export CONDA_PREFIX='\(privacy_boxMojoPrefix.path)'
        export MODULAR_HOME='\(modularHome)'
        export PATH='\(mojoBin)':"$PATH"
        # The vault path shells `<millfolio>/build/mill manifest`, compiles the
        # generated program with `-I <millfolio>/src` + its vendored siblings, and
        # reads the ~/.config/mill index. privacy_box defaults to the dev sibling
        # layout (../millfolio); point it at the installed millfolio checkout instead.
        export PRIVACY_BOX_MILLFOLIO='\(millfolioDir.path)'
        # flare's bundled OpenSSL has a CI-baked CA path; point it at the system
        # bundle so HTTPS to the Anthropic API verifies (else CertificateUntrusted).
        [ -f /etc/ssl/cert.pem ] && export SSL_CERT_FILE='/etc/ssl/cert.pem'
        exec ./build/privacy_box "$@"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    public func launchPrivacyBoxTerminal() async throws {
        let script = try writePrivacyBoxScript()
        let cmd = "'\(script.path)'"
        try run("/usr/bin/osascript",
                ["-e", "tell application \"Terminal\" to activate",
                 "-e", "tell application \"Terminal\" to do script \"\(cmd)\""])
    }

    // ── privacy_box: web (server on :10000 + open the browser) ─────────────────────
    /// Write the `run-privacy_box-web.sh` launcher: set the toolchain env, start the
    /// HTTP server (which serves the built web UI + the /chat API on :10000), and
    /// open the browser at it. Shared by the menu app (new Terminal) and the CLI
    /// (execs it in the current terminal). Returns its path.
    @discardableResult
    public func writePrivacyBoxWebScript() throws -> URL {
        let mojoBin = privacy_boxMojoPrefix.appendingPathComponent("bin").path
        let modularHome = privacy_boxMojoPrefix.appendingPathComponent("share/max").path
        let script = support.appendingPathComponent("run-privacy_box-web.sh")
        let body = """
        #!/bin/bash
        cd '\(privacy_boxDir.path)'
        export CONDA_PREFIX='\(privacy_boxMojoPrefix.path)'
        export MODULAR_HOME='\(modularHome)'
        export PATH='\(mojoBin)':"$PATH"
        # flare's bundled OpenSSL has a CI-baked CA path; use the system bundle.
        [ -f /etc/ssl/cert.pem ] && export SSL_CERT_FILE='/etc/ssl/cert.pem'
        # serve-web.sh: bind 127.0.0.1:10000, open the UI, and expose it on the
        # tailnet via `tailscale serve` when Tailscale is available (else localhost).
        exec bash scripts/serve-web.sh
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// Menu-app entry point: open the privacy_box web app in a new Terminal.
    public func startPrivacyBoxWeb() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do { try await self.launchPrivacyBoxWebTerminal() }
            catch { await self.set(failed: "privacy_box web: \(humanError(error))") }
        }
    }

    public func launchPrivacyBoxWebTerminal() async throws {
        let script = try writePrivacyBoxWebScript()
        let cmd = "'\(script.path)'"
        try run("/usr/bin/osascript",
                ["-e", "tell application \"Terminal\" to activate",
                 "-e", "tell application \"Terminal\" to do script \"\(cmd)\""])
    }

    /// Stop the privacy_box web server (started by `privacy_box web`). It runs as a
    /// foreground process (not a launchd agent), so terminate it by name —
    /// killing the server makes serve-web.sh's own `wait` return and its cleanup
    /// trap tear down any `tailscale serve` mapping. Returns true if one was
    /// running. Best-effort; never throws.
    @discardableResult
    public func stopPrivacyBoxWeb() -> Bool {
        // pkill exits 0 if it signaled at least one process, 1 if none matched.
        let hit = (try? runStatus("/usr/bin/pkill", ["-f", "build/privacy_box-server"])) == 0
        _ = try? runStatus("/usr/bin/pkill", ["-f", "scripts/serve-web.sh"])
        return hit
    }

    // ── millfolio: install ────────────────────────────────────────────────────────
    /// Menu-app entry point: fire-and-forget, drives `phase`.
    public func installMillfolio() {
        guard !isBusy else { return }
        phase = .running("Starting…")
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do { try await self.installMillfolioEngine(); await self.set(done: true) }
            catch { await self.set(failed: humanError(error)) }
        }
    }

    /// Download millfolio's Mojo toolchain + source bundle and build it. Same nightly
    /// as privacy_box; the bundle vendors flare/json + the LanceDB binding + pdftotext/
    /// zlib + prebuilt FFI shims, so the build uses `-I` includes + installs shims.
    public func installMillfolioEngine() async throws {
        // Idempotent: skip the whole download+build if the binary is already there.
        if isMillfolioInstalled
            && !mojoToolchainStale(millfolioMojoPrefix, Self.privacy_boxMojoVersion) {
            set("millfolio already installed — skipping")
            return
        }
        let fm = FileManager.default
        for d in [support, millfolioMojoPrefix, millfolioRoot, cacheDir] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        logHeader("Install millfolio")

        // 1. Mojo toolchain (same nightly as privacy_box).
        if mojoToolchainStale(millfolioMojoPrefix, Self.privacy_boxMojoVersion) {
            set("Downloading Mojo compiler for millfolio (~70 MB)…")
            try? fm.removeItem(at: millfolioMojoPrefix)   // clear any stale nightly
            try fm.createDirectory(at: millfolioMojoPrefix, withIntermediateDirectories: true)
            let compiler = try await download(millfolioMojoCompilerURL, name: "millfolio-mojo-compiler.conda")
            set("Extracting Mojo…")
            try extractConda(compiler, into: millfolioMojoPrefix)
            let py = try await download(millfolioMojoPythonURL, name: "millfolio-mojo-python.conda")
            try extractConda(py, into: millfolioMojoPrefix)
            recordMojoVersion(millfolioMojoPrefix, Self.privacy_boxMojoVersion)
        }
        try relocateMojoPrefix(millfolioMojoPrefix)

        // 2. millfolio source bundle (just source — no FFI/sibling deps yet).
        try await ensureBundle()
        guard fm.fileExists(atPath: millfolioDir.appendingPathComponent("src/millfolio.mojo").path) else {
            throw BootstrapError.step("unpack", "millfolio zip missing millfolio/src/millfolio.mojo")
        }

        // 3. Build millfolio against its vendored siblings (flare/json + the LanceDB
        //    binding + pdftotext/zlib readers), all bundled by package_millfolio.sh.
        let python = try findPython()
        set("Building millfolio (first run, ~1 min)…")
        let mojo = millfolioMojoPrefix.appendingPathComponent("bin/mojo").path
        try run(mojo, ["build", "src/millfolio.mojo",
                       "-I", "../flare", "-I", "../json", "-I", "../lancedb.mojo/src",
                       "-I", "../pdftotext.mojo/src", "-I", "../zlib.mojo/src",
                       "-I", "../csv.mojo/src",
                       "-o", "build/millfolio"],
                cwd: millfolioDir, env: millfolioMojoEnv(python: python))

        // 4. Put the bundle's FFI shims (libzlibmojo / liblancedbmojo / libflare_*
        //    + their dylib deps) under the toolchain's lib/, where each binding's
        //    `$CONDA_PREFIX/lib` lookup finds them at runtime (millfolio runs WITH
        //    CONDA_PREFIX set via run-millfolio.sh).
        try installMillfolioShims()
        await recordLatest("millfolio", repo: "millfolio/millfolio")
    }

    /// Copy the bundled relocatable FFI shims (+ their dylib deps) into the millfolio
    /// Mojo prefix's lib/, where flare/zlib/lancedb's `$CONDA_PREFIX/lib` lookup
    /// finds them. Mirrors installPrivacyBoxShims.
    private func installMillfolioShims() throws {
        let fm = FileManager.default
        let libDir = millfolioMojoPrefix.appendingPathComponent("lib", isDirectory: true)
        try fm.createDirectory(at: libDir, withIntermediateDirectories: true)
        let buildDir = millfolioDir.appendingPathComponent("build", isDirectory: true)
        for name in (try? fm.contentsOfDirectory(atPath: buildDir.path)) ?? []
        where name.hasSuffix(".so") || name.hasSuffix(".dylib") {
            let dst = libDir.appendingPathComponent(name)
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: buildDir.appendingPathComponent(name), to: dst)
        }
    }

    /// The vault program privacy_box compiles + runs executes under privacy_box's
    /// CONDA_PREFIX (privacy_box-mojo), so the millfolio vault FFI shims it dlopens
    /// (liblancedbmojo / libzlibmojo + their dylib deps) must live in
    /// privacy_box-mojo/lib too. Copy the ones privacy_box lacks from the millfolio
    /// toolchain (same Mojo nightly → ABI-compatible). Best-effort; idempotent.
    public func linkVaultShims() {
        let fm = FileManager.default
        let src = millfolioMojoPrefix.appendingPathComponent("lib")
        let dst = privacy_boxMojoPrefix.appendingPathComponent("lib")
        guard fm.fileExists(atPath: src.path) else { return }
        try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: src.path)) ?? []
        where name.hasSuffix(".dylib") || name.hasSuffix(".so") {
            let d = dst.appendingPathComponent(name)
            if !fm.fileExists(atPath: d.path) {   // don't clobber privacy_box's own shims
                try? fm.copyItem(at: src.appendingPathComponent(name), to: d)
            }
        }
    }

    /// A fresh per-ask transcript path: /tmp/millfolio/sessions/<timestamp>-<slug>.log.
    public func newSessionLog(for question: String) -> URL {
        let dir = URL(fileURLWithPath: "/tmp/millfolio/sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: Date())
        var slug = ""
        for c in question.lowercased() {
            slug.append((c.isLetter || c.isNumber) ? c : "-")
            if slug.count >= 40 { break }
        }
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "ask" }
        return dir.appendingPathComponent("\(stamp)-\(slug).log")
    }

    /// `mojo build` env for the millfolio toolchain prefix.
    private func millfolioMojoEnv(python: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extraPath = "\(python.deletingLastPathComponent().path):\(millfolioMojoPrefix.appendingPathComponent("bin").path)"
        env["PATH"] = extraPath + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["CONDA_PREFIX"] = millfolioMojoPrefix.path
        env["MODULAR_HOME"] = millfolioMojoPrefix.appendingPathComponent("share/max").path
        return env
    }

    /// Download the millfolio app bundle (millfolio/app) and build the streaming WS
    /// server (+ the unary HTTP server) ON-DEVICE against the already-installed
    /// privacy_box engine tree — reusing privacy_box's Mojo toolchain + flare shims, so
    /// no new toolchain. Requires the privacy_box engine (installPrivacyBoxEngine).
    public func installAppServer() async throws {
        if isAppServerInstalled {
            set("millfolio app server already installed — skipping")
            return
        }
        guard isPrivacyBoxInstalled else {
            throw BootstrapError.step("app server",
                "privacy_box engine not installed — run `mill install` first")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: appRoot, withIntermediateDirectories: true)
        logHeader("Install millfolio app server")

        try await ensureBundle()
        guard fm.fileExists(atPath: appRoot.appendingPathComponent("src/ws_server.mojo").path) else {
            throw BootstrapError.step("unpack", "millfolio-app.zip missing src/ws_server.mojo")
        }

        let python = try findPython()
        set("Building millfolio app server (first run, ~1 min)…")
        let mojo = privacy_boxMojoPrefix.appendingPathComponent("bin/mojo").path
        // Build against the installed privacy_box engine tree: the orchestrator
        // (privacy_box/src) + the vendored flare/json/jinja2 siblings under
        // privacy_box-engine/. Same -I set privacy_box's own server build uses, plus
        // privacy_box/src.
        let inc = [
            "-I", "src",  // the bundle's own modules (events.mojo, imported by ws_server)
            "-I", privacy_boxDir.appendingPathComponent("src").path,
            "-I", privacy_boxRoot.appendingPathComponent("flare").path,
            "-I", privacy_boxRoot.appendingPathComponent("json").path,
            "-I", privacy_boxRoot.appendingPathComponent("jinja2.mojo/src").path,
        ]
        let env = privacy_boxMojoEnv(python: python)
        // `mojo build -o build/…` won't create the output dir, and the app bundle
        // ships no build/ — make it (mirrors the pixi tasks' `mkdir -p build`).
        try fm.createDirectory(at: appRoot.appendingPathComponent("build"), withIntermediateDirectories: true)
        try run(mojo, ["build", "src/ws_server.mojo"] + inc + ["-o", "build/millfolio-ws"],
                cwd: appRoot, env: env)
        try run(mojo, ["build", "src/server.mojo"] + inc + ["-o", "build/millfolio-server"],
                cwd: appRoot, env: env)
        await recordLatest("app", repo: "millfolio/app")
    }

    // ── millfolio: start (open a ready-to-use Terminal) ───────────────────────────
    /// millfolio is a one-shot vault CLI, so "start" opens a Terminal in the install
    /// dir with the toolchain env pre-set — the user runs e.g.
    /// `./build/mill manifest ~/.config/millfolio/vault`.
    public func startMillfolio() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do { try await self.launchMillfolioTerminal() }
            catch { await self.set(failed: "millfolio: \(humanError(error))") }
        }
    }

    /// Write the `run-millfolio.sh` launcher — sets the toolchain env, cd's to the
    /// install dir, and execs the millfolio binary forwarding any args (`"$@"`).
    /// Shared by the menu app (new Terminal) and the CLI (execs in the current
    /// terminal). Returns its path.
    @discardableResult
    public func writeMillfolioScript() throws -> URL {
        let mojoBin = millfolioMojoPrefix.appendingPathComponent("bin").path
        let modularHome = millfolioMojoPrefix.appendingPathComponent("share/max").path
        let script = support.appendingPathComponent("run-millfolio.sh")
        let body = """
        #!/bin/bash
        cd '\(millfolioDir.path)'
        export CONDA_PREFIX='\(millfolioMojoPrefix.path)'
        export MODULAR_HOME='\(modularHome)'
        export PATH='\(mojoBin)':"$PATH"
        exec ./build/millfolio "$@"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    public func launchMillfolioTerminal() async throws {
        let script = try writeMillfolioScript()
        let cmd = "'\(script.path)'"
        try run("/usr/bin/osascript",
                ["-e", "tell application \"Terminal\" to activate",
                 "-e", "tell application \"Terminal\" to do script \"\(cmd)\""])
    }

    // ── millfolio: the VAULT umbrella (engine + privacy_box + vault) ──────────────────
    // millfolio is the umbrella entry point for the personal-data-vault use case. It
    // composes the three engines: the combined inference server (chat + embeddings
    // — both models' weights), privacy_box (the harness + its vault web chat), and the
    // millfolio vault tools/indexer.

    /// Resolve the vault dir: an explicit arg wins, then $MILLFOLIO_VAULT, then
    /// ~/.config/millfolio/vault. The Swift side always passes this through to the
    /// engines (MILLFOLIO_VAULT env / explicit arg), so it's the canonical location.
    public func vaultDir(_ arg: String? = nil) -> String {
        if let arg, !arg.isEmpty { return arg }
        let env = ProcessInfo.processInfo.environment["MILLFOLIO_VAULT"]
        if let env, !env.isEmpty { return env }
        return dotConfig.appendingPathComponent("millfolio/vault", isDirectory: true).path
    }

    /// Resolve the vault dir AND create it if missing. The millfolio binary's
    /// `manifest`/indexer require the vault dir to exist, but on a clean machine
    /// the default (~/.config/millfolio/vault) isn't there yet — so install/start would fail with
    /// "the directory … does not exist". Idempotent; returns the resolved path.
    @discardableResult
    public func ensureVaultDir(_ arg: String? = nil) -> String {
        let dir = vaultDir(arg)
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `mill install` — install the combined inference server (+ both
    /// models' weights) + privacy_box + millfolio, idempotently. Each step skips what's
    /// already installed (see the guards in installServer/PrivacyBoxEngine/Millfolio-
    /// Engine), so re-running is cheap and reuses anything present.
    public func installVault() async throws {
        try await installServer()           // engine + chat + embedding weights
        try await installPrivacyBoxEngine()   // the harness + vault web chat server
        try await installMillfolioEngine()    // the vault tools + indexer
        linkVaultShims()                    // millfolio FFI shims → privacy_box-mojo/lib (vault-run dlopen)
        ensureVaultDir()                    // leave the default vault dir ready
    }

    /// Menu-app entry point: fire-and-forget umbrella install, drives `phase`.
    public func installVaultFireAndForget() {
        guard !isBusy else { return }
        phase = .running("Starting…")
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do { try await self.installVault(); await self.set(done: true) }
            catch { await self.set(failed: humanError(error)) }
        }
    }

    /// Write `run-millfolio-web.sh` — the VAULT web chat launcher. Like
    /// writePrivacyBoxWebScript, but exports PRIVACY_BOX_VAULT=1 + PRIVACY_BOX_VAULT_DIR
    /// (+ MILLFOLIO_VAULT and the loopback millfolio URLs) and execs privacy_box's
    /// serve-web.sh, so the privacy_box web server comes up in VAULT mode pointed at
    /// the vault dir. The vault tools the generated program calls reach the
    /// combined inference server over loopback (:8000). Returns its path.
    @discardableResult
    public func writeMillfolioWebScript(vaultDir dir: String) throws -> URL {
        let mojoBin = privacy_boxMojoPrefix.appendingPathComponent("bin").path
        let modularHome = privacy_boxMojoPrefix.appendingPathComponent("share/max").path
        let script = support.appendingPathComponent("run-millfolio-web.sh")
        let body = """
        #!/bin/bash
        cd '\(privacy_boxDir.path)'
        export CONDA_PREFIX='\(privacy_boxMojoPrefix.path)'
        export MODULAR_HOME='\(modularHome)'
        export PATH='\(mojoBin)':"$PATH"
        [ -f /etc/ssl/cert.pem ] && export SSL_CERT_FILE='/etc/ssl/cert.pem'
        # VAULT mode: the privacy_box web server answers questions about the vault dir.
        export PRIVACY_BOX_VAULT=1
        export PRIVACY_BOX_VAULT_DIR='\(dir)'
        export MILLFOLIO_VAULT='\(dir)'
        # The vault tools (search/ask_local) hit the combined inference server over
        # loopback — embeddings + chat on one port (:8000).
        export MILLFOLIO_EMBED_URL='http://127.0.0.1:8000/v1'
        export MILLFOLIO_LOCAL_URL='http://127.0.0.1:8000/v1'
        # privacy_box compiles the generated vault program against the millfolio sources —
        # point its -I resolution at the installed millfolio checkout.
        export PRIVACY_BOX_MILLFOLIO='\(millfolioDir.path)'
        exec bash scripts/serve-web.sh
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// Cutover launcher (two local servers): millfolio-server serves the web UI on
    /// :10000, millfolio-ws streams on :10001 — flare can't do both on one port. Both
    /// run from the app bundle dir (so `./web/dist` resolves) with privacy_box's
    /// toolchain env (CONDA_PREFIX + flare shims) + the vault resolution env. Opens
    /// the browser; kills the background WS server when the foreground static
    /// server exits.
    public func writeMillfolioAppScript(vaultDir dir: String) throws -> URL {
        let mojoBin = privacy_boxMojoPrefix.appendingPathComponent("bin").path
        let modularHome = privacy_boxMojoPrefix.appendingPathComponent("share/max").path
        let serverLog = millfolioLogDir.appendingPathComponent("server.log").path
        let script = support.appendingPathComponent("run-millfolio-app.sh")
        let serverBin = appRoot.appendingPathComponent("build/millfolio-server").path
        let wsBin = appRoot.appendingPathComponent("build/millfolio-ws").path
        let body = """
        #!/bin/bash
        # Run from the privacy_box engine dir: the vault orchestrator reads its
        # sandbox/*.sb.template profiles relative to cwd (the same dir the `ask`
        # launcher uses). The UI is served via MILLFOLIO_WEB_DIR (absolute), and the
        # server binaries are referenced by absolute path, so cwd can be privacy_box's.
        cd '\(privacy_boxDir.path)'
        export CONDA_PREFIX='\(privacy_boxMojoPrefix.path)'
        export MODULAR_HOME='\(modularHome)'
        export PATH='\(mojoBin)':"$PATH"
        [ -f /etc/ssl/cert.pem ] && export SSL_CERT_FILE='/etc/ssl/cert.pem'
        export PRIVACY_BOX_VAULT_DIR='\(dir)'
        export MILLFOLIO_VAULT='\(dir)'
        # The vault tools (search/ask_local) hit the combined inference server over
        # loopback — embeddings + chat on one port (:8000).
        export MILLFOLIO_EMBED_URL='http://127.0.0.1:8000/v1'
        export MILLFOLIO_LOCAL_URL='http://127.0.0.1:8000/v1'
        # millfolio-ws compiles the generated vault program against the millfolio sources.
        export PRIVACY_BOX_MILLFOLIO='\(millfolioDir.path)'
        # Serve the built UI by ABSOLUTE path so it doesn't depend on cwd.
        export MILLFOLIO_WEB_DIR='\(appRoot.appendingPathComponent("web/dist").path)'
        # Run both servers detached in the BACKGROUND (no Terminal) — static UI on
        # :10000, streaming WS on :10001 — logging to the millfolio server log. nohup
        # so they survive this launcher (and the CLI) exiting; `mill stop` reaps
        # them. This launcher spawns them and exits immediately.
        LOG='\(serverLog)'
        mkdir -p "$(dirname "$LOG")"
        echo "=== millfolio app servers starting $(date) ===" >> "$LOG"
        nohup '\(serverBin)' >> "$LOG" 2>&1 &
        nohup '\(wsBin)'     >> "$LOG" 2>&1 &
        ( sleep 1.5 && open 'http://localhost:10000' ) >/dev/null 2>&1 &
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// `mill start`: ensure the combined inference server is running (launchd),
    /// then start the vault app servers in the BACKGROUND (no Terminal) and open
    /// http://localhost:10000. Server output goes to the millfolio server log.
    public func startVaultChat(vaultDir dir: String) async throws {
        // 0. The vault dir must exist before privacy_box/millfolio's `manifest` runs
        //    over it (a clean machine has no vault dir yet).
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        // 1. Ensure the combined inference server is up (idempotent).
        if isServerInstalled && weightsPresent {
            refreshServerRunning()
            if !serverRunning { try startServer() }
        }
        // Reap any stale servers holding :10000/:10001 (a prior `start`, or the
        // legacy privacy_box web server) so the fresh ones can bind cleanly.
        _ = stopAppServer()
        _ = stopPrivacyBoxWeb()
        // 2. Start the vault chat. With the app server, the launcher spawns both
        //    servers detached in the background and opens the browser, then exits —
        //    no Terminal window (clients are web/mobile). Fall back to the legacy
        //    privacy_box web UI (still a Terminal) only when the app server is absent.
        if isAppServerInstalled {
            let script = try writeMillfolioAppScript(vaultDir: dir)
            try run("/bin/bash", [script.path])
        } else {
            let script = try writeMillfolioWebScript(vaultDir: dir)
            let cmd = "'\(script.path)'"
            try run("/usr/bin/osascript",
                    ["-e", "tell application \"Terminal\" to activate",
                     "-e", "tell application \"Terminal\" to do script \"\(cmd)\""])
        }
    }

    /// Ensure the combined inference server is running (idempotent). No-op if it
    /// isn't installed yet — the caller surfaces that downstream. Without this,
    /// `ask`/the vault loop blocks on a dead model endpoint with no clue why.
    public func ensureInferenceServer() throws {
        guard isServerInstalled && weightsPresent else { return }
        refreshServerRunning()
        if !serverRunning {
            set("Starting the inference server (loading model weights can take a bit)…")
            try startServer()
        }
    }

    /// Stop the background app servers (millfolio-server + millfolio-ws). Returns true
    /// if at least one was running.
    public func stopAppServer() -> Bool {
        let ws = (try? runStatus("/usr/bin/pkill", ["-f", "build/millfolio-ws"])) == 0
        let srv = (try? runStatus("/usr/bin/pkill", ["-f", "build/millfolio-server"])) == 0
        return ws || srv
    }

    /// Menu-app entry point: open the vault chat (fire-and-forget).
    public func startVaultChatFireAndForget() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do { try await self.startVaultChat(vaultDir: self.vaultDir()) }
            catch { await self.set(failed: "vault chat: \(humanError(error))") }
        }
    }

    // ── helpers ────────────────────────────────────────────────────────────────
    @discardableResult
    private func run(_ launch: String, _ args: [String], cwd: URL? = nil, env: [String: String]? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        if let env { p.environment = env }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        appendLog("\n$ \(launch) \(args.joined(separator: " "))\n")
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        appendLog(out)
        if p.terminationStatus != 0 {
            appendLog("\n[\(URL(fileURLWithPath: launch).lastPathComponent) exited \(p.terminationStatus)]\n")
            throw BootstrapError.step(URL(fileURLWithPath: launch).lastPathComponent,
                                      "exit \(p.terminationStatus): " + out.suffix(500))
        }
        return out
    }

    /// Like `run`, but returns the exit status instead of throwing on nonzero —
    /// for probes (launchctl print/bootout) where a nonzero code is expected.
    @discardableResult
    private func runStatus(_ launch: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        _ = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus
    }

    // ── diagnosable one-shot runs (ask / index) ────────────────────────────────
    // The `ask` and `index` subcommands used to execv /bin/bash, which REPLACES
    // this process — so a failure inside the child (e.g. privacy_box's `posix_spawn`
    // of the mojo compiler failing with ENOENT) left nothing to log. These run the
    // launcher as a child instead, mirroring its combined stdout/stderr to both the
    // terminal and the millfolio log, after dumping the launcher + the paths it
    // depends on. Returns the child's exit status (caller maps it to the CLI exit).

    /// Run the privacy_box vault loop for one question. See runLoggedScript.
    public func runVaultAsk(question: String, vaultDir: String) throws -> Int32 {
        refreshServerRunning()
        let script = try writePrivacyBoxScript()
        let args = ["vault", question, vaultDir]
        logRunDiagnostics(label: "ask", launcher: script, args: args, probes: [
            ("privacy_box launcher", script.path),
            ("privacy_box dir (cwd)", privacy_boxDir.path),
            ("privacy_box binary", privacy_boxBin.path),
            ("mojo compiler (privacy_box shells it)", privacy_boxMojoPrefix.appendingPathComponent("bin/mojo").path),
            ("millfolio vault tools (src)", millfolioDir.appendingPathComponent("src/vault.mojo").path),
            ("vault dir", vaultDir),
        ])
        // Per-ask transcript: the CLI names it (timestamp + question slug) and the
        // privacy_box orchestrator appends the outside-model prompt + program to it.
        let session = newSessionLog(for: question)
        set("session transcript → \(session.path)")
        return try runLoggedScript(script.path, args, label: "ask",
                                   env: ["MILLFOLIO_SESSION_LOG": session.path])
    }

    /// Run the millfolio engine `index <folder>`. See runLoggedScript.
    public func runVaultIndex(folder: String) throws -> Int32 {
        refreshServerRunning()
        let script = try writeMillfolioScript()
        let args = ["index", folder]
        logRunDiagnostics(label: "index", launcher: script, args: args, probes: [
            ("millfolio launcher", script.path),
            ("millfolio dir (cwd)", millfolioDir.path),
            ("millfolio binary", millfolioBin.path),
            ("mojo compiler", millfolioMojoPrefix.appendingPathComponent("bin/mojo").path),
            ("folder", folder),
        ])
        return try runLoggedScript(script.path, args, label: "index")
    }

    /// Dump everything useful for diagnosing a spawn failure: the exact command,
    /// whether each dependency path exists (and is executable), the launcher's
    /// contents (which set PATH/CONDA_PREFIX/MODULAR_HOME), and the inherited PATH.
    private func logRunDiagnostics(label: String, launcher: URL, args: [String], probes: [(String, String)]) {
        let fm = FileManager.default
        vlog("\n===== millfolio \(label) — \(Self.stamp()) =====")
        vlog("command: /bin/bash \(launcher.path) \(args.joined(separator: " "))")
        vlog("server running: \(serverRunning)")
        vlog("paths:")
        for (name, path) in probes {
            let tag = !fm.fileExists(atPath: path) ? "MISSING"
                    : fm.isExecutableFile(atPath: path) ? "exec" : "ok"
            vlog("  [\(tag)] \(name): \(path)")
        }
        if let body = try? String(contentsOf: launcher, encoding: .utf8) {
            vlog("launcher \(launcher.lastPathComponent):")
            for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
                vlog("  | \(line)")
            }
        }
        vlog("inherited PATH: \(ProcessInfo.processInfo.environment["PATH"] ?? "(unset)")")
        vlog("----- child output -----")
    }

    /// Run `/bin/bash <script> <args…>` as a child, teeing its combined stdout and
    /// stderr to BOTH this terminal and the millfolio log. Streams live (so long runs
    /// show progress) and returns the exit status without throwing on nonzero.
    @discardableResult
    public func runLoggedScript(_ scriptPath: String, _ args: [String], label: String,
                                env extra: [String: String] = [:]) throws -> Int32 {
        let logFH = try? FileHandle(forWritingTo: ensureMillfolioLog())
        logFH?.seekToEndOfFile()
        let out = FileHandle.standardOutput
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [scriptPath] + args
        if !extra.isEmpty {
            var e = ProcessInfo.processInfo.environment
            for (k, v) in extra { e[k] = v }
            p.environment = e
        }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        // standardInput is left inherited, so an interactive child still works.
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            out.write(d)
            logFH?.write(d)
        }
        do {
            try p.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            vlog("[\(label)] failed to launch /bin/bash: \(error)")
            try? logFH?.close()
            throw error
        }
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        let rest = pipe.fileHandleForReading.readDataToEndOfFile()
        if !rest.isEmpty { out.write(rest); logFH?.write(rest) }
        let code = p.terminationStatus
        vlog("[\(label)] exit status: \(code)")
        try? logFH?.close()
        return code
    }

    // ── self-update (CLI + components) ──────────────────────────────────────────
    /// Update the `millfolio` CLI via Homebrew (best-effort), then refresh the
    /// downloadable components — the inference-server engine, privacy_box, and the
    /// millfolio engine — to their latest releases. The pinned Mojo toolchains and the
    /// (multi-GB) model weights are preserved; only the source bundles are re-fetched
    /// and rebuilt. Progress streams through `onProgress`.
    public func selfUpdate(updateCLI: Bool = true) async throws {
        vlog("\n===== mill update — \(Self.stamp()) =====")
        if updateCLI { updateHomebrewCLI() }

        // First reference to each component introduces it with a gloss; the
        // granular install steps below then use the short product name.
        // All components ship in ONE millfolio.zip now. Refresh by dropping the whole
        // unpacked bundle (incl. its .unpacked stamp) ONCE — `ensureBundle` (called by
        // installServer below) then re-fetches the latest bundle, and each install
        // rebuilds its component from it. Removing the per-component roots individually
        // would leave the stamp in place, so ensureBundle would skip the re-unpack and
        // the build would fail on a missing `inference-server`. Model weights (hf/) and
        // the Mojo toolchain (mojo/) live outside bundleRoot and are kept.
        try? FileManager.default.removeItem(at: bundleRoot)

        set("Refreshing engine, the inference server…")
        try await installServer()

        set("Refreshing privacy_box, the privacy agent harness…")
        try await installPrivacyBoxEngine()

        set("Refreshing millfolio, the vault engine…")
        try await installMillfolioEngine()
        linkVaultShims()   // millfolio FFI shims → the shared toolchain lib (vault-run dlopen)

        // The streaming app server (built on-device against privacy_box). A real build
        // error must fail the update, not be swallowed (else `mill update` falsely
        // reports success).
        set("Refreshing millfolio app server…")
        try await installAppServer()

        vlog("update complete")
    }

    /// Upgrade the CLI via Homebrew if it's installed that way. Best-effort: if brew
    /// or the formula isn't present, log it and carry on (components still refresh).
    private func updateHomebrewCLI() {
        let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let brew else {
            set("• Homebrew not found — skipping CLI self-update")
            vlog("brew not found at /opt/homebrew or /usr/local; skipped CLI self-update")
            return
        }
        set("Updating the millfolio CLI via Homebrew…")
        _ = try? run(brew, ["update"])   // refresh tap metadata (non-fatal if offline)
        do {
            let out = try run(brew, ["upgrade", "millfolio/tap/mill"])
            vlog("brew upgrade:\n\(out)")
            set("✓ CLI updated (takes effect next run)")
        } catch {
            // `brew upgrade` reports nonzero when nothing to do or the formula isn't
            // installed via brew — neither is fatal to a component refresh.
            vlog("brew upgrade (non-fatal): \(humanError(error))")
            set("• CLI not upgraded via Homebrew (already latest, or not a brew install)")
        }
    }

    // ── component versions ──────────────────────────────────────────────────────
    // Each downloadable component records its installed release tag under
    // support/versions/ at install time (resolved from the repo's releases/latest);
    // `mill version` and `mill update` read them back. The CLI's own version
    // comes from Homebrew.
    private var versionsDir: URL { support.appendingPathComponent("versions", isDirectory: true) }

    /// Resolve a repo's latest release tag from the GitHub API ("" on failure).
    private func latestTag(_ repo: String) async -> String {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")
        else { return "" }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 8
        guard let pair = try? await URLSession.shared.data(for: req),
              (pair.1 as? HTTPURLResponse)?.statusCode == 200,
              let s = String(data: pair.0, encoding: .utf8),
              let r = s.range(of: "\"tag_name\":\"") else { return "" }
        let rest = s[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return "" }
        return String(rest[..<end])
    }

    /// Record `name`'s installed version (the repo's latest tag). Best-effort.
    func recordLatest(_ name: String, repo: String) async {
        let tag = await latestTag(repo)
        guard !tag.isEmpty else { return }
        try? FileManager.default.createDirectory(at: versionsDir, withIntermediateDirectories: true)
        try? tag.write(to: versionsDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func readVersion(_ name: String) -> String {
        (try? String(contentsOf: versionsDir.appendingPathComponent(name), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// The CLI's own version, from Homebrew ("" if not a brew install).
    private func brewCliVersion() -> String {
        guard let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return "" }
        guard let out = try? run(brew, ["list", "--versions", "millfolio/tap/mill"]) else { return "" }
        let toks = out.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        return toks.count >= 2 ? "v" + toks.last! : ""
    }

    /// Installed versions of millfolio + its components (label, version) for display.
    public func componentVersions() -> [(String, String)] {
        func shown(_ s: String) -> String { s.isEmpty ? "—" : s }
        return [
            ("cli (millfolio)", shown(brewCliVersion())),
            ("inference server", shown(readVersion("inference-server"))),
            ("privacy_box", shown(readVersion("privacy_box"))),
            ("millfolio engine", shown(readVersion("millfolio"))),
            ("app server", shown(readVersion("app"))),
        ]
    }

    // ── phase / progress sink ───────────────────────────────────────────────────
    private func set(_ msg: String) {
        phase = .running(msg)
        onProgress?(msg)
    }
    private func set(done: Bool) { phase = .done }
    private func set(failed msg: String) { phase = .failed(msg) }
}

public enum BootstrapError: Error, CustomStringConvertible {
    case step(String, String)
    public var description: String {
        switch self { case .step(let s, let m): return "\(s): \(m)" }
    }
}

func humanError(_ error: Error) -> String {
    if let b = error as? BootstrapError { return b.description }
    return (error as NSError).localizedDescription
}
