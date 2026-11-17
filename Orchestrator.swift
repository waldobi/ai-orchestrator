import SwiftUI
import AppKit
import Combine

// MARK: - Orchestrator (authoring window, routed runs)
//
// See README.md for an overview.
// Engine (T3 engine): each step is a thread on the
// local T3 Code server (T3.swift), which runs the CLIs with their own sign-ins; nothing here spawns them any more.
// Every run gets its own git worktree on branch orch/<id> (outside ~/.t3) and its threads run there
// (`existing_worktree`), so the checkout is untouched until Merge; a Read run's worktree is removed when it ends. Auto = Plan (Claude) → Build (Cursor, Codex, Claude) → Review (Claude),
// each step on the first tool with room; accounts at their limit or billing extra are skipped.
// Runs are kept in …/local.ai-orchestrator/orchestrator-runs.json.

enum OrchScope: String, Codable, CaseIterable, Identifiable {
    case read, edit
    var id: String { rawValue }
    var title: String { self == .read ? "Read" : "Edit" }
}

enum OrchMode: String, CaseIterable, Identifiable {
    case auto, direct
    var id: String { rawValue }
    var title: String { self == .auto ? "Auto" : "Direct" }
}

enum OrchKind: String, Codable { case claude, codex, cursor }

enum OrchState: String, Codable {
    case waiting, running, done, failed, stopped, skipped
    var title: String {
        switch self {
        case .waiting: return "Waiting"
        case .running: return "Running"
        case .done: return "Done"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        case .skipped: return "Skipped"
        }
    }
    var color: Color {
        switch self {
        case .done: return Theme.ok
        case .failed: return Theme.alert
        case .stopped, .skipped: return Theme.warn
        default: return .secondary
        }
    }
}

/// One command-line agent and the account it's signed in to, with live limits from status.json.
struct OrchTarget: Identifiable, Hashable {
    let id: String
    let kind: OrchKind
    let label: String
    let configDir: String?
    let statusID: String?
    var room: Double?
    var blocked = false
    var paysExtra = false
    var installed = false
    /// Why T3 Code can't run it (provider off, not registered), or nil.
    var t3Off: String?
    /// When its tightest window resets (status.json `weeklyResets`/`freesAt`), for the router's tie-break.
    var resets: Date?
    /// The plan name the Plans tab detected, when known.
    var plan: String?

    /// Paid usage so far this cycle (status.json), when the provider reports it.
    var extraUsed: Double?
    /// The account's rule for paid extra usage in orchestration: 0 is Never, otherwise the most to spend this month.
    var extraCap: Double { statusID.map { UserDefaults.standard.double(forKey: "orch.extraCap." + $0) } ?? 0 }
    static let extraMargin = 10.0
    /// No new work for an account at 90% or more of its tightest window; with paid usage on this also keeps a run
    /// from crossing into billed usage.
    var withinPlan: Bool { !blocked && (room ?? 0) >= Self.extraMargin }
    var extraAllowed: Bool { paysExtra && extraCap > 0 && (extraUsed ?? 0) < extraCap }
    var usable: Bool { installed && statusID != nil && t3Off == nil && (withinPlan || extraAllowed) }
    /// Why the router skips it, in plain words; nil when it's usable.
    var why: String? {
        if !installed { return "not installed" }
        if statusID == nil { return kind == .claude ? "no usage data for this login" : "no usage data" }
        if let t3Off { return t3Off }
        if withinPlan || extraAllowed { return nil }
        if paysExtra {
            if extraCap > 0 { return String(format: "paid extra cap reached ($%.0f)", extraCap) }
            return blocked ? "at its limit, paid extra off" : "near its limit, paid extra off"
        }
        return blocked ? "at its limit" : "90%+ used, no new work"
    }
    var roomText: String { room.map { String(format: "%.0f%% left", $0) } ?? "–" }
}

enum OrchTargets {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let statusPath = home + "/Library/Application Support/local.ai-orchestrator/status.json"
    /// Where `claude`, `codex`, `cursor-agent` and `t3` are looked up. Add your own folders (colon-separated) with
    /// `defaults write local.ai-orchestrator binDirs "$HOME/.npm-global/bin:$HOME/.bun/bin"` or the AIO_BIN_DIRS env var.
    static let binDirs: [String] = {
        let extra = (ProcessInfo.processInfo.environment["AIO_BIN_DIRS"] ?? UserDefaults.standard.string(forKey: "binDirs") ?? "")
            .split(separator: ":").map(String.init).filter { !$0.isEmpty }
        return extra + ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.npm-global/bin", home + "/.bun/bin", "/usr/bin"]
    }()

    static func which(_ name: String) -> String? {
        if Demo.on { return nil }   // demo mode never runs real agents or the T3 server
        return binDirs.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The signed-in email of a Claude CLI config (`oauthAccount.emailAddress`, not a secret; the same field `ai-route` reads).
    private static func claudeEmail(_ file: String) -> String? {
        guard let d = FileManager.default.contents(atPath: file),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return (o["oauthAccount"] as? [String: Any])?["emailAddress"] as? String
    }

    static func load() -> [OrchTarget] {
        var status: [[String: Any]] = []
        if let d = FileManager.default.contents(atPath: statusPath),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            status = o["targets"] as? [[String: Any]] ?? []
        }
        func entry(_ id: String) -> [String: Any]? { status.first { $0["id"] as? String == id } }
        func fill(_ t: inout OrchTarget, _ e: [String: Any]?) {
            guard let e else { return }
            t.room = (e["room"] as? NSNumber)?.doubleValue
            t.blocked = e["blocked"] as? Bool ?? false
            t.paysExtra = e["paysExtra"] as? Bool ?? false
            t.extraUsed = (e["extraUsed"] as? NSNumber)?.doubleValue
            let iso = ISO8601DateFormatter()
            t.resets = ((e["freesAt"] ?? e["weeklyResets"]) as? String).flatMap { iso.date(from: $0) }
        }
        var out: [OrchTarget] = []
        let claudeOK = which("claude") != nil
        // Claude CLI logins: ~/.claude (default) plus any ~/.claude-<name> config folder.
        var configs: [(dir: String?, file: String)] = [(nil, home + "/.claude.json")]
        if let names = try? FileManager.default.contentsOfDirectory(atPath: home) {
            for n in names.sorted() where n.hasPrefix(".claude-") {
                let dir = home + "/" + n
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue,
                   FileManager.default.fileExists(atPath: dir + "/.claude.json") {
                    configs.append((dir, dir + "/.claude.json"))
                }
            }
        }
        for c in configs {
            guard let email = claudeEmail(c.file) else { continue }
            let e = status.first { ($0["id"] as? String ?? "").hasPrefix("claude:") && $0["email"] as? String == email }
            let name = e?["name"] as? String ?? email
            var t = OrchTarget(id: "claude:" + (c.dir ?? "default"), kind: .claude, label: "Claude · \(name)",
                               configDir: c.dir, statusID: e?["id"] as? String, installed: claudeOK)
            fill(&t, e)
            out.append(t)
        }
        var cursor = OrchTarget(id: "cursor", kind: .cursor, label: "Cursor", configDir: nil,
                                statusID: entry("cursor:main") == nil ? nil : "cursor:main", installed: which("cursor-agent") != nil)
        fill(&cursor, entry("cursor:main"))
        var codex = OrchTarget(id: "codex", kind: .codex, label: "Codex", configDir: nil,
                               statusID: entry("codex:main") == nil ? nil : "codex:main", installed: which("codex") != nil)
        fill(&codex, entry("codex:main"))
        out.append(cursor)
        out.append(codex)
        return out
    }

