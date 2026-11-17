import SwiftUI
import AppKit

// MARK: - Hub (one-window spec, phase 1, Nov 17)
//
// See README.md for an overview.
// One shared WebSocket to T3 Code carries every call and two kinds of live stream: `orchestration.subscribeShell`
// (every project and thread, kept for the life of the app) and `orchestration.subscribeThread` (only threads someone
// is watching: a running step, or the thread open in the window). Nothing here polls T3. The Hub holds:
//   Projects: T3's projects merged with the git repos Report › Projects knows.
//   Threads:  T3Board.rows, built from the shell stream (14 days; older ones through search).
//   Accounts: OrchEngine.targets (provider, login folder, T3 instance, plan, live limits, paid-extra rule).
// Files (orchestrator-state.json for the phone) are written when what they hold changes, never on a timer.
// Plan, Build and Review are separate top-level T3 threads (launchThread can't name a parent, and getThreadFamily only
// follows forks and subagents), so a request's steps are grouped by our own run id (`HubRequest`).

enum T3Link: Equatable {
    case connecting, live, down(String)
    var text: String {
        switch self {
        case .connecting: return "T3 Code: connecting…"
        case .live: return "T3 Code: live"
        case .down(let why): return "T3 Code: \(why)"
        }
    }
}

struct HubProject: Identifiable, Equatable {
    let id: String          // the folder's resolved path
    var name: String
    let path: String
    var t3Id: String?
    var known: Bool         // a repo Report › Projects knows
}

@MainActor
final class Hub: ObservableObject {
    static let shared = Hub()

    @Published private(set) var link: T3Link = .connecting { didSet { Self.feedLink = link == .live ? "live" : link.text } }
    /// Plain copies for `OrchEngine.writeState` (the phone feed).
    nonisolated(unsafe) static var feedProjects: [[String: Any]] = []
    nonisolated(unsafe) static var feedLink = "connecting"
    nonisolated(unsafe) static var feedCounts: [String: Int] = [:]
    /// Shell stream counters (snapshots, threads in the last snapshot, updates), for diagnosing a thin board.
    static var streamDiag: [String: Int] = [:]
    @Published private(set) var projects: [HubProject] = []
    /// Bumped when a watched thread changes (the open thread view reloads on it).
    @Published private(set) var threadTicks: [String: Int] = [:]
    /// When the shell stream last delivered a change (for the "within a second" check).
    private(set) var lastChange: Date?

    private var shellThreads: [String: [String: Any]] = [:]
    private var shellProjects: [String: [String: Any]] = [:]
    private var shellStream: String?
    private var backoff = 1.0
    private var started = false
    private var rebuildQueued = false
    private var knownRepos: [(name: String, path: String)] = []

    // Thread watching: one subscribeThread per watched thread, shared by everyone watching it.
    private var threadStreams: [String: (stream: String?, refs: Int)] = [:]
    private var waiters: [String: [UUID: CheckedContinuation<Void, Never>]] = [:]
    private var dirty: Set<String> = []

    func start() {
        guard !started else { return }
        started = true
        knownRepos = OrchEngine.knownProjects()
        connectShell()
        DataFolderWatch.shared.start()
    }

    // Shell stream

    private func connectShell() {
        link = .connecting
        Task {
            do {
                shellStream = try await T3Client.shared.stream("orchestration.subscribeShell", [:], onValues: { vals in
                    Task { @MainActor in Hub.shared.applyShell(vals) }
                }, onEnd: { err in
                    Task { @MainActor in Hub.shared.shellEnded(err) }
                })
            } catch {
                shellEnded(error)
            }
        }
    }

    private func shellEnded(_ err: Error?) {
        shellStream = nil
        link = .down(err.map { ($0 as? LocalizedError)?.errorDescription ?? $0.localizedDescription } ?? "stream ended")
        // Everyone waiting on a thread gets woken so they can read once; threads are re-followed on reconnect.
        for id in Array(waiters.keys) { fire(id) }
        for (id, s) in threadStreams { threadStreams[id] = (nil, s.refs) }
        let wait = backoff
        backoff = min(backoff * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.shellStream == nil else { return }
            self.connectShell()
        }
    }

