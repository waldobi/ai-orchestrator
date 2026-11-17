import SwiftUI
import AppKit
import LocalAuthentication
import Carbon.HIToolbox

// MARK: - Overview board (T3 spec phases 2–3, Nov 8)
//
// One view of every agent thread on the Mac's T3 Code server, across all projects and accounts, whoever started
// it (AI Orchestrator, T3, the phone). Grouped Needs you → Running → Failed → Done. From a row: approve or decline
// what an agent is waiting on (approve asks for Touch ID), reply, Stop (T3's own interrupt), or Reassign: hand the
// task to the account with the most room, in the same folder, with what the last agent said. Data: T3's live shell
// stream through the Hub (Hub.swift); nothing here polls.

enum BoardGroup: String, CaseIterable, Identifiable {
    case needsYou, running, failed, done
    var id: String { rawValue }
    var title: String {
        switch self { case .needsYou: return "Needs you"; case .running: return "Running"; case .failed: return "Failed or stopped"; case .done: return "Done" }
    }
    var color: Color {
        switch self { case .needsYou: return .primary; case .running: return .secondary; case .failed: return Theme.alert; case .done: return Theme.ok }
    }
}

/// A run's error as one plain sentence, with what kind of fix applies. The raw text stays behind a disclosure.
struct PlainError: Equatable {
    enum Kind { case model, limit, signIn, unknown }
    let text: String
    let kind: Kind
    let raw: String

    static func modelName(_ raw: String) -> String? {
        for pattern in [#"'([^']+)' model"#, #"model '([^']+)'"#, #"model[: ]+"([^"]+)""#] {
            if let r = raw.range(of: pattern, options: .regularExpression) {
                let m = String(raw[r]), q: Character = pattern.contains("\"") ? "\"" : "'"
                if let name = m.split(separator: q, omittingEmptySubsequences: false).dropFirst().first { return String(name) }
            }
        }
        return nil
    }

    static func isModelError(_ raw: String) -> Bool {
        let l = raw.lowercased()
        return l.contains("model") && (l.contains("not supported") || l.contains("unsupported") || l.contains("not_found") || l.contains("does not exist") || l.contains("not available"))
    }

    static func explain(_ raw: String) -> PlainError {
        let l = raw.lowercased()
        if isModelError(raw) {
            return PlainError(text: "This account can't use \(modelName(raw).map { "the \($0) model" } ?? "that model").", kind: .model, raw: raw)
        }
        if ["usage limit", "rate limit", "limit reached", "quota", "hit your limit", "too many requests"].contains(where: l.contains) {
            return PlainError(text: "This account ran out of room.", kind: .limit, raw: raw)
        }
        if ["not logged in", "not signed in", "please log in", "unauthorized", "authentication", "invalid api key", "401"].contains(where: l.contains) {
            return PlainError(text: "This account isn't signed in.", kind: .signIn, raw: raw)
        }
        var line = raw
        if let r = raw.range(of: #""message"\s*:\s*"[^"]+""#, options: .regularExpression) {
            line = String(raw[r].split(separator: "\"").last ?? "")
        }
        line = line.split(whereSeparator: \.isNewline).first.map(String.init) ?? line
        return PlainError(text: String(line.prefix(140)), kind: .unknown, raw: raw)
    }
}

struct BoardRow: Identifiable, Equatable {
    let id: String
    let title: String
    let project: String
    let projectId: String
    let instance: String
    let account: String
    let status: String
    let group: BoardGroup
    let why: String           // the waiting request, the error or the limit, in plain words
    let latest: String        // the latest visible message
    let updated: Date?
    let activeRunId: String?
    let requestId: String?
    let requestKind: String?
    let worktree: String?
    let branch: String?
    let source: String
    let runtimeMode: String
    var problem: PlainError? = nil

    var canApprove: Bool { ["command", "file-read", "file-change", "permission"].contains(requestKind ?? "") }
}

