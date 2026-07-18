import Foundation
import Darwin
import ArgumentParser
import MillfolioCore

// The `millfolio` CLI — the personal-data-vault umbrella. It drives the same engine
// lifecycle as the millfolio app's Bootstrapper, into the shared install tree
// (~/Library/Application Support/Millfolio) + the me.millfolio.server launchd job, so
// `millfolio` and the `millfolio` CLI interoperate on one inference server. `install`
// provisions the server + enclave + the millfolio vault; `start` brings them all up
// (the vault site at http://localhost:10000); `stop` tears them down.

@main
struct Millfolio: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mill",
        abstract: "The millfolio personal data vault — install, start, stop, index, and ask.",
        subcommands: [Install.self, Update.self, Version.self, Start.self, Stop.self, Status.self, Index.self, Ask.self, Run.self, Export.self, Import.self, Get.self, SetCmd.self, Doctor.self]
    )
}

// ── mill install ──────────────────────────────────────────────────────────
struct Install: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install the millfolio inference server, enclave, and the millfolio web app.",
        discussion: """
        Idempotent — reuses anything already installed. Provisions the combined \
        inference server (chat + embeddings, including both models' weights), the \
        enclave vault harness + sandbox, the millfolio vault tools, and the \
        millfolio web app (UI on :10000). If millfolio was already running, it is \
        restarted so the freshly installed version actually serves (--no-restart \
        to leave the old one running).
        """)
    @Flag(name: .long, help: "Leave an already-running millfolio serving the old version (skip the automatic restart).")
    var noRestart = false

    @MainActor func run() async throws {
        let boot = streaming()
        print("Logging to \(boot.logFileURL.path)")
        print("  (if a step fails, the full timestamped output is there)")
        try await boot.installVault()
        print("✓ millfolio installed (inference server + enclave + millfolio web app)")
        try await restartToApply(boot, skip: noRestart)
    }
}

/// Install/update refresh the components on DISK, but a previously-running
/// server keeps serving the OLD build (the UI shows "restart to apply") until
/// it restarts. When something was serving, do that restart here — full stop
/// (engine + app) then start — so the new version goes live without a manual
/// `mill stop && mill start`. openBrowser:false — a restart is not a
/// user-initiated start: the menu-bar app / existing browser tab reconnects.
@MainActor private func restartToApply(_ boot: Bootstrapper, skip: Bool) async throws {
    if skip || !boot.appServerActive { return }
    print("Restarting millfolio to apply the new version…")
    try boot.stopServer()
    _ = boot.stopAppServer()
    for port in [8000, 10000, 10001] { boot.killStaleOnPort(port) }
    try await boot.startVaultChat(vaultDir: boot.ensureVaultDir(), openBrowser: false)
    print("✓ millfolio restarted — http://localhost:10000")
}

// ── mill update ─────────────────────────────────────────────────────────────
struct Update: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Update millfolio and its components to the latest release.",
        discussion: """
        Upgrades the `millfolio` CLI via Homebrew, then refreshes the downloadable \
        components (inference server, enclave, vault engine, app web server) to their \
        latest releases. The Mojo toolchains and the model weights are kept, so it \
        only re-fetches + rebuilds the source bundles. Progress is logged to \
        ~/Library/Logs/Millfolio/<date>.log.
        """)
    @Flag(name: .long, help: "Refresh the components only; don't upgrade the CLI via Homebrew.")
    var skipCli = false

    @Flag(name: .long, help: "Leave an already-running millfolio serving the old version (skip the automatic restart).")
    var noRestart = false

    @MainActor func run() async throws {
        let boot = streaming()
        print("Versions before update:")
        printVersions(boot.componentVersions())
        print("")
        try await boot.selfUpdate(updateCLI: !skipCli, noRestart: noRestart)
        print("\nVersions after update:")
        printVersions(boot.componentVersions())
        print("✓ millfolio up to date")
        try await restartToApply(boot, skip: noRestart)
    }
}

