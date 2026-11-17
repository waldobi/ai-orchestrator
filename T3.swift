import Foundation
import Security
import AppKit

// MARK: - T3 Code engine (phase 1 of the T3 integration spec)
//
// See README.md for an overview.
// Requests runs go through a local T3 Code server (`t3 service install`, 127.0.0.1:3773) instead of spawning
// the CLIs here. AI Orchestrator talks to it over T3's own WebSocket RPC (the same one its apps use), with a
// session it issues once on this Mac (`t3 auth session issue`, orchestration scopes only) and keeps in its own
// Keychain item. The token is never logged or shown. AI Orchestrator never writes under ~/.t3: T3 does that.

enum T3Error: Error, LocalizedError {
    case notInstalled, notRunning, protocolMismatch(Int), http(Int, String), rpc(String), closed
    var errorDescription: String? {
        switch self {
        case .notInstalled: return "T3 Code's `t3` command isn't installed (npm install -g t3)."
        case .notRunning: return "The T3 Code service isn't running. Run `t3 service install` in Terminal."
        case .protocolMismatch(let v): return "T3 Code needs an update: it speaks protocol \(v), AI Orchestrator expects \(T3Client.protocolVersion)."
        case .http(let code, let body): return "T3 Code answered \(code): \(body.prefix(300))"
        case .rpc(let m): return "T3 Code: \(m.prefix(400))"
        case .closed: return "The connection to T3 Code closed."
        }
    }
}

/// One provider instance on the T3 server (codex, claudeAgent, cursor…).
struct T3Provider {
    let instanceId: String
    let enabled: Bool
    let ready: Bool
    let models: [String]
}

final class T3Client {
    static let shared = T3Client()
    /// The local T3 Code server. Override with `defaults write local.ai-orchestrator t3Origin http://127.0.0.1:<port>`.
    static let origin = UserDefaults.standard.string(forKey: "t3Origin") ?? "http://127.0.0.1:3773"
    static let protocolVersion = 2
    private static let keychainService = "local.ai-orchestrator.t3-session"

    private let queue = DispatchQueue(label: "t3.client")
    private var socket: URLSessionWebSocketTask?
    private var pending: [String: CheckedContinuation<Any, Error>] = [:]
    private var nextId = 1
    private(set) var providers: [String: T3Provider] = [:]
    /// Claude config folder (absolute) → T3 instance id, from T3's provider instance settings (`config.homePath`).
    private(set) var claudeHomes: [String: String] = [:]
    private(set) var serverVersion: String?

    // Session token (Keychain)