    /// Claude accounts in the status file that have no CLI login yet (shown so the gap is visible).
    static func claudeWithoutCLI(_ targets: [OrchTarget]) -> [String] {
        guard let d = FileManager.default.contents(atPath: statusPath),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let all = o["targets"] as? [[String: Any]] else { return [] }
        let have = Set(targets.compactMap(\.statusID))
        return all.compactMap { e in
            guard let id = e["id"] as? String, id.hasPrefix("claude:"), !have.contains(id) else { return nil }
            return e["name"] as? String
        }
    }
}

// MARK: Command lines

enum OrchCLI {
    /// Things a run must never do. Claude gets them as deny rules; every tool's command stream is also checked
    /// and the run is stopped on a match (best effort: the command may already have started).
    static let claudeDeny = ["Bash(sudo:*)", "Bash(pkill:*)", "Bash(killall:*)", "Bash(kill:*)", "Bash(osascript:*)",
                             "Bash(security:*)", "Bash(git push:*)", "Bash(launchctl:*)"]
    static let neverPattern = try! NSRegularExpression(pattern:
        #"(^|[\s;&|("'`])(sudo|killall|pkill|launchctl|security\s+(find|dump|export))\b|osascript.*\bquit\b|git\s+push|Application Support/(Claude|Codex|Cursor|com\.openai)|\.claude\.json|auth\.json|state\.vscdb|Keychains"#,
        options: [.caseInsensitive])

    static func violates(_ command: String) -> Bool {
        neverPattern.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil
    }