// ── mill version ────────────────────────────────────────────────────────────
struct Version: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the installed versions of millfolio and its components.")
    @MainActor func run() async throws {
        printVersions(Bootstrapper().componentVersions())
    }
}

/// Print a (component, version) list aligned for the console.
@MainActor private func printVersions(_ versions: [(String, String)]) {
    for (name, ver) in versions {
        print("  " + name.padding(toLength: 18, withPad: " ", startingAt: 0) + ver)
    }
}

// ── mill start ────────────────────────────────────────────────────────────
struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start everything — the inference server and the millfolio app at http://localhost:10000.",
        discussion: """
        Ensures the combined inference server is running (launchd), then starts the \
        millfolio app servers (UI on :10000, streaming on :10001) in the background — \
        no Terminal — and opens http://localhost:10000. Server logs:
        ~/Library/Logs/Millfolio/server.log.
        """)
    @Flag(name: .long, help: "Don't open the browser (it is auto-skipped anyway while the menu-bar app is running — the app IS the browser).")
    var noOpen = false

    @MainActor func run() async throws {
        let boot = streaming()   // engine-load phases print as they happen
        try await boot.startVaultChat(vaultDir: boot.ensureVaultDir(), openBrowser: !noOpen)
        print("✓ millfolio running in the background — http://localhost:10000")
        print("  logs: \(boot.millfolioLogDir.appendingPathComponent("server.log").path)")
    }
}

// ── mill stop ─────────────────────────────────────────────────────────────
struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop the inference server and the millfolio local site.")
    @MainActor func run() async throws {
        let boot = Bootstrapper()
        boot.refreshServerRunning()
        let wasRunning = boot.serverRunning
        try boot.stopServer()
        print(wasRunning ? "✓ inference server stopped" : "• inference server was not running")
        let stoppedApp = boot.stopAppServer()
        print(stoppedApp ? "✓ millfolio app stopped" : "• millfolio app was not running")
        // Belt-and-suspenders: reap anything still LISTENING on our ports that
        // bootout/pkill missed, so the next `start` never hits AddressInUse.
        for port in [8000, 10000, 10001] { boot.killStaleOnPort(port) }
    }
}

// ── mill status ───────────────────────────────────────────────────────────
struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show what's installed.")
    @MainActor func run() async throws {
        let boot = Bootstrapper()
        print("server:     \(mark(boot.isServerInstalled))")
        print("weights:    \(mark(boot.weightsPresent))")
        print("embeddings: \(mark(boot.embedWeightsPresent))")
        print("enclave:   \(mark(boot.isEnclaveInstalled))")
        print("millfolio:    \(mark(boot.isMillfolioInstalled))")
        print("app web server: \(mark(boot.isAppServerInstalled))")
        // Active vault (multi-vault): which vault `mill index/ask/run` operate on.
        // Only shown once the registry exists (the app has run + seeded it); a
        // pure-CLI single-vault install has no registry and prints nothing here.
        if let av = boot.activeVault() {
            let tag = av.id == "main" ? "" : "  [\(av.id)]"
            print("active vault: \(av.name)\(tag) — \(av.source)")
            print("  index data: \(av.dataDir)")
        }
        // Live health (probe the port, not just "installed"): is the inference
        // server actually answering on :8000, and at what build version?
        if let v = boot.inferenceVersion() {
            print("inference:  ✓ running on :8000" + (v.isEmpty ? "" : " (engine v\(v))"))
            // Decode health: a wedged Metal queue keeps the engine "responding"
            // while decode crawls at ~0.3 tok/s. Only shown for engines new enough
            // to report it, and only once a real generation has set a rate.
            if let dh = boot.decodeHealth() {
                let rate = dh.tokPerSec.map { String(format: "%.1f tok/s", $0) }
                if !dh.healthy {
                    print("decode:     ✗ WEDGED (\(rate ?? "0 tok/s")) — restart: `mill stop && mill start`")
                } else if let rate {
                    print("decode:     ✓ \(rate)")
                }
            }
        } else {
            print("inference:  ✗ not responding on :8000 (run `mill start`)")
        }
    }
}