    private func readToken() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.keychainService,
                                kSecAttrAccount as String: "session", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private func saveToken(_ t: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.keychainService,
                                   kSecAttrAccount as String: "session"]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(t.utf8)
        add[kSecAttrLabel as String] = "AI Orchestrator · T3 Code session"
        SecItemAdd(add as CFDictionary, nil)
    }

    private func clearToken() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.keychainService,
                       kSecAttrAccount as String: "session"] as CFDictionary)
    }

    /// Issues a 30-day session limited to reading and operating threads. Only T3 writes its own records.
    private func issueToken() async throws -> String {
        guard let t3 = OrchTargets.which("t3") else { throw T3Error.notInstalled }
        let r = await Self.run(t3, ["auth", "session", "issue", "--scope", "orchestration:read", "--scope", "orchestration:operate",
                                    "--ttl", "30d", "--label", "AI Orchestrator", "--token-only"])
        let token = r.out.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard r.code == 0, !token.isEmpty, !token.contains(" ") else {
            // Never echo stdout here: on success it is the token.
            throw T3Error.rpc("couldn't issue a session (exit \(r.code))")
        }
        saveToken(token)
        return token
    }

    private var issuing: Task<String, Error>?

    /// The saved session, or one new one even when several calls ask at once.
    private func currentToken() async throws -> String {
        if let t = readToken() { return t }
        let task: Task<String, Error> = queue.sync {
            if let t = issuing { return t }
            let t = Task { try await self.issueToken() }
            issuing = t
            return t
        }
        defer { queue.sync { if issuing == task { issuing = nil } } }
        return try await task.value
    }

    static func run(_ exe: String, _ args: [String]) async -> (code: Int32, out: String) {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = (OrchTargets.binDirs + ["/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
                p.environment = env
                let pipe = Pipe()
                p.standardOutput = pipe; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { c.resume(returning: (1, "")); return }
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                c.resume(returning: (p.terminationStatus, String(decoding: d, as: UTF8.self)))
            }
        }
    }

    // HTTP

    private func http(_ method: String, _ path: String, body: Any? = nil, retry: Bool = true) async throws -> Any {
        let token = try await currentToken()
        var req = URLRequest(url: URL(string: Self.origin + path)!)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(String(Self.protocolVersion), forHTTPHeaderField: "x-t3-orchestration-protocol")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw T3Error.notRunning }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401, retry { clearToken(); return try await http(method, path, body: body, retry: false) }
        guard (200..<300).contains(code) else { throw T3Error.http(code, String(decoding: data, as: UTF8.self)) }
        return data.isEmpty ? [:] : ((try? JSONSerialization.jsonObject(with: data)) ?? [:])
    }

    // WebSocket RPC (Effect RPC, JSON serialization)

    /// Live subscriptions on the shared socket (Effect RPC streams): request id → chunk and end handlers.
    private var streams: [String: (values: ([Any]) -> Void, end: (Error?) -> Void)] = [:]
    private var connecting: Task<Void, Error>?

    /// One socket for every call and stream; concurrent callers wait for the same connect.
    private func connect() async throws {
        if queue.sync(execute: { socket?.state == .running }) { return }
        let task: Task<Void, Error> = queue.sync {
            if let t = connecting { return t }
            let t = Task { try await self.open() }
            connecting = t
            return t
        }
        defer { queue.sync { if connecting == task { connecting = nil } } }
        try await task.value
    }

    private func open() async throws {
        if queue.sync(execute: { socket?.state == .running }) { return }
        let ticket = (try await http("POST", "/api/auth/websocket-ticket") as? [String: Any])?["ticket"] as? String ?? ""
        var comps = URLComponents(string: Self.origin.replacingOccurrences(of: "http", with: "ws") + "/ws")!
        comps.queryItems = [.init(name: "orchestrationProtocol", value: String(Self.protocolVersion)), .init(name: "wsTicket", value: ticket)]
        let ws = URLSession.shared.webSocketTask(with: comps.url!)
        ws.maximumMessageSize = 64 << 20
        queue.sync { socket = ws }
        ws.resume()
        receive(ws)
    }

    private func receive(_ ws: URLSessionWebSocketTask) {
        ws.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                let ended: [(Error?) -> Void] = self.queue.sync {
                    guard self.socket === ws || self.socket == nil else { return [] }
                    self.socket = nil
                    let waiting = self.pending; self.pending = [:]
                    waiting.values.forEach { $0.resume(throwing: T3Error.closed) }
                    let s = self.streams.values.map(\.end); self.streams = [:]
                    return s
                }
                ended.forEach { $0(T3Error.closed) }
            case .success(let msg):
                var data: Data?
                switch msg { case .string(let s): data = Data(s.utf8); case .data(let d): data = d; @unknown default: break }
                if let data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { self.handle(o, ws) }
                self.receive(ws)
            }
        }
    }

    private func handle(_ o: [String: Any], _ ws: URLSessionWebSocketTask) {
        switch o["_tag"] as? String {
        case "Ping": ws.send(.string(#"{"_tag":"Pong"}"#)) { _ in }
        case "Chunk":
            guard let id = o["requestId"] as? String else { return }
            let h = queue.sync { streams[id] }
            // Ack each chunk so the server keeps sending (Effect RPC back-pressure).
            ws.send(.string(#"{"_tag":"Ack","requestId":"\#(id)"}"#)) { _ in }
            h?.values(o["values"] as? [Any] ?? [])
        case "Exit":
            guard let id = o["requestId"] as? String else { return }
            let exit = o["exit"] as? [String: Any] ?? [:]
            let ok = exit["_tag"] as? String == "Success"
            if let s = queue.sync(execute: { streams.removeValue(forKey: id) }) {
                s.end(ok ? nil : T3Error.rpc(Self.failureText(exit["cause"])))
                return
            }
            let c = queue.sync { pending.removeValue(forKey: id) }
            if ok { c?.resume(returning: exit["value"] ?? NSNull()) }
            else { c?.resume(throwing: T3Error.rpc(Self.failureText(exit["cause"]))) }
        case "Defect":
            let (waiting, ended) = queue.sync { () -> ([CheckedContinuation<Any, Error>], [(Error?) -> Void]) in
                let w = Array(pending.values); pending = [:]
                let s = streams.values.map(\.end); streams = [:]
                return (w, s)
            }
            waiting.forEach { $0.resume(throwing: T3Error.rpc(Self.failureText(o["defect"]))) }
            ended.forEach { $0(T3Error.rpc(Self.failureText(o["defect"]))) }
        default: break
        }
    }

    private static func failureText(_ cause: Any?) -> String {
        // Effect causes nest as {_tag: Fail, error: {...message}} or a list of them.
        if let d = cause as? [String: Any] {
            if let e = d["error"] as? [String: Any] { return (e["message"] as? String) ?? (e["detail"] as? String) ?? (e["_tag"] as? String) ?? "\(e)" }
            if let m = d["message"] as? String { return m }
            for v in d.values { let t = failureText(v); if !t.isEmpty { return t } }
        }
        if let a = cause as? [Any] { for v in a { let t = failureText(v); if !t.isEmpty { return t } } }
        if let s = cause as? String { return s }
        return ""
    }

    func call(_ tag: String, _ payload: [String: Any]) async throws -> Any {
        try await connect()
        guard let ws = queue.sync(execute: { socket }) else { throw T3Error.closed }
        let id: String = queue.sync { defer { nextId += 1 }; return String(nextId) }
        let body = try JSONSerialization.data(withJSONObject: ["_tag": "Request", "id": id, "tag": tag, "payload": payload, "headers": [] as [Any]])
        return try await withCheckedThrowingContinuation { c in
            queue.sync { pending[id] = c }
            ws.send(.string(String(decoding: body, as: UTF8.self))) { [weak self] err in
                guard let err, let self else { return }
                if let c = self.queue.sync(execute: { self.pending.removeValue(forKey: id) }) { c.resume(throwing: T3Error.rpc(err.localizedDescription)) }
            }
        }
    }

    /// Starts a live subscription (`orchestration.subscribeShell`, `subscribeThread`…) on the shared socket. `onValues`
    /// gets each chunk's items as they arrive; `onEnd` runs once when the stream ends, fails, or the socket closes.
    /// Both run on the socket's queue. Returns the request id for `cancel`.
    func stream(_ tag: String, _ payload: [String: Any], onValues: @escaping ([Any]) -> Void, onEnd: @escaping (Error?) -> Void) async throws -> String {
        try await connect()
        guard let ws = queue.sync(execute: { socket }) else { throw T3Error.closed }
        let id: String = queue.sync { defer { nextId += 1 }; return String(nextId) }
        let body = try JSONSerialization.data(withJSONObject: ["_tag": "Request", "id": id, "tag": tag, "payload": payload, "headers": [] as [Any]])
        queue.sync { streams[id] = (onValues, onEnd) }
        ws.send(.string(String(decoding: body, as: UTF8.self))) { [weak self] err in
            guard let err, let self else { return }
            if let s = self.queue.sync(execute: { self.streams.removeValue(forKey: id) }) { s.end(T3Error.rpc(err.localizedDescription)) }
        }
        return id
    }

    /// Ends a subscription from our side.
    func cancel(_ id: String) {
        let (ws, had) = queue.sync { (socket, streams.removeValue(forKey: id) != nil) }
        guard had, let ws else { return }
        ws.send(.string(#"{"_tag":"Interrupt","requestId":"\#(id)","interruptors":[]}"#)) { _ in }
    }

    /// The changes T3 recorded for a thread up to its latest turn (every run in it), as a unified diff.
    func threadDiff(_ threadId: String, turns: Int) async throws -> String {
        let v = try await call("orchestration.getFullThreadDiff", ["threadId": threadId, "toTurnCount": turns]) as? [String: Any] ?? [:]
        return v["diff"] as? String ?? ""
    }

    // Server facts

    /// Reads providers and the server's protocol; refuses to guess at a newer protocol.
    @discardableResult
    func refresh() async throws -> [String: T3Provider] {
        var cfg = try await call("server.getConfig", [:]) as? [String: Any] ?? [:]
        // T3 caches each provider's sign-in check; ask it to look again at any enabled one that isn't ready
        // (a login done in Terminal or the browser since), then read the config once more.
        let stale = (cfg["providers"] as? [[String: Any]] ?? []).filter { $0["enabled"] as? Bool == true && $0["status"] as? String != "ready" }
            .compactMap { $0["instanceId"] as? String }
        if !stale.isEmpty {
            for id in stale { _ = try? await call("server.refreshProviders", ["instanceId": id]) }
            cfg = try await call("server.getConfig", [:]) as? [String: Any] ?? cfg
        }
        let env = cfg["environment"] as? [String: Any] ?? [:]
        serverVersion = env["serverVersion"] as? String
        if let v = env["orchestrationProtocolVersion"] as? Int, v != Self.protocolVersion { throw T3Error.protocolMismatch(v) }
        var out: [String: T3Provider] = [:]
        for p in cfg["providers"] as? [[String: Any]] ?? [] {
            guard let id = p["instanceId"] as? String else { continue }
            out[id] = T3Provider(instanceId: id, enabled: p["enabled"] as? Bool ?? false, ready: p["status"] as? String == "ready",
                                 models: (p["models"] as? [[String: Any]] ?? []).compactMap { $0["slug"] as? String })
        }
        providers = out
        var homes: [String: String] = [:]
        let settings = cfg["settings"] as? [String: Any] ?? [:]
        for (id, v) in settings["providerInstances"] as? [String: Any] ?? [:] {
            guard let inst = v as? [String: Any], inst["driver"] as? String == "claudeAgent",
                  let home = (inst["config"] as? [String: Any])?["homePath"] as? String else { continue }
            homes[(home as NSString).expandingTildeInPath] = id
        }
        claudeHomes = homes
        return out
    }

    /// The T3 project whose folder is `root`, created through T3 if there is none.
    func projectId(for root: String) async throws -> String {
        let real = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        let shell = try await http("GET", "/api/orchestration/shell") as? [String: Any] ?? [:]
        for p in shell["projects"] as? [[String: Any]] ?? [] {
            if let ws = p["workspaceRoot"] as? String, URL(fileURLWithPath: ws).resolvingSymlinksInPath().path == real, let id = p["id"] as? String { return id }
        }
        let id = UUID().uuidString.lowercased()
        _ = try await http("POST", "/api/projects/mutate", body: ["type": "project.create", "commandId": UUID().uuidString.lowercased(),
                                                                  "projectId": id, "title": URL(fileURLWithPath: root).lastPathComponent,
                                                                  "workspaceRoot": root])
        return id
    }

    func launch(projectId: String, title: String, instance: String, model: String, worktree: String, branch: String?, prompt: String, askFirst: Bool = false) async throws -> String {
        var ws: [String: Any] = ["type": "existing_worktree", "worktreePath": worktree]
        if let branch { ws["branch"] = branch }
        let v = try await call("orchestration.launchThread", [
            "commandId": UUID().uuidString.lowercased(),
            "projectId": projectId, "title": String(title.prefix(80)), "generateTitle": false,
            "modelSelection": ["instanceId": instance, "model": model],
            // The worktree is the run's own, so full access stays inside it; the never list guards the rest.
            // "Ask before acting" runs wait for an Approve on every command and edit.
            "runtimeMode": askFirst ? "approval-required" : "full-access", "interactionMode": "default",
            "workspaceStrategy": ws,
            "initialMessage": ["text": prompt, "attachments": [] as [Any]],
        ]) as? [String: Any] ?? [:]
        guard let id = v["threadId"] as? String else { throw T3Error.rpc("launch returned no thread id") }
        return id
    }

    /// Every project and thread on the server, with each thread's status, pending request and latest message.
    func shell() async throws -> [String: Any] {
        try await http("GET", "/api/orchestration/shell") as? [String: Any] ?? [:]
    }

    func projection(_ threadId: String) async throws -> [String: Any] {
        try await call("orchestration.getThreadProjection", ["threadId": threadId]) as? [String: Any] ?? [:]
    }

    /// T3's own Stop for a run (never a process kill).
    func interrupt(threadId: String, runId: String) async {
        _ = try? await call("orchestration.dispatchCommand", ["type": "run.interrupt", "commandId": UUID().uuidString.lowercased(),
                                                                "threadId": threadId, "runId": runId])
    }

    /// Idle footprint of the T3 service, measured (resident memory MB, CPU %), or nil when it isn't running.
    static func footprint() async -> (mb: Double, cpu: Double)? {
        let pg = await run("/usr/bin/pgrep", ["-f", "/.t3/runtime/versions/.*/t3 serve"])
        guard let pid = pg.out.split(separator: "\n").first.map(String.init) else { return nil }
        let ps = await run("/bin/ps", ["-o", "rss=,%cpu=", "-p", pid])
        let f = ps.out.split(separator: " ").compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard f.count >= 2 else { return nil }
        return (f[0] / 1024, f[1])
    }
}

extension OrchTarget {
    /// The T3 provider instance that runs this target: a second Claude login maps to the T3 Claude account whose
    /// config folder is that login's folder; nil when T3 has none for it.
    var t3Instance: String? {
        if kind == .claude, let dir = configDir { return T3Client.shared.claudeHomes[dir] }
        return kind.t3Instance
    }
}

extension OrchKind {
    /// The T3 provider instance that runs this tool.
    var t3Instance: String {
        switch self { case .claude: return "claudeAgent"; case .codex: return "codex"; case .cursor: return "cursor" }
    }
}

// MARK: Sign-in from AI Orchestrator (Nov 8)

/// Provider sign-ins without T3's own app. Cursor signs in through T3 (`provider.auth.start` + `subscribe` on one
/// connection, because a sign-in belongs to the client that started it); the page opens in the browser and T3 keeps
/// the credential. A Claude account signs in with Claude's own CLI in Terminal, in that account's config folder.
/// The short session used here (providers:manage) is never saved and is revoked when the sign-in ends.
@MainActor
final class T3SignIn: ObservableObject {
    static let shared = T3SignIn()
    @Published var state: [String: String] = [:]   // instance → plain status line
    private var sockets: [String: URLSessionWebSocketTask] = [:]

    func cursor(_ instance: String = "cursor") {
        guard sockets[instance] == nil else { return }
        state[instance] = "Starting sign-in…"
        Task {
            do {
                guard let t3 = OrchTargets.which("t3") else { throw T3Error.notInstalled }
                let r = await T3Client.run(t3, ["auth", "session", "issue", "--scope", "providers:manage", "--scope", "settings:write",
                                                "--scope", "orchestration:read", "--ttl", "15m", "--label", "AI Orchestrator sign-in", "--token-only"])
                let token = r.out.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                guard r.code == 0, !token.isEmpty else { throw T3Error.rpc("couldn't issue a sign-in session") }
                var req = URLRequest(url: URL(string: T3Client.origin + "/api/auth/websocket-ticket")!)
                req.httpMethod = "POST"
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                req.setValue(String(T3Client.protocolVersion), forHTTPHeaderField: "x-t3-orchestration-protocol")
                let (d, _) = try await URLSession.shared.data(for: req)
                let ticket = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["ticket"] as? String ?? ""
                var comps = URLComponents(string: T3Client.origin.replacingOccurrences(of: "http", with: "ws") + "/ws")!
                comps.queryItems = [.init(name: "orchestrationProtocol", value: String(T3Client.protocolVersion)), .init(name: "wsTicket", value: ticket)]
                let ws = URLSession.shared.webSocketTask(with: comps.url!)
                sockets[instance] = ws
                ws.resume()
                func send(_ id: String, _ tag: String) {
                    let body = try! JSONSerialization.data(withJSONObject: ["_tag": "Request", "id": id, "tag": tag,
                        "payload": tag == "provider.auth.start" ? ["instanceId": instance, "callbackMode": "server"] : ["instanceId": instance],
                        "headers": [] as [Any]])
                    ws.send(.string(String(decoding: body, as: UTF8.self))) { _ in }
                }
                send("1", "provider.auth.start")
                send("2", "provider.auth.subscribe")
                var opened = false
                let deadline = Date().addingTimeInterval(15 * 60)
                loop: while Date() < deadline {
                    let msg = try await ws.receive()
                    guard case .string(let s) = msg, let o = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { continue }
                    switch o["_tag"] as? String {
                    case "Ping": ws.send(.string(#"{"_tag":"Pong"}"#)) { _ in }
                    case "Exit" where o["requestId"] as? String == "1":
                        if (o["exit"] as? [String: Any])?["_tag"] as? String != "Success" {
                            state[instance] = "Couldn't start: " + String(describing: o["exit"] ?? "").prefix(160)
                            if String(describing: o["exit"] ?? "").contains("already in progress") {
                                state[instance] = "A sign-in started elsewhere is still open; try again in a few minutes."
                            }
                            break loop
                        }
                    case "Chunk":
                        for v in o["values"] as? [[String: Any]] ?? [] {
                            let phase = v["phase"] as? String ?? ""
                            if !opened, let u = v["authorizationUrl"] as? String, let url = URL(string: u), url.scheme == "https" {
                                opened = true
                                NSWorkspace.shared.open(url)
                                state[instance] = "Finish signing in in your browser."
                            }
                            if phase == "succeeded" { state[instance] = "Signed in."; break loop }
                            if phase == "failed" || phase == "cancelled" { state[instance] = (v["message"] as? String) ?? "Sign-in \(phase)."; break loop }
                        }
                    default: break
                    }
                }
                ws.cancel(with: .normalClosure, reason: nil)
            } catch {
                state[instance] = error.localizedDescription
            }
            sockets[instance] = nil
            await revokeSignInSessions()
            _ = await OrchEngine.shared.refreshT3()
        }
    }

    /// Adds each `~/.claude-<name>` login T3 doesn't know yet as its own T3 Claude account (create only: an instance
    /// that already exists is left as it is, nothing is removed). Uses a short settings:write session, revoked after.
    func registerClaudeLogins(_ logins: [(name: String, dir: String)]) async -> [String] {
        guard !logins.isEmpty, let t3 = OrchTargets.which("t3") else { return [] }
        var done: [String] = []
        do {
            let r = await T3Client.run(t3, ["auth", "session", "issue", "--scope", "settings:write", "--scope", "providers:manage",
                                            "--ttl", "5m", "--label", "AI Orchestrator sign-in", "--token-only"])
            let token = r.out.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard r.code == 0, !token.isEmpty else { throw T3Error.rpc("couldn't issue a settings session") }
            var req = URLRequest(url: URL(string: T3Client.origin + "/api/auth/websocket-ticket")!)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue(String(T3Client.protocolVersion), forHTTPHeaderField: "x-t3-orchestration-protocol")
            let (d, _) = try await URLSession.shared.data(for: req)
            let ticket = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["ticket"] as? String ?? ""
            var comps = URLComponents(string: T3Client.origin.replacingOccurrences(of: "http", with: "ws") + "/ws")!
            comps.queryItems = [.init(name: "orchestrationProtocol", value: String(T3Client.protocolVersion)), .init(name: "wsTicket", value: ticket)]
            let ws = URLSession.shared.webSocketTask(with: comps.url!)
            ws.resume()
            defer { ws.cancel(with: .normalClosure, reason: nil) }
            for (i, l) in logins.enumerated() {
                let slug = "claude-" + l.name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
                let body = try JSONSerialization.data(withJSONObject: ["_tag": "Request", "id": String(i + 1), "tag": "server.updateSettings",
                    "payload": ["patch": [String: Any](),
                                "providerInstanceMutation": ["operation": "create", "instanceId": slug,
                                                             "instance": ["driver": "claudeAgent", "displayName": "Claude · \(l.name)",
                                                                          "enabled": true, "config": ["homePath": l.dir]]]],
                    "headers": [] as [Any]])
                try await ws.send(.string(String(decoding: body, as: UTF8.self)))
                let deadline = Date().addingTimeInterval(20)
                while Date() < deadline {
                    guard case .string(let s) = try await ws.receive(),
                          let o = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { continue }
                    if o["_tag"] as? String == "Ping" { try? await ws.send(.string(#"{"_tag":"Pong"}"#)); continue }
                    if o["_tag"] as? String == "Chunk", let rid = o["requestId"] as? String {
                        try? await ws.send(.string(#"{"_tag":"Ack","requestId":"\#(rid)"}"#)); continue
                    }
                    guard o["_tag"] as? String == "Exit", o["requestId"] as? String == String(i + 1) else { continue }
                    let ok = (o["exit"] as? [String: Any])?["_tag"] as? String == "Success"
                    state["claude:" + l.name] = ok ? "Added to T3 Code." : "T3 Code didn't add it: " + String(describing: o["exit"] ?? "").prefix(160)
                    if ok { done.append(l.name) }
                    break
                }
            }
        } catch {
            for l in logins where state["claude:" + l.name] == nil { state["claude:" + l.name] = error.localizedDescription }
        }
        await revokeSignInSessions()
        return done
    }

    /// Opens Terminal on Claude's own login for one account's config folder (the user signs in there).
    func claude(name: String) {
        let dir = "~/.claude-" + name.lowercased().replacingOccurrences(of: " ", with: "-")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("claude-login-\(name.lowercased()).command")
        let script = "#!/bin/zsh\necho 'Sign in with the \(name) Claude account.'\nCLAUDE_CONFIG_DIR=\(dir) claude auth login\necho\necho 'Done. You can close this window.'\n"
        try? script.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        NSWorkspace.shared.open(file)
        state["claude:" + name] = "Sign in in the Terminal window, then come back."
    }

    private func revokeSignInSessions() async {
        guard let t3 = OrchTargets.which("t3") else { return }
        let list = await T3Client.run(t3, ["auth", "session", "list", "--json"])
        guard let o = try? JSONSerialization.jsonObject(with: Data(list.out.utf8)) else { return }
        let all = (o as? [[String: Any]]) ?? ((o as? [String: Any])?["sessions"] as? [[String: Any]]) ?? []
        for s in all where (s["client"] as? [String: Any])?["label"] as? String == "AI Orchestrator sign-in" {
            if let id = s["sessionId"] as? String { _ = await T3Client.run(t3, ["auth", "session", "revoke", id]) }
        }
    }
}
