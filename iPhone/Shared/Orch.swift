import Foundation
import CryptoKit

// MARK: - The Mac's orchestrator board, as the app and the widgets see it
//
// GET /orch (pairing code header, like /feed): projects, accounts with their room, the T3 threads (latest message cut
// short) and recent runs without transcripts. GET /orch/thread?id= loads one thread's full text, its run's steps and
// the changed files, only when it's opened. POST /orch queues a run, a board action, a stop, a merge or a discard.
// POSTs are signed: HMAC-SHA256 over "<unix time>\n<body>" keyed with the pairing code, so the code itself never
// travels with them; the Mac rejects anything older than 5 minutes or already seen.
// Away from home the phone tries the "away" address (the Mac's Tailscale name) when the Wi-Fi address fails.

extension Shared {
    /// The Mac's address on a private network that works over cellular (e.g. its Tailscale name).
    static var remoteHost: String {
        get { defaults.string(forKey: "remoteHost") ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "remoteHost") }
    }
    static var hosts: [String] { [host, remoteHost].filter { !$0.isEmpty }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }

    /// "home" or "away": which address last answered.
    static var reachedVia: String {
        get { defaults.string(forKey: "reachedVia") ?? "home" }
        set { defaults.set(newValue, forKey: "reachedVia") }
    }
    static func reached(_ host: String) {
        lastReached = Date()
        reachedVia = (host == Shared.host || remoteHost.isEmpty) ? "home" : "away"
    }

    /// The board counts and the thread groups last seen, for the Inbox widgets and the change notifications.
    static var boardCounts: (needsYou: Int, running: Int, waiting: Int, updated: Date?) {
        (defaults.integer(forKey: "board.needsYou"), defaults.integer(forKey: "board.running"),
         defaults.integer(forKey: "board.waiting"), defaults.object(forKey: "board.updated") as? Date)
    }
    static var boardGroups: [String: String] {
        get { defaults.dictionary(forKey: "board.groups") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "board.groups") }
    }
    static func saveBoard(_ v: OrchView) {
        let board = v.state.board ?? []
        defaults.set(board.filter { $0.group == "needsYou" }.count, forKey: "board.needsYou")
        defaults.set(board.filter { $0.group == "running" }.count, forKey: "board.running")
        defaults.set(v.runs.filter { $0.status == "waiting" }.count, forKey: "board.waiting")
        defaults.set(Date(), forKey: "board.updated")
    }
}

/// Whether the phone can reach the Mac right now, for the status dot.
enum Reach: Equatable {
    case home, away, unreachable, notPaired
    static var now: Reach {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["ORCH_FIXTURE"] != nil { return .home }   // screen checks
        #endif
        guard !Shared.host.isEmpty, !Shared.code.isEmpty else { return .notPaired }
        guard let t = Shared.lastReached, Date().timeIntervalSince(t) < 150 else { return .unreachable }
        return Shared.reachedVia == "away" ? .away : .home
    }
    var label: String {
        switch self {
        case .home: return "Home"
        case .away: return "Away"
        case .unreachable: return "Can't reach the Mac"
        case .notPaired: return "Not paired"
        }
    }
}