// ── mill get / set (config: amount-password) ──────────────────────────────────
struct Get: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read a millfolio setting — currently `mill get amount-password`.",
        discussion: """
        amount-password is the passphrase that unlocks on-screen amounts in the web \
        app (Vault → Records → Show amounts). A random 3-word one is generated on \
        first use; change it with `mill set amount-password <words>`.
        """)
    @Argument(help: "The setting to read (amount-password).")
    var key: String

    @MainActor func run() async throws {
        guard key == "amount-password" else {
            FileHandle.standardError.write(Data(
                "mill get: unknown setting '\(key)' (try: amount-password)\n".utf8))
            throw ExitCode.failure
        }
        let r = Bootstrapper().runVaultConfig(["amount-password", "get"])
        guard r.code == 0 else {
            FileHandle.standardError.write(Data(
                "mill get: \(r.out.isEmpty ? "failed — is millfolio installed? (mill install)" : r.out)\n".utf8))
            throw ExitCode.failure
        }
        print(r.out)
    }
}

struct SetCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Change a millfolio setting — currently `mill set amount-password <words>`.")
    @Argument(help: "The setting to write (amount-password).")
    var key: String
    @Argument(help: "The value — for amount-password, a memorable phrase (multiple words ok).")
    var value: [String]

    @MainActor func run() async throws {
        guard key == "amount-password" else {
            FileHandle.standardError.write(Data(
                "mill set: unknown setting '\(key)' (try: amount-password)\n".utf8))
            throw ExitCode.failure
        }
        guard !value.isEmpty else {
            FileHandle.standardError.write(Data(
                "mill set amount-password: give a phrase, e.g. `mill set amount-password river copper lantern`\n".utf8))
            throw ExitCode.failure
        }
        let r = Bootstrapper().runVaultConfig(["amount-password", "set"] + value)
        guard r.code == 0 else {
            FileHandle.standardError.write(Data(
                "mill set: \(r.out.isEmpty ? "failed" : r.out)\n".utf8))
            throw ExitCode.failure
        }
        print(r.out)  // the stored phrase, echoed back as confirmation
    }
}