    private func applyShell(_ values: [Any]) {
        var touched: Set<String> = []
        for case let v as [String: Any] in values {
            switch v["kind"] as? String {
            case "snapshot":
                let snap = v["snapshot"] as? [String: Any] ?? [:]
                Self.streamDiag["snapshots", default: 0] += 1
                Self.streamDiag["snapThreads"] = (snap["threads"] as? [Any])?.count ?? -1
                Self.streamDiag["snapArchived"] = (snap["archivedThreads"] as? [Any])?.count ?? -1
                shellThreads = [:]; shellProjects = [:]
                for t in snap["threads"] as? [[String: Any]] ?? [] { if let id = t["id"] as? String { shellThreads[id] = t; touched.insert(id) } }
                for p in snap["projects"] as? [[String: Any]] ?? [] { if let id = p["id"] as? String { shellProjects[id] = p } }
                // T3 0.1.7's stream snapshot can come back without threads; fill in from one HTTP shell read.
                Task { @MainActor in await Hub.shared.seedFromHTTP() }
                if link != .live {
                    let wasDown = { if case .down = link { return true }; return false }()
                    link = .live
                    backoff = 1
                    // Back after a drop: providers may have changed while we were away; re-follow watched threads.
                    if wasDown { Task { _ = await OrchEngine.shared.refreshT3() } }
                    for id in threadStreams.keys where threadStreams[id]?.stream == nil { subscribeThread(id) }
                }
            case "thread.updated":
                guard let t = v["thread"] as? [String: Any], let id = t["id"] as? String else { continue }
                Self.streamDiag[v["location"] as? String == "archive" ? "archiveUpdates" : "updates", default: 0] += 1
                if v["location"] as? String == "archive" { shellThreads[id] = nil } else { shellThreads[id] = t }
                touched.insert(id)
            case "thread.removed":
                Self.streamDiag["removed", default: 0] += 1
                if let id = v["threadId"] as? String { shellThreads[id] = nil; touched.insert(id) }
            case "project.updated":
                if let p = v["project"] as? [String: Any], let id = p["id"] as? String { shellProjects[id] = p }
            case "project.removed":
                if let id = v["projectId"] as? String { shellProjects[id] = nil }
            default: break   // "synchronized" and anything newer
            }
        }
        lastChange = Date()
        for id in touched { fire(id) }
        queueRebuild()
    }

    /// One read of T3's HTTP shell after a snapshot: threads the snapshot left out are added (never replacing a
    /// newer stream copy).
    func seedFromHTTP() async {
        guard let sh = try? await T3Client.shared.shell() else { Self.streamDiag["httpThreads"] = -1; return }
        let threads = sh["threads"] as? [[String: Any]] ?? []
        Self.streamDiag["httpThreads"] = threads.count
        var added = false
        for t in threads {
            guard let id = t["id"] as? String, shellThreads[id] == nil else { continue }
            shellThreads[id] = t; added = true
        }
        for p in sh["projects"] as? [[String: Any]] ?? [] {
            if let id = p["id"] as? String, shellProjects[id] == nil { shellProjects[id] = p; added = true }
        }
        if added { queueRebuild() } else { rebuild() }
    }

