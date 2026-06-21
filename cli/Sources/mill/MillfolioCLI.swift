import Foundation
import Darwin
import ArgumentParser
import MillfolioCore

// The `millfolio` CLI — the personal-data-vault umbrella. It drives the same engine
// lifecycle as the millfolio app's Bootstrapper, into the shared install tree
// (~/Library/Application Support/Millfolio) + the me.millfolio.server launchd job, so
// `millfolio` and the `millfolio` CLI interoperate on one inference server. `install`
// provisions the server + privacy_box + the millfolio vault; `start` brings them all up
// (the vault site at http://localhost:10000); `stop` tears them down.

@main
struct Millfolio: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mill",
        abstract: "The millfolio personal data vault — install, start, stop, index, and ask.",
        subcommands: [Install.self, Update.self, Version.self, Start.self, Stop.self, Status.self, Index.self, Ask.self]
    )
}

// ── mill install ──────────────────────────────────────────────────────────
struct Install: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install the millfolio inference server, privacy_box, and the millfolio web app.",
        discussion: """
        Idempotent — reuses anything already installed. Provisions the combined \
        inference server (chat + embeddings, including both models' weights), the \
        privacy_box vault orchestrator + sandbox, the millfolio vault tools, and the \
        millfolio web app (UI on :10000).
        """)
    @MainActor func run() async throws {
        let boot = streaming()
        try await boot.installVault()
        print("✓ millfolio installed (inference server + privacy_box + millfolio web app)")
    }
}

// ── mill update ─────────────────────────────────────────────────────────────
struct Update: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Update millfolio and its components to the latest release.",
        discussion: """
        Upgrades the `millfolio` CLI via Homebrew, then refreshes the downloadable \
        components (inference server, privacy_box, vault engine, app web server) to their \
        latest releases. The Mojo toolchains and the model weights are kept, so it \
        only re-fetches + rebuilds the source bundles. Progress is logged to \
        ~/Library/Logs/Millfolio/<date>.log.
        """)
    @Flag(name: .long, help: "Refresh the components only; don't upgrade the CLI via Homebrew.")
    var skipCli = false

    @MainActor func run() async throws {
        let boot = streaming()
        print("Versions before update:")
        printVersions(boot.componentVersions())
        print("")
        try await boot.selfUpdate(updateCLI: !skipCli)
        print("\nVersions after update:")
        printVersions(boot.componentVersions())
        print("✓ millfolio up to date")
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
    @MainActor func run() async throws {
        let boot = Bootstrapper()
        try await boot.startVaultChat(vaultDir: boot.ensureVaultDir())
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
        print("privacy_box:   \(mark(boot.isPrivacyBoxInstalled))")
        print("millfolio:    \(mark(boot.isMillfolioInstalled))")
        print("app web server: \(mark(boot.isAppServerInstalled))")
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
    @Argument(help: "The folder to index (your vault dir).")
    var folder: String

    @Flag(name: .long, help: "Rebuild the whole index even if no files changed.")
    var force = false

    @MainActor func run() async throws {
        let boot = Bootstrapper()
        // Run the millfolio launcher (`index <folder> [--force]`) as a logged child
        // so its output — and any failure — is captured in the millfolio log.
        let code = try boot.runVaultIndex(folder: folder, force: force)
        try finish(code, boot, "mill index")
    }
}

// ── mill ask "<question>" ─────────────────────────────────────────────────
struct Ask: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "One-shot vault answer (`mill ask \"<question>\"`).",
        discussion: """
        Runs the privacy_box vault loop over your vault dir: a model writes a Mojo \
        program that uses the millfolio vault tools over your real data locally, and \
        the answer is printed here. The vault dir is $MILLFOLIO_VAULT, else ~/.config/millfolio/vault. \
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
        let dir = boot.ensureVaultDir()
        // The vault loop calls the model via the inference server — make sure it's
        // up, else `ask` blocks on a dead endpoint with no feedback.
        try boot.ensureInferenceServer()
        print("Thinking — progress below (first run can take a minute):")
        // Run the privacy_box vault loop (`vault "<q>" <dir>`) as a logged child so its
        // streamed progress + the answer (and any failure) surface here and in the log.
        let code = try boot.runVaultAsk(question: q, vaultDir: dir)
        try finish(code, boot, "mill ask")
    }
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