@MainActor
final class T3Board: ObservableObject {
    static let shared = T3Board()
    @Published var rows: [BoardRow] = []
    @Published var error = ""
    @Published var busy: Set<String> = []
    @Published var note: [String: String] = [:]
    /// The row a notification click should show.
    @Published var focus: String?
    private var lastGroups: [String: BoardGroup]?
    var visible = false
    /// How far back finished threads show (the spec's default; older ones through search).
    static let days = 14.0

    private init() {}

    private static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    private static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    /// The account behind a T3 provider instance, in the names the rest of the app uses.
    static func account(_ instance: String) -> String {
        if let t = OrchEngine.shared.targets.first(where: { $0.t3Instance == instance }) { return t.label }
        switch instance {
        case "codex": return "Codex"
        case "cursor": return "Cursor"
        case "claudeAgent": return "Claude"
        default: return instance
        }
    }

    /// One read of T3's shell over HTTP, only for when the live stream isn't up (the Hub normally feeds `apply`).
    func refresh() async {
        do {
            let shell = try await T3Client.shared.shell()
            apply(threads: shell["threads"] as? [[String: Any]] ?? [], projects: shell["projects"] as? [[String: Any]] ?? [])
            error = ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Rebuilds the rows from the shell stream's threads and projects.
    func apply(threads: [[String: Any]], projects plist: [[String: Any]]) {
        do {
            var projects: [String: String] = [:]
            for p in plist {
                if let id = p["id"] as? String { projects[id] = (p["title"] as? String) ?? URL(fileURLWithPath: p["workspaceRoot"] as? String ?? "").lastPathComponent }
            }
            let dayAgo = Date().addingTimeInterval(-Self.days * 86_400)
            var out: [BoardRow] = []
            for t in threads {
                guard let id = t["id"] as? String, t["archivedAt"] is NSNull || t["archivedAt"] == nil,
                      (t["lineage"] as? [String: Any])?["parentThreadId"] as? String == nil else { continue }
                let status = t["status"] as? String ?? "idle"
                let pending = t["pendingRuntimeRequest"] as? [String: Any]
                let limitAt = Self.date(t["usageLimitResetAt"])
                let updated = Self.date(t["latestRunCompletedAt"]) ?? Self.date(t["updatedAt"]) ?? Self.date(t["createdAt"])
                let latest = ((t["latestVisibleMessage"] as? [String: Any])?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let err = (t["lastError"] as? String) ?? ""
                var why = ""
                var problem: PlainError?
                let group: BoardGroup
                if let pending, pending["blocking"] as? Bool != false {
                    group = .needsYou
                    let kind = pending["kind"] as? String ?? ""
                    why = ["command": "Wants to run a command", "file-change": "Wants to change files", "file-read": "Wants to read a file",
                           "permission": "Asks for a permission", "user_input": "Asked you a question",
                           "mcp-elicitation": "A tool asks for input", "auth_refresh": "Needs a sign-in"][kind] ?? "Waiting on you"
                } else if status == "waiting" {
                    group = .needsYou; why = "Waiting on you"
                } else if let limitAt, ["failed", "interrupted", "idle", "waiting"].contains(status) {
                    group = .needsYou; why = "Hit its usage limit (resets \(limitAt.formatted(date: .omitted, time: .shortened)))"
                } else if ["preparing", "queued", "starting", "running"].contains(status) {
                    group = .running
                } else if ["failed", "interrupted", "cancelled"].contains(status) {
                    guard (updated ?? .distantPast) > dayAgo else { continue }
                    group = .failed
                    if err.isEmpty { why = status.capitalized } else { problem = PlainError.explain(err); why = problem!.text }
                } else if status == "completed" || status == "rolled_back" {
                    guard (updated ?? .distantPast) > dayAgo else { continue }
                    group = .done
                } else { continue }
                let instance = t["providerInstanceId"] as? String ?? ""
                let source = (t["creationSource"] as? String) == "mcp" || (t["createdBy"] as? String) == "agent" ? "AI Orchestrator or an agent" : "T3"
                out.append(BoardRow(id: id, title: t["title"] as? String ?? "Untitled", project: projects[t["projectId"] as? String ?? ""] ?? "–",
                                    projectId: t["projectId"] as? String ?? "", instance: instance, account: Self.account(instance),
                                    status: status, group: group, why: String(why.prefix(300)), latest: String(latest.prefix(600)), updated: updated,
                                    activeRunId: (t["activeRunId"] as? String) ?? (t["latestRunId"] as? String),
                                    requestId: pending?["id"] as? String, requestKind: pending?["kind"] as? String,
                                    worktree: t["worktreePath"] as? String, branch: t["branch"] as? String, source: source,
                                    runtimeMode: t["runtimeMode"] as? String ?? "full-access", problem: problem))
            }
            out.sort { a, b in
                let ga = BoardGroup.allCases.firstIndex(of: a.group)!, gb = BoardGroup.allCases.firstIndex(of: b.group)!
                return ga != gb ? ga < gb : (a.updated ?? .distantPast) > (b.updated ?? .distantPast)
            }
            notifyChanges(out)
            if out != rows { rows = out }
            error = ""
            Self.feedCache = feed
        }
    }

    /// A notification when a thread lands in Needs you, Failed or Done. The first read only records where things are.
    /// The Plan and Build steps of an Auto run stay quiet when done; its Review closes it.
    private func notifyChanges(_ out: [BoardRow]) {
        defer { lastGroups = Dictionary(out.map { ($0.id, $0.group) }, uniquingKeysWith: { a, _ in a }) }
        guard let prev = lastGroups else { return }
        for r in out where prev[r.id] != r.group && r.group != .running {
            if r.group == .done, r.title.hasPrefix("Plan · ") || r.title.hasPrefix("Build · ") { continue }
            Notify.board("\(r.group.title) · \(r.project)", r.why.isEmpty ? r.title : "\(r.title): \(r.why)", thread: r.id)
        }
    }

    // Actions

    private func dispatch(_ cmd: [String: Any]) async throws {
        var c = cmd
        c["commandId"] = UUID().uuidString.lowercased()
        _ = try await T3Client.shared.call("orchestration.dispatchCommand", c)
    }

    private func touchID(_ reason: String) async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return false }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    /// Approve (Touch ID) or decline what the agent is waiting on. Shown only for approvals.
    func answer(_ row: BoardRow, approve: Bool, skipAuth: Bool = false) async {
        guard let req = row.requestId else { return }
        if approve, !skipAuth, !(await touchID("approve what \(row.account) is waiting on")) { note[row.id] = "Not approved."; return }
        await act(row) { try await self.dispatch(["type": "runtime-request.respond", "threadId": row.id, "requestId": req, "decision": approve ? "accept" : "decline"]) }
    }

    /// A message to the thread: it reaches the agent as its next turn (nothing is interrupted).
    func reply(_ row: BoardRow, _ text: String) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        await act(row) {
            try await self.dispatch(["type": "message.dispatch", "threadId": row.id, "messageId": UUID().uuidString.lowercased(), "text": t,
                                     "attachments": [] as [Any], "dispatchMode": ["type": "queue_after_active"], "createdBy": "user", "creationSource": "server"])
        }
    }

    func stop(_ row: BoardRow) async {
        guard let run = row.activeRunId else { return }
        await act(row) { await T3Client.shared.interrupt(threadId: row.id, runId: run) }
    }

    /// The usable tool that isn't the one on this thread, soonest reset first (Router.better).
    func reassignTarget(_ row: BoardRow) -> OrchTarget? {
        Router.best(OrchEngine.shared.targets.filter { $0.usable && $0.t3Instance != row.instance })
    }

    /// Hands the task to `reassignTarget`: stops this thread if it's still going, then starts a new one in the same
    /// project and folder (the same worktree when it had one), with the original request and where it stopped.
    func reassign(_ row: BoardRow) async {
        guard let t = reassignTarget(row), let inst = t.t3Instance else { note[row.id] = "No other account has room."; return }
        await act(row) {
            if ["preparing", "queued", "starting", "running", "waiting"].contains(row.status), let run = row.activeRunId {
                await T3Client.shared.interrupt(threadId: row.id, runId: run)
            }
            let p = try await T3Client.shared.projection(row.id)
            let first = (p["messages"] as? [[String: Any]] ?? []).first { $0["role"] as? String == "user" }?["text"] as? String ?? row.title
            let models = T3Client.shared.providers[inst]?.models ?? []
            guard let model = models.first else { throw T3Error.rpc("T3 offers no model for \(t.label)") }
            let prompt = """
            Take over this task from another agent (\(row.account)), which stopped: \(row.why.isEmpty ? row.status : row.why).
            Continue from where it left off in this folder; check what's already changed before you start. Don't push, deploy or publish, and don't run sudo.

            Original request:
            \(String(first.prefix(8000)))

            Last thing the other agent said:
            \(String(row.latest.suffix(3000)))
            """
            var ws: [String: Any] = ["type": "root"]
            if let wt = row.worktree { ws = ["type": "existing_worktree", "worktreePath": wt]; if let b = row.branch { ws["branch"] = b } }
            _ = try await T3Client.shared.call("orchestration.launchThread", [
                "commandId": UUID().uuidString.lowercased(), "projectId": row.projectId,
                "title": String("↪ \(row.title)".prefix(80)), "generateTitle": false,
                "modelSelection": ["instanceId": inst, "model": model],
                "runtimeMode": row.runtimeMode, "interactionMode": "default", "workspaceStrategy": ws,
                "initialMessage": ["text": prompt, "attachments": [] as [Any]],
            ])
            self.note[row.id] = "Reassigned to \(t.label)."
        }
    }

    private func act(_ row: BoardRow, _ body: @escaping () async throws -> Void) async {
        busy.insert(row.id)
        do { try await body(); if note[row.id] == nil { note[row.id] = "Done." } }
        catch { note[row.id] = error.localizedDescription }
        busy.remove(row.id)
        if Hub.shared.link != .live { await refresh() }
    }

    /// The last board, for `writeState` (which may run off the main thread).
    nonisolated(unsafe) static var feedCache: [[String: Any]] = []

    /// The board as plain data for the phone feed.
    var feed: [[String: Any]] {
        rows.prefix(60).map { r in
            var d: [String: Any] = ["id": r.id, "title": r.title, "project": r.project, "projectId": r.projectId, "account": r.account, "status": r.status,
                                    "group": r.group.rawValue, "why": r.why, "latest": String(r.latest.prefix(600)), "canApprove": r.canApprove,
                                    "reassignTo": reassignTarget(r)?.label ?? ""]
            if let u = r.updated { d["updated"] = ISO8601DateFormatter().string(from: u) }
            if let run = OrchEngine.shared.runs.first(where: { $0.steps.contains { $0.threadId == r.id } }) {
                d["runId"] = run.id.uuidString
                let st = run.steps.first { $0.threadId == r.id }
                d["step"] = st?.name ?? ""
                d["reason"] = st?.reason ?? ""
            } else {
                d["reason"] = "Started in T3 Code on \(r.account)"
            }
            return d
        }
    }
}

/// ⌥⌘K anywhere opens the one window (Carbon hot key: no Accessibility permission needed).
enum GlobalHotKey {
    private static var ref: EventHotKeyRef?
    static func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { OneWindow.show() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4F524348), id: 1) // 'ORCH'
        RegisterEventHotKey(UInt32(kVK_ANSI_K), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }
}