    static func command(_ t: OrchTarget, scope: OrchScope, dir: String, prompt: String, model: String? = nil) -> (exe: String, args: [String], env: [String: String])? {
        let model = model?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (OrchTargets.binDirs + ["/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        env["NO_COLOR"] = "1"
        switch t.kind {
        case .claude:
            guard let exe = OrchTargets.which("claude") else { return nil }
            if let c = t.configDir { env["CLAUDE_CONFIG_DIR"] = c }
            let args = ["-p", prompt, "--output-format", "stream-json", "--verbose",
                        "--permission-mode", scope == .read ? "plan" : "acceptEdits",
                        "--disallowedTools"] + claudeDeny
            return (exe, (model.map { ["--model", $0] } ?? []) + args, env)
        case .codex:
            guard let exe = OrchTargets.which("codex") else { return nil }
            return (exe, ["exec", "--json", "--skip-git-repo-check"] + (model.map { ["-m", $0] } ?? [])
                         + ["-s", scope == .read ? "read-only" : "workspace-write", "-C", dir, prompt], env)
        case .cursor:
            guard let exe = OrchTargets.which("cursor-agent") else { return nil }
            var args = ["-p", "--output-format", "stream-json", "--trust", "--workspace", dir]
            args += scope == .read ? ["--mode", "ask"] : ["--force", "--sandbox", "enabled"]
            if let model { args += ["--model", model] }
            return (exe, args + [prompt], env)
        }
    }

    /// One readable line (or nil) from a line of JSON events. `final` gets the step's last answer;
    /// `command` gets a shell command the agent is about to run, for the never-list check.
    static func render(_ line: String, final: inout String, command: inout String?) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let d = trimmed.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            // Codex's stdin notice and MCP connection chatter aren't about the task.
            if trimmed.hasPrefix("Reading additional input from stdin") || trimmed.contains(" rmcp::") { return nil }
            return trimmed
        }
        let type = o["type"] as? String ?? ""
        // Claude and Cursor: assistant messages with text and tool_use blocks.
        if type == "assistant", let m = o["message"] as? [String: Any] {
            if let s = m["content"] as? String { return s }
            let parts = (m["content"] as? [[String: Any]] ?? []).compactMap { c -> String? in
                switch c["type"] as? String {
                case "text": return c["text"] as? String
                case "tool_use":
                    let name = c["name"] as? String ?? "tool"
                    let input = c["input"] as? [String: Any] ?? [:]
                    if let cmd = input["command"] as? String { command = cmd; return "$ \(cmd)" }
                    if let p = (input["file_path"] ?? input["path"] ?? input["pattern"]) as? String { return "· \(name) \(p)" }
                    return "· \(name)"
                default: return nil
                }
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        if type == "result" {
            if let r = o["result"] as? String { final = r }
            if o["is_error"] as? Bool == true { return "Error: \(o["result"] as? String ?? o["subtype"] as? String ?? "unknown")" }
            return nil
        }
        // Cursor tool calls.
        if type == "tool_call", o["subtype"] as? String == "started", let call = o["tool_call"] as? [String: Any],
           let (name, value) = call.first(where: { $0.value is [String: Any] }) {
            let args = (value as? [String: Any])?["args"] as? [String: Any] ?? [:]
            if let cmd = args["command"] as? String { command = cmd; return "$ \(cmd)" }
            if let p = args["path"] as? String { return "· \(name.replacingOccurrences(of: "ToolCall", with: "")) \(p)" }
            return "· \(name.replacingOccurrences(of: "ToolCall", with: ""))"
        }
        // Codex: item.started / item.completed events.
        if let item = o["item"] as? [String: Any] {
            let kind = item["type"] as? String ?? item["item_type"] as? String ?? ""
            if kind == "command_execution", type == "item.started", let cmd = item["command"] as? String {
                command = cmd; return "$ \(cmd)"
            }
            if type == "item.completed" {
                if kind == "agent_message" || kind == "assistant_message", let t = item["text"] as? String { final = t; return t }
                if kind == "reasoning", let t = item["text"] as? String { return "… " + t }
                if kind == "file_change", let ch = item["changes"] as? [[String: Any]] {
                    return ch.compactMap { $0["path"] as? String }.map { "· edit \($0)" }.joined(separator: "\n")
                }
            }
            return nil
        }
        if type == "turn.failed" || type == "error" {
            let msg = (o["error"] as? [String: Any])?["message"] as? String ?? o["message"] as? String ?? "error"
            return "Error: \(msg)"
        }
        return nil
    }
}

// MARK: Runs

final class OrchStep: ObservableObject, Identifiable {
    let id = UUID()
    let name: String
    let scope: OrchScope
    @Published var target: OrchTarget?
    @Published var targetLabel: String
    @Published var status: OrchState = .waiting
    @Published var output = ""
    @Published var final = ""
    @Published var note = ""
    var roomBefore: Double?
    /// The T3 thread and run this step is.
    var threadId: String?
    var runId: String?

    var model: String?
    var retriedModel = false
    var reassigned = false
    /// Why the router sent this step to its account, in one line.
    @Published var reason = ""

    init(name: String, scope: OrchScope, target: OrchTarget?) {
        self.name = name; self.scope = scope; self.target = target
        targetLabel = target?.label ?? "no tool with room"
    }

    func append(_ s: String) {
        output += (output.isEmpty ? "" : "\n") + s
        if output.count > 200_000 { output = String(output.suffix(150_000)) }
    }
}

final class OrchRun: ObservableObject, Identifiable {
    let id: UUID
    let request: String
    let folder: String
    let mode: OrchMode
    let scope: OrchScope
    let started: Date
    @Published var ended: Date?
    @Published var steps: [OrchStep]
    @Published var status: OrchState = .waiting
    @Published var branch: String?
    @Published var worktree: String?
    @Published var repoRoot: String?
    @Published var baseCommit: String?
    @Published var changed = ""
    @Published var merged = false
    @Published var message = ""
    var stopRequested = false
    var source = "mac"
    /// Runs in T3's approval-required mode: the agent waits for Approve before commands and edits.
    var askFirst = false
    /// "<repo root>#<branch>" while an Edit run works on it (one Edit run per repo branch).
    var editKey: String?
    /// The repo root and branch an Edit run merges into (set when it first tries to start).
    var base: (root: String, branch: String)?

    init(id: UUID = UUID(), request: String, folder: String, mode: OrchMode, scope: OrchScope, steps: [OrchStep], started: Date = Date()) {
        self.id = id; self.request = request; self.folder = folder; self.mode = mode; self.scope = scope
        self.steps = steps; self.started = started
    }

    var title: String { request.split(separator: "\n").first.map(String.init) ?? request }
    var short: String { String(id.uuidString.prefix(6)).lowercased() }
}

/// What's saved per run (output is capped).
struct OrchRecord: Codable {
    struct Step: Codable { var name, target, scope, status, output, final, note: String; var roomBefore: Double?; var model: String?; var thread: String?; var reason: String? }
    var id: UUID, request, folder, mode, scope, status: String
    var started: Date, ended: Date?
    var branch, worktree, repoRoot, baseCommit: String?
    var changed: String, merged: Bool, message: String
    var source: String?
    var askFirst: Bool?
    var steps: [Step]
}

final class OrchEngine: ObservableObject {
    static let shared = OrchEngine()
    static let dataDir = OrchTargets.home + "/Library/Application Support/local.ai-orchestrator"
    static let logPath = dataDir + "/orchestrator-runs.json"
    static let worktreeDir = dataDir + "/worktrees"

    @Published var runs: [OrchRun] = []
    @Published var targets: [OrchTarget] = []
    /// The T3 Code engine's state for the window: version and its measured memory and CPU, or what's wrong.
    @Published var t3Status = "T3 Code: checking…"
    @Published var folders: [String] = UserDefaults.standard.stringArray(forKey: "orch.folders") ?? []
    /// Requests waiting for an account with room ("Waiting for room"); they start on their own when one frees up.
    @Published var queue: [OrchRun] = []
    private var saveQueued = false
    private var lastState: Data?

    private init() {
        targets = Self.applyT3(OrchTargets.load())
        loadLog()
        Task { _ = await self.refreshT3() }
    }

    func refreshTargets() {
        targets = Self.applyT3(OrchTargets.load()); writeState()
        if !queue.isEmpty { Task { @MainActor in self.drainQueue() } }
    }

    /// Marks the tools T3 Code can't run: its provider is off or not ready, or (for now) a second Claude login,
    /// which needs registering as its own T3 Claude account first.
    static func applyT3(_ list: [OrchTarget]) -> [OrchTarget] {
        let providers = T3Client.shared.providers
        guard !providers.isEmpty else { return list.map { var t = $0; t.t3Off = "T3 Code not reached yet"; return t } }
        return list.map { t in
            var t = t
            guard let inst = t.t3Instance else { t.t3Off = "not registered in T3 Code yet"; return t }
            let p = providers[inst]
            if p == nil || p?.enabled != true { t.t3Off = "off in T3 Code" }
            else if p?.ready != true { t.t3Off = "not signed in to T3 Code" }
            return t
        }
    }

    /// Reads T3's providers, then re-marks the targets.
    @MainActor func refreshT3() async -> String? {
        do {
            try await T3Client.shared.refresh()
            refreshTargets()
            // Each ~/.claude-<name> login becomes its own T3 Claude account, once (Phase 3). A failed try isn't repeated
            // on its own; the accounts bar shows why.
            let tried = UserDefaults.standard.stringArray(forKey: "orch.t3Registered") ?? []
            let missing = targets.filter { $0.kind == .claude && $0.t3Instance == nil && $0.installed }
                .compactMap { t -> (name: String, dir: String)? in
                    guard let dir = t.configDir, !tried.contains(dir), FileManager.default.fileExists(atPath: dir) else { return nil }
                    return (t.label.replacingOccurrences(of: "Claude · ", with: ""), dir)
                }
            if !missing.isEmpty {
                UserDefaults.standard.set(tried + missing.map(\.dir), forKey: "orch.t3Registered")
                if !(await T3SignIn.shared.registerClaudeLogins(missing)).isEmpty {
                    try await T3Client.shared.refresh()
                    refreshTargets()
                }
            }
            let f = await T3Client.footprint()
            t3Status = "T3 Code \(T3Client.shared.serverVersion ?? "")" + (f.map { String(format: " · %.0f MB · %.1f%% CPU", $0.mb, $0.cpu) } ?? "")
            return nil
        } catch {
            refreshTargets()
            t3Status = error.localizedDescription
            return error.localizedDescription
        }
    }

    // Folders

    /// Git project folders Burn Rate has seen work in (Report › Projects, projects.json), newest activity first.
    static func knownProjects() -> [(name: String, path: String)] {
        guard let d = FileManager.default.contents(atPath: dataDir + "/projects.json"),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
        let days = o["days"] as? [String: [String: Any]] ?? [:]
        var seen = Set<String>()
        var out: [(name: String, path: String, last: String)] = []
        for p in o["projects"] as? [[String: Any]] ?? [] where p["hidden"] as? Bool != true {
            for f in p["folders"] as? [String] ?? [] where !seen.contains(f) {
                seen.insert(f)
                guard !f.contains("/.claude/worktrees/"), !f.hasPrefix("/private/"), !f.hasPrefix("/tmp/"), !f.hasPrefix(worktreeDir),
                      FileManager.default.fileExists(atPath: f + "/.git") else { continue }
                out.append((URL(fileURLWithPath: f).lastPathComponent, f, days[f]?.keys.max() ?? ""))
            }
        }
        return out.sorted { $0.last > $1.last }.map { ($0.name, $0.path) }
    }

    func allow(_ path: String) { if !folders.contains(path) { folders.append(path); saveFolders() } }

    func addFolder() -> String? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        p.prompt = "Allow"
        p.message = "Choose a project folder that requests may work in."
        guard p.runModal() == .OK, let url = p.url else { return nil }
        let path = url.standardizedFileURL.path
        if !folders.contains(path) { folders.append(path); saveFolders() }
        return path
    }

    func removeFolder(_ path: String) { folders.removeAll { $0 == path }; saveFolders() }
    private func saveFolders() { UserDefaults.standard.set(folders, forKey: "orch.folders"); writeState() }

    // Routing (Hub.swift `Router`)

    /// How long a project stays on the account it last used (prompt caches live minutes to an hour).
    static let affinityWindow: TimeInterval = 3600

    /// Accounts to stay on, best first: the same run's Plan account for its Review, then the accounts this project
    /// used in the last hour, newest first.
    func affinity(_ role: RouteRole, folder: String, steps: [OrchStep], except run: OrchRun? = nil) -> [(id: String, why: String)] {
        var out: [(id: String, why: String)] = []
        if role == .review, let p = steps.first(where: { $0.name == "Plan" })?.target?.id {
            out.append((p, "same account as this run's plan"))
        }
        let cutoff = Date().addingTimeInterval(-Self.affinityWindow)
        for r in runs where r !== run && r.folder == folder && (r.ended ?? Date()) > cutoff {
            for s in r.steps.reversed() where s.status != .waiting && s.status != .skipped {
                if let id = s.target?.id, !out.contains(where: { $0.id == id }) { out.append((id, "this project used it in the last hour")) }
            }
        }
        return out
    }

    private func routed(_ step: OrchStep, _ role: RouteRole, scope: OrchScope, folder: String, avoid: Set<String> = [],
                        prefer: [(id: String, why: String)] = []) {
        let busy = MainActor.assumeIsolated { busyInstances() }
        let r = Router.route(role, scope: scope, project: folder, avoid: avoid, busy: busy, prefer: prefer)
        step.target = r.target; step.targetLabel = r.target?.label ?? "no tool with room"; step.reason = r.reason
    }

    // Starting

    func start(request: String, folder: String, mode: OrchMode, scope: OrchScope, target: OrchTarget?, model: String? = nil, id: UUID = UUID(), source: String = "mac", askFirst: Bool = false) -> OrchRun {
        refreshTargets()
        let steps: [OrchStep]
        if mode == .auto {
            steps = [OrchStep(name: "Plan", scope: .read, target: nil),
                     OrchStep(name: "Build", scope: scope, target: nil),
                     OrchStep(name: "Review", scope: .read, target: nil)]
            routed(steps[0], .plan, scope: .read, folder: folder, prefer: affinity(.plan, folder: folder, steps: steps))
            routed(steps[1], .build, scope: scope, folder: folder, prefer: affinity(.build, folder: folder, steps: steps))
            routed(steps[2], .review, scope: .read, folder: folder, avoid: Set([steps[1].target?.t3Instance].compactMap { $0 }),
                   prefer: affinity(.review, folder: folder, steps: steps))
            if scope == .read { steps[1].note = "Read scope: the build step only answers, it can't edit." }
        } else {
            let step = OrchStep(name: "Run", scope: scope, target: nil)
            let m = model?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            if let target {
                let r = Router.route(.run, direct: target, model: m)
                step.target = r.target; step.targetLabel = r.target?.label ?? target.label; step.reason = r.reason
            } else { routed(step, .run, scope: scope, folder: folder, prefer: affinity(.run, folder: folder, steps: [])) }
            step.model = m
            steps = [step]
        }
        let run = OrchRun(id: id, request: request, folder: folder, mode: mode, scope: scope, steps: steps)
        run.source = source
        run.askFirst = askFirst
        runs.insert(run, at: 0)
        saveLog()
        Task { await self.execute(run) }
        return run
    }

    func stop(_ run: OrchRun) {
        run.stopRequested = true
        if let i = queue.firstIndex(where: { $0 === run }) {
            queue.remove(at: i); run.status = .stopped; run.ended = Date(); run.message = "Stopped while waiting for room."; saveLog()
        }
        for s in run.steps where s.status == .running {
            if let t = s.threadId, let r = s.runId { Task { await T3Client.shared.interrupt(threadId: t, runId: r) } }
        }
    }

    /// Threads running right now on an account (T3's own count, from the shell stream).
    @MainActor func running(on t: OrchTarget) -> Int? {
        guard let inst = t.t3Instance else { return nil }
        return T3Board.shared.rows.filter { $0.group == .running && $0.instance == inst }.count
    }

    /// At most this many threads run at once on one account.
    static let maxRunningPerAccount = 2

    /// T3 instances already running `maxRunningPerAccount` threads (T3's running rows, plus our own steps whose
    /// thread hasn't reached the shell stream yet).
    @MainActor func busyInstances() -> Set<String> {
        var count: [String: Int] = [:]
        var seen = Set<String>()
        for r in T3Board.shared.rows where r.group == .running || r.group == .needsYou {
            guard !r.instance.isEmpty, r.status == "running" || r.status == "starting" || r.status == "preparing" || r.status == "queued" else { continue }
            count[r.instance, default: 0] += 1; seen.insert(r.id)
        }
        for run in runs where run.status == .running {
            for st in run.steps where st.status == .running {
                if let t = st.threadId, seen.contains(t) { continue }
                if let inst = st.target?.t3Instance { count[inst, default: 0] += 1 }
            }
        }
        return Set(count.filter { $0.value >= Self.maxRunningPerAccount }.keys)
    }

    /// Why a run can't start yet, or nil: no account with room (or all busy) for its main step, or another Edit run
    /// already working on the same repo branch.
    @MainActor private func waitReason(_ run: OrchRun, base: (root: String, branch: String)?) -> String? {
        let main = run.steps.first { $0.name == "Build" || $0.name == "Run" }
        if let main {
            if main.target == nil { return main.reason.isEmpty ? "No account has room." : main.reason }
            if let inst = main.target?.t3Instance, busyInstances().contains(inst) {
                return "\(main.targetLabel) is already running \(Self.maxRunningPerAccount) threads."
            }
        }
        if run.scope == .edit, let base {
            let other = runs.first { $0 !== run && $0.status == .running && $0.scope == .edit && $0.editKey == "\(base.root)#\(base.branch)" }
            if other != nil { return "Another Edit run is working on \(URL(fileURLWithPath: base.root).lastPathComponent) (\(base.branch))." }
        }
        return nil
    }

    private var draining = false
    /// Starts queued requests that can go now (account with room and free, repo branch free). Called when accounts,
    /// threads or runs change; the check is in memory, so nothing polls.
    @MainActor func drainQueue() {
        guard !queue.isEmpty, !draining else { return }
        draining = true
        defer { draining = false }
        queue.removeAll { $0.stopRequested }
        for run in queue {
            rerouteMain(run)
            if let why = waitReason(run, base: run.base) {
                if run.message != "Waiting for room: " + why { run.message = "Waiting for room: " + why }
                continue
            }
            queue.removeAll { $0 === run }
            Task { await self.execute(run) }
        }
    }

    /// A queued Auto run's main step goes to whichever account has room now (Direct keeps the account you picked).
    @MainActor private func rerouteMain(_ run: OrchRun) {
        guard run.mode == .auto, let st = run.steps.first(where: { $0.name == "Build" }) else { return }
        let busy = busyInstances()
        if st.target == nil || st.target?.usable != true || busy.contains(st.target?.t3Instance ?? "") {
            routed(st, .build, scope: st.scope, folder: run.folder, prefer: affinity(.build, folder: run.folder, steps: run.steps, except: run))
        }
    }

    func stopAll() { runs.filter { $0.status == .running }.forEach(stop) }

    @MainActor private func finish(_ run: OrchRun, _ state: OrchState, _ msg: String = "") {
        run.status = state
        if !msg.isEmpty { run.message = msg }
        run.ended = Date()
        for s in run.steps where s.status == .waiting { s.status = .skipped }
        refreshTargets()
        saveLog()
        drainQueue()
    }

    @MainActor private func execute(_ run: OrchRun) async {
        run.status = .running
        if let e = await refreshT3() { finish(run, .failed, e); return }
        // Routing ran before T3's providers were known; pick again now if a step's tool is off in T3.
        for st in run.steps where run.mode == .auto && (st.target == nil || targets.first(where: { $0.id == st.target!.id })?.usable != true) {
            let role: RouteRole = st.name == "Plan" ? .plan : st.name == "Build" ? .build : .review
            let avoid = st.name == "Review" ? Set([run.steps.first { $0.name == "Build" }?.target?.t3Instance].compactMap { $0 }) : []
            routed(st, role, scope: st.scope, folder: run.folder, avoid: avoid,
                   prefer: affinity(role, folder: run.folder, steps: run.steps, except: run))
        }
        rerouteMain(run)
        let base = run.scope == .edit ? await Self.baseBranch(run.folder) : nil
        run.base = base
        if let why = waitReason(run, base: base) {
            run.status = .waiting
            run.message = "Waiting for room: " + why
            if !queue.contains(where: { $0 === run }) { queue.append(run) }
            saveLog()
            return
        }
        run.message = ""
        if let base { run.editKey = "\(base.root)#\(base.branch)" }
        var dir = run.folder
        switch await makeWorktree(run) {
        case .success(let d): dir = d
        case .failure(let e): finish(run, .failed, e.message); return
        }
        let project: String
        do { project = try await T3Client.shared.projectId(for: run.repoRoot ?? run.folder) }
        catch { await dropReadWorktree(run); finish(run, .failed, error.localizedDescription); return }
        var plan = ""
        for step in run.steps {
            if run.stopRequested { finish(run, .stopped); return }
            guard let t = step.target, t.installed else {
                step.status = .skipped
                step.note = step.target == nil ? "No tool had room." : "\(step.targetLabel) isn't installed."
                if step.name == "Build" || step.name == "Run" { finish(run, .failed, "No tool with room for this step."); return }
                continue
            }
            let prompt = self.prompt(step.name, run: run, plan: plan)
            let ok = await runStep(step, target: t, project: project, run: run, dir: dir, prompt: prompt)
            if run.stopRequested || step.status == .stopped { await commitWorktree(run); await dropReadWorktree(run); finish(run, .stopped, step.note); return }
            if step.name == "Plan" { plan = step.final.isEmpty ? step.output : step.final }
            if !ok && (step.name == "Build" || step.name == "Run") { await commitWorktree(run); await dropReadWorktree(run); finish(run, .failed, step.note.isEmpty ? "\(step.targetLabel) failed." : step.note); return }
            if step.name == "Build" || step.name == "Run" { await commitWorktree(run) }
        }
        await dropReadWorktree(run)
        finish(run, .done)
    }

    /// A Read run's worktree only exists so its threads can't touch the checkout; remove it when the run ends.
    @MainActor private func dropReadWorktree(_ run: OrchRun) async {
        guard run.scope == .read, run.worktree != nil else { return }
        await removeWorktree(run, force: true)
        run.branch = nil
    }

    private func prompt(_ step: String, run: OrchRun, plan: String) -> String {
        switch step {
        case "Plan":
            return "Plan this request; don't edit any files. Read what you need in this project, then reply with a short numbered plan: the files to change and how. Keep it under 300 words.\n\nRequest:\n\(run.request)"
        case "Build" where run.scope == .edit:
            let p = plan.isEmpty ? "" : "\n\nPlan from the planning step:\n\(String(plan.suffix(6000)))"
            return "Make this change in the current folder. You're on a branch of your own, so edit freely, but don't push, deploy or publish, and don't run sudo. Finish with a two-line summary of what you changed.\n\nRequest:\n\(run.request)\(p)"
        case "Build":
            let p = plan.isEmpty ? "" : "\n\nPlan from the planning step:\n\(String(plan.suffix(6000)))"
            return "Answer this request for the project in the current folder. Don't edit files.\n\nRequest:\n\(run.request)\(p)"
        case "Review":
            if run.scope == .edit, let base = run.baseCommit {
                return "Review the change on this branch for the request below. Run `git diff \(base)` to see it. Don't edit files. Reply with concrete problems (file and line), or say it looks right, in under 200 words.\n\nRequest:\n\(run.request)"
            }
            return "Check the answer below against this project and the request. Point out anything wrong or missing in under 150 words. Don't edit files.\n\nRequest:\n\(run.request)\n\nAnswer:\n\(String(run.steps.first { $0.name == "Build" }?.final.suffix(6000) ?? ""))"
        default:
            return run.scope == .edit
                ? "\(run.request)\n\n(You're on a branch of your own. Don't push, deploy or publish, and don't run sudo.)"
                : "\(run.request)\n\n(Read only: don't edit files.)"
        }
    }

    /// The model for a step: the one picked in Direct, else Codex's own configured model when T3 offers it, else T3's first.
    private func model(for step: OrchStep, _ t: OrchTarget) -> String? { step.model ?? Router.defaultModel(t) }

    /// One step = one T3 thread in the run's worktree. Polls its projection: shows messages, commands and edits,
    /// checks every command against the never list (a match is stopped with T3's own interrupt), and ends with the run.
    @MainActor private func runStep(_ step: OrchStep, target t: OrchTarget, project: String, run: OrchRun, dir: String, prompt: String) async -> Bool {
        guard let model = model(for: step, t) else { step.status = .failed; step.note = "T3 Code offers no model for \(t.label)."; return false }
        step.status = .running
        step.roomBefore = t.room
        step.model = model
        let client = T3Client.shared
        let threadId: String
        do {
            threadId = try await client.launch(projectId: project, title: "\(step.name) · \(run.title)", instance: t.t3Instance ?? t.kind.t3Instance, model: model,
                                               worktree: run.worktree ?? dir, branch: run.branch, prompt: prompt, askFirst: run.askFirst)
        } catch {
            step.status = .failed; step.note = error.localizedDescription; return false
        }
        step.threadId = threadId
        saveLog()
        let hub = Hub.shared
        hub.follow(threadId)
        defer { hub.unfollow(threadId) }
        var seen = Set<String>()
        var blocked = false
        var asked = false
        var misses = 0
        var first = true
        while true {
            // Woken by the thread's live stream (or its shell row); no fixed-interval reads.
            if !first { await hub.nextChange(threadId) }
            first = false
            let p: [String: Any]
            do { p = try await client.projection(threadId); misses = 0 }
            catch { misses += 1; if misses >= 10 { step.status = .failed; step.note = error.localizedDescription; return false }; await hub.nextChange(threadId, timeout: 3); continue }
            defer { scheduleSave() }
            let runs = p["runs"] as? [[String: Any]] ?? []
            guard let r = runs.last else { continue }
            step.runId = r["id"] as? String
            for item in p["turnItems"] as? [[String: Any]] ?? [] {
                guard let id = item["id"] as? String else { continue }
                let status = item["status"] as? String ?? ""
                let type = item["type"] as? String ?? ""
                // Commands are checked as soon as they appear; text and edits are shown once complete.
                if type == "command_execution", let cmd = item["input"] as? String, !seen.contains(id) {
                    seen.insert(id)
                    if item["title"] as? String == "Workspace ready" { continue }
                    step.append("$ " + cmd.replacingOccurrences(of: dir + "/", with: ""))
                    if OrchCLI.violates(cmd), !blocked {
                        blocked = true
                        step.append("Stopped: that command is on the never list.")
                        step.note = "Stopped by the never list."
                        if let rid = step.runId { await client.interrupt(threadId: threadId, runId: rid) }
                    }
                    continue
                }
                guard status == "completed" || status == "failed", !seen.contains(id) else { continue }
                switch type {
                case "assistant_message":
                    seen.insert(id)
                    if let text = item["text"] as? String { step.append(text); step.final = text }
                case "file_change":
                    seen.insert(id)
                    let paths = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
                    step.append(paths.map { "· edit " + $0.replacingOccurrences(of: dir + "/", with: "") }.joined(separator: "\n"))
                default: break
                }
            }
            if !asked, (p["runtimeRequests"] as? [[String: Any]] ?? []).contains(where: { $0["status"] as? String == "pending" }) {
                asked = true
                step.append("Waiting for an answer in T3 Code.")
                step.note = "Waiting for an answer in T3 Code."
            }
            if run.stopRequested, let rid = step.runId { await client.interrupt(threadId: threadId, runId: rid) }
            switch r["status"] as? String ?? "" {
            case "completed":
                step.status = blocked ? .stopped : .done
                if asked { step.note = "" }
                return !blocked
            case "failed":
                let failure = Self.runError(p)
                // A model this account can't use: one automatic retry on the account's default, and say so.
                if !blocked, !step.retriedModel, !run.stopRequested, let failure, PlainError.isModelError(failure),
                   let next = Self.fallbackModel(for: t, not: model) {
                    step.retriedModel = true
                    step.model = next
                    step.output = ""
                    let ok = await runStep(step, target: t, project: project, run: run, dir: dir, prompt: prompt)
                    if ok { step.note = "\(model) isn't available on this account, so this ran on \(next)." }
                    return ok
                }
                // Out of room mid-run: hand the step to the account with the most room, once, and say where it went.
                if !blocked, !step.reassigned, !run.stopRequested, let failure, PlainError.explain(failure).kind == .limit {
                    let r = Router.route(.reassign, avoid: [t.t3Instance ?? t.id], busy: busyInstances())
                    if let next = r.target {
                        step.reassigned = true
                        step.reason = "Moved: \(t.label) hit its limit. \(r.reason)"
                        step.target = next; step.targetLabel = next.label
                        step.model = nil   // the new account's own default model
                        step.append("\(t.label) ran out of room; moved to \(next.label).")
                        saveLog()
                        let ok = await runStep(step, target: next, project: project, run: run, dir: dir, prompt: prompt)
                        if step.note.isEmpty { step.note = "Moved from \(t.label) (hit its limit) to \(next.label)." }
                        return ok
                    }
                }
                step.status = blocked ? .stopped : .failed
                if !blocked { step.note = failure ?? "The run failed in T3 Code." }
                return false
            case "interrupted", "cancelled":
                step.status = .stopped
                if step.note.isEmpty { step.note = "Stopped." }
                return false
            default: continue
            }
        }
    }

    /// The model to retry on: Codex's configured model when T3 offers it, else the first other model T3 offers for this account.
    private static func fallbackModel(for t: OrchTarget, not failed: String) -> String? { Router.defaultModel(t, not: failed) }

    /// The error text of a failed T3 run, from its last error item.
    private static func runError(_ p: [String: Any]) -> String? {
        for item in (p["turnItems"] as? [[String: Any]] ?? []).reversed() where item["type"] as? String == "error" {
            if let m = (item["message"] ?? item["text"]) as? String { return String(m.prefix(400)) }
        }
        return nil
    }

    // Git

    struct GitError: Error { let message: String }

    static func git(_ args: [String], in dir: String) async -> (code: Int32, out: String) {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                p.arguments = ["-C", dir] + args
                let pipe = Pipe()
                p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { c.resume(returning: (1, error.localizedDescription)); return }
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                c.resume(returning: (p.terminationStatus, String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }

    /// The repo root and checked-out branch an Edit run will merge back into.
    static func baseBranch(_ folder: String) async -> (root: String, branch: String)? {
        let top = await git(["rev-parse", "--show-toplevel"], in: folder)
        let br = await git(["rev-parse", "--abbrev-ref", "HEAD"], in: folder)
        guard top.code == 0, br.code == 0 else { return nil }
        return (top.out.trimmingCharacters(in: .whitespacesAndNewlines), br.out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @MainActor private func makeWorktree(_ run: OrchRun) async -> Result<String, GitError> {
        let top = await Self.git(["rev-parse", "--show-toplevel"], in: run.folder)
        guard top.code == 0 else { return .failure(GitError(message: "Edit runs need a git folder, so the changes land on a branch of their own. \(URL(fileURLWithPath: run.folder).lastPathComponent) isn't one.")) }
        let root = top.out
        let head = await Self.git(["rev-parse", "HEAD"], in: root)
        guard head.code == 0 else { return .failure(GitError(message: "This repository has no commits yet.")) }
        let branch = "orch/\(run.short)"
        let path = Self.worktreeDir + "/\(URL(fileURLWithPath: root).lastPathComponent)-\(run.short)"
        try? FileManager.default.createDirectory(atPath: Self.worktreeDir, withIntermediateDirectories: true)
        let add = await Self.git(["worktree", "add", "-b", branch, path, head.out], in: root)
        guard add.code == 0 else { return .failure(GitError(message: "Couldn't make the worktree: \(add.out)")) }
        run.repoRoot = root; run.branch = branch; run.worktree = path; run.baseCommit = head.out
        let rel = run.folder.hasPrefix(root) ? String(run.folder.dropFirst(root.count)) : ""
        return .success(path + rel)
    }

    @MainActor private func commitWorktree(_ run: OrchRun) async {
        guard let wt = run.worktree, let base = run.baseCommit else { return }
        _ = await Self.git(["add", "-A"], in: wt)
        let dirty = await Self.git(["status", "--porcelain"], in: wt)
        if !dirty.out.isEmpty {
            let line = String(run.title.prefix(60))
            _ = await Self.git(["commit", "-q", "-m", "AI Orchestrator run \(run.short): \(line)"], in: wt)
        }
        run.changed = await Self.git(["diff", "--stat", base, "HEAD"], in: wt).out
        saveLog()
    }

    /// Merge the run's branch into the folder's current branch, then remove the run's worktree and branch.
    @MainActor func merge(_ run: OrchRun) async {
        guard let root = run.repoRoot, let branch = run.branch else { return }
        let m = await Self.git(["merge", "--no-ff", "--no-edit", branch], in: root)
        guard m.code == 0 else {
            run.message = "Merge didn't go through, nothing changed: \(m.out.suffix(400))"
            _ = await Self.git(["merge", "--abort"], in: root)
            saveLog(); return
        }
        run.merged = true
        run.message = "Merged \(branch)."
        await removeWorktree(run, force: false)
    }

    /// Throw away the run's branch and worktree (only ever the run's own).
    @MainActor func discard(_ run: OrchRun) async {
        await removeWorktree(run, force: true)
        run.message = "Discarded \(run.branch ?? "the branch")."
        saveLog()
    }

    @MainActor private func removeWorktree(_ run: OrchRun, force: Bool) async {
        guard let root = run.repoRoot, let wt = run.worktree, wt.hasPrefix(Self.worktreeDir), let branch = run.branch, branch.hasPrefix("orch/") else { return }
        _ = await Self.git(["worktree", "remove"] + (force ? ["--force"] : []) + [wt], in: root)
        _ = await Self.git(["branch", force ? "-D" : "-d", branch], in: root)
        run.worktree = nil
        saveLog()
    }

    // Log

    /// Live output reaches the phone through the run log; coalesce a burst of updates into one write.
    func scheduleSave() {
        guard !saveQueued else { return }
        saveQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.saveQueued = false; self?.saveLog() }
    }

    func saveLog() {
        let recs = runs.prefix(100).map { r in
            OrchRecord(id: r.id, request: r.request, folder: r.folder, mode: r.mode.rawValue, scope: r.scope.rawValue, status: r.status.rawValue,
                       started: r.started, ended: r.ended, branch: r.branch, worktree: r.worktree, repoRoot: r.repoRoot, baseCommit: r.baseCommit,
                       changed: r.changed, merged: r.merged, message: r.message, source: r.source, askFirst: r.askFirst,
                       steps: r.steps.map { s in .init(name: s.name, target: s.targetLabel, scope: s.scope.rawValue, status: s.status.rawValue,
                                                       output: String(s.output.suffix(40_000)), final: String(s.final.suffix(20_000)),
                                                       note: s.note, roomBefore: s.roomBefore, model: s.model, thread: s.threadId, reason: s.reason) })
        }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted]
        if let d = try? enc.encode(Array(recs)) {
            try? FileManager.default.createDirectory(atPath: Self.dataDir, withIntermediateDirectories: true)
            try? d.write(to: URL(fileURLWithPath: Self.logPath), options: .atomic)
        }
    }

    private func loadLog() {
        guard let d = FileManager.default.contents(atPath: Self.logPath) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let recs = try? dec.decode([OrchRecord].self, from: d) else { return }
        runs = recs.map { r in
            let steps = r.steps.map { s -> OrchStep in
                let st = OrchStep(name: s.name, scope: OrchScope(rawValue: s.scope) ?? .read, target: nil)
                st.targetLabel = s.target; st.output = s.output; st.final = s.final; st.note = s.note; st.roomBefore = s.roomBefore
                st.threadId = s.thread; st.model = s.model; st.reason = s.reason ?? ""
                let state = OrchState(rawValue: s.status) ?? .stopped
                st.status = (state == .running || state == .waiting) ? .stopped : state
                return st
            }
            let run = OrchRun(id: r.id, request: r.request, folder: r.folder, mode: OrchMode(rawValue: r.mode) ?? .direct,
                              scope: OrchScope(rawValue: r.scope) ?? .read, steps: steps, started: r.started)
            let state = OrchState(rawValue: r.status) ?? .stopped
            run.status = state == .running ? .stopped : state
            run.ended = r.ended; run.branch = r.branch; run.worktree = r.worktree; run.repoRoot = r.repoRoot
            run.baseCommit = r.baseCommit; run.changed = r.changed; run.merged = r.merged; run.message = r.message
            run.source = r.source ?? "mac"
            run.askFirst = r.askFirst ?? false
            return run
        }
        // Requests still waiting for room when the app quit wait again, on the accounts they were sent to.
        queue = runs.filter { $0.status == .waiting && $0.ended == nil }
        for run in queue { for st in run.steps { st.target = targets.first { $0.label == st.targetLabel }; st.status = .waiting } }
    }
}

/// Splits a byte stream into lines across reads.
final class LineBuffer {
    private var data = Data()
    private let lock = NSLock()
    func add(_ d: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        data.append(d)
        var lines: [String] = []
        while let i = data.firstIndex(of: 10) {
            lines.append(String(decoding: data[data.startIndex..<i], as: UTF8.self))
            data.removeSubrange(data.startIndex...i)
        }
        return lines
    }
    func flush() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard !data.isEmpty else { return [] }
        let s = String(decoding: data, as: UTF8.self); data.removeAll()
        return [s]
    }
}

// MARK: Phone bridge
//
// bin/phone-feed serves orchestrator-state.json and orchestrator-runs.json to the paired phone and appends
// signed phone requests to orchestrator-inbox.json. Burn Rate reads that file every 3 s and acts only on
// folders already allowed here; Edit needs the folder's one-time OK given on the Mac.

extension OrchEngine {
    static let statePath = dataDir + "/orchestrator-state.json"
    static let inboxPath = dataDir + "/orchestrator-inbox.json"
    static var editAllowed: [String] { UserDefaults.standard.stringArray(forKey: "orch.editAllowed") ?? [] }

    func writeState() {
        var state: [String: Any] = [
            "folders": folders.map { ["path": $0, "name": URL(fileURLWithPath: $0).lastPathComponent, "edit": Self.editAllowed.contains($0)] },
            "targets": targets.map { t -> [String: Any] in
                var d: [String: Any] = ["id": t.id, "label": t.label, "usable": t.usable, "kind": t.kind.rawValue]
                if let r = t.room { d["room"] = r }
                if let w = t.why { d["why"] = w }
                return d
            },
            "board": T3Board.feedCache,
            "projects": Hub.feedProjects,
            "link": Hub.feedLink,
            "t3Counts": Hub.feedCounts,
            "preview": routePreview(),
        ]
        // Written only when something in it changed (the time stamp alone doesn't count).
        guard let body = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), body != lastState else { return }
        lastState = body
        state["updated"] = ISO8601DateFormatter().string(from: Date())
        if let d = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: Self.statePath), options: .atomic)
        }
    }

    /// Where an Auto request would go right now, from the same router the run uses (the build step decides the account),
    /// for the phone's New request sheet: the default, plus any project with a pin.
    func routePreview() -> [String: Any] {
        let busy: Set<String> = Thread.isMainThread ? MainActor.assumeIsolated { busyInstances() } : []
        func one(_ project: String?) -> [String: String] {
            let prefer = Thread.isMainThread ? project.map { affinity(.build, folder: $0, steps: []) } ?? [] : []
            return ["read": Router.route(.build, scope: .read, project: project, busy: busy, prefer: prefer).reason,
                    "edit": Router.route(.build, scope: .edit, project: project, busy: busy, prefer: prefer).reason]
        }
        var pinned: [String: Any] = [:]
        for p in Hub.feedProjects.compactMap({ $0["path"] as? String }) where Router.pin(p) != nil { pinned[p] = one(p) }
        return ["default": one(nil), "pinned": pinned]
    }

    /// Starts the Hub (T3 streams) and the data-folder watch that picks up phone requests as they land.
    func startInbox() {
        writeState()
        MainActor.assumeIsolated { Hub.shared.start() }
    }

    func readInbox() {
        guard let d = FileManager.default.contents(atPath: Self.inboxPath),
              let items = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return }
        var seen = UserDefaults.standard.stringArray(forKey: "orch.phoneSeen") ?? []
        var changed = false
        for i in items {
            guard let id = i["id"] as? String, !seen.contains(id) else { continue }
            seen.append(id); changed = true
            if i["kind"] as? String == "stop" {
                if let rid = i["runId"] as? String, let run = runs.first(where: { $0.id.uuidString == rid.uppercased() }) { stop(run) }
                continue
            }
            // Merge or discard a finished run's branch (the phone asks Face ID before merge).
            if let k = i["kind"] as? String, k == "merge" || k == "discard" {
                if let rid = i["runId"] as? String, let run = runs.first(where: { $0.id.uuidString == rid.uppercased() }) {
                    Task { @MainActor in if k == "merge" { await self.merge(run) } else { await self.discard(run) } }
                }
                continue
            }
            // Overview actions from the phone (signed like every phone request; the phone asks Face ID before approve).
            if i["kind"] as? String == "board", let thread = i["thread"] as? String, let action = i["action"] as? String {
                Task { @MainActor in
                    let board = T3Board.shared
                    if Hub.shared.link != .live { await board.refresh() }
                    guard let row = board.rows.first(where: { $0.id == thread }) else { return }
                    switch action {
                    case "approve": await board.answer(row, approve: true, skipAuth: true)
                    case "decline": await board.answer(row, approve: false)
                    case "stop": await board.stop(row)
                    case "reassign": await board.reassign(row)
                    case "reply": await board.reply(row, i["text"] as? String ?? "")
                    default: break
                    }
                }
                continue
            }
            guard let uuid = UUID(uuidString: id), let request = i["request"] as? String, !request.isEmpty,
                  let folder = i["folder"] as? String else { continue }
            let mode = OrchMode(rawValue: i["mode"] as? String ?? "") ?? .auto
            let scope = OrchScope(rawValue: i["scope"] as? String ?? "") ?? .read
            // A project from the Mac's own list may be picked on the phone; it's allowed here on first use (Read).
            if !folders.contains(folder), Hub.feedProjects.contains(where: { $0["path"] as? String == folder }) { allow(folder) }
            if !folders.contains(folder) || (scope == .edit && !Self.editAllowed.contains(folder)) {
                let run = OrchRun(id: uuid, request: request, folder: folder, mode: mode, scope: scope, steps: [])
                run.source = "phone"; run.status = .failed; run.ended = Date()
                run.message = folders.contains(folder) ? "Edit isn't allowed in this folder yet. Allow it once from the Requests window on the Mac."
                                                       : "That folder isn't on the Mac's allowed list."
                runs.insert(run, at: 0); saveLog(); continue
            }
            refreshTargets()
            let target = (i["target"] as? String).flatMap { t in targets.first { $0.id == t } }
            _ = start(request: request, folder: folder, mode: target == nil ? .auto : mode, scope: scope, target: target,
                      model: i["model"] as? String, id: uuid, source: i["source"] as? String ?? "phone", askFirst: i["ask"] as? Bool ?? false)
        }
        if changed { UserDefaults.standard.set(Array(seen.suffix(500)), forKey: "orch.phoneSeen") }
    }
}