    /// Coalesces a burst of stream items into one rebuild.
    private func queueRebuild() {
        guard !rebuildQueued else { return }
        rebuildQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            self.rebuildQueued = false
            self.rebuild()
        }
    }

    private static var worktreeCache: [String: Bool] = [:]
    static func isLinkedWorktree(_ path: String) -> Bool {
        if let v = worktreeCache[path] { return v }
        var dir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path + "/.git", isDirectory: &dir)
        let v = exists && !dir.boolValue
        worktreeCache[path] = v
        return v
    }

    private func rebuild() {
        T3Board.shared.apply(threads: Array(shellThreads.values), projects: Array(shellProjects.values))
        var byPath: [String: HubProject] = [:]
        for r in knownRepos {
            // A linked git worktree (".git" is a file) is a branch of another repo, not a project.
            if Self.isLinkedWorktree(r.path) { continue }
            let real = URL(fileURLWithPath: r.path).resolvingSymlinksInPath().path
            byPath[real] = HubProject(id: real, name: r.name, path: r.path, t3Id: nil, known: true)
        }
        for p in shellProjects.values {
            guard let root = p["workspaceRoot"] as? String, let id = p["id"] as? String, p["deletedAt"] == nil || p["deletedAt"] is NSNull else { continue }
            // Our own worktrees aren't projects.
            if root.hasPrefix(OrchEngine.worktreeDir) { continue }
            let real = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
            let name = (p["title"] as? String) ?? URL(fileURLWithPath: root).lastPathComponent
            if var e = byPath[real] { e.t3Id = id; byPath[real] = e }
            else { byPath[real] = HubProject(id: real, name: name, path: root, t3Id: id, known: false) }
        }
        let rows = T3Board.shared.rows
        let lastActive = Dictionary(rows.map { ($0.projectId, $0.updated ?? .distantPast) }, uniquingKeysWith: max)
        let out = byPath.values.sorted { a, b in
            let la = a.t3Id.flatMap { lastActive[$0] } ?? .distantPast, lb = b.t3Id.flatMap { lastActive[$0] } ?? .distantPast
            return la != lb ? la > lb : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        // Same folder name in two places: add the parent folder so the rows can be told apart.
        let dupes = Dictionary(grouping: out, by: { $0.name.lowercased() }).filter { $0.value.count > 1 }.keys
        let named = out.map { p -> HubProject in
            guard dupes.contains(p.name.lowercased()) else { return p }
            var q = p; q.name = "\(p.name) · \(URL(fileURLWithPath: p.path).deletingLastPathComponent().lastPathComponent)"; return q
        }
        if named != projects { projects = named }
        OrchEngine.shared.drainQueue()
        let top = shellThreads.values.filter { ($0["lineage"] as? [String: Any])?["parentThreadId"] as? String == nil }
        Self.feedCounts = Self.streamDiag.merging(["threads": shellThreads.count, "topLevel": top.count, "rows": rows.count,
                           "statuses": Set(top.compactMap { $0["status"] as? String }).count]) { $1 }
        Self.feedProjects = out.prefix(60).map { p in
            ["id": p.id, "name": p.name, "path": p.path, "t3": p.t3Id ?? "",
             "edit": OrchEngine.editAllowed.contains(p.path), "allowed": OrchEngine.shared.folders.contains(p.path)] as [String: Any]
        }
        OrchEngine.shared.writeState()
    }

    /// projects.json changed on disk (a new repo in Report › Projects).
    func reloadKnownRepos() {
        knownRepos = OrchEngine.knownProjects()
        queueRebuild()
    }

    /// The T3 project id for a folder, from the stream (nil until T3 has one).
    func t3Project(for path: String) -> String? {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return shellProjects.first { ($0.value["workspaceRoot"] as? String).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == real }?.key
    }

    func shellRow(_ threadId: String) -> [String: Any]? { shellThreads[threadId] }

    // Thread watching

    /// Starts (or shares) a live subscription to one thread. Pair with `unfollow`.
    func follow(_ threadId: String) {
        if let s = threadStreams[threadId] { threadStreams[threadId] = (s.stream, s.refs + 1); return }
        threadStreams[threadId] = (nil, 1)
        if link == .live { subscribeThread(threadId) }
    }

    func unfollow(_ threadId: String) {
        guard let s = threadStreams[threadId] else { return }
        if s.refs > 1 { threadStreams[threadId] = (s.stream, s.refs - 1); return }
        threadStreams[threadId] = nil
        if let id = s.stream { T3Client.shared.cancel(id) }
        dirty.remove(threadId)
    }

    private func subscribeThread(_ threadId: String) {
        Task {
            do {
                let sid = try await T3Client.shared.stream("orchestration.subscribeThread", ["threadId": threadId], onValues: { _ in
                    Task { @MainActor in Hub.shared.fire(threadId) }
                }, onEnd: { _ in
                    Task { @MainActor in
                        let h = Hub.shared
                        if let s = h.threadStreams[threadId] { h.threadStreams[threadId] = (nil, s.refs) }
                        h.fire(threadId)
                    }
                })
                if let s = threadStreams[threadId] { threadStreams[threadId] = (sid, s.refs) } else { T3Client.shared.cancel(sid) }
            } catch {
                fire(threadId)
            }
        }
    }

    private func fire(_ threadId: String) {
        if threadStreams[threadId] != nil { threadTicks[threadId, default: 0] += 1 }
        guard let w = waiters.removeValue(forKey: threadId), !w.isEmpty else {
            if threadStreams[threadId] != nil { dirty.insert(threadId) }
            return
        }
        w.values.forEach { $0.resume() }
    }

    /// Waits until the thread changes (stream event or shell row update). Returns at once if it changed since the last
    /// wait. `timeout` is only a safety net for a stream that went quiet; it is not a poll interval.
    func nextChange(_ threadId: String, timeout: Double = 30) async {
        if dirty.remove(threadId) != nil { return }
        let token = UUID()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters[threadId, default: [:]][token] = c
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let c = self.waiters[threadId]?.removeValue(forKey: token) else { return }
                c.resume()
            }
        }
    }
}