// ── mill doctor ─────────────────────────────────────────────────────────────
struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Diagnose the environment + install; optionally file a report on GitHub Discussions.")
    @Flag(name: .customLong("no-prompt"), help: "Print the report only; skip the bug-report prompt.")
    var noPrompt = false

    @MainActor func run() async throws {
        let boot = Bootstrapper()
        let fm = FileManager.default
        var checks: [(String, Bool, String)] = []   // (label, ok, hint-when-failing)

        // ── environment — the build prerequisites are the SAME checks `mill install`
        // gates on (boot.preflightEnv()), so doctor and the install preflight never drift.
        let osVer = sh("/usr/bin/sw_vers", ["-productVersion"]).out  // kept for the report title
        for c in boot.preflightEnv() { checks.append((c.label, c.ok, c.hint)) }
        checks.append(("Homebrew",
                       ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].contains { fm.isExecutableFile(atPath: $0) },
                       "https://brew.sh"))
        let vals = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let freeGB = Double(vals?.volumeAvailableCapacityForImportantUsage ?? 0) / 1e9
        checks.append((String(format: "Free disk — %.0f GB", freeGB), freeGB >= 10,
                       "a fresh install needs ~8 GB (toolchain + weights)"))

        // ── install state ──
        checks.append(("Inference server built", boot.isServerInstalled, "run: mill install"))
        checks.append(("Chat model weights", boot.weightsPresent, "run: mill install"))
        checks.append(("Embedding model weights", boot.embedWeightsPresent, "run: mill install"))
        checks.append(("enclave built", boot.isEnclaveInstalled, "run: mill install"))
        checks.append(("Vault tools built", boot.isMillfolioInstalled, "run: mill install"))
        checks.append(("App web server built", boot.isAppServerInstalled, "run: mill install"))
        let engineUp = boot.inferenceVersion() != nil
        checks.append(("Inference server responding (:8000)", engineUp, "run: mill start"))
        // Decode-wedge check — only meaningful when the engine is up AND reports the
        // signal AND has decoded at least once (nil health → skip, not a failure).
        if engineUp, let dh = boot.decodeHealth(), dh.tokPerSec != nil {
            let rate = dh.tokPerSec.map { String(format: " (%.1f tok/s)", $0) } ?? ""
            checks.append(("Engine decode healthy\(rate)", dh.healthy,
                           "Metal decode is wedged — restart: mill stop && mill start"))
        }

        // ── render to the console ──
        print("mill doctor — environment + install\n")
        var failures = 0
        for (label, ok, hint) in checks {
            print(ok ? "  ✓ \(label)" : "  ✗ \(label)  — \(hint)")
            if !ok { failures += 1 }
        }
        print("\nVersions:")
        printVersions(boot.componentVersions())
        print("\nLog: \(boot.logFileURL.path)")
        print(failures == 0 ? "\n✓ all checks passed" : "\n✗ \(failures) issue(s) found")

        // ── assemble a markdown report (also copied to the clipboard) ──
        let logTail = (try? String(contentsOf: boot.logFileURL, encoding: .utf8))
            .map { $0.components(separatedBy: "\n").suffix(40).joined(separator: "\n") } ?? "(no log)"
        var md = "### `mill doctor` report\n\n_Describe what you were doing / what failed:_\n\n\n"
        md += "| check | status |\n|---|---|\n"
        for (label, ok, hint) in checks { md += "| \(label) | \(ok ? "✓" : "✗ — \(hint)") |\n" }
        md += "\n**Versions**\n\n"
        for (n, v) in boot.componentVersions() { md += "- \(n): \(v)\n" }
        md += "\n<details><summary>Recent log tail</summary>\n\n```\n\(logTail)\n```\n</details>\n"

        // ── offer to file a report ──
        if noPrompt { return }
        print("\nFile a report on GitHub Discussions? (pre-fills your environment; also copied to your clipboard) [y/N] ", terminator: "")
        let ans = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        guard ans == "y" || ans == "yes" else { return }
        pbcopy(md)
        let title = failures == 0 ? "mill doctor: all checks passed" : "mill doctor: \(failures) issue(s) on macOS \(osVer)"
        // The Discussions new-form accepts category/title/body; cap the body to keep the
        // URL sane — the full report is on the clipboard regardless.
        let url = "https://github.com/millfolio/millfolio/discussions/new?category=q-a"
            + "&title=\(enc(title))&body=\(enc(String(md.prefix(5500))))"
        openURL(url)
        print("Opened GitHub Discussions — paste the report into the body (⌘V) if it didn't pre-fill.")
    }
}