// MARK: Window

/// The old entry points (`orch`, ⌥⌘K, the menu, notifications) now open the one window (OneWindow.swift).
enum OrchestratorWindow {
    /// From `orch "request"`: "read|<folder>\n<text>" or "edit|<folder>\n<text>". Auto, in that project.
    @MainActor static func sendFromTerminal(_ payload: String) {
        guard let nl = payload.firstIndex(of: "\n") else { return }
        let head = payload[..<nl].split(separator: "|", maxSplits: 1).map(String.init)
        let text = String(payload[payload.index(after: nl)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.count == 2, !text.isEmpty else { return }
        let scope: OrchScope = head[0] == "edit" ? .edit : .read
        let folder = head[1]
        let engine = OrchEngine.shared
        engine.allow(folder)
        if scope == .edit, !OrchEngine.editAllowed.contains(folder) {
            Notify.send("Edit runs aren't allowed here yet", "Send one Edit request for \(URL(fileURLWithPath: folder).lastPathComponent) from the window first.")
            show(folder: folder)
            return
        }
        let run = engine.start(request: text, folder: folder, mode: .auto, scope: scope, target: nil, source: "terminal")
        show(folder: folder)
        OneModel.shared.selection = .run(run.id)
    }

    /// `view` is kept for old callers ("requests", "board"); there is one window now.
    static func show(view: String? = nil, folder: String? = nil, thread: String? = nil) {
        OneWindow.show(folder: folder, thread: thread)
    }
}