// MARK: Router
//
// One routing service for the composer, `orch`, Reassign and the phone: route(request) → account, model, reason.

enum RouteRole: String { case plan, build, review, run, reassign }

struct Route {
    let target: OrchTarget?
    let model: String?
    let reason: String
}

enum Router {
    /// Resets this close together count as the same time; room breaks the tie.
    static let resetTie: TimeInterval = 6 * 3600

    /// Soonest reset first: room left in a window that resets sooner is lost sooner, so that account goes first.
    /// Accounts inside their plan always beat ones that would bill paid extra; no known reset sorts last.
    static func better(_ a: OrchTarget, _ b: OrchTarget) -> Bool {
        if a.withinPlan != b.withinPlan { return a.withinPlan }
        let ra = a.resets ?? .distantFuture, rb = b.resets ?? .distantFuture
        if abs(ra.timeIntervalSince(rb)) > resetTie { return ra < rb }
        return (a.room ?? 0) > (b.room ?? 0)
    }

    static func best(_ list: [OrchTarget]) -> OrchTarget? { list.sorted(by: better).first }

    /// Why `t` won over the others of its kind, in a few words.
    private static func whyBest(_ t: OrchTarget, _ c: [OrchTarget]) -> String? {
        guard c.count > 1 else { return nil }
        let others = c.filter { $0.id != t.id }
        let k = t.kind.rawValue.capitalized
        if others.allSatisfy({ abs(($0.resets ?? .distantFuture).timeIntervalSince(t.resets ?? .distantFuture)) <= resetTie }) {
            return "most room of \(c.count) \(k) logins"
        }
        return "resets soonest of \(c.count) \(k) logins"
    }

    private static func roomWords(_ t: OrchTarget) -> String {
        var s = t.roomText
        if let r = t.resets, r.timeIntervalSinceNow < 48 * 3600 { s += ", resets \(r.formatted(.relative(presentation: .named)))" }
        return s
    }

    /// Picks the account for one step. `avoid` holds T3 instances not to use (Review avoids Build's; Reassign avoids the thread's).
    /// The account pinned to a project folder (Projects › Pin), if any.
    static func pin(_ project: String?) -> String? {
        project.flatMap { UserDefaults.standard.string(forKey: "orch.pin." + $0) }
    }
    static func setPin(_ project: String, _ targetId: String?) {
        UserDefaults.standard.set(targetId, forKey: "orch.pin." + project)
        OrchEngine.shared.objectWillChange.send()
    }