// ── mill index <folder> ───────────────────────────────────────────────────
struct Index: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Build the vault index over a folder (`mill index <folder>`).",
        discussion: """
        Forwards to the millfolio binary's `index` command, which embeds every file's \
        chunks via the combined inference server's /v1/embeddings and stores them in \
        the on-device LanceDB index. Needs the server running (`mill start`). \
        Re-indexing is incremental (only changed files re-embed); pass --force to \
        rebuild from scratch — needed after an extractor/chunking change (e.g. the \
        PDF fix), where file bytes (and the skip-hash) don't change.
        """)
    @Argument(help: "One or more files or folders to index (folders are walked recursively).")
    var paths: [String]

    @Flag(name: .long, help: "Rebuild the whole index even if no files changed.")
    var force = false

    @MainActor func run() async throws {
        guard !paths.isEmpty else {
            FileHandle.standardError.write(Data(
                "mill index: give one or more files or folders to index\n".utf8))
            throw ExitCode.failure
        }
        // Validate + make ABSOLUTE. The millfolio child runs with a different
        // working directory, so a relative path like `financial/WF` would resolve
        // against the wrong cwd (and silently index nothing) — resolve each here
        // against the user's cwd. Fail fast on anything that doesn't exist.
        let fm = FileManager.default
        var absPaths: [String] = []
        for p in paths {
            guard fm.fileExists(atPath: p) else {
                FileHandle.standardError.write(Data(
                    "mill index: does not exist: \(p)\n".utf8))
                throw ExitCode.failure
            }
            absPaths.append(URL(fileURLWithPath: p).standardizedFileURL.path)
        }

        let boot = streaming()   // stream progress to the console
        // Indexing embeds every chunk via the inference server — make sure it's up,
        // else `index` blocks on a dead endpoint (or stalls waiting for embeddings)
        // with no feedback. First start also loads the embedding model (~tens of s).
        try boot.ensureInferenceServer()
        print("Indexing — progress below (first run loads the embedding model):")
        // Run the millfolio launcher (`index <path…> [--force]`) as a logged child
        // so its output — and any failure — is captured in the millfolio log.
        let code = try boot.runVaultIndex(paths: absPaths, force: force)
        try finish(code, boot, "mill index")
    }
}

// ── mill ask "<question>" ─────────────────────────────────────────────────
struct Ask: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "One-shot vault answer (`mill ask \"<question>\"`).",
        discussion: """
        Runs the enclave vault loop over your vault dir: a model writes a Mojo \
        program that uses the millfolio vault tools over your real data locally, and \
        the answer is printed here. Runs over the ACTIVE vault (see `mill status`); $MILLFOLIO_VAULT overrides it. \
        Needs the inference server running.
        """)
    @Argument(parsing: .remaining, help: "The question to ask your vault.")
    var question: [String] = []

    @MainActor func run() async throws {
        guard !question.isEmpty else {
            throw BootstrapError.step("mill ask", "no question given")
        }
        let boot = streaming()   // stream progress to the console
        let q = question.joined(separator: " ")
        let dir = boot.ensureActiveVaultDir()   // the active vault (registry), else default
        // The vault loop calls the model via the inference server — make sure it's
        // up, else `ask` blocks on a dead endpoint with no feedback.
        try boot.ensureInferenceServer()
        print("Thinking — progress below (first run can take a minute):")
        // Run the enclave vault loop (`vault "<q>" <dir>`) as a logged child so its
        // streamed progress + the answer (and any failure) surface here and in the log.
        let code = try boot.runVaultAsk(question: q, vaultDir: dir)
        try finish(code, boot, "mill ask")
    }
}

// ── mill run <path-or-url> ────────────────────────────────────────────────
struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a supplied vault program over your vault (`mill run <path-or-url>`).",
        discussion: """
        Runs a HUMAN-written `from vault import *` Mojo program over your real \
        indexed vault WITHOUT any model call — the program comes from a local file \
        or an https:// URL instead of the frontier model. It runs in the SAME \
        Seatbelt sandbox that model-written programs run in (network-denied except \
        127.0.0.1, writes confined to scratch), so it's as sandboxed as codegen \
        output — but it's arbitrary code you chose to run, so only run programs you \
        trust. Runs over the ACTIVE vault (see `mill status`); $MILLFOLIO_VAULT overrides it. \
        Needs the inference server running (a program may call search()/ask_local()).
        """)
    @Argument(help: "A local .mojo file path OR an https:// URL to a `from vault import *` program.")
    var source: String

    @MainActor func run() async throws {
        let boot = streaming()   // stream progress to the console
        let dir = boot.ensureActiveVaultDir()   // the active vault (registry), else default
        // Resolve the program to a LOCAL file: download an https URL to a temp file,
        // or use the local path directly. http:// and other schemes are rejected.
        let resolved = try await resolveRunProgram(source)
        defer { if resolved.isTemp { try? FileManager.default.removeItem(atPath: resolved.path) } }

        print("Program source: \(source)")
        print("Running it in the sandbox over your vault (\(dir)).")
        print("  It runs as sandboxed as model-written code — but this is arbitrary")
        print("  code you supplied, so only run programs you trust.")

        // A supplied program may call search()/ask_local() (127.0.0.1 only) — make
        // sure the inference server is up, mirroring `mill ask`.
        try boot.ensureInferenceServer()
        let code = try boot.runVaultRun(programPath: resolved.path, vaultDir: dir)
        try finish(code, boot, "mill run")
    }
}