struct OrchView: Decodable {
    struct Folder: Decodable, Hashable { let path: String; let name: String; let edit: Bool? }
    struct Target: Decodable, Hashable { let id: String; let label: String; let usable: Bool; let room: Double?; let why: String?; let kind: String? }
    /// One T3 thread on the Mac's board (the one window's Inbox).
    struct Thread: Decodable, Identifiable, Hashable {
        let id: String; let title: String; let project: String; let projectId: String?; let account: String; let status: String
        let group: String; let why: String?; let latest: String?; let canApprove: Bool?; let reassignTo: String?; let updated: String?
        let runId: String?; let step: String?; let reason: String?
    }
    /// A project from the Mac's sidebar: its repos and T3's projects merged.
    struct Project: Decodable, Identifiable, Hashable { let id: String; let name: String; let path: String; let t3: String?; let edit: Bool?; let allowed: Bool? }
    /// Where an Auto request would go now (the router's reason for the build step), by scope.
    struct Preview: Decodable { let `default`: [String: String]?; let pinned: [String: [String: String]]? }
    struct State: Decodable {
        let folders: [Folder]?; let targets: [Target]?; let updated: String?
        let board: [Thread]?; let projects: [Project]?; let link: String?; let preview: Preview?
    }
    struct Step: Decodable, Hashable {
        let name: String; let target: String?; let scope: String?; let status: String; let note: String?; let output: String?
        let roomBefore: Double?; let reason: String?; let model: String?; let threadId: String?
    }
    struct Run: Decodable, Identifiable, Hashable {
        let id: String; let request: String; let folder: String; let mode: String?; let scope: String?; let status: String
        let started: String?; let ended: String?; let branch: String?; let changed: String?; let merged: Bool?; let message: String?
        let source: String?; let steps: [Step]; let open: Bool?
        var title: String { request.split(separator: "\n").first.map(String.init) ?? request }
        var running: Bool { status == "running" || status == "waiting" }
        /// A finished Edit run whose branch is still there to merge or throw away.
        var canMerge: Bool { open == true && status == "done" && merged != true && (branch ?? "").hasPrefix("orch/") && !(changed ?? "").isEmpty }
    }
    let state: State
    let runs: [Run]
}

/// One thread or run, loaded when it's opened.
struct OrchDetail: Decodable {
    struct File: Decodable, Hashable { let path: String; let added: Int; let removed: Int }
    let thread: OrchView.Thread?
    let run: OrchView.Run?
    let files: [File]
}

enum OrchClient {
    enum Failure: LocalizedError {
        case unreachable, refused(String)
        var errorDescription: String? {
            switch self {
            case .unreachable: return "Can't reach your Mac. On Wi-Fi it needs to be awake on the same network; away from home, set the away address in Settings and turn on Tailscale."
            case .refused(let m): return "The Mac said: \(m)"
            }
        }
    }

    private static func url(_ host: String, _ path: String) -> URL? {
        URL(string: "http://\(host.contains(":") ? "[\(host)]" : host):\(FeedClient.port)\(path)")
    }

    /// Tries the Wi-Fi address, then the away address.
    private static func send(_ path: String, _ make: (URL) -> URLRequest) async throws -> Data {
        var lastStatus: (Int, Data)?
        for h in Shared.hosts {
            guard let u = url(h, path) else { continue }
            do {
                let (data, resp) = try await URLSession.shared.data(for: make(u))
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 { Shared.reached(h); return data }
                lastStatus = (code, data)
                break   // the Mac answered; another address won't change its answer
            } catch { continue }
        }
        guard let (code, data) = lastStatus else { throw Failure.unreachable }
        if code == 401, (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] == nil { throw FeedError.wrongCode }
        let msg = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String ?? "error \(code)"
        throw Failure.refused(msg)
    }

    private static func get(_ path: String, timeout: TimeInterval) async throws -> Data {
        guard !Shared.code.isEmpty else { throw FeedError.notSetUp }
        return try await send(path) { u in
            var r = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
            r.setValue(Shared.code, forHTTPHeaderField: "X-Pairing-Code")
            return r
        }
    }

    static func fetch(timeout: TimeInterval = 6) async throws -> OrchView {
        let v = try JSONDecoder().decode(OrchView.self, from: try await get("/orch", timeout: timeout))
        Shared.saveBoard(v)
        return v
    }

    static func detail(_ id: String) async throws -> OrchDetail {
        let q = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
        return try JSONDecoder().decode(OrchDetail.self, from: try await get("/orch/thread?id=\(q)", timeout: 8))
    }

    static func post(_ body: [String: Any]) async throws {
        guard !Shared.code.isEmpty else { throw FeedError.notSetUp }
        let raw = try JSONSerialization.data(withJSONObject: body)
        let ts = String(Int(Date().timeIntervalSince1970))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(ts.utf8) + Data("\n".utf8) + raw, using: SymmetricKey(data: Data(Shared.code.utf8)))
        let sig = mac.map { String(format: "%02x", $0) }.joined()
        _ = try await send("/orch") { u in
            var r = URLRequest(url: u, timeoutInterval: 10)
            r.httpMethod = "POST"
            r.httpBody = raw
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue(ts, forHTTPHeaderField: "X-Timestamp")
            r.setValue(sig, forHTTPHeaderField: "X-Signature")
            return r
        }
    }
}