    static func route(_ role: RouteRole, scope: OrchScope = .read, project: String? = nil, avoid: Set<String> = [],
                      direct: OrchTarget? = nil, model: String? = nil, targets: [OrchTarget]? = nil, busy: Set<String> = [],
                      prefer: [(id: String, why: String)] = []) -> Route {
        let all = targets ?? OrchEngine.shared.targets
        if let d = direct {
            let t = all.first { $0.id == d.id } ?? d
            return Route(target: t, model: model ?? defaultModel(t), reason: "You picked \(t.label)" + (t.why.map { " (it is \($0))" } ?? ""))
        }
        let usable = all.filter { $0.usable && !avoid.contains($0.t3Instance ?? $0.id) && !busy.contains($0.t3Instance ?? $0.id) }
        // A project pin wins for plan/build/run when that account has room and isn't already busy.
        var pinNote = ""
        if role != .reassign, !(role == .review && !avoid.isEmpty), let pid = pin(project), let p = all.first(where: { $0.id == pid }) {
            if usable.contains(where: { $0.id == pid }) {
                return Route(target: p, model: defaultModel(p), reason: "\(p.label): pinned for this project (\(roomWords(p)))")
            }
            let state = busy.contains(p.t3Instance ?? p.id) ? "running \(OrchEngine.maxRunningPerAccount) threads" : (p.why ?? "busy")
            pinNote = "Pinned \(p.label) is \(state), so "
        }
        func pick(_ order: [OrchKind], _ why: String) -> Route {
            for k in order {
                let c = usable.filter { $0.kind == k }
                // Affinity: stay on the account this run or project just used, so its prompt cache is reused
                // instead of written again on another account. Only inside the plan, never into paid extra.
                if c.count > 1, let p = prefer.first(where: { p in c.contains { $0.id == p.id && $0.withinPlan } }),
                   let t = c.first(where: { $0.id == p.id }) {
                    return Route(target: t, model: defaultModel(t), reason: pinNote + "\(t.label): \(p.why) (\(roomWords(t)))")
                }
                if let t = best(c) {
                    return Route(target: t, model: defaultModel(t), reason: pinNote + "\(t.label): \(whyBest(t, c) ?? why) (\(roomWords(t)))")
                }
            }
            let skipped = all.filter { !$0.usable || busy.contains($0.t3Instance ?? $0.id) }
                .map { "\($0.label) \($0.why ?? "running \(OrchEngine.maxRunningPerAccount) threads")" }.joined(separator: "; ")
            return Route(target: nil, model: nil, reason: pinNote + "No account has room" + (skipped.isEmpty ? "." : ": \(skipped)."))
        }
        switch role {
        case .plan: return pick([.claude, .codex, .cursor], "plans and reviews go to Claude first")
        case .review: return pick([.claude, .codex, .cursor], avoid.isEmpty ? "plans and reviews go to Claude first" : "a different account from the build")
        case .build where scope == .edit: return pick([.codex, .cursor, .claude], "builds go to Codex first")
        case .build: return pick([.claude, .codex, .cursor], "read-only answers go to Claude first")
        case .run: return pick([.claude, .codex, .cursor], "most room")
        case .reassign:
            guard let t = best(usable) else { return pick([], "") }
            return Route(target: t, model: defaultModel(t), reason: "\(t.label): resets soonest of the other accounts with room (\(roomWords(t)))")
        }
    }

    /// Codex's own configured model when T3 offers it, else T3's first model for that account.
    static func defaultModel(_ t: OrchTarget, not failed: String? = nil) -> String? {
        let offered = t.t3Instance.flatMap { T3Client.shared.providers[$0]?.models } ?? []
        if t.kind == .codex, let txt = try? String(contentsOfFile: OrchTargets.home + "/.codex/config.toml", encoding: .utf8),
           let line = txt.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("model ") || $0.hasPrefix("model=") }),
           let q = line.split(separator: "\"").dropFirst().first.map(String.init), q != failed, offered.contains(q) { return q }
        return offered.first { $0 != failed }
    }
}

// MARK: Data folder watch
//
// One kqueue watch on Application Support/local.ai-orchestrator. When status.json changes the accounts are re-read,
// when the phone appends to orchestrator-inbox.json it is handled, when projects.json changes the project list is
// rebuilt. Replaces the 3 s inbox timer and the window's 60 s re-read.

final class DataFolderWatch {
    static let shared = DataFolderWatch()
    private var source: DispatchSourceFileSystemObject?
    private var mtimes: [String: Date] = [:]
    private var queued = false

    private func mtime(_ name: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: OrchEngine.dataDir + "/" + name))?[.modificationDate] as? Date
    }

    func start() {
        guard source == nil else { return }
        for n in ["status.json", "orchestrator-inbox.json", "projects.json"] { mtimes[n] = mtime(n) }
        let fd = open(OrchEngine.dataDir, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .link], queue: .main)
        s.setEventHandler { [weak self] in self?.queueCheck() }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
        // The inbox may already hold requests that arrived while we were closed.
        OrchEngine.shared.readInbox()
    }

    private func queueCheck() {
        guard !queued else { return }
        queued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.queued = false
            self.check()
        }
    }

    private func check() {
        func changed(_ n: String) -> Bool {
            let m = mtime(n)
            defer { mtimes[n] = m }
            return m != mtimes[n]
        }
        if changed("orchestrator-inbox.json") { OrchEngine.shared.readInbox() }
        if changed("status.json") { OrchEngine.shared.refreshTargets() }
        if changed("projects.json") { MainActor.assumeIsolated { Hub.shared.reloadKnownRepos() } }
    }
}