/// Resolve a `mill run` source to a local file path. An `https://` URL is fetched
/// to a temp file (returned with `isTemp: true` so the caller deletes it); a bare
/// path is used in place. `http://` and any other `<scheme>://` are rejected —
/// https + local file only.
private func resolveRunProgram(_ source: String) async throws -> (path: String, isTemp: Bool) {
    if source.hasPrefix("https://") {
        guard let url = URL(string: source) else {
            throw BootstrapError.step("mill run", "not a valid URL: \(source)")
        }
        let (data, resp) = try await URLSession.shared.data(from: url)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BootstrapError.step("mill run", "download failed (HTTP \(http.statusCode)): \(source)")
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mill-run-\(UUID().uuidString).mojo")
        try data.write(to: tmp)
        return (tmp.path, true)
    }
    if source.contains("://") {
        throw BootstrapError.step("mill run",
            "only https:// URLs and local file paths are supported (got: \(source))")
    }
    let abs = URL(fileURLWithPath: source).standardizedFileURL.path
    guard FileManager.default.fileExists(atPath: abs) else {
        throw BootstrapError.step("mill run", "no such file: \(source)")
    }
    return (abs, false)
}

/// Map a child's exit status to the CLI's: on failure, point at the diagnostic
/// log, then propagate the same code via ArgumentParser's ExitCode.
@MainActor private func finish(_ code: Int32, _ boot: Bootstrapper, _ what: String) throws {
    if code != 0 {
        FileHandle.standardError.write(Data(
            "\n\(what) failed (exit \(code)). Diagnostics: \(boot.millfolioLogURL.path)\n".utf8))
    }
    throw ExitCode(code)
}

// ── helpers ──────────────────────────────────────────────────────────────────
/// A Bootstrapper that streams progress lines to stdout (for `install`).
@MainActor private func streaming() -> Bootstrapper {
    let boot = Bootstrapper()
    boot.onProgress = { print($0) }
    return boot
}

private func mark(_ ok: Bool) -> String { ok ? "yes" : "no" }

// ── mill doctor helpers ───────────────────────────────────────────────────────
/// Run a process, capture combined stdout/stderr (trimmed) + its exit code.
@discardableResult
private func sh(_ launch: String, _ args: [String]) -> (out: String, code: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launch)
    p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    guard (try? p.run()) != nil else { return ("", -1) }
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            p.terminationStatus)
}

/// Copy a string to the macOS clipboard via pbcopy.
private func pbcopy(_ s: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
    let pipe = Pipe(); p.standardInput = pipe
    guard (try? p.run()) != nil else { return }
    pipe.fileHandleForWriting.write(Data(s.utf8))
    try? pipe.fileHandleForWriting.close()
    p.waitUntilExit()
}

/// Open a URL in the default browser (via /usr/bin/open — no AppKit dependency).
private func openURL(_ url: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = [url]
    try? p.run()
    p.waitUntilExit()
}

/// Percent-encode a query value (encode everything non-alphanumeric — safe for URLs).
private func enc(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
}
