// Burn Rate — a floating widget that measures what your AI tools cost and helps you spend less:
// every Claude, Codex and Cursor account side by side with live limits, trends, a monthly budget,
// an ideas backlog and a manager (Claude API) that reads your real usage and says what to change.
// Each Claude account is the regular Claude app launched with its own --user-data-dir profile.
//
// Build with "Install Burn Rate.command" (macOS 14+). Single file, no dependencies.
// (Formerly Claude Switcher; the bundle id and data folder are still local.ai-orchestrator.)

import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers
import Charts
import Combine
import CommonCrypto
import CoreServices
import LocalAuthentication
import Security
import ServiceManagement
import SQLite3
import SwiftUI
import UserNotifications
import WebKit

// MARK: - Paths & small helpers

/// Demo mode (`AIO_DEMO=1`): made-up usage for every account instead of reading claude.ai, Codex logs or
/// cursor.com, for screenshots and trying the app without signing in. Run it with a throwaway home folder
/// (`CFFIXED_USER_HOME=/tmp/aio-demo`) so nothing real is read. See scripts/demo.sh.
enum Demo {
    static let on = ProcessInfo.processInfo.environment["AIO_DEMO"] == "1"
    private static func iso(_ hours: Double) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date().addingTimeInterval(hours * 3600))
    }
    private static let readings: [String: (Double, Double, Double, Double)] = [   // 5h %, resets in h, weekly %, resets in h
        "main": (38, 2.4, 61, 70), "work": (12, 4.1, 27, 115), "side": (91, 0.6, 84, 30)]
    static func claudeJSON(_ slug: String) -> String {
        let r = readings[slug] ?? (20, 3, 40, 90)
        let obj: [String: Any] = ["status": "ok", "email": "\(slug)@example.com",
            "usage": ["five_hour": ["utilization": r.0, "resets_at": iso(r.1)],
                      "seven_day": ["utilization": r.2, "resets_at": iso(r.3)]],
            "org": ["rate_limit_tier": "default_claude_max_5x", "billing_type": "stripe_subscription", "capabilities": ["chat", "claude_max"]]]
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
    static var codex: CodexUsage {
        CodexUsage(plan: "plus", weeklyPercent: 46, weeklyResets: Date().addingTimeInterval(52 * 3600), shortPercent: 22,
                   shortResets: Date().addingTimeInterval(3 * 3600), tokensWeek: 4_200_000, sessionsWeek: 18, measuredAt: Date())
    }
    static var cursor: CursorUsage {
        CursorUsage(plan: "pro", percent: 34, used: 6.8, limit: 20, cycleEnd: Date().addingTimeInterval(12 * 86_400))
    }
}

enum Paths {
    static let claudeApp = URL(fileURLWithPath: "/Applications/Claude.app")
    static let appSupport = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support")
    static let mainProfile = appSupport.appendingPathComponent("Claude")
    static func profile(slug: String) -> URL { appSupport.appendingPathComponent("Claude-\(slug)") }
    static let configName = "claude_desktop_config.json"
}

func slugify(_ s: String) -> String {
    var out = ""
    var lastWasDash = false
    for ch in s.lowercased().unicodeScalars {
        if ch.isASCII && CharacterSet.alphanumerics.contains(ch) {
            out.unicodeScalars.append(ch)
            lastWasDash = false
        } else if !lastWasDash && !out.isEmpty {
            out.append("-")
            lastWasDash = true
        }
    }
    while out.hasSuffix("-") { out.removeLast() }
    return out
}

func prettify(_ slug: String) -> String {
    slug.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
}

/// Command-line arguments of another process (used to tell Claude instances apart).
func processArguments(_ pid: pid_t) -> [String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    if sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) != 0 || size < 8 { return [] }
    var buf = [UInt8](repeating: 0, count: size)
    if sysctl(&mib, u_int(mib.count), &buf, &size, nil, 0) != 0 { return [] }
    let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
    var i = 4
    while i < size && buf[i] != 0 { i += 1 }   // executable path
    while i < size && buf[i] == 0 { i += 1 }   // padding
    var args: [String] = []
    while args.count < argc && i < size {
        let start = i
        while i < size && buf[i] != 0 { i += 1 }
        args.append(String(decoding: buf[start..<i], as: UTF8.self))
        i += 1
    }
    return args
}

func showAlert(_ title: String, _ text: String) {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = text
    NSApp.activate()
    a.runModal()
}

// MARK: - Models

struct Account: Identifiable, Hashable {
    let slug: String          // "main" = Claude's normal profile
    var name: String
    var profileURL: URL
    var isMain: Bool { slug == "main" }
    var id: String { slug }
}

struct UsageWindow {
    var percent: Double
    var resetsAt: Date?
}

enum UsageState: Equatable {
    case loading, ok, needsSignIn
    case error(String)
}

struct UsageInfo {
    var state: UsageState = .loading
    var session: UsageWindow?
    var weekly: UsageWindow?
    var email: String?
    var updated: Date?
    var details: UsageDetails?
    /// What claude.ai says about the organization's plan (non-secret): e.g. "default_claude_max_20x",
    /// "stripe_subscription", ["claude_max", "chat"]. Used only to name the plan; nil when not reported.
    var rateLimitTier: String?
    /// Next renewal, when claude.ai reports one (subscription details or the Billing page's "auto renew on …").
    var renews: Date?
    var billingType: String?
    var capabilities: [String] = []
}

struct LimitRow: Identifiable {
    let id: String
    let name: String
    let percent: Double
    let resetsAt: Date?
}

/// Everything claude.ai reports beyond the two headline bars, for the hover panel.
struct UsageDetails {
    var limits: [LimitRow] = []
    var surfaces: [(name: String, percent: Double)] = []
    var weekStart: Date?
    var extraEnabled = false
    var extraReached = false
    var extraUsed: Double?
    var extraLimit: Double?
    var extraPercent: Double?
    /// Why extra usage is off, when Claude gives a reason worth showing.
    var extraNote: String?
    /// Dollar-capped windows beyond the percent limits. Claude only names these with internal codes.
    var spendCaps: [(used: Double, limit: Double, percent: Double?, resetsAt: Date?)] = []
    /// Scoped limits measured against the weekly one, e.g. Fable has used 30 of its 50% share.
    var weeklyShares: [(name: String, used: Double, allowed: Double)] = []
    var currency = "USD"
    var prepaid: Double?
    /// Claude's auto-reload of prepaid credit (nil when not reported).
    var autoReload: Bool?
    var autoReloadTo: Double?, autoReloadBelow: Double?
    /// Credit grants Claude reports (id, when, dollars, auto-reload?) — used to log purchases over time.
    var grants: [(id: String, date: Date, amount: Double, auto: Bool)] = []
}

struct TokenStats: Codable {
    var input = 0, output = 0, cacheWrite = 0, cacheRead = 0
    var sessions = 0
    var byModel: [String: Int] = [:]
    /// What these tokens would have cost at Anthropic API list prices (USD).
    var value: Double = 0
    /// The same value split by model; nil on days saved before it was kept.
    var valueByModel: [String: Double]?
    var total: Int { input + output + cacheWrite + cacheRead }

    init() {}
    // Older saved files have no "value"; read them anyway.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        input = try c.decodeIfPresent(Int.self, forKey: .input) ?? 0
        output = try c.decodeIfPresent(Int.self, forKey: .output) ?? 0
        cacheWrite = try c.decodeIfPresent(Int.self, forKey: .cacheWrite) ?? 0
        cacheRead = try c.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0
        sessions = try c.decodeIfPresent(Int.self, forKey: .sessions) ?? 0
        byModel = try c.decodeIfPresent([String: Int].self, forKey: .byModel) ?? [:]
        value = try c.decodeIfPresent(Double.self, forKey: .value) ?? 0
        valueByModel = try c.decodeIfPresent([String: Double].self, forKey: .valueByModel)
    }
}

/// Anthropic API list prices per million tokens (input, output, cache read), first matching prefix wins.
/// Cache writes are 1.25× input for the 5-minute TTL and 2× for the 1-hour TTL. Fast mode doubles every
/// rate on the models that offer it. Haiku 5.5 moves to higher prices when a request's prompt tops
/// 100K tokens, counting cache reads and writes. Unknown models fall back to Opus 5.5.
enum APIPrices {
    private static let table: [(prefix: String, input: Double, output: Double, cacheRead: Double)] = [
        ("claude-fable-5-1", 10, 50, 0.25), ("claude-mythos-5-1", 10, 50, 0.25),
        ("claude-fable-5", 10, 50, 1.0), ("claude-mythos-5", 10, 50, 1.0),
        ("claude-opus-5-5", 4, 20, 0.20), ("claude-opus-5", 5, 25, 0.50),
        ("claude-opus-4-1", 15, 75, 1.50), ("claude-opus-4-2", 15, 75, 1.50),   // 4.1, and 4 (claude-opus-4-2025…)
        ("claude-opus-4", 5, 25, 0.50),
        ("claude-sonnet-5-5", 2, 10, 0.10), ("claude-sonnet-5", 2, 10, 0.20), ("claude-sonnet-4", 3, 15, 0.30),
        ("claude-haiku-5-5", 0.10, 0.50, 0.01), ("claude-haiku-4", 1, 5, 0.10), ("claude-3-5-haiku", 0.80, 4, 0.08),
    ]

    /// `cacheWrite` is all cache writes; `cacheWrite5m` is the part of it at the 5-minute TTL.
    static func cost(model: String, input: Int, output: Int, cacheWrite: Int, cacheRead: Int,
                     cacheWrite5m: Int = 0, fast: Bool = false) -> Double {
        var p = table.first { model.hasPrefix($0.prefix) } ?? ("", 4, 20, 0.20)
        if model.hasPrefix("claude-haiku-5-5"), input + cacheWrite + cacheRead > 100_000 { p = ("", 0.50, 2.50, 0.05) }
        let speed = fast && (model.hasPrefix("claude-opus-5") || model.hasPrefix("claude-opus-4-8")) ? 2.0 : 1.0
        return (Double(input) * p.input + Double(output) * p.output
                + Double(cacheWrite - cacheWrite5m) * p.input * 2 + Double(cacheWrite5m) * p.input * 1.25
                + Double(cacheRead) * p.cacheRead) * speed / 1_000_000
    }

    static func cost(_ en: TokenCounter.Entry) -> Double {
        cost(model: en.model, input: en.input, output: en.output, cacheWrite: en.cacheWrite, cacheRead: en.cacheRead,
             cacheWrite5m: en.cacheWrite5m, fast: en.fast)
    }
}

// MARK: - Token counts from local Claude Code transcripts

/// Each profile lists its Claude Code sessions in claude-code-sessions/…/local_*.json, whose
/// cliSessionId names a transcript in ~/.claude/projects. Transcripts record tokens per message.
/// Only sessions run from that Claude window on this Mac are counted (not chats or other devices).
/// Opens another app's SQLite file read-only. A database in WAL mode whose app has closed it has no -shm file,
/// and a read-only connection can't create one, so the open or the first query fails (Codex's state_5.sqlite
/// since Oct 28). Then it opens again as immutable, which reads the file as it is without locks or WAL.
enum ReadOnlyDB {
    static func open(_ db: URL, _ h: inout OpaquePointer?) -> Int32 {
        if sqlite3_open_v2("file:\(db.path)?mode=ro", &h, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
           sqlite3_exec(h, "SELECT count(*) FROM sqlite_master", nil, nil, nil) == SQLITE_OK { return SQLITE_OK }
        sqlite3_close(h); h = nil
        // Only when no -wal file is waiting; otherwise immutable would miss its newest writes.
        let wal = db.path + "-wal"
        guard !FileManager.default.fileExists(atPath: wal) || ((try? FileManager.default.attributesOfItem(atPath: wal)[.size] as? Int) ?? 0) == 0 else { return SQLITE_CANTOPEN }
        return sqlite3_open_v2("file:\(db.path)?mode=ro&immutable=1", &h, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
    }
}

enum TokenCounter {
    static let queue = DispatchQueue(label: "ai-orchestrator.tokens", qos: .utility)

    struct Entry: Codable {
        let id: String
        let date: Date
        let model: String
        let input, output, cacheWrite, cacheRead: Int
        // Required on purpose: a cache saved without them fails to load, so transcripts are read again.
        let cacheWrite5m: Int
        let fast: Bool
    }
    /// Parsed entries per transcript, plus how many bytes were read, so a growing file only has its new lines parsed.
    private static var cache: [String: (read: UInt64, entries: [Entry])] = loadCache()
    private static var cacheDirty = false

    /// The parsed-entries cache is kept on disk so a relaunch doesn't re-read every transcript.
    private struct CacheFile: Codable { var read: UInt64; var entries: [Entry] }
    private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.ai-orchestrator/token-cache.json")
    }
    private static func loadCache() -> [String: (read: UInt64, entries: [Entry])] {
        guard let data = try? Data(contentsOf: cacheURL),
              let file = try? JSONDecoder().decode([String: CacheFile].self, from: data) else { return [:] }
        return file.mapValues { ($0.read, $0.entries) }
    }
    private static var lastSave = Date.distantPast
    static func saveCache() {
        // Writing it takes a few seconds, so at most every 15 minutes.
        guard cacheDirty, Date().timeIntervalSince(lastSave) > 900 else { return }
        cacheDirty = false
        lastSave = Date()
        let file = cache.mapValues { CacheFile(read: $0.read, entries: $0.entries) }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(file) { try? data.write(to: cacheURL, options: .atomic) }
    }
    private static let projects = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    /// Deduplicated token entries for a profile since a date, with the session each came from.
    /// Claude Code session ids that a profile's window started.
    static func sessionIDs(profile: URL) -> Set<String> {
        let fm = FileManager.default
        var ids = Set<String>()
        let sessions = profile.appendingPathComponent("claude-code-sessions")
        if let e = fm.enumerator(at: sessions, includingPropertiesForKeys: nil) {
            for case let url as URL in e where url.lastPathComponent.hasPrefix("local_") && url.pathExtension == "json" {
                if let data = try? Data(contentsOf: url),
                   let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let id = obj["cliSessionId"] as? String, !id.isEmpty {
                    ids.insert(id)
                }
            }
        }
        return ids
    }

    private static func collect(profile: URL, since: Date) -> [(entry: Entry, session: String)] {
        let fm = FileManager.default
        let ids = sessionIDs(profile: profile)
        let dirs = (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        var files: [(url: URL, session: String)] = []
        for dir in dirs {
            for id in ids {
                let main = dir.appendingPathComponent("\(id).jsonl")
                if fm.fileExists(atPath: main.path) { files.append((main, id)) }
                let sub = dir.appendingPathComponent(id)   // subagent transcripts
                if let e = fm.enumerator(at: sub, includingPropertiesForKeys: nil) {
                    for case let url as URL in e where url.pathExtension == "jsonl" { files.append((url, id)) }
                }
            }
        }

        return collect(files: files, since: since)
    }

    /// Every transcript on this Mac whose session no Claude window claims (terminal, Remote Control…).
    private static func collectOther(excluding ids: Set<String>, since: Date) -> [(entry: Entry, session: String)] {
        var files: [(url: URL, session: String)] = []
        let base = projects.standardizedFileURL.pathComponents.count
        if let e = FileManager.default.enumerator(at: projects, includingPropertiesForKeys: nil) {
            for case let url as URL in e where url.pathExtension == "jsonl" {
                let comps = url.standardizedFileURL.pathComponents
                guard comps.count > base + 1 else { continue }
                // projects/<dir>/<id>.jsonl or projects/<dir>/<id>/…/x.jsonl
                let session = comps.count == base + 2 ? url.deletingPathExtension().lastPathComponent : comps[base + 1]
                if !ids.contains(session) { files.append((url, session)) }
            }
        }
        return collect(files: files, since: since)
    }

    private static func collect(files: [(url: URL, session: String)], since: Date) -> [(entry: Entry, session: String)] {
        let fm = FileManager.default
        var out: [(entry: Entry, session: String)] = []
        var seen = Set<String>()
        for (file, session) in files {
            guard let attrs = try? fm.attributesOfItem(atPath: file.path),
                  let mtime = attrs[.modificationDate] as? Date, mtime >= since else { continue }
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            var c = cache[file.path] ?? (0, [])
            if size < c.read { c = (0, []) }                    // rewritten, start over
            if size > c.read {
                let (more, end) = parse(file, from: c.read)
                c = (end, c.entries + more)
                cache[file.path] = c
                cacheDirty = true
            }
            let entries = c.entries
            for en in entries where en.date >= since && seen.insert(en.id).inserted {
                out.append((en, session))
            }
        }
        return out
    }

    private static func add(_ en: Entry, to stats: inout TokenStats) {
        stats.input += en.input
        stats.output += en.output
        stats.cacheWrite += en.cacheWrite
        stats.cacheRead += en.cacheRead
        stats.byModel[en.model, default: 0] += en.input + en.output + en.cacheWrite + en.cacheRead
        let cost = APIPrices.cost(en)
        stats.value += cost
        stats.valueByModel = stats.valueByModel ?? [:]
        stats.valueByModel?[en.model, default: 0] += cost
    }

    static func stats(profile: URL, since: Date) -> TokenStats {
        var stats = TokenStats()
        var sessions = Set<String>()
        for (en, session) in collect(profile: profile, since: since) {
            add(en, to: &stats)
            sessions.insert(session)
        }
        stats.sessions = sessions.count
        return stats
    }

    /// Per-day totals (local calendar days) — the token history comes straight from the transcripts.
    /// How Claude Code is being used: how much context each turn re-sends, how long sessions run.
    struct WorkPattern {
        var turns = 0, heavyTurns = 0, sessions = 0, longSessions = 0
        var heavyTokens = 0, allTokens = 0
        var busiestHours: [Int] = []
    }

    static func pattern(profiles: [URL], since: Date) -> WorkPattern {
        var w = WorkPattern()
        var perSession: [String: Int] = [:]
        var hours = [Int](repeating: 0, count: 24)
        var seen = Set<String>()
        for p in profiles {
            for (en, session) in collect(profile: p, since: since) where seen.insert(en.id).inserted {
                let context = en.input + en.cacheRead + en.cacheWrite
                let all = context + en.output
                w.turns += 1
                w.allTokens += all
                if context > 300_000 { w.heavyTurns += 1; w.heavyTokens += all }
                perSession[session, default: 0] += 1
                hours[Calendar.current.component(.hour, from: en.date)] += 1
            }
        }
        w.sessions = perSession.count
        w.longSessions = perSession.values.filter { $0 > 300 }.count
        w.busiestHours = hours.enumerated().sorted { $0.element > $1.element }.prefix(3).map(\.offset).sorted()
        return w
    }

    /// Every transcript entry on this Mac since a date, deduplicated: the profiles' own sessions plus
    /// terminal and remote ones. Used by the command center (shapes, heat, projects, manager).
    static func everything(profiles: [URL], since: Date) -> [(entry: Entry, session: String)] {
        var out: [(entry: Entry, session: String)] = []
        var seen = Set<String>()
        for p in profiles {
            for e in collect(profile: p, since: since) where seen.insert(e.entry.id).inserted { out.append(e) }
        }
        let ids = profiles.reduce(into: Set<String>()) { $0.formUnion(sessionIDs(profile: $1)) }
        for e in collectOther(excluding: ids, since: since) where seen.insert(e.entry.id).inserted { out.append(e) }
        return out
    }

    /// Project folder for a session id, from the transcript's location under ~/.claude/projects.
    /// "-Users-me-Code-my-app" → "Code/my-app" (folder names with "-" in
    /// them can't be told apart from path separators, so this is a label, not a path).
    static func project(ofSession id: String) -> String {
        if let p = projectOf[id] { return p }
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs where fm.fileExists(atPath: dir.appendingPathComponent("\(id).jsonl").path) || fm.fileExists(atPath: dir.appendingPathComponent(id).path) {
            var name = dir.lastPathComponent
            let home = FileManager.default.homeDirectoryForCurrentUser.path.replacingOccurrences(of: "/", with: "-")
            if name.hasPrefix(home) { name = String(name.dropFirst(home.count)) }
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-")).replacingOccurrences(of: "-", with: "/")
            projectOf[id] = name.isEmpty ? "Home" : name
            return projectOf[id]!
        }
        projectOf[id] = "Unknown"
        return "Unknown"
    }
    private static var projectOf: [String: String] = [:]

    /// One Claude Code session: how long it ran, how many turns, how much of its tokens were the
    /// same context re-read every turn. Measured straight from the transcript.
    struct SessionShape: Identifiable {
        let id: String
        var project = ""
        var start = Date.distantFuture, end = Date.distantPast
        var turns = 0, heavyTurns = 0
        var input = 0, output = 0, cacheWrite = 0, cacheRead = 0
        var value = 0.0
        var byModel: [String: Int] = [:]
        var total: Int { input + output + cacheWrite + cacheRead }
        var cacheShare: Double { total > 0 ? Double(cacheRead) / Double(total) : 0 }
        var minutes: Int { max(0, Int(end.timeIntervalSince(start) / 60)) }
        var topModel: String { byModel.max { $0.value < $1.value }?.key ?? "" }
    }

    static func shapes(profiles: [URL], since: Date) -> [SessionShape] {
        var map: [String: SessionShape] = [:]
        for (en, session) in everything(profiles: profiles, since: since) {
            var s = map[session] ?? SessionShape(id: session)
            s.start = min(s.start, en.date); s.end = max(s.end, en.date)
            s.turns += 1
            if en.input + en.cacheRead + en.cacheWrite > 300_000 { s.heavyTurns += 1 }
            s.input += en.input; s.output += en.output; s.cacheWrite += en.cacheWrite; s.cacheRead += en.cacheRead
            s.value += APIPrices.cost(en)
            s.byModel[en.model, default: 0] += en.input + en.output + en.cacheWrite + en.cacheRead
            map[session] = s
        }
        return map.values.map { var s = $0; s.project = project(ofSession: s.id); return s }.sorted { $0.value > $1.value }
    }

    /// Tokens by weekday (0 = Sunday) and hour of day, local time.
    static func heat(profiles: [URL], since: Date) -> [[Int]] {
        var grid = [[Int]](repeating: [Int](repeating: 0, count: 24), count: 7)
        let cal = Calendar.current
        for (en, _) in everything(profiles: profiles, since: since) {
            let wd = cal.component(.weekday, from: en.date) - 1
            let h = cal.component(.hour, from: en.date)
            grid[wd][h] += en.input + en.output + en.cacheWrite + en.cacheRead
        }
        return grid
    }

    /// What the user typed in a session (the "role":"user" text lines, not tool results or
    /// system-inserted text), trimmed. Only used when the user has allowed transcripts to go to the manager.
    static func prompts(session id: String, limit: Int = 25, chars: Int = 400) -> [String] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        guard let file = dirs.map({ $0.appendingPathComponent("\(id).jsonl") }).first(where: { fm.fileExists(atPath: $0.path) }),
              let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return [] }
        var out: [String] = []
        let needle: StaticString = "\"role\":\"user\",\"content\":\""
        data.withUnsafeBytes { (all: UnsafeRawBufferPointer) in
            guard let base = all.baseAddress else { return }
            let n = all.count
            var start = 0
            while start < n && out.count < limit {
                guard let nl = memchr(base + start, 0x0A, n - start) else { break }
                let end = base.distance(to: UnsafeRawPointer(nl))
                let len = end - start
                if let i = find(base + start, len, needle) {
                    var j = i, text = [UInt8](), escaped = false
                    while j < len, text.count < chars * 2 {
                        let c = (base + start).load(fromByteOffset: j, as: UInt8.self)
                        if escaped {
                            switch c { case 0x6E: text.append(0x0A); case 0x74: text.append(0x20); case 0x75: j += 4; default: text.append(c) }
                            escaped = false
                        } else if c == 0x5C { escaped = true }
                        else if c == 0x22 { break }
                        else { text.append(c) }
                        j += 1
                    }
                    var s = String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty, !s.hasPrefix("<"), !s.hasPrefix("Caveat:"), !s.hasPrefix("[Request interrupted") {
                        if s.count > chars { s = String(s.prefix(chars)) + "…" }
                        out.append(s)
                    }
                }
                start = end + 1
            }
        }
        return out
    }

    static func daily(profile: URL, since: Date) -> [Date: TokenStats] {
        bucket(collect(profile: profile, since: since))
    }

    static func dailyOther(excluding profiles: [URL], since: Date) -> [Date: TokenStats] {
        bucket(collectOther(excluding: profiles.reduce(into: Set<String>()) { $0.formUnion(sessionIDs(profile: $1)) },
                            since: since))
    }

    private static func bucket(_ list: [(entry: Entry, session: String)]) -> [Date: TokenStats] {
        let cal = Calendar.current
        var days: [Date: TokenStats] = [:]
        var sessions: [Date: Set<String>] = [:]
        for (en, session) in list {
            let day = cal.startOfDay(for: en.date)
            add(en, to: &days[day, default: TokenStats()])
            sessions[day, default: []].insert(session)
        }
        for (day, set) in sessions { days[day]?.sessions = set.count }
        return days
    }

    /// Reads complete lines from `offset` on. Pulls out only the few fields needed with byte searches —
    /// far faster than decoding every (often huge) JSON line or parsing dates with a formatter.
    private static func parse(_ file: URL, from offset: UInt64) -> (entries: [Entry], end: UInt64) {
        // Memory-mapped, so a multi-hundred-MB transcript isn't copied into memory.
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped), UInt64(data.count) > offset else { return ([], offset) }
        var out: [Entry] = []
        var consumed = 0
        data.withUnsafeBytes { (all: UnsafeRawBufferPointer) in
            guard let start0 = all.baseAddress else { return }
            let base = start0 + Int(offset)
            let n = all.count - Int(offset)
            var start = 0
            while start < n {
                guard let nl = memchr(base + start, 0x0A, n - start) else { break }   // only whole lines
                let end = base.distance(to: UnsafeRawPointer(nl))
                if let e = entry(base + start, end - start) { out.append(e) }
                start = end + 1
                consumed = start
            }
        }
        return (out, offset + UInt64(consumed))
    }

    fileprivate static func find(_ p: UnsafeRawPointer, _ len: Int, _ needle: StaticString) -> Int? {
        guard let r = memmem(p, len, needle.utf8Start, needle.utf8CodeUnitCount) else { return nil }
        return p.distance(to: UnsafeRawPointer(r)) + needle.utf8CodeUnitCount
    }

    fileprivate static func string(_ p: UnsafeRawPointer, _ len: Int, after needle: StaticString) -> String? {
        guard let i = find(p, len, needle) else { return nil }
        var j = i
        while j < len && p.load(fromByteOffset: j, as: UInt8.self) != 0x22 { j += 1 }
        return String(decoding: UnsafeRawBufferPointer(start: p + i, count: j - i), as: UTF8.self)
    }

    fileprivate static func int(_ p: UnsafeRawPointer, _ len: Int, after needle: StaticString) -> Int {
        guard let i = find(p, len, needle) else { return 0 }
        var j = i, v = 0
        while j < len, case let c = p.load(fromByteOffset: j, as: UInt8.self), c >= 48 && c <= 57 { v = v * 10 + Int(c - 48); j += 1 }
        return v
    }

    /// "2026-10-09T16:53:52.283Z" → Date, without a formatter.
    fileprivate static func date(_ s: String) -> Date? {
        let b = Array(s.utf8)
        guard b.count >= 19 else { return nil }
        func num(_ from: Int, _ count: Int) -> Int { b[from..<from + count].reduce(0) { $0 * 10 + Int($1) - 48 } }
        var y = num(0, 4), m = num(5, 2)
        let d = num(8, 2), hh = num(11, 2), mm = num(14, 2), ss = num(17, 2)
        // days from civil (Howard Hinnant)
        y -= m <= 2 ? 1 : 0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        m = m > 2 ? m - 3 : m + 9
        let doy = (153 * m + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        return Date(timeIntervalSince1970: Double(days * 86_400 + hh * 3600 + mm * 60 + ss))
    }

    private static func entry(_ p: UnsafeRawPointer, _ len: Int) -> Entry? {
        // Assistant turns carry message.usage; tool results (user lines) can contain other "usage" keys.
        guard find(p, len, "\"type\":\"assistant\"") != nil, let u = find(p, len, "\"usage\":{") else { return nil }
        guard let model = string(p, len, after: "\"model\":\""), !model.hasPrefix("<"),
              let ts = string(p, len, after: "\"timestamp\":\""), let when = date(ts) else { return nil }
        let id = string(p, len, after: "\"id\":\"msg_") ?? string(p, len, after: "\"requestId\":\"") ?? UUID().uuidString
        // Top-level usage fields come first; later repeats are inside "iterations".
        let up = p + u, ul = len - u
        return Entry(id: id, date: when, model: model,
                     input: int(up, ul, after: "\"input_tokens\":"),
                     output: int(up, ul, after: "\"output_tokens\":"),
                     cacheWrite: int(up, ul, after: "\"cache_creation_input_tokens\":"),
                     cacheRead: int(up, ul, after: "\"cache_read_input_tokens\":"),
                     cacheWrite5m: int(up, ul, after: "\"ephemeral_5m_input_tokens\":"),
                     fast: find(up, ul, "\"speed\":\"fast\"") != nil)
    }
}

// MARK: - Reading an existing Claude login (so usage works without signing in twice)

enum CookieImporter {
    static let queue = DispatchQueue(label: "ai-orchestrator.cookies")
    private static var cachedKey: Data?
    private static var keyDenied = false

    /// Electron encrypts cookies with a key kept in the login keychain under "Claude Safe Storage".
    private static func aesKey() -> Data? {
        if let k = cachedKey { return k }
        if keyDenied { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Safe Storage",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let password = out as? Data, !password.isEmpty else { keyDenied = true; return nil }
        var key = [UInt8](repeating: 0, count: 16)
        let salt = Array("saltysalt".utf8)
        let rc = password.withUnsafeBytes { pw -> Int32 in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                 pw.baseAddress!.assumingMemoryBound(to: CChar.self), password.count,
                                 salt, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                 &key, key.count)
        }
        guard rc == Int32(kCCSuccess) else { return nil }
        cachedKey = Data(key)
        return cachedKey
    }

    private static func decrypt(_ enc: Data, key: Data, dbVersion: Int) -> String? {
        guard enc.count > 3, enc.prefix(3) == Data("v10".utf8) else { return nil }
        let body = Data(enc.dropFirst(3))
        let iv = [UInt8](repeating: 0x20, count: 16)
        var out = [UInt8](repeating: 0, count: body.count + kCCBlockSizeAES128)
        var outLen = 0
        let status = body.withUnsafeBytes { b in
            key.withUnsafeBytes { k in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128),
                        CCOptions(kCCOptionPKCS7Padding),
                        k.baseAddress, kCCKeySizeAES128, iv,
                        b.baseAddress, body.count, &out, out.count, &outLen)
            }
        }
        guard status == Int32(kCCSuccess) else { return nil }
        let bytes = Array(out.prefix(outLen))
        // Newer Chromium prepends a 32-byte hash of the domain to the value.
        func clean(_ b: [UInt8]) -> String? {
            guard let s = String(bytes: b, encoding: .utf8),
                  !s.isEmpty, s.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7f }) else { return nil }
            return s
        }
        if dbVersion >= 24, bytes.count > 32, let s = clean(Array(bytes.dropFirst(32))) { return s }
        if let s = clean(bytes) { return s }
        if bytes.count > 32 { return clean(Array(bytes.dropFirst(32))) }
        return nil
    }

    /// claude.ai cookies from a Claude profile folder. Runs off the main thread.
    static func cookies(profile: URL) -> [HTTPCookie] {
        let fm = FileManager.default
        let candidates = [profile.appendingPathComponent("Cookies"),
                          profile.appendingPathComponent("Network/Cookies")]
        for db in candidates where fm.fileExists(atPath: db.path) {
            guard let key = aesKey() else { return [] }
            let tmpDir = fm.temporaryDirectory.appendingPathComponent("ai-orchestrator-\(UUID().uuidString)")
            try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmpDir) }
            let copy = tmpDir.appendingPathComponent("Cookies")
            do { try fm.copyItem(at: db, to: copy) } catch { continue }
            for ext in ["-wal", "-journal"] {
                let side = URL(fileURLWithPath: db.path + ext)
                if fm.fileExists(atPath: side.path) {
                    try? fm.copyItem(at: side, to: URL(fileURLWithPath: copy.path + ext))
                }
            }

            var handle: OpaquePointer?
            guard sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
                sqlite3_close(handle); continue
            }
            defer { sqlite3_close(handle) }

            var version = 0
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(handle, "SELECT value FROM meta WHERE key='version'", -1, &stmt, nil) == SQLITE_OK,
               sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) {
                version = Int(String(cString: c)) ?? 0
            }
            sqlite3_finalize(stmt)
            stmt = nil

            let sql = """
            SELECT name, value, encrypted_value, host_key, path, expires_utc, is_secure
            FROM cookies WHERE host_key LIKE '%claude.ai'
            """
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(stmt) }

            var result: [HTTPCookie] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                func text(_ i: Int32) -> String {
                    guard let c = sqlite3_column_text(stmt, i) else { return "" }
                    return String(cString: c)
                }
                let name = text(0)
                var value = text(1)
                if value.isEmpty, let blob = sqlite3_column_blob(stmt, 2) {
                    let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 2)))
                    value = decrypt(data, key: key, dbVersion: version) ?? ""
                }
                guard !name.isEmpty, !value.isEmpty else { continue }
                var props: [HTTPCookiePropertyKey: Any] = [
                    .name: name, .value: value, .domain: text(3),
                    .path: text(4).isEmpty ? "/" : text(4),
                ]
                if sqlite3_column_int(stmt, 6) != 0 { props[.secure] = "TRUE" }
                let expires = sqlite3_column_int64(stmt, 5)
                if expires > 0 {
                    let date = Date(timeIntervalSince1970: Double(expires) / 1_000_000 - 11_644_473_600)
                    if date < Date() { continue }
                    props[.expires] = date
                }
                if let cookie = HTTPCookie(properties: props) { result.append(cookie) }
            }
            if result.contains(where: { $0.name == "sessionKey" }) { return result }
        }
        return []
    }
}

// MARK: - Usage fetching (one private web view per account)

final class UsageFetcher: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    let account: Account
    let webView: WKWebView
    var onUpdate: (UsageInfo) -> Void = { _ in }

    private var ready = false
    private var pending: [() -> Void] = []
    private var importedThisRun = false
    private var signInWindow: NSWindow?

    init(account: Account, storeID: UUID) {
        self.account = account
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeID)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 460, height: 680), configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func refresh() {
        if Demo.on { handle(Demo.claudeJSON(account.slug), allowRetry: false); return }
        if !importedThisRun {
            importedThisRun = true
            importCookies { [weak self] in self?.runFetch(allowRetry: true) }
        } else {
            runFetch(allowRetry: true)
        }
    }

    private func importCookies(_ done: @escaping () -> Void) {
        let profile = account.profileURL
        CookieImporter.queue.async {
            let cookies = CookieImporter.cookies(profile: profile)
            DispatchQueue.main.async {
                let store = self.webView.configuration.websiteDataStore.httpCookieStore
                let group = DispatchGroup()
                for c in cookies {
                    group.enter()
                    store.setCookie(c) { group.leave() }
                }
                group.notify(queue: .main, execute: done)
            }
        }
    }

    private func whenReady(_ f: @escaping () -> Void) {
        if ready { f(); return }
        pending.append(f)
        if !webView.isLoading {
            // A tiny same-origin page so fetch() carries the account's claude.ai cookies.
            webView.load(URLRequest(url: URL(string: "https://claude.ai/robots.txt")!))
        }
    }

    private static let script = """
    const get = async (p) => {
      const r = await fetch(p, { credentials: 'include', headers: { 'accept': 'application/json' } });
      let body = null;
      try { body = r.ok ? await r.json() : null; } catch (e) {}
      return { status: r.status, body };
    };
    const o = await get('/api/organizations');
    if (o.status === 401 || o.status === 403) return JSON.stringify({ status: 'signin' });
    if (!Array.isArray(o.body) || o.body.length === 0) return JSON.stringify({ status: 'error', message: 'HTTP ' + o.status });
    const has = (x, c) => Array.isArray(x.capabilities) && x.capabilities.includes(c);
    const org = o.body.find(x => has(x, 'claude_max')) || o.body.find(x => has(x, 'claude_pro')) || o.body.find(x => has(x, 'chat')) || o.body[0];
    const u = await get('/api/organizations/' + org.uuid + '/usage');
    let email = null;
    try { const a = await get('/api/account'); email = a.body && (a.body.email_address || a.body.email) || null; } catch (e) {}
    if (!u.body) return JSON.stringify({ status: (u.status === 401 || u.status === 403) ? 'signin' : 'error', message: 'HTTP ' + u.status });
    let prepaid = null;
    try { prepaid = (await get('/api/organizations/' + org.uuid + '/prepaid/credits')).body; } catch (e) {}
    const orgInfo = { rate_limit_tier: org.rate_limit_tier || null, billing_type: org.billing_type || null,
                      capabilities: Array.isArray(org.capabilities) ? org.capabilities : [] };
    // Subscription details (renewal date), if claude.ai answers this internal endpoint; null otherwise.
    let subscription = null;
    try { const s = await get('/api/organizations/' + org.uuid + '/subscription_details'); subscription = s.body; } catch (e) {}
    return JSON.stringify({ status: 'ok', usage: u.body, email, prepaid, org: orgInfo, subscription });
    """

    private func runFetch(allowRetry: Bool) {
        whenReady { [weak self] in
            guard let self else { return }
            self.webView.callAsyncJavaScript(Self.script, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value): self.handle(value as? String, allowRetry: allowRetry)
                case .failure:
                    self.onUpdate(UsageInfo(state: .error("Couldn't reach claude.ai")))
                    self.connectReadFailed("couldn't reach claude.ai")
                }
            }
        }
    }

    private func handle(_ json: String?, allowRetry: Bool) {
        guard let data = json?.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            onUpdate(UsageInfo(state: .error("Unexpected response"))); return
        }
        switch obj["status"] as? String {
        case "ok":
            let u = obj["usage"] as? [String: Any] ?? [:]
            var info = UsageInfo(state: .ok)
            info.session = Self.window(u["five_hour"])
            info.weekly = Self.window(u["seven_day"])
            info.email = obj["email"] as? String
            info.updated = Date()
            info.details = Self.details(u, prepaid: obj["prepaid"] as? [String: Any])
            let org = obj["org"] as? [String: Any] ?? [:]
            info.rateLimitTier = org["rate_limit_tier"] as? String
            info.billingType = org["billing_type"] as? String
            info.capabilities = org["capabilities"] as? [String] ?? []
            var sub = obj["subscription"] as? [String: Any]
            info.renews = sub.flatMap(Self.renewalDate)
            sub?["payment_method"] = nil     // card brand/last 4: not needed, not kept
            Self.saveRaw(["usage": u, "prepaid": obj["prepaid"] ?? NSNull(), "org": org, "subscription": sub ?? NSNull()], slug: account.slug)
            onUpdate(info)
            connectSucceeded(info.email)
            if info.renews == nil { scrapeRenewalIfDue() }
        case "signin":
            if connectMode { connectChecking = false; return }
            if allowRetry {
                importCookies { [weak self] in self?.runFetch(allowRetry: false) }
            } else {
                onUpdate(UsageInfo(state: .needsSignIn))
            }
        default:
            onUpdate(UsageInfo(state: .error(obj["message"] as? String ?? "Error")))
            connectReadFailed(obj["message"] as? String ?? "error")
        }
    }

    /// Last raw usage response, kept for debugging what claude.ai reports.
    static func saveRaw(_ obj: [String: Any], slug: String) {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.ai-orchestrator")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("usage-\(slug).json"))
        }
    }

    private static func details(_ u: [String: Any], prepaid: [String: Any]?) -> UsageDetails {
        var d = UsageDetails()
        func num(_ any: Any?) -> Double? { (any as? NSNumber)?.doubleValue }
        let limits = u["limits"] as? [[String: Any]] ?? []
        for l in limits {
            guard let pct = num(l["percent"]) else { continue }
            let kind = l["kind"] as? String ?? ""
            var name = kind == "session" ? "5-hour" : "Weekly"
            if let scope = l["scope"] as? [String: Any],
               let model = (scope["model"] as? [String: Any])?["display_name"] as? String {
                name += " · \(model)"
            }
            d.limits.append(LimitRow(id: "\(kind)-\(name)", name: name, percent: pct,
                                     resetsAt: parseDate(l["resets_at"] as? String)))
        }
        for s in u["weekly_scoped_shares"] as? [[String: Any]] ?? [] {
            guard let i = num(s["limit_index"]).map({ Int($0) }), limits.indices.contains(i),
                  let name = ((limits[i]["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String,
                  let used = num(s["used_percent_of_weekly"]), let allowed = num(s["allowance_percent_of_weekly"]) else { continue }
            d.weeklyShares.append((name, used, allowed))
        }
        for v in u.values {
            guard let c = v as? [String: Any], let limit = num(c["limit_dollars"]), let used = num(c["used_dollars"]) else { continue }
            d.spendCaps.append((used, limit, num(c["utilization"]), parseDate(c["resets_at"] as? String)))
        }
        if d.limits.isEmpty {
            if let w = window(u["five_hour"]) { d.limits.append(LimitRow(id: "5h", name: "5-hour", percent: w.percent, resetsAt: w.resetsAt)) }
            if let w = window(u["seven_day"]) { d.limits.append(LimitRow(id: "7d", name: "Weekly", percent: w.percent, resetsAt: w.resetsAt)) }
        }
        if let b = u["seven_day_breakdown"] as? [String: Any] {
            d.weekStart = parseDate(b["window_started_at"] as? String)
            for r in b["rows"] as? [[String: Any]] ?? [] {
                if let p = num(r["percent"]), p > 0, let n = r["display_name"] as? String { d.surfaces.append((n, p)) }
            }
        }
        if let e = u["extra_usage"] as? [String: Any] {
            let scale = pow(10, num(e["decimal_places"]) ?? 2)
            d.extraEnabled = e["is_enabled"] as? Bool ?? false
            d.extraReached = e["spend_limit_reached"] as? Bool ?? false
            d.extraUsed = num(e["used_credits"]).map { $0 / scale }
            d.extraLimit = num(e["monthly_limit"]).map { $0 / scale }
            d.extraPercent = num(e["utilization"])
            if e["disabled_reason"] as? String == "out_of_credits" { d.extraNote = "out of credits" }
            d.currency = e["currency"] as? String ?? "USD"
        }
        if let p = prepaid {
            if let ar = p["auto_reload_settings"] as? [String: Any] {
                d.autoReload = ar["enabled"] as? Bool ?? false
                d.autoReloadTo = num(ar["reload_to_in_minor_units"]).map { $0 / 100 }
                d.autoReloadBelow = num(ar["threshold_in_minor_units"]).map { $0 / 100 }
            }
            else if p["auto_reload_settings"] is NSNull { d.autoReload = false }   // never set up
            let tranches = p["tranches"] as? [[String: Any]] ?? []
            for t in tranches {
                guard let id = t["id"] as? String, let when = parseDate(t["granted_at"] as? String),
                      let amt = num(t["granted_amount_minor_units"]) else { continue }
                d.grants.append((id, when, amt / 100, (t["program_id"] as? String ?? "").contains("auto")))
            }
            if !tranches.isEmpty {
                d.prepaid = tranches.compactMap { num($0["remaining_amount_minor_units"]) }.reduce(0, +) / 100
            } else if let amount = num(p["amount"]) {
                d.prepaid = amount / 100
            }
        }
        return d
    }

    private static func window(_ any: Any?) -> UsageWindow? {
        guard let d = any as? [String: Any] else { return nil }
        let pct = (d["utilization"] as? NSNumber)?.doubleValue ?? (d["utilization"] as? String).flatMap(Double.init)
        guard let p = pct else { return nil }
        return UsageWindow(percent: p, resetsAt: parseDate(d["resets_at"] as? String))
    }

    private static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        // e.g. 2026-10-14T22:20:00.523434+00:00 — drop the fraction and retry
        let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return f.date(from: trimmed)
    }

    // Manual sign-in fallback, only needed if reading the app's login didn't work.
    func showSignIn() {
        connectMode = true
        connectDone = false
        connectChecking = false
        connectFailures = 0
        showPage(URL(string: "https://claude.ai/login")!, title: "Connect usage — \(account.name)")
        setConnectStatus("Loading claude.ai…", busy: true)
        connectTimer?.invalidate()
        connectTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.checkConnected() }
    }

    // The Connect window says what it's doing, notices the sign-in by itself, confirms it and closes.
    private var connectMode = false
    private var connectDone = false
    private var connectChecking = false
    private var connectFailures = 0
    private var connectTimer: Timer?
    private let connectLabel = NSTextField(labelWithString: "")
    private let connectSpinner = NSProgressIndicator()
    private lazy var connectBox: NSView = {
        let stripHeight: CGFloat = 36
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 680))
        let strip = NSView(frame: NSRect(x: 0, y: 680 - stripHeight, width: 460, height: stripHeight))
        strip.autoresizingMask = [.width, .minYMargin]
        connectSpinner.style = .spinning
        connectSpinner.controlSize = .small
        connectSpinner.isDisplayedWhenStopped = false
        connectSpinner.frame = NSRect(x: 12, y: 10, width: 16, height: 16)
        connectLabel.frame = NSRect(x: 36, y: 9, width: 412, height: 18)
        connectLabel.autoresizingMask = [.width]
        connectLabel.font = .systemFont(ofSize: 12, weight: .medium)
        connectLabel.lineBreakMode = .byTruncatingTail
        strip.addSubview(connectSpinner)
        strip.addSubview(connectLabel)
        box.addSubview(strip)
        return box
    }()

    private func setConnectStatus(_ text: String, busy: Bool) {
        connectLabel.stringValue = text
        if busy { connectSpinner.startAnimation(nil) } else { connectSpinner.stopAnimation(nil) }
    }

    private func installContent(_ w: NSWindow) {
        if connectMode {
            guard webView.superview !== connectBox else { return }
            webView.removeFromSuperview()
            connectBox.frame = NSRect(origin: .zero, size: w.contentRect(forFrameRect: w.frame).size)
            webView.frame = NSRect(x: 0, y: 0, width: connectBox.bounds.width, height: connectBox.bounds.height - 36)
            webView.autoresizingMask = [.width, .height]
            connectBox.addSubview(webView)
            w.contentView = connectBox
        } else if w.contentView !== webView {
            webView.removeFromSuperview()
            w.contentView = webView
        }
    }

    /// Asks claude.ai whether this view is signed in yet. 401/403 means not yet; any page error just waits for the next tick.
    private func checkConnected() {
        guard connectMode, !connectDone, !connectChecking else { return }
        guard webView.url?.host?.lowercased().hasSuffix("claude.ai") == true else {
            setConnectStatus("Finish signing in below.", busy: webView.isLoading)
            return
        }
        connectChecking = true
        let js = "const r = await fetch('/api/organizations', { credentials: 'include', headers: { 'accept': 'application/json' } }); return r.status;"
        webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self, self.connectMode, !self.connectDone else { return }
            if case .success(let v) = result, (v as? NSNumber)?.intValue == 200 {
                self.setConnectStatus("Signed in. Reading your usage…", busy: true)
                self.runFetch(allowRetry: false)
            } else {
                self.connectChecking = false
                self.setConnectStatus(self.webView.isLoading ? "Loading claude.ai…"
                                      : "Sign in below. This window closes by itself once you're connected.", busy: self.webView.isLoading)
            }
        }
    }

    private func connectSucceeded(_ email: String?) {
        guard connectMode, !connectDone else { return }
        connectDone = true
        connectTimer?.invalidate(); connectTimer = nil
        setConnectStatus("✓ Connected\(email.map { " as \($0)" } ?? "").", busy: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.connectDone else { return }
            self.signInWindow?.close()
        }
    }

    /// Signed in but the usage read failed: try again on the next ticks, then say so plainly.
    private func connectReadFailed(_ why: String) {
        guard connectMode, !connectDone else { return }
        connectFailures += 1
        connectChecking = false
        if connectFailures >= 3 {
            connectTimer?.invalidate(); connectTimer = nil
            setConnectStatus("Signed in, but usage didn't load (\(why)). Close this window to try again.", busy: false)
        }
    }

    /// Billing pages open here, in this account's own signed-in web view, so they're for the right account.
    /// Only claude.ai, anthropic.com and Stripe's billing pages load inside; any other link opens in the browser.
    /// Burn Rate never clicks anything on these pages: upgrades, funds and cancels are the user's own clicks.
    func showBilling(_ url: URL, title: String) {
        if signInWindow == nil {
            importCookies { [weak self] in self?.showPage(url, title: title, billing: true) }
        } else {
            showPage(url, title: title, billing: true)
        }
    }

    private var billingMode = false
    private var scraping = false
    var onRenewal: (Date) -> Void = { _ in }

    /// The next charge from claude.ai's subscription details: the exact timestamp (`next_charge_at`) first,
    /// then a plain date, then period-end style fields.
    static func renewalDate(_ obj: [String: Any]) -> Date? {
        for key in ["next_charge_at", "next_charge_date", "next_billing_date", "current_period_end", "renews_at", "renewal_date"] {
            if let str = obj[key] as? String, let d = parseDate(str) ?? parseDay(str) { return d }
            if let n = obj[key] as? NSNumber, n.doubleValue > 1_600_000_000 { return Date(timeIntervalSince1970: n.doubleValue) }
        }
        for v in obj.values { if let d = v as? [String: Any], let x = renewalDate(d) { return x } }
        return nil
    }

    private static func parseDay(_ s: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(s.prefix(10)))
    }

    /// "Your subscription will auto renew on Oct 27, 2026." on claude.ai › Settings › Billing.
    static func renewal(inPageText t: String) -> Date? {
        guard let r = t.range(of: #"renew(s|al)?( date)?( on|:)? ([A-Z][a-z]{2,8}\.? \d{1,2}, \d{4})"#, options: .regularExpression) else { return nil }
        let m = String(t[r])
        guard let d = m.range(of: #"[A-Z][a-z]{2,8}\.? \d{1,2}, \d{4}"#, options: .regularExpression) else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        let s = String(m[d]).replacingOccurrences(of: ".", with: "")
        for fmt in ["MMM d, yyyy", "MMMM d, yyyy"] { f.dateFormat = fmt; if let x = f.date(from: s) { return x } }
        return nil
    }

    private func readRenewalFromPage(_ done: @escaping () -> Void = {}) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self else { return }
            self.webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { v, _ in
                if let t = v as? String, let d = Self.renewal(inPageText: t) {
                    UserDefaults.standard.set(Date(), forKey: "renewScraped.\(self.account.slug)")
                    self.onRenewal(d)
                }
                done()
            }
        }
    }

    /// Reads the Billing page in the hidden view at most twice a day, only when no other source gave a date.
    private func scrapeRenewalIfDue() {
        let key = "renewScraped.\(account.slug)", tried = "renewTried.\(account.slug)"
        let last = max(UserDefaults.standard.object(forKey: key) as? Date ?? .distantPast,
                       UserDefaults.standard.object(forKey: tried) as? Date ?? .distantPast)
        guard !scraping, signInWindow == nil, Date().timeIntervalSince(last) > 12 * 3600 else { return }
        UserDefaults.standard.set(Date(), forKey: tried)
        scraping = true
        ready = false
        webView.load(URLRequest(url: URL(string: "https://claude.ai/settings/billing")!))
    }

    private func showPage(_ url: URL, title: String, billing: Bool = false) {
        billingMode = billing
        if billing { connectMode = false; connectTimer?.invalidate(); connectTimer = nil }
        if let w = signInWindow {
            w.title = title
            installContent(w)
            ready = false
            webView.load(URLRequest(url: url))
            w.makeKeyAndOrderFront(nil); NSApp.activate(); return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: billing ? 980 : 460, height: billing ? 760 : 680),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        installContent(w)
        w.delegate = self
        w.center()
        signInWindow = w
        ready = false
        webView.load(URLRequest(url: url))
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    static func allowedInBilling(_ host: String) -> Bool {
        ["claude.ai", "anthropic.com", "stripe.com", "stripe.network"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if billingMode, navigationAction.targetFrame?.isMainFrame != false,
           let url = navigationAction.request.url, let host = url.host?.lowercased(),
           url.scheme == "https" || url.scheme == "http", !Self.allowedInBilling(host) {
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func windowWillClose(_ notification: Notification) {
        connectTimer?.invalidate(); connectTimer = nil
        connectMode = false
        connectDone = false
        webView.removeFromSuperview()
        signInWindow?.contentView = nil
        signInWindow = nil
        billingMode = false
        ready = false
        webView.load(URLRequest(url: URL(string: "https://claude.ai/robots.txt")!))
        runFetch(allowRetry: false)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if billingMode, webView.url?.path.contains("billing") == true { readRenewalFromPage() }
        if scraping, signInWindow == nil {
            readRenewalFromPage { [weak self] in
                guard let self, self.signInWindow == nil else { return }
                self.scraping = false
                self.webView.load(URLRequest(url: URL(string: "https://claude.ai/robots.txt")!))
            }
            if webView.url?.path.contains("billing") == true { return }
        }
        ready = true
        let work = pending
        pending = []
        work.forEach { $0() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failPending() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failPending() }

    private func failPending() {
        guard !pending.isEmpty else { return }
        pending = []
        onUpdate(UsageInfo(state: .error("Offline")))
    }

    // Keep sign-in popups (e.g. Google) inside the same view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        webView.load(navigationAction.request)
        return nil
    }
}

// MARK: - Account store

final class AccountStore: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var usage: [String: UsageInfo] = [:]
    @Published var running: Set<String> = []
    @Published var active: String?
    @Published var hovering = false {
        didSet { if hovering && !oldValue { lookedAt() } }
    }
    /// Claude accounts whose usage fetch is still out (for the menu-bar "Refreshing" state).
    @Published var fetching: Set<String> = []
    var fetchStarted = Date.distantPast
    @Published var tokens: [String: TokenStats] = [:]
    @Published var growsRight = false
    @Published var others: [OtherAccount] = []
    @Published var otherRunning: Set<String> = []
    @Published var codexUsage: [String: CodexUsage] = [:]
    @Published var codexChecked = false
    @Published var cursorUsage: [String: CursorUsage] = [:]
    /// Why a Codex or Cursor account has no usage right now (shown on its tile and row), by account id.
    @Published var otherProblem: [String: String] = [:]
    /// The newest Codex reading already saved to history, per account.
    var codexRecorded: [String: Date] = [:]
    @Published var mainLogins: [OtherApp: MainLogin] = [:]
    private var tokensUpdated = Date.distantPast

    let claudeBundleID: String
    private var fetchers: [String: UsageFetcher] = [:]
    private var timers: [Timer] = []
    private let defaults = UserDefaults.standard

    init() {
        claudeBundleID = Bundle(url: Paths.claudeApp)?.bundleIdentifier ?? "com.anthropic.claudefordesktop"
        reload()
        reloadOthers()
        refreshRunning()
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == claudeBundleID {
            active = slug(forPID: front.processIdentifier)
        }
        timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshRunning() })
        timers.append(Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refreshUsage() })
        // Notes filed on the iPhone (bin/phone-feed /inbox): expenses, plan changes and ideas.
        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in PhoneInbox.importNew() })
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { PhoneInbox.importNew() }
        // The manager's daily brief, when it's turned on. Checked every 10 minutes; runs once a day after the chosen hour.
        timers.append(Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            guard let self else { return }
            Manager.shared.tick(store: self)
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in if let self { Manager.shared.tick(store: self) } }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == self.claudeBundleID,
                  let s = self.slug(forPID: app.processIdentifier) else { return }
            if self.active != s { self.active = s; self.writeStatus() }   // the phone marks the instance in use
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refreshUsage() }
        Notify.ask()
        Notify.delegate.onSwitch = { [weak self] id in
            guard let self, let t = self.targets.first(where: { $0.id == id }) else { return }
            self.open(t)
        }
    }

    var current: Account {
        accounts.first { $0.slug == active }
            ?? accounts.first { running.contains($0.slug) }
            ?? accounts[0]
    }

    // Accounts = Claude's normal profile + every "Claude-<name>" profile folder.
    func reload() {
        let hidden = Set(defaults.stringArray(forKey: "hidden") ?? [])
        var list = [Account(slug: "main", name: displayName("main", fallback: "Main"), profileURL: Paths.mainProfile)]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: Paths.appSupport, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey])) ?? []
        let profiles = items.filter {
            $0.lastPathComponent.hasPrefix("Claude-")
                && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a < b
        }
        for url in profiles {
            let slug = String(url.lastPathComponent.dropFirst("Claude-".count))
            guard !slug.isEmpty, !hidden.contains(slug) else { continue }
            list.append(Account(slug: slug, name: displayName(slug, fallback: prettify(slug)), profileURL: url))
        }
        accounts = list
        for a in list where fetchers[a.slug] == nil {
            let f = UsageFetcher(account: a, storeID: storeID(a.slug))
            f.onUpdate = { [weak self] info in self?.apply(info, to: a.slug) }
            f.onRenewal = { [weak self] date in
                guard let self else { return }
                PlanStore.shared.noteRenewal("claude:\(a.slug)", date, store: self)
            }
            fetchers[a.slug] = f
        }
    }

    private func displayName(_ slug: String, fallback: String) -> String {
        defaults.string(forKey: "name.\(slug)") ?? fallback
    }

    private func storeID(_ slug: String) -> UUID {
        if let s = defaults.string(forKey: "store.\(slug)"), let id = UUID(uuidString: s) { return id }
        let id = UUID()
        defaults.set(id.uuidString, forKey: "store.\(slug)")
        return id
    }

    private func apply(_ info: UsageInfo, to slug: String) {
        var merged = info
        if info.state != .ok, let old = usage[slug] {   // keep last known numbers on hiccups
            merged.session = old.session
            merged.weekly = old.weekly
            merged.email = old.email
            merged.updated = old.updated
            merged.details = old.details
            merged.rateLimitTier = old.rateLimitTier
            merged.billingType = old.billingType
            merged.capabilities = old.capabilities
            merged.renews = old.renews
        }
        usage[slug] = merged
        if info.state != .loading, fetching.contains(slug) { fetching.remove(slug) }
        if info.state == .ok { checkGuard() }
        if info.state == .ok, let a = accounts.first(where: { $0.slug == slug }) {
            PurchaseLog.note(info.details?.grants ?? [], account: a.name)
            var limits: [String: Double] = [:]
            info.details?.limits.forEach { limits[$0.name] = $0.percent }
            History.record(UsageSnapshot(t: Date(), provider: "claude", account: slug, name: a.name,
                                         session: info.session?.percent, weekly: info.weekly?.percent,
                                         limits: limits, extraUsed: info.details?.extraUsed,
                                         extraLimit: info.details?.extraLimit, currency: info.details?.currency))
        }
    }

    func refreshUsage() {
        fetching = Set(accounts.map(\.slug))
        fetchStarted = Date()
        fetchers.values.forEach { $0.refresh() }
        refreshTokens(force: true)
        reloadOthers()
        refreshCodex(force: true)
        refreshCursor()
    }

    /// Recount Claude Code tokens for the current weekly window (off the main thread, cached per file).
    func refreshTokens(force: Bool = false) {
        guard force || Date().timeIntervalSince(tokensUpdated) > 60 else { return }
        tokensUpdated = Date()
        let list = accounts
        let starts = usage.mapValues { $0.details?.weekStart }
        let codex = others.filter { $0.app == .codex }.map { (home: $0.codexHome, name: "Codex \($0.name)") }
        TokenCounter.queue.async {
            var out: [String: TokenStats] = [:]
            for a in list {
                let since = (starts[a.slug] ?? nil) ?? Date().addingTimeInterval(-7 * 86_400)
                out[a.slug] = TokenCounter.stats(profile: a.profileURL, since: since)
            }
            DispatchQueue.main.async { self.tokens = out }
            _ = TokenHistory.snapshot(accounts: list)   // keep daily totals past transcript cleanup
            DailyUsage.shared.update(codex: codex)
            TokenCounter.saveCache()
        }
    }
    func refreshUsage(_ a: Account) { fetchers[a.slug]?.refresh() }
    /// Someone is looking (strip hovered or panel opened): recount tokens and re-read Codex and Cursor.
    func lookedAt() { refreshTokens(); reloadOthers(); refreshCodex(); refreshCursor() }
    /// The newest Claude reading is over 6 hours old (the Codex rule, now for every provider).
    func isStale(_ a: Account) -> Bool {
        guard let u = usage[a.slug], u.session != nil || u.weekly != nil, let t = u.updated else { return false }
        return Date().timeIntervalSince(t) > 6 * 3600
    }
    func connectUsage(_ a: Account) { fetchers[a.slug]?.showSignIn() }
    func openBilling(_ a: Account, _ url: URL, title: String) { fetchers[a.slug]?.showBilling(url, title: "\(title) — \(a.name)") }

    // MARK: Running instances

    func slug(forPID pid: pid_t) -> String? {
        let args = processArguments(pid)
        var dir: String?
        for (i, arg) in args.enumerated() {
            if arg.hasPrefix("--user-data-dir=") {
                dir = String(arg.dropFirst("--user-data-dir=".count))
            } else if arg == "--user-data-dir", i + 1 < args.count {
                dir = args[i + 1]
            }
        }
        guard var path = dir else { return "main" }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let std = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        if let a = accounts.first(where: { $0.profileURL.standardizedFileURL.path == std.path }) { return a.slug }
        let last = std.lastPathComponent
        return last.hasPrefix("Claude-") ? String(last.dropFirst("Claude-".count)) : nil
    }

    private func instance(of a: Account) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == claudeBundleID && !$0.isTerminated && slug(forPID: $0.processIdentifier) == a.slug
        }
    }

    func refreshRunning() {
        var now = Set<String>()
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == claudeBundleID {
            if let s = slug(forPID: app.processIdentifier) { now.insert(s) }
        }
        if now != running { running = now }
        refreshOtherRunning()
    }

    // MARK: Switching

    func switchTo(_ a: Account) {
        active = a.slug
        guard let app = instance(of: a) else { launch(a); return }
        bringForward(app)
    }

    func bringForward(_ app: NSRunningApplication) {
        NSApp.yieldActivation(to: app)
        if app.isHidden { app.unhide() }
        _ = app.activate(from: NSRunningApplication.current, options: [.activateAllWindows])
        // "Reopen" makes Claude show a window again if you'd closed it.
        let target = NSAppleEventDescriptor(processIdentifier: app.processIdentifier)
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
                                           eventID: AEEventID(kAEReopenApplication),
                                           targetDescriptor: target,
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        _ = try? event.sendEvent(options: [.noReply], timeout: 2)
    }

    func launch(_ a: Account) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = true
        if !a.isMain {
            try? FileManager.default.createDirectory(at: a.profileURL, withIntermediateDirectories: true)
            config.arguments = ["--user-data-dir=\(a.profileURL.path)"]
        }
        NSWorkspace.shared.openApplication(at: Paths.claudeApp, configuration: config) { _, error in
            guard let error else { return }
            DispatchQueue.main.async { showAlert("Couldn't open Claude", error.localizedDescription) }
        }
    }

    // MARK: Managing accounts

    func askName(title: String, info: String, initial: String = "", appURL: URL? = nil, button: String? = nil) -> String? {
        askForName(title: title, info: info, initial: initial, button: button ?? "Rename", appURL: appURL)
    }

    /// Next free default name like "Cursor 2", so adding an account is one click.
    func suggestedName(_ base: String, taken: [String]) -> String {
        var n = taken.count + 1
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    private func askForName(title: String, info: String, initial: String = "", button: String,
                            appURL: URL? = nil) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        if let appURL { alert.icon = NSWorkspace.shared.icon(forFile: appURL.path) }   // the app being added, not Claude
        let label = NSTextField(labelWithString: "Account name (how it shows in the widget)")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 0, y: 28, width: 260, height: 16)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        field.placeholderString = "e.g. Work or Personal"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 46))
        box.addSubview(label)
        box.addSubview(field)
        alert.accessoryView = box
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    func addAccount() {
        guard let name = askForName(
            title: "Add a Claude account",
            info: "Opens a fresh Claude window where you sign in with your other account. Your MCP and tool settings from Main come along.",
            initial: suggestedName("Claude", taken: accounts.map(\.name)),
            button: "Open Claude to sign in", appURL: Paths.claudeApp) else { return }
        var base = slugify(name)
        if base.isEmpty || base == "main" { base = "account" }
        var slug = base
        var n = 2
        while FileManager.default.fileExists(atPath: Paths.profile(slug: slug).path) {
            slug = "\(base)-\(n)"; n += 1
        }
        let url = Paths.profile(slug: slug)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defaults.set(name, forKey: "name.\(slug)")
        copySharedConfig(to: url, overwrite: false)
        reload()
        if let a = accounts.first(where: { $0.slug == slug }) { switchTo(a) }
    }

    func rename(_ a: Account) {
        guard let name = askForName(title: "Rename account", info: "", initial: a.name, button: "Rename", appURL: Paths.claudeApp) else { return }
        defaults.set(name, forKey: "name.\(a.slug)")
        reload()
    }

    func hide(_ a: Account) {
        var hidden = defaults.stringArray(forKey: "hidden") ?? []
        hidden.append(a.slug)
        defaults.set(hidden, forKey: "hidden")
        reload()
    }

    var hasHidden: Bool { !(defaults.stringArray(forKey: "hidden") ?? []).isEmpty }

    func unhideAll() {
        defaults.removeObject(forKey: "hidden")
        reload()
        reloadOthers()
        refreshUsage()
    }

    func reveal(_ a: Account) {
        NSWorkspace.shared.activateFileViewerSelecting([a.profileURL])
    }

    /// MCP servers & local tool settings live in claude_desktop_config.json inside each profile.
    func copySharedConfig(to profile: URL, overwrite: Bool) {
        let src = Paths.mainProfile.appendingPathComponent(Paths.configName)
        let dst = profile.appendingPathComponent(Paths.configName)
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else { return }
        if fm.fileExists(atPath: dst.path) {
            guard overwrite else { return }
            try? fm.removeItem(at: dst)
        }
        try? fm.copyItem(at: src, to: dst)
    }

    func syncSettingsFromMain(_ a: Account) {
        let alert = NSAlert()
        alert.messageText = "Copy settings from Main to \(a.name)?"
        alert.informativeText = "Replaces this account's MCP servers and local tool settings with Main's. Restart that Claude window afterwards."
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        copySharedConfig(to: a.profileURL, overwrite: true)
    }

    var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func toggleOpenAtLogin() {
        do {
            if opensAtLogin { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            showAlert("Couldn't change Open at Login", error.localizedDescription)
        }
        objectWillChange.send()
    }

    // MARK: Tooltip text

    func tooltip(for a: Account) -> String {
        var lines: [String] = []
        let u = usage[a.slug]
        if let e = u?.email { lines.append(e) }
        let time = DateFormatter()
        time.dateFormat = "EEE h:mm a"
        if let s = u?.session {
            lines.append("5-hour session: \(Int(s.percent.rounded()))%" + (s.resetsAt.map { " · resets \(time.string(from: $0))" } ?? ""))
        }
        if let w = u?.weekly {
            lines.append("Weekly: \(Int(w.percent.rounded()))%" + (w.resetsAt.map { " · resets \(time.string(from: $0))" } ?? ""))
        }
        if let d = u?.updated {
            let rel = RelativeDateTimeFormatter()
            lines.append("Updated \(rel.localizedString(for: d, relativeTo: Date()))")
        }
        lines.append(running.contains(a.slug) ? "Open — click to switch" : "Not open — click to launch")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Views

extension Color {
    /// Opaque so text stays high-contrast over anything; white in Light mode, near-black in Dark.
    static var widgetBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark ? NSColor(white: 0.09, alpha: 1) : NSColor(white: 1, alpha: 1)
        })
    }
}

/// A grip you can drag to move the widget.
struct DragHandle: NSViewRepresentable {
    /// Set by the app: starts a morphing drag from the grip's screen centre. Returns false to fall back to a plain window drag.
    static var onBegin: ((NSPoint) -> Bool)?
    final class HandleView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            // The desktop strip hands the drag to StripMorpher, which reshapes the strip around this grip.
            if let w = window, let begin = DragHandle.onBegin {
                let r = w.convertToScreen(convert(bounds, to: nil))
                if begin(NSPoint(x: r.midX, y: r.midY)) { return }
            }
            window?.performDrag(with: event)
        }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        private var hovering = false
        override func updateTrackingAreas() {
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                           owner: self, userInfo: nil))
        }
        override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
        override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
        override func draw(_ dirtyRect: NSRect) {
            if hovering {
                NSColor.labelColor.withAlphaComponent(0.08).setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
            }
            // Clean white on dark surfaces; a solid dark grey in Light mode, so the grip stays legible.
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            (dark ? NSColor(white: 1, alpha: 0.88) : NSColor(white: 0, alpha: 0.62)).setFill()
            // 2 × 3 grip dots, centred
            let dot: CGFloat = 2.5, gap: CGFloat = 4
            let ox = bounds.midX - (dot + gap) / 2
            let oy = bounds.midY - (dot + 2 * gap) / 2
            for row in 0..<3 {
                for col in 0..<2 {
                    NSBezierPath(ovalIn: NSRect(x: ox + CGFloat(col) * gap, y: oy + CGFloat(row) * gap,
                                                width: dot, height: dot)).fill()
                }
            }
        }
    }
    func makeNSView(context: Context) -> HandleView { HandleView() }
    func updateNSView(_ nsView: HandleView, context: Context) {}
}

struct StatusDot: View {
    let running: Bool
    var body: some View {
        Circle()
            .fill(running ? Theme.ok : Color.secondary.opacity(0.35))
            .frame(width: 5, height: 5)
    }
}

struct MiniMeter: View {
    let label: String
    let value: Double?
    /// A reading older than 6 hours (any provider): hatched and dimmed so it doesn't read as live.
    var stale = false
    @Environment(\.tileMetrics) private var m
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var barWidth: CGFloat { 14 * m.scale }
    private var fraction: CGFloat { CGFloat(min(max((value ?? 0) / 100, 0), 1)) }
    private var color: Color {
        guard let v = value else { return .clear }
        return stale ? Color.secondary : meterColor(v)
    }

    var body: some View {
        HStack(spacing: 2 * m.font) {
            Text(label)
                .font(.system(size: 7.5 * m.font, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 10 * m.font, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.18))
                if stale, (value ?? 0) > 0 {
                    Hatch().fill(Color.secondary).frame(width: max(2, barWidth * fraction)).clipShape(Capsule())
                } else {
                    Capsule().fill(color).frame(width: (value ?? 0) <= 0 ? 0 : max(2, barWidth * fraction))
                }
            }
            .frame(width: barWidth, height: 3 * m.font)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: value)
            Text(value.map { "\(Int($0.rounded()))%" } ?? "–")
                .font(.system(size: 8.5 * m.font, weight: stale ? .semibold : Theme.valueWeight(value)).monospacedDigit())
                .foregroundStyle(stale ? .secondary : .primary)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 27 * m.font, alignment: .trailing)
        }
        .opacity(stale ? 0.45 : 1)
    }
}

/// Diagonal hatching for stale bars.
struct Hatch: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        var x = r.minX - r.height
        while x < r.maxX {
            p.addRect(CGRect(x: x, y: r.minY, width: 1, height: r.height).applying(.init(a: 1, b: 0, c: -1, d: 1, tx: r.height, ty: 0)))
            x += 2.5
        }
        return p
    }
}

/// Sizes for the one tile component: 1× on the desktop strip, larger in the menu-bar panel.
struct TileMetrics {
    var scale: CGFloat = 1        // widths
    var font: CGFloat = 1         // type and heights
    var gap: CGFloat = 1
    /// The panel gives the strip a fixed width; the desktop strip shows four tiles and scrolls.
    var maxWidth: CGFloat?
    /// Panel tiles sit on fill.platter with a 12 pt radius.
    var platter = false
    var radius: CGFloat { platter ? 12 : 6 }
    /// Tiles have a fixed frame: hover and keyboard focus change the fill only, never layout.
    static let height: CGFloat = 34
    static let panel = TileMetrics(scale: 1.8, font: 1.42, gap: 4, maxWidth: 516, platter: true)
}

private struct TileMetricsKey: EnvironmentKey { static let defaultValue = TileMetrics() }
private struct TileHoverKey: EnvironmentKey { static let defaultValue: (String, Bool) -> Void = { _, _ in } }
private struct TileTappedKey: EnvironmentKey { static let defaultValue: () -> Void = {} }
private struct TileFocusKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues {
    var tileMetrics: TileMetrics { get { self[TileMetricsKey.self] } set { self[TileMetricsKey.self] = newValue } }
    /// Tells the panel or strip which tile the pointer is over (account id, inside?).
    var tileHover: (String, Bool) -> Void { get { self[TileHoverKey.self] } set { self[TileHoverKey.self] = newValue } }
    /// Called after a tile switches account (the panel closes).
    var tileTapped: () -> Void { get { self[TileTappedKey.self] } set { self[TileTappedKey.self] = newValue } }
    /// The tile chosen with the arrow keys in the panel.
    var tileFocus: String? { get { self[TileFocusKey.self] } set { self[TileFocusKey.self] = newValue } }
}

/// The 5-hour and weekly meters, stacked. Keeps a fixed height so tiles never jump.
struct TileUsage: View {
    @ObservedObject var store: AccountStore
    let account: Account

    @Environment(\.tileMetrics) private var m
    private var usage: UsageInfo? { store.usage[account.slug] }
    static let reset: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE ha"; f.amSymbol = "am"; f.pmSymbol = "pm"; return f }()

    var body: some View {
        Group {
            if usage?.state == .needsSignIn {
                Button("Connect usage") { store.connectUsage(account) }
                    .buttonStyle(.link)
                    .font(.system(size: 9 * m.font))
            } else if let u = usage, u.session == nil, u.weekly == nil, case .error(let msg) = u.state {
                Text(msg)
                    .font(.system(size: 9 * m.font))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                let stale = store.isStale(account)
                VStack(alignment: .leading, spacing: 0) {
                    // claude.ai reports no 5-hour window for this account (five_hour is null, e.g. Max 20x since Nov):
                    // drop that row and show when the weekly limit resets instead.
                    if let u = usage, u.state == .ok, u.session == nil, let w = u.weekly {
                        MiniMeter(label: "7d", value: w.percent, stale: stale)
                        Text(w.resetsAt.map { "↻ " + Self.reset.string(from: $0) } ?? "no 5h limit")
                            .font(.system(size: 7.5 * m.font, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        MiniMeter(label: "5h", value: usage?.session?.percent, stale: stale)
                        MiniMeter(label: "7d", value: usage?.weekly?.percent, stale: stale)
                    }
                }
            }
        }
        .frame(height: 19 * m.font, alignment: .leading)
    }
}

/// One account. A single click switches to it (or opens it if it isn't running).
struct AccountTile: View {
    @ObservedObject var store: AccountStore
    let account: Account
    @State private var hovering = false
    /// The fuller of the 5-hour and weekly limits, which is the one that stops you.
    private var worstUsed: Double? {
        let u = store.usage[account.slug]
        let v = [u?.session?.percent, u?.weekly?.percent].compactMap { $0 }
        return v.max()
    }
    @Environment(\.tileMetrics) private var m
    @Environment(\.tileHover) private var tileHover
    @Environment(\.tileTapped) private var tileTapped
    @Environment(\.tileFocus) private var tileFocus

    var body: some View {
        let isActive = store.current.slug == account.slug
        let isRunning = store.running.contains(account.slug)
        let lit = hovering || tileFocus == "claude:\(account.slug)"
        // The Claude instance in use: the running one that was frontmost last.
        let inUse = isRunning && store.active == account.slug
        VStack(alignment: .leading, spacing: 1 * m.font) {
            HStack(spacing: 3 * m.font) {
                StatusDot(running: isRunning)
                AppIcon(url: Paths.claudeApp, size: 9 * m.font)
                Text(account.name)
                    .font(.system(size: 8.5 * m.font, weight: isActive ? .bold : .semibold))
                    .foregroundStyle(isRunning || isActive ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                let target = store.targets.first { $0.id == "claude:\(account.slug)" }
                if let t = target, t.paysExtra && t.blocked {
                    Text("$").font(.system(size: 8 * m.font, weight: .heavy)).foregroundStyle(Theme.alert)
                        .help("This account is billing extra usage right now")
                } else if store.pick?.id == "claude:\(account.slug)" && !isActive {
                    Image(systemName: "arrow.right.circle.fill").font(.system(size: 7 * m.font)).foregroundStyle(Theme.ok)
                        .help("Most room left: use this one next")
                }
            }
            TileUsage(store: store, account: account)
        }
        .padding(.horizontal, 4 * m.font)
        .padding(.vertical, 2 * m.font)
        .frame(width: 64 * m.scale, height: TileMetrics.height * m.font, alignment: .topLeading)
        .modifier(TileSurface(lit: lit, used: worstUsed, active: inUse))
        .overlay(alignment: .bottom) { if inUse { ActiveMark() } }
        .contentShape(Rectangle())
        .onHover { hovering = $0; tileHover("claude:\(account.slug)", $0) }
        .onTapGesture { store.switchTo(account); tileTapped() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(store.accessibilityLabel(for: account))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Switches account")
        .accessibilityAction { store.switchTo(account); tileTapped() }
        .accessibilityAction(named: "Refresh usage") { store.refreshUsage(account) }
        .accessibilityAction(named: "Connect usage manually") { store.connectUsage(account) }
        .accessibilityAction(named: "Rename") { store.rename(account) }
        .contextMenu {
            Button(isRunning ? "Switch to \(account.name)" : "Open \(account.name)") {
                store.switchTo(account)
            }
            Divider()
            Button("Refresh usage") { store.refreshUsage(account) }
            Button("Connect usage manually…") { store.connectUsage(account) }
            Button("Rename…") { store.rename(account) }
            if !account.isMain {
                Button("Copy MCP settings from Main…") { store.syncSettingsFromMain(account) }
            }
            Button("Show profile folder") { store.reveal(account) }
            ManagePlanMenu(store: store, id: "claude:\(account.slug)")
            if !account.isMain {
                Divider()
                Button("Hide from list") { store.hide(account) }
            }
            Divider()
            WidgetMenuItems(store: store)
        }
    }
}

/// The row of tiles: Claude accounts, then Codex and Cursor, then a + tile. Shows four tiles at a
/// time and scrolls sideways for the rest, fading out on the right so it's clear there's more.
struct TileStrip: View {
    @ObservedObject var store: AccountStore
    /// A short column: three tiles, then it scrolls (swipe up, down, left or right).
    var vertical = false
    static let visibleVertical = 3
    @Environment(\.tileMetrics) private var m
    @State private var offset: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    static let visible = 4
    static let tileWidth: CGFloat = 64
    static let fade: CGFloat = 18

    var body: some View {
        // Every Codex and Cursor account gets a tile, with "–" bars when its usage can't be read.
        let others = store.others
        let count = store.accounts.count + others.count + 1      // + the add tile
        let tileW = Self.tileWidth * m.scale + m.gap
        // Panel: as many as fit in its width (tiles plus the + tile), then scroll. Desktop: four, then scroll.
        let overflows = m.maxWidth.map { CGFloat(count - 1) * tileW + 26 * m.font > $0 } ?? (count > Self.visible)
        let width = m.maxWidth ?? (CGFloat(Self.visible) * tileW + (overflows ? Self.fade : 0))
        if vertical {
            let tileH = TileMetrics.height * m.font + m.gap
            let full = CGFloat(count - 1) * tileH + 30 * m.font
            let height = min(max(StripLayout.shared.columnHeight, TileMetrics.height * m.font), full)
            let column = VStack(spacing: m.gap) {
                ForEach(store.stripTiles) { t in StripTileView(store: store, tile: t, vertical: true) }
                AddTile(store: store).frame(width: Self.tileWidth * m.scale)
            }
            if full > height + 1 {
                let topFade = offset < -1, bottomFade = offset + contentWidth > height + 1
                ScrollView(.vertical, showsIndicators: false) {
                    column.scrollTargetLayout()
                        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("tileColumn")) }) {
                            offset = $0.minY
                            contentWidth = $0.height
                        }
                }
                .scrollTargetBehavior(.viewAligned)
                .coordinateSpace(name: "tileColumn")
                .frame(width: Self.tileWidth * m.scale, height: height)
                .mask(
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.black.opacity(topFade ? 0 : 1), .black], startPoint: .top, endPoint: .bottom).frame(height: 10)
                        Rectangle()
                        LinearGradient(colors: [.black, .black.opacity(bottomFade ? 0 : 1)], startPoint: .top, endPoint: .bottom).frame(height: 10)
                    }
                )
            } else {
                column
            }
        } else {
            row(count: count, overflows: overflows, width: width)
        }
    }

    @ViewBuilder private func row(count: Int, overflows: Bool, width: CGFloat) -> some View {
        let tiles = HStack(spacing: m.gap) {
            ForEach(store.stripTiles) { t in StripTileView(store: store, tile: t) }
            AddTile(store: store)
        }
        if overflows {
            let leftFade = offset < -1, rightFade = offset + contentWidth > width + 1
            ScrollView(.horizontal, showsIndicators: false) {
                tiles.scrollTargetLayout()
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("tileRow")) }) {
                        offset = $0.minX
                        contentWidth = $0.width
                    }
            }
            .scrollTargetBehavior(.viewAligned)
            .coordinateSpace(name: "tileRow")
            .frame(width: width)
            .mask(
                HStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(leftFade ? 0 : 1), .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Self.fade)
                    Rectangle()
                    LinearGradient(colors: [.black, .black.opacity(rightFade ? 0 : 1)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Self.fade)
                }
            )
        } else {
            tiles
        }
    }
}

/// One tile in the strip's saved order (Claude, Codex and Cursor mixed, as the user arranged them).
enum StripTile: Identifiable {
    case claude(Account), other(OtherAccount)
    var id: String {
        switch self {
        case .claude(let a): return "claude:\(a.slug)"
        case .other(let o): return o.id
        }
    }
}

extension AccountStore {
    static let tileOrderKey = "strip.tileOrder"
    /// Tiles in the order the user dragged them into; new accounts go at the end in their usual place.
    var stripTiles: [StripTile] {
        let all = accounts.map(StripTile.claude) + others.map(StripTile.other)
        let order = UserDefaults.standard.stringArray(forKey: Self.tileOrderKey) ?? []
        func rank(_ i: Int, _ t: StripTile) -> Int { order.firstIndex(of: t.id) ?? (order.count + i) }
        return all.enumerated().sorted { rank($0.offset, $0.element) < rank($1.offset, $1.element) }.map(\.element)
    }
    /// Drop `id` onto `target`: it takes the target's place, pushing the target toward where the tile came from.
    func moveTile(_ id: String, onto target: String) {
        var ids = stripTiles.map(\.id)
        guard id != target, let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target) else { return }
        ids.remove(at: from)
        ids.insert(id, at: to)
        objectWillChange.send()
        UserDefaults.standard.set(ids, forKey: Self.tileOrderKey)
    }
}

/// A tile you can drag onto another to reorder the strip. A light bar marks where it will land.
struct StripTileView: View {
    @ObservedObject var store: AccountStore
    let tile: StripTile
    var vertical = false
    @State private var targeted = false
    @Environment(\.tileMetrics) private var m

    var body: some View {
        content
            .draggable(tile.id) { content.opacity(0.9) }
            .dropDestination(for: String.self) { items, _ in
                guard let id = items.first else { return false }
                withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { store.moveTile(id, onto: tile.id) }
                return true
            } isTargeted: { targeted = $0 }
            .overlay(alignment: vertical ? .top : .leading) {
                if targeted {
                    Capsule().fill(Color.white.opacity(0.9))
                        .frame(width: vertical ? 40 * m.scale : 2, height: vertical ? 2 : 26 * m.font)
                        .offset(x: vertical ? 0 : -1.5, y: vertical ? -1.5 : 0)
                }
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: targeted)
    }

    @ViewBuilder private var content: some View {
        switch tile {
        case .claude(let a): AccountTile(store: store, account: a)
        case .other(let o): OtherTile(store: store, account: o)
        }
    }
}

/// End of the strip: add another Claude, Codex or Cursor account.
struct AddTile: View {
    @ObservedObject var store: AccountStore
    @Environment(\.tileMetrics) private var m
    var body: some View {
        Menu {
            Button("Claude account…") { store.addAccount() }
            ForEach(OtherApp.allCases.filter(\.installed)) { app in
                Button(store.mainLogins[app]?.signedIn == true ? "A different \(app.title) account…" : "\(app.title) account…") {
                    store.addOther(app)
                }
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 10 * m.font, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 26 * m.font, height: 30 * m.font)
                .background(RoundedRectangle(cornerRadius: m.radius, style: .continuous).strokeBorder(Color.primary.opacity(0.2), style: StrokeStyle(lineWidth: 0.75, dash: [2, 2])))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add another Claude, Codex or Cursor account")
        .accessibilityLabel("Add account")
    }
}

/// A tile's background: clear on the desktop strip (lifts on hover), fill.platter in the panel.
/// Marks the Claude instance in use, like the Dock's running dot: a short neutral bar on the tile's bottom edge.
struct ActiveMark: View {
    @Environment(\.tileMetrics) private var m
    var body: some View {
        Capsule().fill(Color.primary.opacity(0.7))
            .frame(width: 14 * m.font, height: 2 * m.font)
            .offset(y: 1 * m.font)
    }
}

struct TileSurface: ViewModifier {
    let lit: Bool
    /// The fuller of the tile's limits (0–100); tints the tile's glass by how much is left. Nil leaves it neutral.
    var used: Double? = nil
    /// The instance in use: brighter glass and a clearer edge.
    var active: Bool = false
    @Environment(\.tileMetrics) private var m
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: m.radius, style: .continuous)
        let tint = used.map(meterColor)
        let solid = Look.current == .solid
        content
            .background {
                ZStack {
                    // A second, lighter glass layer on the strip's glass.
                    if !solid { shape.fill(.ultraThinMaterial) }
                    shape.fill(m.platter || solid ? Theme.platter : Color.primary.opacity(0.03))
                    if let tint { shape.fill(tint.opacity(active ? 0.30 : 0.16)) }
                    // Hover: clearly brighter, with a crisp light edge.
                    if lit { shape.fill(Color.white.opacity(0.22)) }
                    // Light catching the top edge, like the Dock's glass.
                    shape.fill(LinearGradient(colors: [Color.white.opacity(active ? 0.22 : 0.12), .clear], startPoint: .top, endPoint: .center))
                }
                .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75), value: lit)
            }
            .overlay(shape.strokeBorder(
                lit && !active ? AnyShapeStyle(Color.white.opacity(0.75)) :
                active ? AnyShapeStyle((tint ?? Color.primary).opacity(0.85))
                       : AnyShapeStyle(LinearGradient(colors: [Color.white.opacity(0.28), Color.primary.opacity(0.08)], startPoint: .top, endPoint: .bottom)),
                lineWidth: active || lit || contrast == .increased ? 1.2 : 0.5))
    }
}

/// A Codex or Cursor account on the strip, same size as a Claude tile. Codex shows its 5-hour and
/// weekly limits; Cursor shows this month's included usage and what's left of it.
struct OtherTile: View {
    @ObservedObject var store: AccountStore
    let account: OtherAccount
    @State private var hovering = false
    @Environment(\.tileMetrics) private var m
    @Environment(\.tileHover) private var tileHover
    @Environment(\.tileTapped) private var tileTapped
    @Environment(\.tileFocus) private var tileFocus

    private var title: String {
        if account.isMain { return account.app.title }
        return account.name == account.app.title ? "\(account.app.title) 2" : account.name
    }

    var body: some View {
        let isRunning = store.otherRunning.contains(account.id)
        let worstUsed: Double? = account.app == .cursor ? store.cursorUsage[account.id]?.percent
            : [store.codexUsage[account.id]?.shortPercent, store.codexUsage[account.id]?.weeklyPercent].compactMap { $0 }.max()
        VStack(alignment: .leading, spacing: 1 * m.font) {
            HStack(spacing: 3 * m.font) {
                StatusDot(running: isRunning)
                AppIcon(url: account.app.appURL, size: 9 * m.font)
                Text(title)
                    .font(.system(size: 8.5 * m.font, weight: .semibold))
                    .foregroundStyle(isRunning ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if store.pick?.id == account.id {
                    Image(systemName: "arrow.right.circle.fill").font(.system(size: 7 * m.font)).foregroundStyle(Theme.ok)
                        .help("Most room left: use this one next")
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                if account.app == .cursor {
                    let u = store.cursorUsage[account.id]
                    MiniMeter(label: "m", value: u?.percent)
                    Text(u?.limit.map { Fmt.money(max(0, $0 - (u?.used ?? 0)).rounded(), "USD") + " left" } ?? "")
                        .font(.system(size: 7.5 * m.font, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    let u = store.codexUsage[account.id]
                    if let u, !u.hasShortWindow {
                        MiniMeter(label: "7d", value: u.weeklyPercent, stale: u.stale)
                        Text(u.weeklyResets.map { "↻ " + TileUsage.reset.string(from: $0) } ?? "no 5h limit")
                            .font(.system(size: 7.5 * m.font, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        MiniMeter(label: "5h", value: u?.shortPercent, stale: u?.stale ?? false)
                        MiniMeter(label: "7d", value: u?.weeklyPercent, stale: u?.stale ?? false)
                    }
                }
            }
            .frame(height: 19 * m.font, alignment: .leading)
        }
        .padding(.horizontal, 4 * m.font)
        .padding(.vertical, 2 * m.font)
        .frame(width: 64 * m.scale, height: TileMetrics.height * m.font, alignment: .topLeading)
        .modifier(TileSurface(lit: hovering || tileFocus == account.id, used: worstUsed))
        .contentShape(Rectangle())
        .onHover { hovering = $0; tileHover(account.id, $0) }
        .onTapGesture { store.switchTo(account); tileTapped() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(store.accessibilityLabel(for: account))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Switches account")
        .accessibilityAction { store.switchTo(account); tileTapped() }
        .accessibilityAction(named: "Rename") { store.renameOther(account) }
        .help((isRunning ? "Switch to \(account.app.title) · \(account.name)" : "Open \(account.app.title) · \(account.name)")
              + (store.otherProblem[account.id].map { "\nNo usage: \($0)" } ?? "")
              + (store.codexUsage[account.id]?.measuredAt.map { "\nLimits " + Fmt.measured($0) + " (read from Codex directly; if it couldn't be reached, this is the last logged reading)" } ?? ""))
        .contextMenu {
            Button("Open / switch") { store.switchTo(account) }
            Button("Rename…") { store.renameOther(account) }
            ManagePlanMenu(store: store, id: "\(account.app == .codex ? "codex" : "cursor"):\(account.slug)")
            if !account.isMain { Button("Hide from list") { store.hideOther(account) } }
            Divider()
            WidgetMenuItems(store: store)
        }
    }
}

/// App-wide items at the end of every right-click menu. Appearance and open at login live in Settings.
struct WidgetMenuItems: View {
    @ObservedObject var store: AccountStore
    var body: some View {
        Button("Open \(Product.name)…") { ReportWindow.show(store: store) }
        Button("Settings…") { SettingsWindow.show() }
        Button("Refresh all usage") { store.refreshUsage() }
        if store.hasHidden { Button("Show hidden accounts") { store.unhideAll() } }
        Menu("Strip layout") {
            ForEach(DesktopStrip.Orientation.allCases, id: \.self) { o in
                Button((DesktopStrip.orientation == o ? "✓ " : "") + o.title) { DesktopStrip.orientation = o }
            }
        }
        Divider()
        Button("Quit \(Product.name)") { NSApp.terminate(nil) }
    }
}

/// One small design system for the widget and the report: a type scale, section headers and cards.
enum Theme {
    static let sectionTitle = Font.system(size: 10.5, weight: .semibold)
    static let cardTitle = Font.system(size: 11.5, weight: .semibold)
    /// Window titles.
    static func headline(_ size: CGFloat) -> Font { .system(size: size, weight: .bold) }
    static let body = Font.system(size: 11)
    static let caption = Font.system(size: 9.5)
    static let bigNumber = Font.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit()
    /// Warnings: a muted gold rather than orange, so the interface stays neutral.
    static let warn = Color(red: 0.90, green: 0.78, blue: 0.48)
    /// Over a limit or budget: a softened red.
    static let alert = Color(red: 0.94, green: 0.42, blue: 0.42)
    /// Highlights (ranks, icons, heat): plain foreground, so colour is kept for status only.
    static let accent = Color.primary
    /// Bars below 70%, the running dot and the Use next arrow (meter.ok).
    static let ok = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0x5F/255, green: 0xC4/255, blue: 0x7C/255, alpha: 1) : NSColor(srgbRed: 0x2F/255, green: 0x9A/255, blue: 0x50/255, alpha: 1) })
    /// Solid surface for the menu-bar panel and pinned strip (material.panel in Solid mode).
    static let panelSolid = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0x1C/255, green: 0x1C/255, blue: 0x20/255, alpha: 1) : NSColor(srgbRed: 0xF4/255, green: 0xF4/255, blue: 0xF6/255, alpha: 1) })
    /// Tiles, focus card and stats inside the panel (fill.platter); never another glass layer.
    static let platter = Color.primary.opacity(0.06)
    static let platterHover = Color.primary.opacity(0.12)
    /// Value text gets heavier as a limit fills, so colour is never the only cue.
    static func valueWeight(_ v: Double?) -> Font.Weight { (v ?? 0) >= 90 ? .heavy : ((v ?? 0) >= 70 ? .bold : .semibold) }
}

/// Small caps-style header above a group: quiet, so the numbers carry the weight.
struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(Theme.sectionTitle)
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

/// A rounded card: a platter with a hairline edge. In a glass window it sits darker than the glass for
/// contrast, and is never a second glass layer.
struct CardStyle: ViewModifier {
    var padding: CGFloat = 12
    var radius: CGFloat = 12
    @AppStorage(Look.key) private var look = Look.glass.rawValue
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let glass = look == Look.glass.rawValue && Look.glassActive
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(glass ? (scheme == .dark ? Color.black.opacity(0.34) : Color.white.opacity(0.62)) : Color.primary.opacity(0.06)))
            .overlay(shape.strokeBorder(Color.primary.opacity(glass ? 0.16 : 0.08), lineWidth: 0.5))
    }
}

extension View {
    func card(padding: CGFloat = 12, radius: CGFloat = 12) -> some View {
        modifier(CardStyle(padding: padding, radius: radius))
    }
}

/// Bars: green, gold from 70%, soft red from 90%.
func meterColor(_ v: Double) -> Color { v >= 90 ? Theme.alert : (v >= 70 ? Theme.warn : Theme.ok) }

enum Fmt {
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        switch d {
        case 1e9...: return String(format: "%.1fB", d / 1e9)
        case 1e6...: return String(format: "%.1fM", d / 1e6)
        case 1e3...: return String(format: "%.0fK", d / 1e3)
        default: return "\(n)"
        }
    }
    static func money(_ v: Double, _ currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = v.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 2
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
    static func reset(_ d: Date?) -> String {
        guard let d else { return "" }
        let f = DateFormatter()
        f.dateFormat = d.timeIntervalSinceNow < 20 * 3600 ? "h:mm a" : "EEE h a"
        return "resets " + f.string(from: d)
    }
    /// "3:10 PM" today or tomorrow morning, "Thu 9 AM" this week, else "Oct 31".
    static func when(_ d: Date) -> String {
        let f = DateFormatter()
        let s = d.timeIntervalSinceNow
        f.dateFormat = s < 20 * 3600 ? "h:mm a" : (s < 6 * 86_400 ? "EEE h a" : "MMM d")
        return f.string(from: d)
    }
    /// "Oct 27" (with the year when it isn't this year).
    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) ? "MMM d" : "MMM d, yyyy"
        return f.string(from: d)
    }
    private static let monthFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        f.timeZone = .autoupdatingCurrent
        return f
    }()
    static func monthKey(_ d: Date) -> String {
        return monthFormat.string(from: d)
    }
    /// "2026-10-19" → "Oct 19"
    static func dateKey(_ k: String) -> String {
        ProjectScan.date(ofKey: k)?.formatted(.dateTime.month(.abbreviated).day()) ?? k
    }
    /// "claude-opus-5-5" → "Opus 5.5"
    static func model(_ id: String) -> String {
        var parts = id.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().prefix { Int($0) != nil }.joined(separator: ".")
        return (family.prefix(1).uppercased() + family.dropFirst()) + (version.isEmpty ? "" : " " + version)
    }
}

struct DetailRow: View {
    let label: String
    let percent: Double?
    let value: String
    var note = ""
    var noteColor: Color = .secondary

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(Theme.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 74, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.18))
                if let p = percent, p > 0 {
                    Capsule().fill(meterColor(p)).frame(width: max(2, 56 * CGFloat(min(p, 100) / 100)))
                }
            }
            .frame(width: 56, height: 4)
            Text(value)
                .font(Theme.caption.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 2)
            Text(note)
                .font(Theme.caption)
                .foregroundStyle(noteColor)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

struct AccountDetails: View {
    @ObservedObject var store: AccountStore
    let account: Account

    var body: some View {
        let u = store.usage[account.slug]
        let t = store.tokens[account.slug]
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                StatusDot(running: store.running.contains(account.slug))
                AppIcon(url: Paths.claudeApp)
                Text(account.name).font(Theme.cardTitle)
                if let e = u?.email {
                    Text(e).font(Theme.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            if let d = u?.details {
                ForEach(d.limits) { l in
                    DetailRow(label: l.name, percent: l.percent, value: "\(Int(l.percent.rounded()))%",
                              note: Fmt.reset(l.resetsAt))
                }
                ForEach(d.weeklyShares, id: \.name) { s in
                    Text("\(s.name): \(Int(s.used.rounded()))% of weekly used, \(Int(s.allowed.rounded()))% allowed")
                        .font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                ForEach(d.spendCaps.indices, id: \.self) { i in
                    let c = d.spendCaps[i]
                    DetailRow(label: "Spend cap", percent: c.percent,
                              value: Fmt.money(c.used, d.currency) + " of " + Fmt.money(c.limit, d.currency),
                              note: Fmt.reset(c.resetsAt))
                }
                if !d.surfaces.isEmpty {
                    Text("Week by app: " + d.surfaces.map { "\($0.name) \(Int($0.percent.rounded()))%" }.joined(separator: " · "))
                        .font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let used = d.extraUsed {
                    let limit = d.extraLimit.map { " of " + Fmt.money($0, d.currency) } ?? ""
                    DetailRow(label: "Extra (month)", percent: d.extraPercent,
                              value: Fmt.money(used, d.currency) + limit,
                              note: d.extraReached ? "limit hit" : (d.extraEnabled ? "" : d.extraNote ?? "off"),
                              noteColor: d.extraReached ? Theme.alert : .secondary)
                }
                if let p = d.prepaid, p > 0 {
                    Text("Prepaid credit left: " + Fmt.money(p, d.currency))
                        .font(Theme.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(u?.state == .needsSignIn ? "Not connected — right-click › Connect usage" : "Loading usage…")
                    .font(Theme.caption).foregroundStyle(.secondary)
            }
            if let t {
                if t.total > 0 {
                    Text("Claude Code tokens this week · \(t.sessions) session\(t.sessions == 1 ? "" : "s")")
                        .font(Theme.caption.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.top, 2)
                    HStack(spacing: 8) {
                        tokenCell("Input", t.input)
                        tokenCell("Output", t.output)
                        tokenCell("Cache write", t.cacheWrite)
                        tokenCell("Cache read", t.cacheRead)
                        tokenCell("Total", t.total, bold: true)
                    }
                    let models = t.byModel.sorted { $0.value > $1.value }.prefix(3)
                    Text(models.map { "\(Fmt.model($0.key)) \(Int((Double($0.value) / Double(t.total) * 100).rounded()))%" }
                            .joined(separator: " · "))
                        .font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("No Claude Code sessions this week on this Mac")
                        .font(Theme.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Counting tokens…").font(Theme.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func tokenCell(_ label: String, _ n: Int, bold: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Fmt.tokens(n)).font(Theme.body.weight(bold ? .bold : .semibold).monospacedDigit())
            Text(label).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
    }
}

/// The widget's own surface: solid and opaque (white in Light, near-black in Dark) for contrast.
/// The desktop strip's surface: a glass capsule in Glass mode, today's solid background in Solid mode.
struct WidgetGlass: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View {
        content.modifier(Surface(radius: radius, solid: Color.widgetBackground, dockLike: true, solidRadius: 8))
    }
}

/// The desktop strip. Hovering it shows the focus card in its own window above (or beside) the tiles,
/// so the strip never resizes on hover.
struct RootView: View {
    @ObservedObject var store: AccountStore
    @ObservedObject var focus: PanelModel
    @ObservedObject private var layout = StripLayout.shared
    @AppStorage(DesktopStrip.verticalKey) private var vertical = false
    @Namespace private var morph
    static let morphSpring = Animation.spring(response: 0.5, dampingFraction: 0.74)
    /// Off while a drag hands back to the strip, which has already morphed in its own window.
    static var animateSwap = true
    static let columnGripInset: CGFloat = 4

    var body: some View {
        // Row ⇄ column: the glass shape springs from one size to the other while the tiles cross-fade.
        ZStack(alignment: store.growsRight ? .bottomLeading : .bottomTrailing) {
            if vertical {
                column.matchedGeometryEffect(id: "strip", in: morph)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: store.growsRight ? .bottomLeading : .bottomTrailing)))
            } else {
                row.matchedGeometryEffect(id: "strip", in: morph)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: store.growsRight ? .bottomLeading : .bottomTrailing)))
            }
        }
        .animation(Self.animateSwap ? Self.morphSpring : nil, value: vertical)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: store.growsRight ? .bottomLeading : .bottomTrailing)
    }

    /// Vertical mode: a short column of tiles.
    private var column: some View {
        VStack(alignment: store.growsRight ? .leading : .trailing, spacing: 2) {
            // The grip sits at the outer top corner, so a drag that turns a row into a column keeps it under the pointer.
            DragHandle().rotationEffect(.degrees(90)).frame(width: 30, height: 9).help("Drag to move")
                .padding(store.growsRight ? .leading : .trailing, RootView.columnGripInset)
            TileStrip(store: store, vertical: true)
                .environment(\.tileHover, { id, inside in focus.hover(id, inside: inside) })
                .id(layout.columnHeight)
            StripColumnGrip().frame(width: 30, height: 8).frame(maxWidth: .infinity)
        }
        .padding(5)
        .fixedSize()
        .modifier(WidgetGlass(radius: 12))
        .contextMenu { WidgetMenuItems(store: store) }
    }

    private var row: some View {
        HStack(spacing: 1) {
            if !store.growsRight { StripResizeGrip() }
            if store.growsRight { DragHandle().frame(width: 9, height: 30).help("Drag to move") }
            TileStrip(store: store)
                .environment(\.tileMetrics, TileMetrics(maxWidth: layout.viewport))
                .environment(\.tileHover, { id, inside in focus.hover(id, inside: inside) })
            if !store.growsRight { DragHandle().frame(width: 9, height: 30).help("Drag to move") }
            if store.growsRight { StripResizeGrip() }
        }
        .frame(height: layout.rowHeight)
        .padding(.horizontal, layout.sidePadding)
        .padding(.vertical, 2)
        .fixedSize()
        .modifier(WidgetGlass(radius: layout.radius))
        .contextMenu { WidgetMenuItems(store: store) }
    }
}

// MARK: Morphing drag
//
// Dragging the grip lifts the strip into its own canvas window, centred on the grip, which follows the pointer. The tiles are laid
// out between row and column by `t` (0 row … 1 column), driven by how far the drag has moved toward a side or toward the top/bottom,
// each tile a little behind the one before it. Their glass melts together (Liquid Glass container), so the shape flows around the grip.
// On release it springs to the nearer shape and hands back to the normal strip with the grip on the same spot.

final class MorphModel: ObservableObject {
    @Published var t: CGFloat = 0
    @Published var right = true
}

struct MorphStripView: View {
    @ObservedObject var store: AccountStore
    @ObservedObject var model: MorphModel
    static let canvas = CGSize(width: 780, height: 440)
    private static let w: CGFloat = 64, h: CGFloat = 34, stepX: CGFloat = 65, stepY: CGFloat = 35

    private func smooth(_ x: CGFloat) -> CGFloat { let c = min(max(x, 0), 1); return c * c * (3 - 2 * c) }
    /// Each tile turns a little after the one nearer the grip, so the strip bends like something soft.
    private func ti(_ i: Int, _ n: Int) -> CGFloat { let k: CGFloat = 0.07; return smooth(model.t * (1 + CGFloat(n) * k) - CGFloat(i) * k) }
    private func center(_ i: Int, _ n: Int, width: CGFloat, height: CGFloat) -> CGPoint {
        let c = CGPoint(x: Self.canvas.width / 2, y: Self.canvas.height / 2)
        let s: CGFloat = model.right ? 1 : -1
        let row = CGPoint(x: c.x + s * (4.5 + 1 + CGFloat(i) * Self.stepX + width / 2), y: c.y)
        // Column: the grip is at the tile's outer top corner (5 pt padding + inset + half the grip's 30 pt width from its edge).
        let gripFromEdge = 5 + RootView.columnGripInset + 15
        let col = CGPoint(x: c.x + s * (Self.w / 2 + 5 - gripFromEdge), y: c.y + 4.5 + 2 + CGFloat(i) * Self.stepY + height / 2)
        let t = ti(i, n)
        return CGPoint(x: row.x + (col.x - row.x) * t, y: row.y + (col.y - row.y) * t)
    }
    private func visible(_ i: Int, _ n: Int) -> CGFloat {
        let rowCount = max(1, Int((StripLayout.shared.viewport + 1) / Self.stepX))
        let colCount = max(1, Int((StripLayout.shared.columnHeight + 1) / Self.stepY))
        let a: CGFloat = i < rowCount ? 1 : 0, b: CGFloat = i < colCount ? 1 : 0
        return a + (b - a) * ti(i, n)
    }

    var body: some View {
        let tiles = store.stripTiles, n = tiles.count + 1
        let c = CGPoint(x: Self.canvas.width / 2, y: Self.canvas.height / 2)
        let blobs: [(CGPoint, CGSize)] = [(c, CGSize(width: 22, height: 22))]
            + tiles.indices.compactMap { i in
                let v = visible(i, n)
                return v > 0.02 ? (center(i, n, width: Self.w, height: Self.h), CGSize(width: (Self.w + 6) * v, height: (Self.h + 6) * v)) : nil
            }
        ZStack(alignment: .topLeading) {
            MorphGlass(blobs: blobs)
            ForEach(Array(tiles.enumerated()), id: \.element.id) { i, tile in
                Group {
                    switch tile {
                    case .claude(let a): AccountTile(store: store, account: a)
                    case .other(let o): OtherTile(store: store, account: o)
                    }
                }
                .allowsHitTesting(false)
                .position(center(i, n, width: Self.w, height: Self.h))
                .opacity(visible(i, n))
            }
            DragHandle().frame(width: 9, height: 30).rotationEffect(.degrees(90 * Double(model.t))).position(c).allowsHitTesting(false)
        }
        .frame(width: Self.canvas.width, height: Self.canvas.height)
    }
}

/// The tiles' glass as separate blobs that melt into one shape where they touch.
struct MorphGlass: View {
    let blobs: [(CGPoint, CGSize)]
    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 14) {
                ZStack(alignment: .topLeading) {
                    Color.clear
                    ForEach(blobs.indices, id: \.self) { i in
                        Color.clear.frame(width: blobs[i].1.width, height: blobs[i].1.height)
                            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                            .position(blobs[i].0)
                    }
                }
            }
        } else {
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(blobs.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.regularMaterial)
                        .frame(width: blobs[i].1.width, height: blobs[i].1.height).position(blobs[i].0)
                }
            }
        }
    }
}

/// The focus card's own window: a fixed, transparent canvas beside the strip, so the card can spring open,
/// grow and shrink between accounts without any window resizing under the pointer.
/// Where the card opens, decided from the room around the strip: above or below a row, right or left of a column.
final class CardPlacement: ObservableObject {
    @Published var below = false
    @Published var right = true
}

struct CardRoot: View {
    @ObservedObject var store: AccountStore
    @ObservedObject var focus: PanelModel
    @ObservedObject var place: CardPlacement
    @AppStorage(DesktopStrip.verticalKey) private var vertical = false
    var onHover: (Bool) -> Void
    static let size = CGSize(width: 344, height: 460)
    static let gap: CGFloat = 6
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.78)

    private var alignment: Alignment {
        if vertical { return place.right ? .bottomLeading : .bottomTrailing }
        return place.below ? (store.growsRight ? .topLeading : .topTrailing) : (store.growsRight ? .bottomLeading : .bottomTrailing)
    }
    /// Where the card grows from: the corner nearest the strip.
    private var anchor: UnitPoint {
        if vertical { return place.right ? .bottomLeading : .bottomTrailing }
        return place.below ? (store.growsRight ? .topLeading : .topTrailing) : (store.growsRight ? .bottomLeading : .bottomTrailing)
    }

    var body: some View {
        let id = focus.hovered ?? "claude:\(store.current.slug)"
        ZStack(alignment: alignment) {
            Color.clear
            if store.hovering {
                FocusCard(store: store, id: id, glass: true)
                    .frame(width: 330)
                    .animation(Self.spring, value: id)
                    .modifier(WidgetGlass(radius: 16))
                    .onHover(perform: onHover)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.92, anchor: anchor).combined(with: .opacity).combined(with: .offset(x: vertical ? (place.right ? -10 : 10) : 0, y: vertical ? 0 : (place.below ? -10 : 10))),
                        removal: .scale(scale: 0.96, anchor: anchor).combined(with: .opacity)))
            }
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: alignment)
        .animation(Self.spring, value: store.hovering)
    }
}

// MARK: - Codex & Cursor accounts
//
// Same idea as Claude: each extra account is the normal app launched with its own
// --user-data-dir (~/Library/Application Support/Codex-<name> or Cursor-<name>), so logins stay
// separate. Codex also keeps its login in CODEX_HOME, so each Codex account gets its own
// <data dir>/codex-home. "Main" is the app's normal profile. Nothing here ever quits or deletes them.

enum OtherApp: String, CaseIterable, Identifiable {
    case codex, cursor
    var id: String { rawValue }
    var title: String { self == .codex ? "Codex" : "Cursor" }
    var appURL: URL { URL(fileURLWithPath: self == .codex ? "/Applications/ChatGPT.app" : "/Applications/Cursor.app") }
    var installed: Bool { FileManager.default.fileExists(atPath: appURL.path) }
    var bundleID: String { Bundle(url: appURL)?.bundleIdentifier ?? "" }
    var folderPrefix: String { "\(title)-" }
    var mainDataDir: URL { Paths.appSupport.appendingPathComponent(title) }
}

struct OtherAccount: Identifiable, Hashable {
    let app: OtherApp
    let slug: String
    var name: String
    let dataDir: URL
    var isMain: Bool { slug == "main" }
    var id: String { "\(app.rawValue):\(slug)" }
    var codexHome: URL {
        if isMain {
            if let env = ProcessInfo.processInfo.environment["CODEX_HOME"] { return URL(fileURLWithPath: env) }
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        }
        return dataDir.appendingPathComponent("codex-home")
    }
}

/// Who is signed in to the app's normal (Main) profile — read from non-secret local state only.
struct MainLogin {
    var signedIn = false
    var email: String?
    var plan: String?

    static func detect(_ app: OtherApp) -> MainLogin {
        switch app {
        case .cursor:
            // Cursor caches the signed-in email and plan next to its settings.
            let db = app.mainDataDir.appendingPathComponent("User/globalStorage/state.vscdb")
            var h: OpaquePointer?
            guard ReadOnlyDB.open(db, &h) == SQLITE_OK else {
                sqlite3_close(h); return MainLogin()
            }
            defer { sqlite3_close(h) }
            func value(_ key: String) -> String? {
                var st: OpaquePointer?
                defer { sqlite3_finalize(st) }
                guard sqlite3_prepare_v2(h, "SELECT value FROM ItemTable WHERE key = ?", -1, &st, nil) == SQLITE_OK else { return nil }
                sqlite3_bind_text(st, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                guard sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) else { return nil }
                let v = String(cString: c).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return v.isEmpty || v == "null" ? nil : v
            }
            let email = value("cursorAuth/cachedEmail")
            return MainLogin(signedIn: email != nil, email: email, plan: value("cursorAuth/stripeMembershipType"))
        case .codex:
            // Signed in when Codex has saved a login; the plan comes from its session logs.
            let home = OtherAccount(app: .codex, slug: "main", name: "", dataDir: app.mainDataDir).codexHome
            return MainLogin(signedIn: FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path))
        }
    }
}

struct CodexUsage {
    var plan: String?
    var weeklyPercent: Double?
    var weeklyResets: Date?
    var shortPercent: Double?
    /// False when Codex's newest reading lists a weekly window and no short one (Pro, since Nov: `secondary` is null).
    var hasShortWindow: Bool { shortPercent != nil || shortResetPassed || weeklyPercent == nil }
    var shortResets: Date?
    var tokensWeek = 0
    var sessionsWeek = 0
    /// When Codex last wrote these limits (the log line's timestamp). Codex only logs them while it runs,
    /// and ChatGPT can reset a window early, so an old reading is shown with its age, never as current.
    var measuredAt: Date?
    var weeklyResetPassed = false
    var shortResetPassed = false
    var stale: Bool { measuredAt.map { Date().timeIntervalSince($0) > 6 * 3600 } ?? true }
}

extension Fmt {
    /// "measured 3 days ago", "measured 20 min ago".
    static func measured(_ d: Date) -> String {
        let s = max(0, Date().timeIntervalSince(d))
        if s < 3600 { return "measured \(max(1, Int(s / 60))) min ago" }
        if s < 86_400 { let h = Int(s / 3600); return "measured \(h) hour\(h == 1 ? "" : "s") ago" }
        let days = Int(s / 86_400); return "measured \(days) day\(days == 1 ? "" : "s") ago"
    }
}

enum CodexReader {
    static let queue = DispatchQueue(label: "ai-orchestrator.codex", qos: .utility)

    /// Live limits from Codex's own app server (`account/rateLimits/read`, stdio JSON-RPC, under its own login).
    /// Costs no tokens. Session logs only change while Codex runs, so they miss resets; they stay as the fallback.
    private static var lastLive: [String: (at: Date, rates: [String: Any])] = [:]

    private static func liveRates(home: URL, force: Bool) -> [String: Any]? {
        if !force, let c = lastLive[home.path], Date().timeIntervalSince(c.at) < 60 { return c.rates }
        guard let exe = OrchTargets.which("codex") else { return nil }
        let p = Process(), input = Pipe(), output = Pipe()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["app-server"]
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = home.path
        env["PATH"] = (OrchTargets.binDirs + ["/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        p.environment = env
        p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // Only this child process is ever stopped; a stuck read ends when it does.
        let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        defer { timeout.cancel(); if p.isRunning { p.terminate() }; try? input.fileHandleForWriting.close() }
        let hello = #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"ai-orchestrator","version":"1"}}}"# + "\n"
            + #"{"method":"initialized"}"# + "\n" + #"{"id":2,"method":"account/rateLimits/read"}"# + "\n"
        try? input.fileHandleForWriting.write(contentsOf: Data(hello.utf8))
        var buffer = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer = Data(buffer[buffer.index(after: nl)...])
                guard let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      (o["id"] as? NSNumber)?.intValue == 2 else { continue }
                guard let r = (o["result"] as? [String: Any])?["rateLimits"] as? [String: Any] else { return nil }
                lastLive[home.path] = (Date(), r)
                return r
            }
        }
    }

    /// Replaces the log's limits with the live reading, when there is one.
    private static func applyLive(_ usage: inout CodexUsage, home: URL, force: Bool) {
        guard let r = liveRates(home: home, force: force) else { return }
        var windows: [(pct: Double, mins: Int, reset: Date?)] = []
        for key in ["primary", "secondary"] {
            guard let w = r[key] as? [String: Any], let pct = (w["usedPercent"] as? NSNumber)?.doubleValue else { continue }
            windows.append((pct, (w["windowDurationMins"] as? NSNumber)?.intValue ?? 0,
                            (w["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }))
        }
        guard !windows.isEmpty else { return }
        usage.plan = r["planType"] as? String ?? usage.plan
        usage.measuredAt = lastLive[home.path]?.at ?? Date()
        usage.weeklyPercent = nil; usage.weeklyResets = nil; usage.weeklyResetPassed = false
        usage.shortPercent = nil; usage.shortResets = nil; usage.shortResetPassed = false
        for w in windows {
            if w.mins >= 6 * 24 * 60 { usage.weeklyPercent = w.pct; usage.weeklyResets = w.reset }
            else { usage.shortPercent = w.pct; usage.shortResets = w.reset }
        }
    }

    /// Latest limits and this week's tokens from Codex's own session logs ($CODEX_HOME/sessions).
    static func read(home: URL, force: Bool = false) -> CodexUsage? {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: home.appendingPathComponent("sessions"),
                                    includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        var files: [(url: URL, mtime: Date)] = []
        for case let u as URL in e where u.pathExtension == "jsonl" {
            let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if m >= weekAgo { files.append((u, m)) }
        }
        guard !files.isEmpty else {
            var none = CodexUsage()
            applyLive(&none, home: home, force: force)
            return none
        }
        files.sort { $0.mtime > $1.mtime }
        var usage = CodexUsage()
        var gotLimits = false
        for f in files {
            // The newest token_count line is near the end: read the last 1 MB, or 8 MB if that misses it.
            guard let h = try? FileHandle(forReadingFrom: f.url) else { continue }
            let size = (try? h.seekToEnd()) ?? 0
            func tail(_ n: UInt64) -> Data {
                try? h.seek(toOffset: size > n ? size - n : 0)
                return (try? h.readToEnd()) ?? Data()
            }
            var data = tail(1_048_576)
            if size > 1_048_576, data.range(of: Data("\"token_count\"".utf8)) == nil { data = tail(8_388_608) }
            try? h.close()
            var sessionTotal = 0
            for line in data.split(separator: 0x0A).reversed() {
                guard line.range(of: Data("\"token_count\"".utf8)) != nil,
                      let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      let p = obj["payload"] as? [String: Any] else { continue }
                if sessionTotal == 0, let info = p["info"] as? [String: Any],
                   let t = info["total_token_usage"] as? [String: Any] {
                    sessionTotal = (t["total_tokens"] as? NSNumber)?.intValue ?? 0
                }
                if !gotLimits, let r = p["rate_limits"] as? [String: Any] {
                    gotLimits = true
                    usage.plan = r["plan_type"] as? String
                    let iso = ISO8601DateFormatter()
                    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    usage.measuredAt = (obj["timestamp"] as? String).flatMap { iso.date(from: $0) } ?? f.mtime
                    for key in ["primary", "secondary"] {
                        guard let w = r[key] as? [String: Any],
                              let pct = (w["used_percent"] as? NSNumber)?.doubleValue else { continue }
                        let mins = (w["window_minutes"] as? NSNumber)?.intValue ?? 0
                        // resets_at (epoch seconds), or older logs' resets_in_seconds counted from the line's time.
                        let reset = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                            ?? (w["resets_in_seconds"] as? NSNumber).flatMap { s in usage.measuredAt.map { $0.addingTimeInterval(s.doubleValue) } }
                        // A window that already reset reads as 0%, marked as not measured since.
                        let passed = (reset ?? .distantFuture) <= Date()
                        let live = passed ? 0 : pct
                        if mins >= 6 * 24 * 60 { usage.weeklyPercent = live; usage.weeklyResets = passed ? nil : reset; usage.weeklyResetPassed = passed }
                        else { usage.shortPercent = live; usage.shortResets = passed ? nil : reset; usage.shortResetPassed = passed }
                    }
                }
                if sessionTotal > 0 && gotLimits { break }
            }
            _ = sessionTotal
            if gotLimits { break }      // limits come from the newest log; tokens come from Codex's database
        }
        applyLive(&usage, home: home, force: force)
        let week = CodexHistory.threads(home: home).filter { $0.updated >= weekAgo }
        usage.tokensWeek = week.map(\.tokens).reduce(0, +)
        usage.sessionsWeek = week.count
        return usage
    }
}

/// Codex keeps a token total for every thread in $CODEX_HOME/state_5.sqlite, even after it prunes
/// the session logs, so history comes from there (opened read-only).
enum CodexHistory {
    struct Thread { let created: Date; let updated: Date; let tokens: Int }

    static func threads(home: URL) -> [Thread] {
        let db = home.appendingPathComponent("state_5.sqlite")
        guard FileManager.default.fileExists(atPath: db.path) else { return [] }
        var h: OpaquePointer?
        guard ReadOnlyDB.open(db, &h) == SQLITE_OK else {
            sqlite3_close(h); return []
        }
        defer { sqlite3_close(h) }
        var st: OpaquePointer?
        defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(h, "SELECT created_at, updated_at, tokens_used FROM threads WHERE tokens_used > 0", -1, &st, nil) == SQLITE_OK else { return [] }
        var out: [Thread] = []
        while sqlite3_step(st) == SQLITE_ROW {
            out.append(Thread(created: Date(timeIntervalSince1970: Double(sqlite3_column_int64(st, 0))),
                              updated: Date(timeIntervalSince1970: Double(sqlite3_column_int64(st, 1))),
                              tokens: Int(sqlite3_column_int64(st, 2))))
        }
        return out
    }

    /// Tokens per local day, counted on the day each thread started.
    static func daily(home: URL) -> [Date: TokenStats] {
        let cal = Calendar.current
        var days: [Date: TokenStats] = [:]
        for t in threads(home: home) {
            let d = cal.startOfDay(for: t.created)
            days[d, default: TokenStats()].input += t.tokens
            days[d, default: TokenStats()].sessions += 1
        }
        return days
    }
}

extension AccountStore {
    func reloadOthers() {
        var logins: [OtherApp: MainLogin] = [:]
        for app in OtherApp.allCases where app.installed { logins[app] = MainLogin.detect(app) }
        if logins.mapValues(\.email) != mainLogins.mapValues(\.email) || logins.count != mainLogins.count { mainLogins = logins }
        var list: [OtherAccount] = []
        let hidden = Set(UserDefaults.standard.stringArray(forKey: "hidden") ?? [])
        let items = (try? FileManager.default.contentsOfDirectory(
            at: Paths.appSupport, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey])) ?? []
        for app in OtherApp.allCases where app.installed {
            list.append(OtherAccount(app: app, slug: "main", name: otherName(app, "main", fallback: "Main"),
                                     dataDir: app.mainDataDir))
            let dirs = items.filter {
                $0.lastPathComponent.hasPrefix(app.folderPrefix)
                    && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }.sorted {
                ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
                    < ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
            }
            // A Cursor profile signed in to an account that's already listed is the same account twice:
            // leave it out (the folder itself is never touched).
            var emails = Set([app == .cursor ? logins[app]?.email : nil].compactMap { $0 })
            for url in dirs {
                let slug = String(url.lastPathComponent.dropFirst(app.folderPrefix.count))
                guard !slug.isEmpty, !hidden.contains("\(app.rawValue):\(slug)") else { continue }
                if app == .cursor, let e = CursorReader.email(dataDir: url) {
                    guard emails.insert(e).inserted else { continue }
                }
                list.append(OtherAccount(app: app, slug: slug, name: otherName(app, slug, fallback: prettify(slug)),
                                         dataDir: url))
            }
        }
        if list != others { others = list }
    }

    private func otherName(_ app: OtherApp, _ slug: String, fallback: String) -> String {
        UserDefaults.standard.string(forKey: "name.\(app.rawValue).\(slug)") ?? fallback
    }

    /// Which account a running Codex/Cursor process belongs to, from its --user-data-dir.
    private func otherSlug(_ app: OtherApp, pid: pid_t) -> String {
        for arg in processArguments(pid) where arg.hasPrefix("--user-data-dir=") {
            let path = URL(fileURLWithPath: String(arg.dropFirst("--user-data-dir=".count))).standardizedFileURL
            let last = path.lastPathComponent
            if last.hasPrefix(app.folderPrefix) { return String(last.dropFirst(app.folderPrefix.count)) }
            if path.path == app.mainDataDir.standardizedFileURL.path { return "main" }
            return last
        }
        return "main"
    }

    func refreshOtherRunning() {
        var now = Set<String>()
        for app in OtherApp.allCases where app.installed {
            let id = app.bundleID
            for r in NSWorkspace.shared.runningApplications where r.bundleIdentifier == id && !r.isTerminated {
                now.insert("\(app.rawValue):\(otherSlug(app, pid: r.processIdentifier))")
            }
        }
        if now != otherRunning { otherRunning = now }
    }

    func switchTo(_ o: OtherAccount) {
        let id = o.app.bundleID
        if let r = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == id && !$0.isTerminated && otherSlug(o.app, pid: $0.processIdentifier) == o.slug
        }) {
            bringForward(r)
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = true
        if !o.isMain {
            let fm = FileManager.default
            try? fm.createDirectory(at: o.dataDir, withIntermediateDirectories: true)
            config.arguments = ["--user-data-dir=\(o.dataDir.path)"]
            if o.app == .codex {
                try? fm.createDirectory(at: o.codexHome, withIntermediateDirectories: true)
                // Share settings (MCP servers, instructions) but never the login.
                let mainHome = OtherAccount(app: .codex, slug: "main", name: "", dataDir: o.app.mainDataDir).codexHome
                for f in ["config.toml", "AGENTS.md"] {
                    let src = mainHome.appendingPathComponent(f), dst = o.codexHome.appendingPathComponent(f)
                    if fm.fileExists(atPath: src.path) && !fm.fileExists(atPath: dst.path) { try? fm.copyItem(at: src, to: dst) }
                }
                var env = ProcessInfo.processInfo.environment
                env["CODEX_HOME"] = o.codexHome.path
                config.environment = env
            }
        }
        NSWorkspace.shared.openApplication(at: o.app.appURL, configuration: config) { _, error in
            guard let error else { return }
            DispatchQueue.main.async { showAlert("Couldn't open \(o.app.title)", error.localizedDescription) }
        }
    }

    func addOther(_ app: OtherApp) {
        guard let name = askName(title: "Add a \(app.title) account",
                                 info: (mainLogins[app]?.signedIn == true
                                        ? "Your main \(app.title) login\(mainLogins[app]?.email.map { " (\($0))" } ?? "") is already connected, so you only need this for a different account. "
                                        : "") + "It opens a separate \(app.title) window where you sign in with the other account.",
                                 initial: suggestedName(app.title, taken: others.filter { $0.app == app }.map(\.name)),
                                 appURL: app.appURL, button: "Open \(app.title) to sign in") else { return }
        var base = slugify(name)
        if base.isEmpty || base == "main" { base = "account" }
        var slug = base, n = 2
        while FileManager.default.fileExists(atPath: Paths.appSupport.appendingPathComponent(app.folderPrefix + slug).path) {
            slug = "\(base)-\(n)"; n += 1
        }
        let dir = Paths.appSupport.appendingPathComponent(app.folderPrefix + slug)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        UserDefaults.standard.set(name, forKey: "name.\(app.rawValue).\(slug)")
        reloadOthers()
        if let o = others.first(where: { $0.app == app && $0.slug == slug }) { switchTo(o) }
    }

    func renameOther(_ o: OtherAccount) {
        guard let name = askName(title: "Rename \(o.app.title) account", info: "", initial: o.name, appURL: o.app.appURL) else { return }
        UserDefaults.standard.set(name, forKey: "name.\(o.app.rawValue).\(o.slug)")
        reloadOthers()
    }

    func hideOther(_ o: OtherAccount) {
        var hidden = UserDefaults.standard.stringArray(forKey: "hidden") ?? []
        hidden.append(o.id)
        UserDefaults.standard.set(hidden, forKey: "hidden")
        reloadOthers()
    }

    func refreshCodex(force: Bool = false) {
        let codex = others.filter { $0.app == .codex }
        CodexReader.queue.async {
            var out: [String: CodexUsage] = [:]
            for o in codex { if let u = Demo.on ? Demo.codex : CodexReader.read(home: o.codexHome, force: force) { out[o.id] = u } }
            DispatchQueue.main.async {
                self.codexUsage = out
                self.codexChecked = true
                for o in codex {
                    let u = out[o.id]
                    self.otherProblem[o.id] = u == nil ? "no Codex session log found in its home folder"
                        : (u?.weeklyPercent == nil && u?.shortPercent == nil ? "the newest Codex log has no limit reading" : nil)
                }
                self.checkGuard()
                for o in codex {
                    // Record each Codex reading once, not the same old reading again on every refresh.
                    guard let u = out[o.id], u.weeklyPercent != nil || u.shortPercent != nil,
                          let at = u.measuredAt, at > (self.codexRecorded[o.id] ?? .distantPast) else { continue }
                    self.codexRecorded[o.id] = at
                    History.record(UsageSnapshot(t: Date(), provider: "codex", account: o.slug, name: "Codex \(o.name)",
                                                 session: u.shortPercent, weekly: u.weeklyPercent, limits: nil,
                                                 extraUsed: nil, extraLimit: nil, currency: nil))
                }
            }
        }
    }
}

/// Cursor's included usage this billing cycle, from cursor.com/api/usage-summary. The widget reads
/// the profile's saved access token (with the user's OK, Oct 19) only to make this call.
struct CursorUsage {
    var plan: String?
    var percent: Double
    var used: Double            // dollars
    var limit: Double?          // dollars
    var cycleEnd: Date?
    var onDemand = false        // pay-as-you-go past the plan is switched on
    var onDemandUsed: Double = 0
}

enum CursorReader {
    static let queue = DispatchQueue(label: "ai-orchestrator.cursor", qos: .utility)
    private static var cachedKey: Data?
    private static var keyDenied = false
    private static let encryptedPrefix = "cursor-safe-storage:v1:"

    /// The saved access token. Cursor (late Oct 2026 on) stores it as "cursor-safe-storage:v1:" + base64 of
    /// Electron safeStorage data ("v10" + AES-128-CBC), keyed by the "Cursor Safe Storage" keychain item
    /// (the user OK'd reading it, Oct 29). The decrypted token stays in memory only: never logged or saved.
    static func token(dataDir: URL) -> String? {
        guard let raw = value("cursorAuth/accessToken", dataDir: dataDir) else { return nil }
        guard raw.hasPrefix(encryptedPrefix) else { return raw }
        guard let enc = Data(base64Encoded: String(raw.dropFirst(encryptedPrefix.count))), let key = safeStorageKey(),
              let t = decrypt(enc, key: key), t.split(separator: ".").count == 3 else { return nil }
        return t
    }
    static func isEncrypted(dataDir: URL) -> Bool { value("cursorAuth/accessToken", dataDir: dataDir)?.hasPrefix(encryptedPrefix) ?? false }
    static var keyWasDenied: Bool { keyDenied }

    /// Same derivation as CookieImporter's "Claude Safe Storage" key: PBKDF2-SHA1, "saltysalt", 1003 rounds, 16 bytes.
    private static func safeStorageKey() -> Data? {
        if let k = cachedKey { return k }
        if keyDenied { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Cursor Safe Storage",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let password = out as? Data, !password.isEmpty else { keyDenied = true; return nil }
        var key = [UInt8](repeating: 0, count: 16)
        let salt = Array("saltysalt".utf8)
        let rc = password.withUnsafeBytes { pw -> Int32 in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                 pw.baseAddress!.assumingMemoryBound(to: CChar.self), password.count,
                                 salt, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                 &key, key.count)
        }
        guard rc == Int32(kCCSuccess) else { return nil }
        cachedKey = Data(key)
        return cachedKey
    }

    private static func decrypt(_ enc: Data, key: Data) -> String? {
        guard enc.count > 3, enc.prefix(3) == Data("v10".utf8) else { return nil }
        let body = Data(enc.dropFirst(3))
        let iv = [UInt8](repeating: 0x20, count: 16)
        var out = [UInt8](repeating: 0, count: body.count + kCCBlockSizeAES128)
        var outLen = 0
        let status = body.withUnsafeBytes { b in
            key.withUnsafeBytes { k in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
                        k.baseAddress, kCCKeySizeAES128, iv, b.baseAddress, body.count, &out, out.count, &outLen)
            }
        }
        guard status == Int32(kCCSuccess) else { return nil }
        return String(bytes: out.prefix(outLen), encoding: .utf8)
    }
    static func email(dataDir: URL) -> String? { value("cursorAuth/cachedEmail", dataDir: dataDir) }

    private static func value(_ key: String, dataDir: URL) -> String? {
        let db = dataDir.appendingPathComponent("User/globalStorage/state.vscdb")
        var h: OpaquePointer?
        guard ReadOnlyDB.open(db, &h) == SQLITE_OK else {
            sqlite3_close(h); return nil
        }
        defer { sqlite3_close(h) }
        var st: OpaquePointer?
        defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(h, "SELECT value FROM ItemTable WHERE key = ?", -1, &st, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(st, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) else { return nil }
        let t = String(cString: c).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return t.isEmpty || t == "null" ? nil : t
    }

    /// The user id is the part after "|" in the token's `sub` claim.
    private static func userID(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var b = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b),
              let claims = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let sub = claims["sub"] as? String else { return nil }
        return sub.split(separator: "|").last.map(String.init)
    }

    /// Calls back with the usage, or nil and a short, plain reason (never the token).
    static func fetch(dataDir: URL, done: @escaping (CursorUsage?, String?) -> Void) {
        // Off the main thread: the first keychain read shows a macOS prompt.
        queue.async { fetchNow(dataDir: dataDir, done: done) }
    }

    private static func fetchNow(dataDir: URL, done: @escaping (CursorUsage?, String?) -> Void) {
        guard let token = token(dataDir: dataDir) else {
            if !isEncrypted(dataDir: dataDir) { return done(nil, "not signed in to Cursor") }
            return done(nil, keyWasDenied ? "\(Product.name) wasn't allowed to read \"Cursor Safe Storage\" (quit and reopen \(Product.name), then choose Always Allow)"
                                          : "couldn't unlock Cursor's encrypted sign-in")
        }
        guard let uid = userID(token), let url = URL(string: "https://cursor.com/api/usage-summary") else {
            return done(nil, "Cursor's saved sign-in is in a format \(Product.name) doesn't know")
        }
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.setValue("WorkosCursorSessionToken=\(uid)%3A%3A\(token)", forHTTPHeaderField: "Cookie")
        URLSession.shared.dataTask(with: r) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode
            if err != nil || code == nil { return done(nil, "couldn't reach cursor.com") }
            guard code == 200 else { return done(nil, code == 401 || code == 403 ? "cursor.com didn't accept the saved sign-in (\(code!))" : "cursor.com answered \(code!)") }
            guard let data,
                  let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let ind = j["individualUsage"] as? [String: Any],
                  let plan = ind["plan"] as? [String: Any] else { return done(nil, "cursor.com's usage format changed") }
            func n(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
            let used = (n(plan["used"]) ?? 0) / 100
            let limit = n(plan["limit"]).map { $0 / 100 }
            let pct = n(plan["totalPercentUsed"]) ?? (limit.map { $0 > 0 ? used / $0 * 100 : 0 } ?? 0)
            let od = ind["onDemand"] as? [String: Any]
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            done(CursorUsage(plan: j["membershipType"] as? String, percent: pct, used: used, limit: limit,
                             cycleEnd: (j["billingCycleEnd"] as? String).flatMap { iso.date(from: $0) },
                             onDemand: od?["enabled"] as? Bool ?? false, onDemandUsed: (n(od?["used"]) ?? 0) / 100), nil)
        }.resume()
    }
}

extension AccountStore {
    func refreshCursor() {
        for o in others where o.app == .cursor {
            if Demo.on { cursorUsage[o.id] = Demo.cursor; otherProblem[o.id] = nil; continue }
            CursorReader.fetch(dataDir: o.dataDir) { u, problem in
                DispatchQueue.main.async {
                    self.cursorUsage[o.id] = u
                    self.otherProblem[o.id] = u == nil ? problem : nil
                    self.checkGuard()
                }
            }
        }
    }
}

struct AppIcon: View {
    let url: URL
    var size: CGFloat = 13
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: size, height: size)
    }
}

// MARK: - Planner (use next, budget guard, plan ahead)
//
// Spreads work across the subscriptions you already pay for before anything tips into paid extra
// usage: picks the account with the most room (weighted towards weekly room that resets soon and
// would otherwise go unused), warns at 90% and when an account starts billing extra, and tracks
// Claude extra usage against the monthly budget set in the Report.

struct WorkTarget: Identifiable {
    enum Kind { case claude(Account), codex(OtherAccount) }   // .codex covers any OtherAccount (Codex or Cursor)
    let id: String
    let name: String
    let kind: Kind
    let short: Double?
    let shortResets: Date?
    let weekly: Double?
    let weeklyResets: Date?
    /// Claude only: extra usage is on and under its cap, so going past 100% costs money.
    let paysExtra: Bool

    /// Percent left on whichever limit is tighter.
    var room: Double { max(0, 100 - max(short ?? 0, weekly ?? 0)) }
    var blocked: Bool { room <= 3 }
    /// When a blocked target frees up: the latest reset among the limits that are used up.
    var freesAt: Date? {
        [(short, shortResets), (weekly, weeklyResets)].filter { ($0.0 ?? 0) >= 97 }.compactMap(\.1).max()
    }
    /// Room, boosted up to 2× when the weekly window resets soon (use it or lose it).
    var score: Double {
        guard !blocked else { return 0 }
        let hours = weeklyResets.map { max($0.timeIntervalSinceNow / 3600, 1) } ?? 168
        return room * (1 + max(0, min(1, (168 - hours) / 168)))
    }
}

/// Clicking a warning (or its Switch button) opens the suggested account.
final class NotifyDelegate: NSObject, UNUserNotificationCenterDelegate {
    var onSwitch: ((String) -> Void)?
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if let thread = response.notification.request.content.userInfo["board"] as? String {
            Task { @MainActor in
                OrchestratorWindow.show(thread: thread)
            }
            done(); return
        }
        if let id = response.notification.request.content.userInfo["target"] as? String,
           response.actionIdentifier == "switch" || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            DispatchQueue.main.async { self.onSwitch?(id) }
        }
        done()
    }
}

enum Notify {
    /// Only the installed app has a bundle; test binaries would crash in UNUserNotificationCenter.
    static var available: Bool { Bundle.main.bundleIdentifier == "local.ai-orchestrator" }
    static let delegate = NotifyDelegate()
    static func ask() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.setNotificationCategories([UNNotificationCategory(
            identifier: "switch", actions: [UNNotificationAction(identifier: "switch", title: "Switch", options: [.foreground])],
            intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    /// `target` is a WorkTarget id; when set, the notification gets a Switch button for it.
    static func send(_ title: String, _ body: String, target: String? = nil) {
        guard available else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        if let target {
            c.categoryIdentifier = "switch"
            c.userInfo = ["target": target]
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
    /// An Overview change; clicking it opens that row.
    static func board(_ title: String, _ body: String, thread: String) {
        guard available else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.userInfo = ["board": thread]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
    /// Runs `fire` once per key (keys carry the reset time or month, so each window warns once).
    static func once(_ key: String, _ fire: () -> Void) {
        var sent = UserDefaults.standard.stringArray(forKey: "guard.sent") ?? []
        guard !sent.contains(key) else { return }
        fire()
        sent.append(key)
        UserDefaults.standard.set(Array(sent.suffix(300)), forKey: "guard.sent")
    }
}

extension AccountStore {
    /// Every Claude, Codex and Cursor account with live limits. Cursor's monthly included usage
    /// stands in for a weekly limit, resetting at the end of its billing cycle.
    var targets: [WorkTarget] {
        var out: [WorkTarget] = []
        for a in accounts {
            guard let u = usage[a.slug], u.session != nil || u.weekly != nil else { continue }
            let d = u.details
            out.append(WorkTarget(id: "claude:\(a.slug)", name: a.name, kind: .claude(a),
                                  short: u.session?.percent, shortResets: u.session?.resetsAt,
                                  weekly: u.weekly?.percent, weeklyResets: u.weekly?.resetsAt,
                                  paysExtra: (d?.extraEnabled ?? false) && !(d?.extraReached ?? false)))
        }
        for o in others where o.app == .codex {
            guard let u = codexUsage[o.id], u.shortPercent != nil || u.weeklyPercent != nil else { continue }
            out.append(WorkTarget(id: o.id, name: o.isMain ? "Codex" : "Codex \(o.name)", kind: .codex(o),
                                  short: u.shortPercent, shortResets: u.shortResets,
                                  weekly: u.weeklyPercent, weeklyResets: u.weeklyResets, paysExtra: false))
        }
        for o in others where o.app == .cursor {
            guard let u = cursorUsage[o.id] else { continue }
            out.append(WorkTarget(id: o.id, name: o.isMain ? "Cursor" : "Cursor \(o.name)", kind: .codex(o),
                                  short: nil, shortResets: nil, weekly: u.percent, weeklyResets: u.cycleEnd,
                                  paysExtra: u.onDemand))
        }
        return out
    }

    var pick: WorkTarget? { targets.filter { !$0.blocked }.max { $0.score < $1.score } }

    func open(_ t: WorkTarget) {
        switch t.kind {
        case .claude(let a): switchTo(a)
        case .codex(let o): switchTo(o)
        }
    }

    /// Claude extra usage billed this month, across accounts (Claude resets it monthly).
    var extraThisMonth: Double { accounts.compactMap { usage[$0.slug]?.details?.extraUsed }.reduce(0, +) }
    /// There's one budget now: the monthly AI + tech ceiling (Money tab). `extraBudget` is kept as its mirror.
    var extraBudget: Double { Budget.shared.ceiling }


    /// Live limits for command-line routing (bin/ai-route): written on every usage update, only
    /// from real data. ~/Library/Application Support/local.ai-orchestrator/status.json
    func writeStatus() {
        PlanStore.shared.sync(self)
        let iso = ISO8601DateFormatter()
        let pickID = pick?.id
        let items: [[String: Any]] = targets.map { t in
            var d: [String: Any] = ["id": t.id, "name": t.name, "room": t.room, "blocked": t.blocked,
                                    "paysExtra": t.paysExtra, "pick": t.id == pickID, "heat": 0]
            if let v = t.short { d["shortPercent"] = v }
            if let v = t.weekly { d["weeklyPercent"] = v }
            if let r = t.shortResets { d["shortResets"] = iso.string(from: r) }
            if let r = t.weeklyResets { d["weeklyResets"] = iso.string(from: r) }
            if let r = t.freesAt { d["freesAt"] = iso.string(from: r) }
            if case .claude(let a) = t.kind, let e = usage[a.slug]?.email { d["email"] = e }
            // Paid usage so far this cycle, for the per-account rule in orchestration.
            if case .claude(let a) = t.kind, let v = usage[a.slug]?.details?.extraUsed { d["extraUsed"] = v }
            if t.id.hasPrefix("cursor"), let v = cursorUsage[t.id]?.onDemandUsed { d["extraUsed"] = v }
            if case .claude(let a) = t.kind, a.slug == active, running.contains(a.slug) { d["inUse"] = true }
            if case .claude(let a) = t.kind, let u = usage[a.slug]?.details {
                if let n = u.extraNote { d["extraNote"] = n }
                d["weeklyShares"] = u.weeklyShares.map { ["name": $0.name, "used": $0.used, "allowed": $0.allowed] }
                d["spendCaps"] = u.spendCaps.map { c -> [String: Any] in
                    var row: [String: Any] = ["used": c.used, "limit": c.limit]
                    if let p = c.percent { row["percent"] = p }
                    if let r = c.resetsAt { row["resets"] = iso.string(from: r) }
                    return row
                }
            }
            return d
        }
        let fp = Footprint.compute(codexHomes: others.filter { $0.app == .codex }.map { ($0.isMain ? "Codex" : "Codex \($0.name)", $0.codexHome) })
        // Command center for bin/phone-feed and the iPhone app: budget standing, ranked ideas, latest brief.
        let st = Budget.shared.standing(store: self)
        var budget: [String: Any] = ["month": Fmt.monthKey(st.month), "ceiling": st.ceiling, "spent": st.spent, "extra": st.extra,
                                     "plans": st.plans, "plansEntered": st.plans > 0, "api": st.api, "ai": st.ai, "tech": st.tech,
                                     "day": st.day, "daysInMonth": st.daysInMonth, "left": st.left, "perDaySoFar": st.perDaySoFar]
        // Revenue (income) stays on the Mac: never in status.json or the phone feed.
        if let m = st.maxPerDay { budget["maxPerDay"] = m }
        let ideas: [[String: Any]] = IdeaStore.shared.ranked.prefix(25).enumerated().map { i, idea in
            var d: [String: Any] = ["id": idea.id.uuidString, "title": idea.title, "status": idea.status, "rank": i + 1,
                                    "score": idea.score, "value": idea.value, "effort": idea.effort, "size": idea.size, "created": iso.string(from: idea.created)]
            if let r = idea.managerRank { d["managerRank"] = r }
            if let n = idea.managerNote { d["managerNote"] = n }
            if !idea.notes.isEmpty { d["notes"] = idea.notes }
            return d
        }
        var manager: [String: Any] = ["enabled": Manager.shared.hasKey, "costThisMonth": Manager.shared.costThisMonth]
        if let b = Manager.shared.latest {
            manager["date"] = iso.string(from: b.date); manager["model"] = b.model; manager["headline"] = b.headline; manager["brief"] = b.brief
            manager["budgetMove"] = b.budgetMove; manager["nextActions"] = b.nextActions; manager["promptTips"] = b.promptTips; manager["workflow"] = b.workflow
            manager["findings"] = b.findings.map { ["session": $0.session, "project": $0.project, "waste": $0.waste, "fix": $0.fix] }
            manager["cost"] = b.cost
        }
        let obj: [String: Any] = ["updated": iso.string(from: Date()), "pick": pickID ?? NSNull(), "targets": items,
                                  "footprint": Footprint.json(fp), "plans": PlanStore.shared.json(self),
                                  "upcomingCharges": PlanStore.shared.upcoming(self).map { u -> [String: Any] in
                                      var d: [String: Any] = ["date": iso.string(from: u.date), "account": u.account, "title": u.title, "note": u.note]
                                      if let a = u.amount { d["amount"] = a }
                                      return d
                                  },
                                  "commandCenter": ["budget": budget, "ideas": ideas, "manager": manager],
                                  "menubar": menuBarStatus.json]
        let dir = Paths.appSupport.appendingPathComponent("local.ai-orchestrator")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("status.json"), options: .atomic)
        }
    }

    /// Sends each warning once per limit window (and once per month for the budget).
    func checkGuard() {
        writeStatus()
        let all = targets, next = pick
        for t in all {
            let alt = next.flatMap { $0.id == t.id ? nil : $0 }
            let tail = alt.map { " Next best: \($0.name) (\(Int($0.room))% left)." }
                ?? " Nothing else has much room, so wait for the reset if you can."
            for (label, pct, reset) in [("5-hour", t.short, t.shortResets), (t.id.hasPrefix("cursor:") ? "monthly" : "weekly", t.weekly, t.weeklyResets)] {
                guard let p = pct, p >= 90, let r = reset else { continue }
                let window = "\(t.id).\(label).\(Int(r.timeIntervalSince1970))"
                if p >= 100 && t.paysExtra {
                    Notify.once(window + ".paid") {
                        Notify.send("\(t.name) is now on paid extra usage",
                                    "Its \(label) limit is used up until \(Fmt.when(r))." + tail, target: alt?.id)
                    }
                } else {
                    Notify.once(window + ".90") {
                        Notify.send("\(t.name) is at \(Int(p))% of its \(label) limit", "Resets \(Fmt.when(r))." + tail, target: alt?.id)
                    }
                }
            }
        }
        let st = Budget.shared.standing(store: self)
        let b = st.ceiling, spent = st.spent
        guard b > 0 else { return }
        let month = Fmt.monthKey(Date())
        for level in [80, 100] where spent >= b * Double(level) / 100 {
            Notify.once("budget.\(level).\(month)") {
                Notify.send(level >= 100 ? "Over your monthly AI & tech budget" : "80% of your monthly AI & tech budget",
                            "\(Fmt.money(spent, "USD")) of \(Fmt.money(b, "USD")) this month." + (next.map { " Most room now: \($0.name)." } ?? ""), target: next?.id)
            }
        }
    }
}

// MARK: - Usage history (saved locally, one JSON line per snapshot)

struct UsageSnapshot: Codable {
    var t: Date
    var provider: String
    var account: String
    var name: String
    var session: Double?
    var weekly: Double?
    var limits: [String: Double]?
    var extraUsed: Double?
    var extraLimit: Double?
    var currency: String?
}

enum History {
    static let dir = Paths.appSupport.appendingPathComponent("local.ai-orchestrator")
    static let file = dir.appendingPathComponent("history.jsonl")
    private static var lastWrite: [String: Date] = [:]
    private static let queue = DispatchQueue(label: "ai-orchestrator.history")

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    /// At most one snapshot per account every 10 minutes.
    static func record(_ snap: UsageSnapshot) {
        let key = "\(snap.provider):\(snap.account)"
        if let last = lastWrite[key], snap.t.timeIntervalSince(last) < 600 { return }
        lastWrite[key] = snap.t
        guard var line = try? encoder.encode(snap) else { return }
        line.append(0x0A)
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
            guard let h = try? FileHandle(forWritingTo: file) else { return }
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line)
        }
    }

    static func load(since: Date) -> [UsageSnapshot] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? d.decode(UsageSnapshot.self, from: Data($0)) }
            .filter { $0.t >= since }
    }
}

/// Daily token totals kept by the widget itself, because Claude Code deletes transcripts after
/// 30 days by default. Keyed "yyyy-MM-dd|account"; fresh counts from transcripts replace old ones.
enum TokenHistory {
    static let file = History.dir.appendingPathComponent("tokens-daily.json")
    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()

    static func load() -> [String: TokenStats] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: TokenStats].self, from: data)) ?? [:]
    }

    static func save(_ rows: [DayTokens]) {
        var all = load()
        for r in rows { all["\(fmt.string(from: r.day))|\(r.account)"] = r.stats }
        try? FileManager.default.createDirectory(at: History.dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: file, options: .atomic) }
    }

    /// Saved rows for days the transcripts no longer cover.
    static func rows(since: Date, missingFrom live: [DayTokens]) -> [DayTokens] {
        let have = Set(live.map { "\(fmt.string(from: $0.day))|\($0.account)" })
        return load().compactMap { key, stats in
            guard !have.contains(key) else { return nil }
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let day = fmt.date(from: parts[0]), day >= since else { return nil }
            return DayTokens(day: day, account: parts[1], stats: stats)
        }
    }

    /// Recount the last 30 days from transcripts and store them (runs on TokenCounter.queue).
    static func snapshot(accounts: [Account]) -> [DayTokens] {
        let since = Calendar.current.startOfDay(for: Date().addingTimeInterval(-29 * 86_400))
        var rows: [DayTokens] = []
        for a in accounts {
            for (day, s) in TokenCounter.daily(profile: a.profileURL, since: since) {
                rows.append(DayTokens(day: day, account: a.name, stats: s))
            }
        }
        for (day, s) in TokenCounter.dailyOther(excluding: accounts.map(\.profileURL), since: since) {
            rows.append(DayTokens(day: day, account: "Terminal & remote", stats: s))
        }
        save(rows)
        return rows
    }
}

/// Claude credit purchases, logged as they show up (Claude only reports the current grants, so the
/// widget keeps its own history). Kept apart from "paid" because extra usage already counts that spend.
enum PurchaseLog {
    struct Purchase: Codable, Identifiable { var id: String; var date: Date; var provider: String; var account: String; var amount: Double; var auto: Bool }
    static let file = History.dir.appendingPathComponent("purchases.json")

    static func load() -> [Purchase] {
        guard let d = try? Data(contentsOf: file) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([Purchase].self, from: d)) ?? []
    }

    static func note(_ grants: [(id: String, date: Date, amount: Double, auto: Bool)], account: String) {
        guard !grants.isEmpty else { return }
        var all = load()
        let known = Set(all.map(\.id))
        let new = grants.filter { !known.contains($0.id) }
        guard !new.isEmpty else { return }
        all += new.map { Purchase(id: $0.id, date: $0.date, provider: "Anthropic", account: account, amount: $0.amount, auto: $0.auto) }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
        try? FileManager.default.createDirectory(at: History.dir, withIntermediateDirectories: true)
        if let d = try? enc.encode(all.sorted { $0.date > $1.date }) { try? d.write(to: file, options: .atomic) }
    }

    /// Days with several separate top-ups, or small auto-reloads — places one larger purchase would have done.
    struct Cluster: Identifiable { let id = UUID(); let day: Date; let provider: String; let count: Int; let total: Double; let autoCount: Int }

    static func clusters() -> [Cluster] {
        var items: [(Date, String, Double, Bool)] = load().map { ($0.date, $0.provider, $0.amount, $0.auto) }
        for p in Spend.shared.payments where p.item.lowercased().contains("credit") {
            items.append((p.date, p.provider, p.amount, p.item.lowercased().contains("auto")))
        }
        let cal = Calendar.current
        let grouped = Dictionary(grouping: items) { "\(cal.startOfDay(for: $0.0).timeIntervalSince1970)|\($0.1)" }
        return grouped.compactMap { _, v in
            let autos = v.filter(\.3).count
            guard v.count >= 2 || v.contains(where: { $0.3 && $0.2 < 50 }) else { return nil }
            return Cluster(day: cal.startOfDay(for: v[0].0), provider: v[0].1, count: v.count,
                           total: v.map(\.2).reduce(0, +), autoCount: autos)
        }.sorted { $0.day > $1.day }
    }
}

// MARK: - Footprint (estimates)
//
// Energy, carbon and water for AI use, from the saved daily token totals (tokens-daily.json, local
// calendar days). These are ESTIMATES: providers don't publish per-token energy, so every figure is a
// low / middle / high range and is labelled as an estimate wherever it's shown. bin/phone-feed uses the
// same factors so the iPhone app matches. Money figures next to them are measured, not estimated.

enum Footprint {
    /// Wh per million tokens by type, middle estimate (Simon Couch, Jan 2026, inferred from API prices).
    static let whInput = 390.0, whCacheWrite = 490.0, whCacheRead = 39.0, whOutput = 1950.0
    /// Range around the middle (Hausfather: 170 kWh, range 70–330).
    static let lowFactor = 0.41, highFactor = 1.94
    /// Codex has no token-type split: Wh per million tokens, rougher (Hausfather ratio).
    static let codexWh = (low: 22.0, mid: 53.0, high: 103.0)
    static let gCO2ePerKWh = 341.0          // eGRID 2024 US average
    static let waterLPerKWh = 0.55 + 3.142  // Li et al.: on site + at power plants, US average
    static let gCO2PerMile = 400.0          // EPA passenger car
    static let homeKWhPerMonth = 865.0      // EIA 2024 average US home
    // Everyday yardsticks (same as the iPhone app), applied to the middle estimate.
    static let phoneChargeKWh = 0.019       // EPA greenhouse gas equivalencies: one smartphone charge
    static let homeKWhPerDay = 865.0 / 30   // EIA 2024: ~28.8 kWh a day
    static let showerL = 65.0               // EPA WaterSense average shower
    static let bottleL = 0.5                // a standard bottle of water
    static let chatbotWh = 0.24             // Google, Aug 2025: median Gemini text prompt
    static let definitions = [
        ("Token", "a small chunk of text, about ¾ of a word"),
        ("kWh", "the unit on your power bill"),
        ("CO₂e", "the climate effect of all greenhouse gases, counted as CO₂"),
        ("Water", "what data centers and power plants use for cooling"),
    ]
    /// Round to something a person can picture: 3.4, 58, 22,000, 1.8 million.
    static func approx(_ v: Double) -> String {
        switch v {
        case ..<10: return v.formatted(.number.precision(.fractionLength(v < 1 ? 2 : 1)))
        case ..<1000: return Int(v.rounded()).formatted()
        case ..<1_000_000:
            let mag = pow(10, floor(log10(v)) - 1)
            return Int((v / mag).rounded() * mag).formatted()
        default: return (v / 1_000_000).formatted(.number.precision(.fractionLength(1))) + " million"
        }
    }

    /// How long an average US home would run on this much electricity.
    static func homeTime(_ kWh: Double) -> String {
        let days = kWh / homeKWhPerDay
        if days < 1 { let h = days * 24; return "\(approx(h)) hour\(h >= 0.95 && h < 1.05 ? "" : "s")" }
        return "\(approx(days)) day\(days >= 0.95 && days < 1.05 ? "" : "s")"
    }

    /// Plain sentences for a period ("this month", "today"); also sent to the iPhone app.
    static func plain(_ f: Figures, period: String) -> [String: String] {
        let k = f.kWh.mid, co2 = f.kgCO2e.mid, w = f.waterL.mid
        return [
            "headline": "Estimated: \(period) your AI use took about \(approx(k)) kWh of electricity, about what an average US home uses in \(homeTime(k)).",
            "electricity": "About \(approx(k)) kWh. That's like charging a phone \(approx(k / phoneChargeKWh)) times, or \(homeTime(k)) of an average home's power.",
            "carbon": "About \(approx(co2)) kg CO₂e. That's like driving a gas car \(approx(co2 * 1000 / gCO2PerMile)) miles.",
            "water": "About \(approx(w)) liters. That's like \(approx(w / showerL)) showers, or \(approx(w / bottleL)) bottles of water.",
            "chatbot": "The same energy as about \(approx(k * 1000 / chatbotWh)) typical chatbot questions.",
            "range": "Range: \(approx(f.kWh.low))–\(approx(f.kWh.high)) kWh, \(approx(f.kgCO2e.low))–\(approx(f.kgCO2e.high)) kg CO₂e, \(approx(f.waterL.low))–\(approx(f.waterL.high)) L.",
        ]
    }

    static let sources = "Estimates, shown as low–high ranges. Energy per token: Simon Couch (Jan 2026, inferred from API prices), range from Zeke Hausfather; Codex uses a rougher per-token figure because it doesn't split token types. Carbon: EPA eGRID 2024 US average (341 g/kWh). Water: Li et al. US averages (0.55 L/kWh on site + 3.142 L/kWh at power plants). Car: EPA 400 g CO2/mile. Home: EIA 2024, 865 kWh/month. Phone charge: EPA, 0.019 kWh. Shower: EPA WaterSense, 65 L. Typical chatbot question: Google (Aug 2025), median Gemini text prompt, 0.24 Wh."

    struct Range {
        var low = 0.0, mid = 0.0, high = 0.0
        static func + (a: Range, b: Range) -> Range { Range(low: a.low + b.low, mid: a.mid + b.mid, high: a.high + b.high) }
        func times(_ k: Double) -> Range { Range(low: low * k, mid: mid * k, high: high * k) }
        var json: [String: Double] { ["low": low, "mid": mid, "high": high] }
    }

    struct Figures {
        var tokens = 0
        var cacheRead = 0
        var kWh = Range()
        var kgCO2e: Range { kWh.times(gCO2ePerKWh / 1000) }
        var waterL: Range { kWh.times(waterLPerKWh) }
        var miles: Range { kWh.times(gCO2ePerKWh / gCO2PerMile) }
        var homeShare: Range { kWh.times(1 / homeKWhPerMonth) }
        var json: [String: Any] { ["tokens": tokens, "kWh": kWh.json, "kgCO2e": kgCO2e.json, "waterL": waterL.json] }
        static func + (a: Figures, b: Figures) -> Figures {
            Figures(tokens: a.tokens + b.tokens, cacheRead: a.cacheRead + b.cacheRead, kWh: a.kWh + b.kWh)
        }
    }

    static func claude(_ s: TokenStats) -> Figures {
        let mid = (Double(s.input) * whInput + Double(s.cacheWrite) * whCacheWrite
                   + Double(s.cacheRead) * whCacheRead + Double(s.output) * whOutput) / 1e6 / 1000
        return Figures(tokens: s.total, cacheRead: s.cacheRead,
                       kWh: Range(low: mid * lowFactor, mid: mid, high: mid * highFactor))
    }

    static func codex(_ tokens: Int) -> Figures {
        let m = Double(tokens) / 1e6 / 1000
        return Figures(tokens: tokens, kWh: Range(low: m * codexWh.low, mid: m * codexWh.mid, high: m * codexWh.high))
    }

    /// One account's estimate for one local day.
    struct Row { let day: Date; let account: String; let fig: Figures; let codex: Bool }

    /// Date ranges the report (and the iPhone app, via status.json) can show.
    enum Period: String, CaseIterable, Identifiable {
        case month, d30, d60, d90, d365, all, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .month: return "This month"
            case .d30: return "30 days"
            case .d60: return "60 days"
            case .d90: return "90 days"
            case .d365: return "365 days"
            case .all: return "All time"
            case .custom: return "Custom"
            }
        }
        var key: String { ["month": "month", "d30": "30d", "d60": "60d", "d90": "90d", "d365": "365d", "all": "all", "custom": "custom"][rawValue]! }
        var days: Int? { ["d30": 30, "d60": 60, "d90": 90, "d365": 365][rawValue] }
    }

    struct RangeResult {
        var claude = Figures(), codex = Figures()
        var byAccount: [(name: String, figures: Figures)] = []
        var from: Date?                 // nil = all time
        var to = Date()
        var claudeStart: Date?, codexStart: Date?
        var total: Figures { claude + codex }
        var period = ""                 // "in the last 30 days", "since Sep 27"…
        /// Plain note when the range reaches back before the saved history.
        var note: String?
    }

    struct Summary {
        var today = Figures(), month = Figures(), lastMonth = Figures()       // Claude Code
        var codexToday = Figures(), codexMonth = Figures(), codexLastMonth = Figures()
        var byAccount: [(name: String, figures: Figures)] = []                // this month, Claude + Codex
        var total: Figures { month + codexMonth }
        var rows: [Row] = []

        /// Totals for a range of local days, `from` and `to` inclusive (`from` nil = everything saved).
        func range(from: Date?, to: Date, period: String) -> RangeResult {
            let cal = Calendar.current
            let end = cal.startOfDay(for: to)
            var r = RangeResult(from: from.map { cal.startOfDay(for: $0) }, to: end)
            r.claudeStart = rows.filter { !$0.codex }.map(\.day).min()
            r.codexStart = rows.filter(\.codex).map(\.day).min()
            var accounts: [String: Figures] = [:]
            for row in rows where row.day <= end && (r.from.map { row.day >= $0 } ?? true) {
                if row.codex { r.codex = r.codex + row.fig } else { r.claude = r.claude + row.fig }
                accounts[row.account, default: Figures()] = accounts[row.account, default: Figures()] + row.fig
            }
            r.byAccount = accounts.map { ($0.key, $0.value) }.sorted { $0.figures.kWh.mid > $1.figures.kWh.mid }
            let df = DateFormatter(); df.dateFormat = "MMM d, yyyy"
            let starts = [r.claudeStart, r.codexStart].compactMap { $0 }
            if let f = r.from {
                var gaps: [String] = []
                if let c = r.claudeStart, f < c { gaps.append("Claude Code history starts \(df.string(from: c))") }
                if let c = r.codexStart, f < c { gaps.append("Codex history starts \(df.string(from: c))") }
                if !gaps.isEmpty { r.note = gaps.joined(separator: " and ") + ", so any use before then isn't counted in this range." }
                r.period = period
            } else if let first = starts.min() {
                r.period = "since \(df.string(from: first))"
                r.note = "All time means everything saved on this Mac: " + [r.claudeStart.map { "Claude Code from \(df.string(from: $0))" }, r.codexStart.map { "Codex from \(df.string(from: $0))" }].compactMap { $0 }.joined(separator: ", ") + ". Earlier use isn't recorded."
            }
            return r
        }

        func range(_ p: Period, custom: (Date, Date)? = nil) -> RangeResult {
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            switch p {
            case .month:
                return range(from: cal.date(from: cal.dateComponents([.year, .month], from: today)), to: today, period: "this month")
            case .all:
                return range(from: nil, to: today, period: "")
            case .custom:
                let (a, b) = custom ?? (today, today)
                let df = DateFormatter(); df.dateFormat = "MMM d"
                return range(from: min(a, b), to: max(a, b), period: "from \(df.string(from: min(a, b))) to \(df.string(from: max(a, b)))")
            default:
                let n = p.days ?? 30
                return range(from: cal.date(byAdding: .day, value: -(n - 1), to: today), to: today, period: "in the last \(n) days")
            }
        }
    }

    static func compute(codexHomes: [(name: String, home: URL)]) -> Summary {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let month = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        let lastMonth = cal.date(byAdding: .month, value: -1, to: month)!
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        var out = Summary()
        var accounts: [String: Figures] = [:]
        for (key, stats) in TokenHistory.load() {
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let day = f.date(from: parts[0]) else { continue }
            let fig = claude(stats)
            out.rows.append(Row(day: day, account: parts[1], fig: fig, codex: false))
            if day == today { out.today = out.today + fig }
            if day >= month { out.month = out.month + fig; accounts[parts[1], default: Figures()] = accounts[parts[1], default: Figures()] + fig }
            else if day >= lastMonth { out.lastMonth = out.lastMonth + fig }
        }
        for c in codexHomes {
            for (day, s) in CodexHistory.daily(home: c.home) {
                let fig = codex(s.input)
                out.rows.append(Row(day: day, account: c.name, fig: fig, codex: true))
                if day == today { out.codexToday = out.codexToday + fig }
                if day >= month { out.codexMonth = out.codexMonth + fig; accounts[c.name, default: Figures()] = accounts[c.name, default: Figures()] + fig }
                else if day >= lastMonth { out.codexLastMonth = out.codexLastMonth + fig }
            }
        }
        out.byAccount = accounts.map { ($0.key, $0.value) }.sorted { $0.figures.kWh.mid > $1.figures.kWh.mid }
        return out
    }

    /// For status.json (read by bin/phone-feed): today and month are Claude Code; Codex is separate.
    static func json(_ s: Summary) -> [String: Any] {
        ["estimate": true, "today": s.today.json, "month": s.month.json,
         "plain": ["today": plain(s.today + s.codexToday, period: "today"), "month": plain(s.total, period: "this month"),
                   "definitions": Dictionary(uniqueKeysWithValues: definitions.map { ($0.0, $0.1) })],
         "codex": ["today": s.codexToday.json, "month": s.codexMonth.json],
         "ranges": Dictionary(uniqueKeysWithValues: Period.allCases.filter { $0 != .custom }.map { p -> (String, Any) in
             let r = s.range(p)
             let iso = ISO8601DateFormatter()
             var d: [String: Any] = ["title": p.title, "total": r.total.json, "claude": r.claude.json, "codex": r.codex.json,
                                     "plain": plain(r.total, period: r.period), "partial": r.note != nil && r.from != nil,
                                     "to": iso.string(from: r.to)]
             if let f = r.from { d["from"] = iso.string(from: f) }
             if let n = r.note { d["note"] = n }
             return (p.key, d)
         }),
         "factors": ["whPerMTok": ["input": whInput, "cacheWrite": whCacheWrite, "cacheRead": whCacheRead, "output": whOutput],
                     "low": lowFactor, "high": highFactor, "gCO2ePerKWh": gCO2ePerKWh, "waterLPerKWh": waterLPerKWh,
                     "gCO2PerMile": gCO2PerMile, "homeKWhPerMonth": homeKWhPerMonth]]
    }

    /// "12 kWh (5–23)" style text for an estimate range.
    static func text(_ r: Range, _ unit: String, digits: Int = 0) -> String {
        func n(_ v: Double) -> String {
            let d = v < 10 && digits == 0 ? 1 : digits
            return v.formatted(.number.precision(.fractionLength(d)))
        }
        let u = unit == "%" ? unit : " " + unit
        return "\(n(r.mid))\(u) (\(n(r.low))–\(n(r.high)))"
    }
}

// MARK: - Report card

struct DayTokens: Identifiable {
    let id = UUID()
    let day: Date
    let account: String
    let stats: TokenStats
}

final class ReportModel: ObservableObject {
    @Published var days = 30
    @Published var tokenDays: [DayTokens] = []
    @Published var snapshots: [UsageSnapshot] = []
    @Published var loading = true
    @Published var updating = false
    @Published var allDays: [DayTokens] = []
    @Published var codexDays: [DayTokens] = []      // all history, from Codex's database
    @Published var pattern: TokenCounter.WorkPattern?
    @Published var allSnapshots: [UsageSnapshot] = []
    @Published var selectedMonth: Date?
    @Published var footprint: Footprint.Summary?
    @Published var fpPeriod: Footprint.Period = .month
    @Published var fpFrom = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    @Published var fpTo = Date()

    /// Lean score from value per $1 paid this month.
    static func grade(_ multiple: Double) -> (letter: String, label: String) {
        switch multiple {
        case 5...: return ("S", "Legendary value")
        case 3..<5: return ("A", "Excellent value")
        case 2..<3: return ("B", "Good value")
        case 1..<2: return ("C", "Breaking even")
        default: return ("D", "Paying more than it's worth")
        }
    }

    /// Days in a row (ending today) on which paid extra usage didn't grow, from the snapshots.
    var leanStreak: (days: Int, tracked: Int) {
        let cal = Calendar.current
        var perDay: [Date: [String: Double]] = [:]
        for s in allSnapshots where s.provider == "claude" {
            guard let u = s.extraUsed else { continue }
            let d = cal.startOfDay(for: s.t)
            perDay[d, default: [:]][s.account] = max(perDay[d]?[s.account] ?? 0, u)
        }
        let days = perDay.keys.sorted()
        guard days.count >= 2 else { return (0, days.count) }
        var streak = 0
        for i in stride(from: days.count - 1, through: 1, by: -1) {
            let today = perDay[days[i]]!.values.reduce(0, +)
            let before = perDay[days[i - 1]]!.values.reduce(0, +)
            let newMonth = !cal.isDate(days[i], equalTo: days[i - 1], toGranularity: .month)
            if newMonth ? today == 0 : today <= before + 0.01 { streak += 1 } else { break }
        }
        return (streak, days.count)
    }
    let store: AccountStore
    private var reloads = 0

    init(store: AccountStore) { self.store = store; reload(); Spend.shared.refresh() }

    func reload() {
        let accounts = store.accounts
        let since = Calendar.current.startOfDay(for: Date().addingTimeInterval(-Double(days - 1) * 86_400))
        // Show the saved daily totals right away, then recount from transcripts in the background.
        reloads += 1
        let run = reloads
        if tokenDays.isEmpty { loading = true }
        DispatchQueue.global(qos: .userInitiated).async {
            let saved = TokenHistory.rows(since: since, missingFrom: [])
            guard !saved.isEmpty else { return }
            let all = History.load(since: .distantPast)
            DispatchQueue.main.async {
                guard run == self.reloads else { return }
                self.tokenDays = saved.sorted { $0.day < $1.day }
                self.snapshots = all.filter { $0.t >= since }
                self.allSnapshots = all
                self.loading = false
            }
        }
        updating = true
        let codex = store.others.filter { $0.app == .codex }
        CodexReader.queue.async {
            var rows: [DayTokens] = []
            for o in codex {
                for (day, s) in CodexHistory.daily(home: o.codexHome) {
                    rows.append(DayTokens(day: day, account: "Codex \(o.name)", stats: s))
                }
            }
            DispatchQueue.main.async { self.codexDays = rows.sorted { $0.day < $1.day } }
        }
        TokenCounter.queue.async {
            var rows: [DayTokens] = []
            for a in accounts {
                for (day, s) in TokenCounter.daily(profile: a.profileURL, since: since) {
                    rows.append(DayTokens(day: day, account: a.name, stats: s))
                }
            }
            for (day, s) in TokenCounter.dailyOther(excluding: accounts.map(\.profileURL), since: since) {
                rows.append(DayTokens(day: day, account: "Terminal & remote", stats: s))
            }
            TokenHistory.save(rows)
            let fp = Footprint.compute(codexHomes: codex.map { ($0.isMain ? "Codex" : "Codex \($0.name)", $0.codexHome) })
            DispatchQueue.main.async { self.footprint = fp }
            rows += TokenHistory.rows(since: since, missingFrom: rows)
            let pat = TokenCounter.pattern(profiles: accounts.map(\.profileURL), since: Date().addingTimeInterval(-7 * 86_400))
            DispatchQueue.main.async { self.pattern = pat }
            let all = History.load(since: .distantPast)
            DispatchQueue.main.async {
                self.tokenDays = rows.sorted { $0.day < $1.day }
                self.snapshots = all.filter { $0.t >= since }
                self.loading = false
                self.updating = false
                if since <= Calendar.current.startOfDay(for: Date().addingTimeInterval(-29 * 86_400)) || self.allDays.isEmpty {
                    self.allDays = rows
                }
                self.allSnapshots = all
            }
        }
    }

    /// Money paid today, measured: the growth in Claude extra usage since the last reading before today,
    /// plus payment-ledger charges dated today. `complete` is false when an account has no earlier
    /// reading this month to measure from.
    func paidToday() -> (amount: Double, complete: Bool) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let month = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        var extra = 0.0, complete = true
        let snaps = allSnapshots.filter { $0.provider == "claude" && $0.extraUsed != nil && $0.t >= month }
        for (_, list) in Dictionary(grouping: snaps, by: \.account) {
            guard let now = list.filter({ $0.t >= today }).compactMap(\.extraUsed).max() else { continue }
            if let before = list.filter({ $0.t < today }).compactMap(\.extraUsed).max() { extra += max(0, now - before) }
            else if today == month { extra += now }
            else { complete = false }
        }
        let ledger = Spend.shared.payments.filter { cal.isDate($0.date, inSameDayAs: Date()) }.map(\.amount).reduce(0, +)
        return (extra + ledger, complete)
    }

    func total(_ account: String? = nil) -> TokenStats {
        var t = TokenStats()
        for r in tokenDays where account == nil || r.account == account {
            t.input += r.stats.input; t.output += r.stats.output
            t.cacheWrite += r.stats.cacheWrite; t.cacheRead += r.stats.cacheRead
            t.value += r.stats.value
            for (m, n) in r.stats.byModel { t.byModel[m, default: 0] += n }
        }
        return t
    }

    struct MonthRow: Identifiable {
        let month: Date
        var tokens = TokenStats()
        var extra: Double = 0        // Claude extra usage billed that month
        var api: Double = 0          // OpenAI / Anthropic API spend that month
        var plans: Double = 0        // monthly plans (current list)
        var codex = 0                // Codex tokens (from Codex's own database)
        var codexThreads = 0
        var payments: Double = 0     // charges from the payments ledger (e.g. OpenAI / ChatGPT)
        var extraBy: [String: Double] = [:]   // Claude extra usage per account name
        var claudePlans: Double = 0  // entered plans whose name mentions Claude (current month only)
        var claudeCharges: Double = 0 // ledger charges from Anthropic
        var paid: Double { extra + api + plans + payments }
        /// What Claude alone cost: extra usage, Claude plans and Anthropic charges. Compare this, not
        /// `paid`, with the Claude Code API-price figure.
        var claudePaid: Double { extra + claudePlans + claudeCharges }
        var id: Date { month }
    }

    /// Month-by-month history: tokens and API-price value from the saved daily totals (refreshed from
    /// transcripts), spend from the recorded snapshots (the highest month-to-date figure per account).
    var months: [MonthRow] { Self.months(allDays: allDays, codexDays: codexDays, snapshots: allSnapshots) }

    static func months(allDays: [DayTokens], codexDays: [DayTokens], snapshots allSnapshots: [UsageSnapshot]) -> [MonthRow] {
        let cal = Calendar.current
        func monthOf(_ d: Date) -> Date { cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d }
        var rows: [Date: MonthRow] = [:]
        let live = Set(allDays.map { "\($0.day.timeIntervalSince1970)|\($0.account)" })
        let saved = TokenHistory.rows(since: .distantPast, missingFrom: allDays).filter {
            !live.contains("\($0.day.timeIntervalSince1970)|\($0.account)")
        }
        for r in codexDays {
            let m = monthOf(r.day)
            var row = rows[m] ?? MonthRow(month: m)
            row.codex += r.stats.input
            row.codexThreads += r.stats.sessions
            rows[m] = row
        }
        for r in allDays + saved {
            let m = monthOf(r.day)
            var row = rows[m] ?? MonthRow(month: m)
            row.tokens.input += r.stats.input; row.tokens.output += r.stats.output
            row.tokens.cacheWrite += r.stats.cacheWrite; row.tokens.cacheRead += r.stats.cacheRead
            row.tokens.value += r.stats.value
            for (k, n) in r.stats.byModel { row.tokens.byModel[k, default: 0] += n }
            rows[m] = row
        }
        var peak: [String: Double] = [:]   // "month|provider|account" → highest month-to-date spend
        var names: [String: String] = [:]
        for s in allSnapshots {
            guard let used = s.extraUsed else { continue }
            let key = "\(monthOf(s.t).timeIntervalSince1970)|\(s.provider)|\(s.account)"
            peak[key] = max(peak[key] ?? 0, used)
            names[key] = s.name
        }
        for (key, used) in peak {
            let parts = key.split(separator: "|")
            let m = Date(timeIntervalSince1970: Double(parts[0]) ?? 0)
            var row = rows[m] ?? MonthRow(month: m)
            if parts[1] == "claude" {
                row.extra += used
                row.extraBy[names[key] ?? String(parts[2]), default: 0] += used
            } else { row.api += used }
            rows[m] = row
        }
        let plans = Spend.shared.subscriptionTotal
        for p in Spend.shared.payments {
            let m = monthOf(p.date)
            var row = rows[m] ?? MonthRow(month: m)
            row.payments += p.amount
            if p.provider.localizedCaseInsensitiveContains("anthropic") { row.claudeCharges += p.amount }
            rows[m] = row
        }
        // Plans are a current list with no start dates, so they only count toward this month;
        // earlier months show what was actually recorded.
        let claudePlans = Spend.shared.subscriptions.filter { $0.name.localizedCaseInsensitiveContains("claude") }
            .map(\.monthly).reduce(0, +)
        let now = monthOf(Date())
        if rows[now] == nil { rows[now] = MonthRow(month: now) }
        return rows.values.map { r -> MonthRow in
            var r = r
            if r.month == now { r.plans = plans; r.claudePlans = claudePlans }
            return r
        }.sorted { $0.month > $1.month }
    }

    /// Writes the per-day token history and the saved limit snapshots as two CSV files.
    func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ai-usage-\(days)d.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var csv = "date,account,sessions,input_tokens,output_tokens,cache_write_tokens,cache_read_tokens,total_tokens,api_value_usd\n"
        for r in tokenDays {
            let s = r.stats
            csv += "\(day.string(from: r.day)),\(q(r.account)),\(s.sessions),\(s.input),\(s.output),\(s.cacheWrite),\(s.cacheRead),\(s.total),\(String(format: "%.2f", s.value))\n"
        }
        try? csv.write(to: url, atomically: true, encoding: .utf8)
        let iso = ISO8601DateFormatter()
        var snaps = "time,provider,account,five_hour_pct,weekly_pct,extra_used,extra_limit,currency\n"
        for s in History.load(since: .distantPast) {
            snaps += "\(iso.string(from: s.t)),\(s.provider),\(q(s.name)),\(s.session.map { "\($0)" } ?? ""),\(s.weekly.map { "\($0)" } ?? ""),\(s.extraUsed.map { "\($0)" } ?? ""),\(s.extraLimit.map { "\($0)" } ?? ""),\(s.currency ?? "")\n"
        }
        let snapURL = url.deletingPathExtension().appendingPathExtension("snapshots.csv")
        try? snaps.write(to: snapURL, atomically: true, encoding: .utf8)
        NSWorkspace.shared.activateFileViewerSelecting([url, snapURL])
    }

    /// Plain, checkable suggestions drawn from the live numbers.
    func tips() -> [String] {
        var out: [String] = []
        if let m = months.first, m.tokens.value > 0 {
            var line = "This month's Claude Code tokens would cost \(Fmt.money(m.tokens.value.rounded(), "USD")) if billed at API list prices. "
            line += "Claude alone cost you \(Fmt.money(m.claudePaid, "USD")) this month"
            line += m.claudePlans > 0 ? " (extra usage plus your Claude plans)." : " in extra usage; your Claude plans aren't entered, so that's incomplete."
            out.append(line)
        }
        if let m = months.first, m.extra > 0 {
            let parts = m.extraBy.sorted { $0.value > $1.value }.map { "\($0.key) \(Fmt.money($0.value, "USD"))" }
            out.append("Claude extra usage this month is \(Fmt.money(m.extra, "USD")): " + parts.joined(separator: ", ") + ".")
        }
        let accts = store.accounts.compactMap { a -> (Account, UsageDetails, Double)? in
            guard let u = store.usage[a.slug], let d = u.details, let w = u.weekly?.percent else { return nil }
            return (a, d, w)
        }
        let full = accts.filter { $0.2 >= 90 }
        let roomy = accts.filter { $0.2 < 70 }.sorted { $0.2 < $1.2 }
        for f in full {
            let reset = f.1.limits.first { $0.name == "Weekly" }?.resetsAt
            if let r = roomy.first {
                out.append("\(f.0.name) is at \(Int(f.2))% of its weekly limit\(reset.map { " until " + Fmt.reset($0).replacingOccurrences(of: "resets ", with: "") } ?? ""). \(r.0.name) is at \(Int(r.2))%, so switch heavy work there first.")
            } else {
                var line = "\(f.0.name) is at \(Int(f.2))% of its weekly limit\(reset.map { " (" + Fmt.reset($0) + ")" } ?? ""), and no other account has much room left."
                if f.1.extraEnabled, !f.1.extraReached, let used = f.1.extraUsed {
                    line += " More work here is billed as extra usage (\(Fmt.money(used, f.1.currency))\(f.1.extraLimit.map { " of " + Fmt.money($0, f.1.currency) } ?? "") so far this month)."
                }
                out.append(line)
            }
        }
        for a in accts {
            if a.1.extraReached {
                out.append("\(a.0.name) hit its extra-usage cap for the month, so it stops once its plan limits run out.")
            } else if let used = a.1.extraUsed, used > 0, let r = roomy.first(where: { $0.0.slug != a.0.slug }) {
                out.append("\(a.0.name) has paid \(Fmt.money(used, a.1.currency)) in extra usage this month. Switching to \(r.0.name) when \(a.0.name) runs out uses plan allowance you already pay for.")
            }
        }
        let t = total()
        if t.total > 0 {
            let readShare = Double(t.cacheRead) / Double(t.total)
            if readShare > 0.9 {
                out.append("\(Int((readShare * 100).rounded()))% of Claude Code tokens are cache reads: earlier context being sent again on each turn. A fresh session for each unrelated task sends less of it; the widget doesn't measure how much that would save.")
            }
            if let top = t.byModel.max(by: { $0.value < $1.value }), Double(top.value) / Double(t.total) > 0.85 {
                out.append("\(Int((Double(top.value) / Double(t.total) * 100).rounded()))% of tokens went to \(Fmt.model(top.key)). A lighter model for routine edits and searches may use less of the weekly limit; that isn't measured here.")
            }
        }
        if let w = pattern, w.turns > 0 {
            let heavyShare = Double(w.heavyTokens) / Double(max(w.allTokens, 1))
            if heavyShare > 0.3 {
                out.append("This week \(Int(Double(w.heavyTurns) / Double(w.turns) * 100))% of Claude Code turns re-sent over 300K tokens of context, and those turns used \(Int(heavyShare * 100))% of all tokens. Use /clear or a new session when you switch tasks, and /compact in long ones.")
            }
            if w.longSessions > 0 {
                out.append("\(w.longSessions) of \(w.sessions) sessions this week ran past 300 turns. Splitting big jobs into a plan plus smaller follow-up sessions means each turn re-sends less history.")
            }
            if !w.busiestHours.isEmpty {
                let f = DateFormatter(); f.dateFormat = "h a"
                let names = w.busiestHours.map { f.string(from: Calendar.current.date(bySettingHour: $0, minute: 0, second: 0, of: Date())!) }
                out.append("Your busiest hours are \(names.joined(separator: ", ")). Heavy work started at the beginning of a fresh 5-hour window, on the account with the most weekly room, has the most headroom before a limit.")
            }
        }
        // Across apps: point work at whichever plan still has room.
        let claudeFull = store.accounts.allSatisfy { (store.usage[$0.slug]?.weekly?.percent ?? 0) >= 90 }
        for o in store.others where o.app == .codex {
            if let w = store.codexUsage[o.id]?.weeklyPercent {
                if claudeFull && w < 70 {
                    out.append("Every Claude account is near its weekly limit, but Codex \(o.name) is only at \(Int(w))%. Hand reviews, refactors and test-writing to Codex until Claude resets.")
                } else if w >= 100 {
                    let reset = store.codexUsage[o.id]?.weeklyResets
                    out.append("Codex \(o.name) has used its whole weekly limit" + (reset.map { " until \(Fmt.when($0))" } ?? "") + ", so it can't take work before then.")
                } else if w >= 90 {
                    out.append("Codex \(o.name) is at \(Int(w))% of its weekly limit, with \(100 - Int(w))% left.")
                }
            }
        }
        if out.isEmpty {
            out.append(accts.isEmpty ? "No usage has loaded yet, so there's nothing to suggest."
                                     : "No account is above 90% of its weekly limit and none is billing extra usage right now.")
        }
        return out
    }

    // MARK: Feedback notes

    struct Note: Codable, Identifiable { var id = UUID(); var date: Date; var text: String }
    static let notesFile = History.dir.appendingPathComponent("feedback.json")
    @Published var notes: [Note] = ReportModel.loadNotes()
    static func loadNotes() -> [Note] {
        guard let d = try? Data(contentsOf: ReportModel.notesFile) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([Note].self, from: d)) ?? []
    }

    func addNote(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        notes.insert(Note(date: Date(), text: t), at: 0)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: History.dir, withIntermediateDirectories: true)
        if let d = try? enc.encode(notes) { try? d.write(to: Self.notesFile, options: .atomic) }
    }

    /// A summary of the numbers, the coach's suggestions and the user's notes, to talk through with Claude.
    func discussionPrompt(extra: Double) -> String {
        let cur = months.first
        var lines = ["Help me improve how I use my AI tools. Here's my usage summary from \(Product.name):", ""]
        if let m = cur {
            lines.append("- This month: \(Fmt.tokens(m.tokens.total)) Claude Code tokens (\(Fmt.money(m.tokens.value.rounded(), "USD")) if billed at API list prices); \(Fmt.tokens(m.codex)) Codex tokens.")
            lines.append("- Paid this month: \(Fmt.money(m.paid, "USD")) (extra usage \(Fmt.money(extra, "USD")), " + (m.plans > 0 ? "plans \(Fmt.money(m.plans, "USD"))" : "plans not entered, so this is incomplete") + ").")
        }
        for a in store.accounts {
            if let w = store.usage[a.slug]?.weekly?.percent { lines.append("- Claude \(a.name): \(Int(w))% of weekly limit.") }
        }
        for o in store.others where o.app == .codex {
            if let w = store.codexUsage[o.id]?.weeklyPercent { lines.append("- Codex \(o.name): \(Int(w))% of weekly limit.") }
        }
        lines += ["", "What the widget's coach suggests:"] + tips().map { "- " + $0 }
        if !notes.isEmpty {
            lines += ["", "My notes and feedback:"] + notes.prefix(10).map { "- " + $0.text }
        }
        lines += ["", "What should I change first, and what patterns do you see?"]
        return lines.joined(separator: "\n")
    }
}

struct StatCard: View {
    let title: String
    let value: String
    var detail = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.body).foregroundStyle(.secondary)
            Text(value).font(Theme.bigNumber).lineLimit(1).minimumScaleFactor(0.7)
            if !detail.isEmpty { Text(detail).font(Theme.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
        .card(padding: 12, radius: 14)
    }
}

/// One app or account in the report's "Right now" grid: tighter limit, when it frees up.
struct AppNowCard: View {
    let target: WorkTarget
    let isPick: Bool
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let used = 100 - target.room
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(target.name).font(Theme.cardTitle).lineLimit(1)
                Spacer(minLength: 0)
                if isPick {
                    Text("Next").font(.system(size: 9, weight: .semibold)).foregroundStyle(.green)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.green.opacity(0.15)))
                } else if target.paysExtra && target.blocked {
                    Text("Paying").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.alert)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.alert.opacity(0.15)))
                }
            }
            Text("\(Int(used.rounded()))%").font(Theme.bigNumber)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(meterColor(used)).frame(width: max(3, 126 * CGFloat(min(used, 100) / 100)))
            }
            .frame(width: 126, height: 4)
            let reset = target.blocked ? target.freesAt
                : (target.short != nil && (target.short ?? 0) >= (target.weekly ?? 0)) ? target.shortResets : target.weeklyResets
            Text(reset.map { (target.blocked ? "Frees up " : "Resets ") + Fmt.when($0) } ?? " ")
                .font(Theme.caption).foregroundStyle(.secondary)
        }
        .card(padding: 12, radius: 14)
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .help("Open \(target.name)")
    }
}

/// One Report tab with its own scroll position. Showing or hiding it only flips its opacity. Its content
/// is redrawn while `live`, or once when `catchUps` moves, after a switch to a tab whose data has changed.
struct ReportPage<Content: View>: View {
    let active: Bool
    let live: Bool
    let catchUps: Int
    @ViewBuilder let content: () -> Content

    private struct Held: View, Equatable {
        let live: Bool
        let catchUps: Int
        let content: () -> Content
        static func == (a: Self, b: Self) -> Bool { a.catchUps == b.catchUps && !(a.live && b.live) }
        var body: some View { ScrollView { content() } }
    }

    var body: some View {
        Held(live: live, catchUps: catchUps, content: content)
            .equatable()
            .opacity(active ? 1 : 0)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
            .disabled(!active)      // keeps a hidden text field out of keyboard focus
    }
}

/// Stacks the Report's pages. A hidden page keeps the size it last had, so resizing the window lays out only the one on show.
struct ReportPages: Layout {
    struct Name: LayoutValueKey { static let defaultValue = "" }
    struct Shown: LayoutValueKey { static let defaultValue = false }

    func makeCache(subviews: Subviews) -> [String: CGSize] { [:] }
    func updateCache(_ cache: inout [String: CGSize], subviews: Subviews) {}
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout [String: CGSize]) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout [String: CGSize]) {
        for page in subviews {
            let name = page[Name.self]
            if page[Shown.self] { cache[name] = bounds.size }
            page.place(at: bounds.origin, proposal: ProposedViewSize(cache[name] ?? bounds.size))
        }
    }
}

/// The Report: four tabs. Now (limits, spend, footprint), Money (budget, plans, expenses, value),
/// Projects (projects and when the work happens) and Ideas (manager brief and backlog).
struct ReportView: View {
    @ObservedObject var model: ReportModel
    @ObservedObject var store: AccountStore
    @ObservedObject var spend = Spend.shared
    @ObservedObject var budget = Budget.shared
    @State private var draft = ""
    @State private var copied = false
    @ObservedObject private var nav = ReportNav.shared
    @ObservedObject private var projects = ProjectStore.shared
    /// Tabs built so far. A built tab stays in place, hidden, so going back to it costs nothing.
    @State private var built: Set<String> = []
    @State private var live = ReportNav.normalized(ReportNav.shared.tab)
    @State private var catchUps: [String: Int] = [:]
    /// Tabs whose data changed since they last drew. A class, so noting it doesn't redraw anything.
    private final class Stale { var tabs = Set<String>() }
    @State private var stale = Stale()
    private var tab: String { ReportNav.normalized(nav.tab) }

    var body: some View {
        ReportPages {
            page("now") { nowTab }
            page("money") { moneyTab }
            page("projects") {
                ProjectsView(store: store)
                TrendsView(model: model, store: store)
            }
            page("ideas") {
                section("Manager brief") { ManagerView(store: store) }
                section("Ideas") { IdeasView(store: store) }
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .task {
            for t in ReportNav.tabs {
                try? await Task.sleep(for: .milliseconds(300))
                built.insert(t)
            }
        }
        .onChange(of: tab) { old, new in
            built.insert(new)
            if old == "projects" { projects.lock() }
            // After the switch has drawn: the tab's content catches up, and these used to run as a tab appeared.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard tab == new else { return }
                live = new
                if stale.tabs.remove(new) != nil { catchUps[new, default: 0] += 1 }
                switch new {
                case "money": PlanStore.shared.sync(store)
                case "projects":
                    projects.refreshReport()
                    projects.refreshIfStale(accounts: store.accounts, codexHomes: store.others.filter { $0.app == .codex }.map(\.codexHome))
                case "ideas": IdeaStore.shared.reloadIfChanged()
                default: break
                }
            }
        }
        .onReceive(model.objectWillChange.merge(with: store.objectWillChange, spend.objectWillChange, budget.objectWillChange)) { _ in
            stale.tabs = Set(ReportNav.tabs).subtracting(live == tab ? [live] : [])
        }
        .onChange(of: model.days) { _, _ in model.reload() }
        // The four tabs sit in the toolbar (glass on macOS 26); the day range and Export at its right.
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Tab", selection: Binding(get: { tab }, set: { nav.tab = $0 })) {
                    Text("Now").tag("now")
                    Text("Money").tag("money")
                    Text("Projects").tag("projects")
                    Text("Ideas").tag("ideas")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if tab == "now" {
                    Picker("Range", selection: $model.days) {
                        Text("Last 7 days").tag(7)
                        Text("Last 30 days").tag(30)
                        Text("Last 90 days").tag(90)
                        Text("Last year").tag(365)
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button("Export") { model.exportCSV() }.help("Export CSV…")
                }
                if tab == "money" || tab == "projects" {
                    Button { projects.unlocked ? projects.lock() : projects.unlock() } label: {
                        Image(systemName: projects.unlocked ? "lock.open" : "lock")
                    }
                    .help(projects.unlocked ? "Hide income and profit" : "Show income and profit (Touch ID)")
                    .accessibilityLabel(projects.unlocked ? "Lock private money" : "Unlock private money")
                }
            }
        }
    }

    @ViewBuilder private func page<C: View>(_ name: String, @ViewBuilder _ content: @escaping () -> C) -> some View {
        if built.contains(name) || name == tab {
            ReportPage(active: name == tab, live: name == tab && name == live, catchUps: catchUps[name] ?? 0) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 12) {
                        Brand.mark(40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Product.name).font(Theme.headline(26))
                            Text(Date(), format: .dateTime.weekday(.wide).month(.wide).day())
                                .font(Theme.body).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    content()
                }
                .padding(.horizontal, 22)
                .padding(.top, 2)
                .padding(.bottom, 22)
            }
            .layoutValue(key: ReportPages.Name.self, value: name)
            .layoutValue(key: ReportPages.Shown.self, value: name == tab)
        }
    }

    // MARK: Now

    @ViewBuilder private var nowTab: some View {
        let t = model.total()
        let extraSum = store.extraThisMonth
        if store.targets.isEmpty {
            emptyState(store.accounts.isEmpty && store.others.isEmpty ? "No accounts yet. Add one to see its limits here."
                                                                      : "Waiting for the first usage reading.")
        } else {
            section("Right now", boxed: false) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(store.targets) { t in AppNowCard(target: t, isPick: store.pick?.id == t.id) { store.open(t) } }
                }
            }
        }

        section("Use next", boxed: false) {
            let free = store.targets.compactMap { t in t.freesAt.map { (t.name, $0) } }.filter { $0.1 > Date() }.min { $0.1 < $1.1 }
            HStack(spacing: 10) {
                StatCard(title: "Use next", value: store.pick?.name ?? "—",
                         detail: store.pick.map { "\(Int($0.room))% left" + ($0.weeklyResets.map { " · resets " + Fmt.when($0) } ?? "") } ?? "Everything is near its limit")
                StatCard(title: "Frees up next", value: free.map { Fmt.when($0.1) } ?? "—", detail: free?.0 ?? "Nothing is at its limit")
                StatCard(title: "Claude Code tokens", value: Fmt.tokens(t.total),
                         detail: "last \(model.days) days · \(Fmt.tokens(t.output)) output · \(Fmt.tokens(t.cacheRead)) cache read")
            }
            let upcoming = store.targets.flatMap { w in
                [("5h", w.short, w.shortResets), (w.id.hasPrefix("cursor:") ? "month" : "week", w.weekly, w.weeklyResets)].compactMap { l, p, r -> (String, Date)? in
                    guard let p, p >= 50, let r, r > Date() else { return nil }
                    return ("\(w.name) \(l) \(Fmt.when(r))", r)
                }
            }.sorted { $0.1 < $1.1 }.prefix(6)
            if !upcoming.isEmpty {
                Text("Frees up: " + upcoming.map(\.0).joined(separator: " · "))
                    .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.leading, 4)
            }
        }

        section("Usage by day") { UsageDaysView(range: model.days) }

        section("AI spend this month") {
            let ledger = spend.paid(inMonthOf: Date())
            let total = extraSum + spend.apiTotal + spend.subscriptionTotal + ledger
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.money(total, "USD")).font(.system(size: 22, weight: .bold).monospacedDigit())
                Spacer()
                Button("Budget & plans…") { nav.tab = "money" }
            }
            spendRow("Claude extra usage", extraSum)
            ForEach(APIProvider.allCases) { p in
                if let s = spend.api[p] {
                    spendRow(p.title + (s.error != nil ? " (couldn't load)" : " · \(Fmt.tokens(s.totalTokens)) tokens"), s.cost)
                }
            }
            ForEach(spend.subscriptions) { sub in spendRow(sub.name, sub.monthly) }
            ForEach(Array(Set(spend.payments.map(\.provider))).sorted(), id: \.self) { prov in
                let amt = spend.paid(inMonthOf: Date(), provider: prov)
                if amt > 0 { spendRow("\(prov) charges", amt) }
            }
            if spend.subscriptions.isEmpty && spend.payments.isEmpty {
                emptyState("Your plans and charges aren't in yet, so this total is incomplete.")
            }
        }

        section(model.updating && !model.loading ? "Limits over time · updating…" : "Limits over time") {
            Text("Tokens per day (Claude Code + Codex)").font(Theme.cardTitle)
            if model.loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading Claude Code transcripts… the first count after launch takes a little while.")
                        .font(Theme.body).foregroundStyle(.secondary)
                }
            } else if model.tokenDays.isEmpty {
                Text("No Claude Code sessions in this range.").font(Theme.body).foregroundStyle(.secondary)
            } else {
                let since = Calendar.current.startOfDay(for: Date().addingTimeInterval(-Double(model.days - 1) * 86_400))
                Chart(model.tokenDays + model.codexDays.filter { $0.day >= since }) { r in
                    BarMark(x: .value("Day", r.day, unit: .day),
                            y: .value("Tokens", Double(r.stats.total) / 1e6))
                        .foregroundStyle(by: .value("Account", r.account))
                }
                .chartForegroundStyleScale(domain: seriesNames, range: seriesColors)
                .chartYAxisLabel("Million tokens")
                .frame(height: 160)
            }
            Text("Weekly limit").font(Theme.cardTitle).padding(.top, 6)
            let weekly = model.snapshots.filter { $0.weekly != nil }
            if !hasLine(weekly) {
                Text("History started \(historyStart). The chart fills in as the widget records a snapshot every 10 minutes.")
                    .font(Theme.body).foregroundStyle(.secondary)
            } else {
                Chart(weekly, id: \.t) { s in
                    LineMark(x: .value("Time", s.t), y: .value("Weekly %", s.weekly ?? 0))
                        .foregroundStyle(by: .value("Account", s.name))
                }
                .chartForegroundStyleScale(domain: seriesNames, range: seriesColors)
                .chartYScale(domain: 0...100)
                .frame(height: 140)
            }
            Text("Extra usage spend").font(Theme.cardTitle).padding(.top, 6)
            let extraSnaps = model.snapshots.filter { $0.extraUsed != nil }
            if !hasLine(extraSnaps) {
                Text("Fills in as snapshots are recorded.").font(Theme.body).foregroundStyle(.secondary)
            } else {
                Chart(extraSnaps, id: \.t) { s in
                    LineMark(x: .value("Time", s.t), y: .value("Spent", s.extraUsed ?? 0))
                        .foregroundStyle(by: .value("Account", s.name))
                }
                .chartForegroundStyleScale(domain: seriesNames, range: seriesColors)
                .chartYAxisLabel("USD")
                .frame(height: 140)
            }
        }

        section("Footprint") { footprint }

        Text("Tokens come from Claude Code transcripts on this Mac, going back as far as they're kept. Sessions started in a Claude window count for that account; terminal and Remote Control sessions show as Terminal & remote. Chats, Cowork and other devices only show up in the limit percentages and extra spend.")
            .font(.system(size: 10)).foregroundStyle(.secondary)
    }

    @ViewBuilder private var footprint: some View {
        if let fp = model.footprint {
            let paid = model.paidToday()
            let cur = model.months.first
            let rng = fp.range(model.fpPeriod, custom: (model.fpFrom, model.fpTo))
            let t = rng.total
            HStack(spacing: 10) {
                StatCard(title: "Paid today", value: Fmt.money(paid.amount, "USD"),
                         detail: paid.complete ? "Measured: extra usage and charges" : "Measured; some accounts have no earlier reading to compare")
                StatCard(title: "Paid this month", value: Fmt.money(cur?.paid ?? 0, "USD"),
                         detail: (cur?.plans ?? 0) > 0 ? "Measured" : "Measured; plans not entered")
            }
            let today = fp.today + fp.codexToday
            let p = Footprint.plain(t, period: rng.period)
            HStack {
                SectionHeader(title: "Estimated footprint · what it's like")
                Spacer()
                Picker("", selection: $model.fpPeriod) {
                    ForEach(Footprint.Period.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            .padding(.top, 4)
            if model.fpPeriod == .custom {
                HStack(spacing: 8) {
                    DatePicker("From", selection: $model.fpFrom, in: ...Date(), displayedComponents: .date)
                    DatePicker("to", selection: $model.fpTo, in: ...Date(), displayedComponents: .date)
                }
                .datePickerStyle(.field)
                .font(Theme.body)
                .fixedSize()
            }
            if let n = rng.note {
                Label(n, systemImage: "info.circle").font(Theme.caption).foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(p["headline"] ?? "").font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 10) {
                StatCard(title: "Electricity", value: "\(Footprint.approx(t.kWh.mid)) kWh",
                         detail: "≈ \(Footprint.approx(t.kWh.mid / Footprint.phoneChargeKWh)) phone charges · \(Footprint.homeTime(t.kWh.mid)) of a home's power")
                StatCard(title: "Climate", value: "\(Footprint.approx(t.kgCO2e.mid)) kg CO₂e",
                         detail: "≈ driving a gas car \(Footprint.approx(t.kgCO2e.mid * 1000 / Footprint.gCO2PerMile)) miles")
                StatCard(title: "Water", value: "\(Footprint.approx(t.waterL.mid)) L",
                         detail: "≈ \(Footprint.approx(t.waterL.mid / Footprint.showerL)) showers · \(Footprint.approx(t.waterL.mid / Footprint.bottleL)) bottles")
            }
            Text("Compared with typical use, that's the same energy as about \(Footprint.approx(t.kWh.mid * 1000 / Footprint.chatbotWh)) typical chatbot questions.").font(Theme.body).fixedSize(horizontal: false, vertical: true)
            Text("Today so far: about \(Footprint.approx(today.kWh.mid)) kWh, like \(Footprint.homeTime(today.kWh.mid)) of a home's power or driving \(Footprint.approx(today.kgCO2e.mid * 1000 / Footprint.gCO2PerMile)) miles.")
                .font(Theme.body).fixedSize(horizontal: false, vertical: true)
            Text("These are estimates, so the middle value is shown. " + (p["range"] ?? ""))
                .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Details: definitions, by account, sources") {
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Footprint.definitions, id: \.0) { d in
                            (Text(d.0 + ": ").fontWeight(.semibold) + Text(d.1)).font(Theme.caption).foregroundStyle(.secondary)
                        }
                    }
                    SectionHeader(title: "By account, \(model.fpPeriod == .month ? "this month" : rng.period) (estimate)").padding(.top, 4)
                    ForEach(rng.byAccount, id: \.name) { a in
                        HStack {
                            Text(a.name).font(Theme.body)
                            Spacer()
                            Text("\(Fmt.tokens(a.figures.tokens)) tokens · about \(Footprint.approx(a.figures.kWh.mid)) kWh, \(Footprint.homeTime(a.figures.kWh.mid)) of a home's power")
                                .font(Theme.body.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    let readShare = fp.month.tokens > 0 ? Double(fp.month.cacheRead) / Double(fp.month.tokens) * 100 : 0
                    let turns = model.pattern.map { $0.sessions > 0 ? Double($0.turns) / Double($0.sessions) : 0 } ?? 0
                    Text("Measured: \(Int(readShare.rounded()))% of Claude Code tokens this month were the same earlier conversation being re-read each turn (cache reads)" + (turns > 0 ? "; sessions this week averaged \(Int(turns.rounded())) back-and-forth turns." : "."))
                        .font(Theme.body).fixedSize(horizontal: false, vertical: true)
                    Text("Measured: \(Fmt.tokens(fp.total.tokens)) tokens this month so far, against \(Fmt.tokens((fp.lastMonth + fp.codexLastMonth).tokens)) in all of last month. Estimated electricity: about \(Footprint.approx(fp.total.kWh.mid)) kWh so far, against \(Footprint.approx((fp.lastMonth + fp.codexLastMonth).kWh.mid)) kWh last month.")
                        .font(Theme.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(Footprint.sources).font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            }
            .font(Theme.body)
        } else {
            Text("Counting tokens…").font(Theme.body).foregroundStyle(.secondary)
        }
    }

    // MARK: Money

    @ViewBuilder private var moneyTab: some View {
        section("Budget · this month") {
            BudgetCard(store: store)
            Text("One budget for everything AI and tech, including Claude extra usage. You get a notification at 80% and 100% of it.")
                .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        section("Revenue and spend by month") { RevenueMonths(store: store, months: model.months) }
        section("Plans", boxed: false) { PlansView(store: store) }
        section("Expenses") { ExpensesView() }
        section("Value") { valueCard }
    }

    /// Lean score up top; lifetime, months, apps, models, purchases and the coach behind disclosures.
    @ViewBuilder private var valueCard: some View {
        let t = model.total()
        let extraSum = store.extraThisMonth
        let cur = model.months.first
        let mult = (cur?.claudePlans ?? 0) > 0 && (cur?.claudePaid ?? 0) > 0 ? (cur!.tokens.value / cur!.claudePaid) : 0
        let g = ReportModel.grade(mult)
        let streak = model.leanStreak
        let st = budget.standing(store: store)
        HStack(alignment: .top, spacing: 12) {
            Text(mult > 0 ? g.letter : "–")
                .font(.system(size: 44, weight: .heavy, design: .rounded))
                .foregroundStyle(mult <= 0 ? .secondary : g.letter == "S" || g.letter == "A" ? .green : (g.letter == "B" ? .blue : (g.letter == "C" ? Theme.warn : Theme.alert)))
                .frame(width: 64, height: 64)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
            VStack(alignment: .leading, spacing: 4) {
                Text(mult > 0 ? "Lean score: " + g.label : "No lean score yet").font(.system(size: 14, weight: .semibold))
                Text(mult > 0 ? String(format: "Claude Code tokens this month would cost %.1f× what Claude cost you if billed at API list prices. Next grade at %@.", mult, nextGrade(mult))
                              : "Your Claude plans aren't entered, so what you paid this month is incomplete and no grade can be worked out. Confirm them in Plans above.")
                    .font(Theme.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(streak.tracked < 2 ? "Lean streak starts tomorrow (days without new extra-usage charges)."
                                        : "\(streak.days)-day lean streak: days without new extra-usage charges.")
                    .font(Theme.body)
            }
            Spacer()
        }
        let readShare = t.total > 0 ? Double(t.cacheRead) / Double(t.total) : 0
        let full = store.accounts.filter { (store.usage[$0.slug]?.weekly?.percent ?? 0) >= 90 }.count
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 6) {
            badge("2× API-price value (plans entered)", mult >= 2)
            badge("Under budget so far", st.ceiling > 0 && st.spent <= st.ceiling)
            badge("No extra spend this week", streak.days >= 7)
            badge("Fresh sessions (<90% cache reads)", t.total > 0 && readShare < 0.9)
            badge("An account with room left", full < store.accounts.count)
            badge("Plans entered", spend.subscriptionTotal > 0)
        }

        DisclosureGroup("Lifetime") {
            VStack(alignment: .leading, spacing: 8) {
                let all = model.months
                let first = all.last?.month
                let claude = all.map(\.tokens.total).reduce(0, +)
                let codexT = all.map(\.codex).reduce(0, +)
                let value = all.map(\.tokens.value).reduce(0, +)
                let paidAll = all.map(\.paid).reduce(0, +)
                HStack(spacing: 10) {
                    StatCard(title: "Tokens since \(first.map(monthName) ?? "—")", value: Fmt.tokens(claude + codexT),
                             detail: "Claude Code \(Fmt.tokens(claude)) · Codex \(Fmt.tokens(codexT))")
                    StatCard(title: "If billed at API prices", value: Fmt.money(value.rounded(), "USD"), detail: "Claude Code only, at list prices")
                    StatCard(title: "Paid", value: Fmt.money(paidAll, "USD"),
                             detail: spend.subscriptionTotal > 0 ? "" : "Charges and extra usage only; plans not entered")
                }
                Text("Lifetime starts with the oldest data on this Mac: Codex's thread database, the Claude Code transcripts still kept, and the billing you've entered.")
                    .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        }

        DisclosureGroup("Month by month") {
            VStack(alignment: .leading, spacing: 8) { monthByMonth }.padding(.top, 6)
        }

        DisclosureGroup("By app this month") {
            VStack(alignment: .leading, spacing: 8) {
                appRow("Claude", Paths.claudeApp,
                       "\(Fmt.tokens(cur?.tokens.total ?? 0)) Claude Code tokens · \(Fmt.money((cur?.tokens.value ?? 0).rounded(), "USD")) if billed at API list prices",
                       "extra \(Fmt.money(extraSum, "USD"))")
                ForEach(store.others.filter { $0.app == .codex }) { o in
                    let u = store.codexUsage[o.id]
                    appRow("Codex · \(o.name)", o.app.appURL,
                           "\(Fmt.tokens(cur?.codex ?? 0)) tokens in \(cur?.codexThreads ?? 0) threads" + (u?.weeklyPercent.map { " · week \(Int($0))%" } ?? ""),
                           [u?.plan?.capitalized, spend.paid(inMonthOf: Date(), provider: "OpenAI") > 0
                                ? "paid \(Fmt.money(spend.paid(inMonthOf: Date(), provider: "OpenAI"), "USD"))" : nil]
                               .compactMap { $0 }.joined(separator: " · "))
                }
                if let login = store.mainLogins[.cursor], OtherApp.cursor.installed {
                    appRow("Cursor", OtherApp.cursor.appURL,
                           login.signedIn ? (store.cursorUsage["cursor:main"].map { u in
                               "\(Int(u.percent.rounded()))% of included usage · \(Fmt.money(u.used, "USD"))" + (u.limit.map { " of " + Fmt.money($0.rounded(), "USD") } ?? "")
                           } ?? "Signed in as \(login.email ?? "you")") : "Not signed in",
                           (login.plan ?? "").replacingOccurrences(of: "_", with: " ").capitalized)
                }
                ForEach(APIProvider.allCases) { p in
                    if let a = spend.api[p] {
                        appRow(p.title, nil, a.error ?? "\(Fmt.tokens(a.totalTokens)) tokens", Fmt.money(a.cost, "USD"))
                    }
                }
            }
            .padding(.top, 6)
        }

        DisclosureGroup("By model") {
            VStack(alignment: .leading, spacing: 4) {
                let total = max(t.total, 1)
                ForEach(t.byModel.sorted { $0.value > $1.value }, id: \.key) { m in
                    DetailRow(label: Fmt.model(m.key), percent: Double(m.value) / Double(total) * 100,
                              value: Fmt.tokens(m.value), note: "\(Int((Double(m.value) / Double(total) * 100).rounded()))%")
                }
            }
            .padding(.top, 6)
        }

        DisclosureGroup("Purchase patterns") {
            VStack(alignment: .leading, spacing: 4) {
                let cl = PurchaseLog.clusters()
                if cl.isEmpty {
                    Text("No bunched-up top-ups found.").font(Theme.body).foregroundStyle(.secondary)
                } else {
                    Text("Days with several separate credit top-ups or small auto-reloads, from your billing records.")
                        .font(Theme.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ForEach(cl.prefix(12)) { c in
                        HStack {
                            Text(c.day, format: .dateTime.month(.abbreviated).day()).font(.system(size: 11).monospacedDigit()).frame(width: 60, alignment: .leading)
                            Text("\(c.provider): \(c.count) purchase\(c.count == 1 ? "" : "s")" + (c.autoCount > 0 ? " (\(c.autoCount) auto-reload)" : ""))
                                .font(Theme.body)
                            Spacer()
                            Text(Fmt.money(c.total, "USD")).font(Theme.body.weight(.medium).monospacedDigit())
                        }
                    }
                }
            }
            .padding(.top, 6)
        }

        DisclosureGroup("Coach") {
            VStack(alignment: .leading, spacing: 8) { coach(extraSum) }.padding(.top, 6)
        }
    }

    @ViewBuilder private var monthByMonth: some View {
        let months = model.months
        if months.isEmpty {
            Text("No history yet.").font(Theme.body).foregroundStyle(.secondary)
        } else {
            let idx = months.firstIndex { $0.month == model.selectedMonth } ?? 0
            let m = months[idx]
            HStack(spacing: 8) {
                Button { model.selectedMonth = months[min(idx + 1, months.count - 1)].month } label: {
                    Image(systemName: "chevron.left")
                }.disabled(idx >= months.count - 1)
                Text(monthName(m.month)).font(.system(size: 13, weight: .semibold)).frame(minWidth: 120)
                Button { model.selectedMonth = months[max(idx - 1, 0)].month } label: {
                    Image(systemName: "chevron.right")
                }.disabled(idx == 0)
                Spacer()
            }
            HStack(spacing: 10) {
                StatCard(title: "If billed at API prices", value: Fmt.money(m.tokens.value.rounded(), "USD"),
                         detail: "\(Fmt.tokens(m.tokens.total)) Claude Code tokens · Claude cost you \(Fmt.money(m.claudePaid, "USD"))" + (m.claudePlans > 0 ? "" : " (plans not entered)"))
                StatCard(title: m.plans > 0 ? "You paid" : "You paid (plans missing)", value: Fmt.money(m.paid, "USD"),
                         detail: (m.plans > 0 ? "plans \(Fmt.money(m.plans, "USD"))" : "plans not entered") + " · Claude extra " + (m.extraBy.isEmpty ? Fmt.money(m.extra, "USD") : m.extraBy.sorted { $0.value > $1.value }.map { "\($0.key) \(Fmt.money($0.value, "USD"))" }.joined(separator: " + ")) + (m.payments > 0 ? " · charges \(Fmt.money(m.payments, "USD"))" : "") + (m.api > 0 ? " · API \(Fmt.money(m.api, "USD"))" : ""))
                StatCard(title: "API-price value per $1 of Claude spend", value: multiple(m),
                         detail: m.plans == 0 ? "Can't be worked out until your plans are entered" : "at API list prices")
            }
            Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow {
                    Text("Month").gridColumnAlignment(.leading)
                    Text("Claude Code"); Text("Codex"); Text("API value"); Text("Paid (all)"); Text("Claude value / $")
                }
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(months) { r in
                    GridRow {
                        Text(monthName(r.month)).gridColumnAlignment(.leading)
                        Text(Fmt.tokens(r.tokens.total))
                        Text(r.codex > 0 ? Fmt.tokens(r.codex) : "–")
                        Text(Fmt.money(r.tokens.value.rounded(), "USD"))
                        Text(Fmt.money(r.paid, "USD"))
                        Text(multiple(r))
                    }
                    .font(.system(size: 11, weight: r.month == m.month ? .bold : .regular).monospacedDigit())
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectedMonth = r.month }
                }
            }
            Text("Value is what the same Claude Code tokens would cost on the Anthropic API at list prices (cache writes at their 5-minute or 1-hour rate, fast mode at its premium). Codex tokens come from Codex's own thread database, counted on the day each thread started; they aren't priced because Codex doesn't split input and output. Chats aren't included.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func coach(_ extraSum: Double) -> some View {
        ForEach(Array(model.tips().enumerated()), id: \.offset) { _, tip in
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "lightbulb").foregroundStyle(Theme.warn).font(.system(size: 11))
                Text(tip).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
        }
        Text("Your notes and feedback").font(.system(size: 11, weight: .semibold)).padding(.top, 6)
        TextEditor(text: $draft)
            .font(.system(size: 12))
            .frame(height: 60)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
        HStack {
            Button("Save note") { model.addNote(draft); draft = "" }.disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            Spacer()
            Button {
                if !draft.trimmingCharacters(in: .whitespaces).isEmpty { model.addNote(draft); draft = "" }
                let prompt = model.discussionPrompt(extra: extraSum)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(prompt, forType: .string)
                var c = URLComponents(string: "claude://claude.ai/new")!
                c.queryItems = [URLQueryItem(name: "q", value: prompt)]
                if let url = c.url { NSWorkspace.shared.open(url) }
                copied = true
            } label: { Label("Discuss with Claude", systemImage: "bubble.left.and.bubble.right") }
            .buttonStyle(.bordered)
        }
        if copied {
            Text("Opened a new Claude chat with your summary. It's also on your clipboard if the chat starts empty.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        ForEach(model.notes.prefix(5)) { n in
            HStack(alignment: .top, spacing: 6) {
                Text(n.date, style: .date).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                Text(n.text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One sentence plus a button into Setup.
    private func emptyState(_ sentence: String) -> some View {
        HStack(spacing: 8) {
            Text(sentence).font(Theme.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Open Setup…") { SettingsWindow.show(setup: true) }.controlSize(.small)
        }
    }

    /// Same color for an account in every chart.
    /// Every series name that can appear (Claude accounts, Codex accounts, terminal), plus any
    /// other name found in saved data — Charts traps on a value missing from the scale's domain.
    private var seriesNames: [String] {
        var names = store.accounts.map(\.name)
        names += store.others.filter { $0.app == .codex }.map { "Codex \($0.name)" }
        for n in model.tokenDays.map(\.account) + model.snapshots.map(\.name) where !names.contains(n) && n != "Terminal & remote" {
            names.append(n)
        }
        return names + ["Terminal & remote"]
    }
    private var seriesColors: [Color] {
        let palette: [Color] = [.blue, Theme.warn, .purple, .pink, .teal, .yellow, .mint, .indigo, .brown, .cyan]
        return (0..<(seriesNames.count - 1)).map { palette[$0 % palette.count] } + [.gray]
    }

    private func hasLine(_ snaps: [UsageSnapshot]) -> Bool {
        Dictionary(grouping: snaps, by: \.account).values.contains { $0.count >= 2 }
    }

    private var historyStart: String {
        guard let first = model.snapshots.first?.t else { return "today" }
        let f = DateFormatter(); f.dateStyle = .medium
        return f.string(from: first)
    }

    private func nextGrade(_ m: Double) -> String {
        for t in [1.0, 2, 3, 5] where m < t { return String(format: "%.0f×", t) }
        return "the top"
    }

    private func badge(_ title: String, _ earned: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: earned ? "checkmark.seal.fill" : "seal").foregroundStyle(earned ? .green : .secondary)
            Text(title).font(.system(size: 11)).foregroundStyle(earned ? .primary : .secondary)
        }
    }

    private func appRow(_ name: String, _ icon: URL?, _ detail: String, _ trailing: String) -> some View {
        HStack(spacing: 8) {
            if let icon { AppIcon(url: icon, size: 18) } else { Image(systemName: "key").frame(width: 18) }
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(trailing).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
    }

    private func monthName(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f.string(from: d)
    }

    /// Only when plans are entered: without them "paid" leaves out the subscriptions and the ratio flatters.
    private func multiple(_ r: ReportModel.MonthRow) -> String {
        guard r.claudePaid > 0, r.claudePlans > 0 else { return "–" }
        return String(format: "%.1f×", r.tokens.value / r.claudePaid)
    }

    private func fpRange(_ r: Footprint.Range, _ unit: String) -> String {
        let t = Footprint.text(r, unit)
        guard let open = t.range(of: "("), let close = t.range(of: ")") else { return t }
        return String(t[open.upperBound..<close.lowerBound]) + " " + unit
    }

    private func spendRow(_ name: String, _ amount: Double) -> some View {
        HStack {
            Text(name).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Text(Fmt.money(amount, "USD")).font(.system(size: 12, weight: .medium).monospacedDigit())
        }
    }

    /// A titled group. Boxed sections sit in one card; unboxed ones hold their own cards.
    @ViewBuilder private func section<C: View>(_ title: String, boxed: Bool = true, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title).padding(.leading, 4)
            if boxed {
                VStack(alignment: .leading, spacing: 8) { content() }
                    .card(padding: 14, radius: 16)
            } else {
                content()
            }
        }
    }
}

enum ReportWindow {
    private static var window: NSWindow?
    private static var model: ReportModel?

    static func show(store: AccountStore) {
        if let w = window {
            model?.reload()
            AppWindows.present(w)
            return
        }
        let w = make(store: store)
        window = w
        AppWindows.present(w)
        // Don't focus the budget field on open, which scrolls the report to the middle.
        DispatchQueue.main.async { w.makeFirstResponder(nil) }
    }

    /// The Report window, with the SwiftUI toolbar bridged into the window's (glass) toolbar.
    static func make(store: AccountStore) -> NSWindow {
        let m = ReportModel(store: store)
        model = m
        ProjectStore.shared.prepare()
        let hc = NSHostingController(rootView: ReportView(model: m, store: store).burnWindow())
        hc.sceneBridgingOptions = [.toolbars]
        let w = NSWindow(contentViewController: hc)
        AppWindows.configure(w, title: Product.name, autosave: "BurnRateReport", size: NSSize(width: 720, height: 780), min: NSSize(width: 600, height: 520))
        w.toolbarStyle = .unified
        return w
    }
}

// MARK: - Provider connections & total spend
//
// API keys live only in the login Keychain (service "local.ai-orchestrator"), never in files.
// OpenAI and Anthropic admin keys can read the organization's cost and usage reports.
// Plans without a usage API (Cursor, ChatGPT, Gemini…) are entered by hand as monthly spend.

enum Keychain {
    private static let service = "local.ai-orchestrator"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Returns the Keychain status so a failed save can be shown instead of silently dropped.
    @discardableResult static func set(_ account: String, _ value: String?) -> OSStatus {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard let value, !value.isEmpty else { return errSecSuccess }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(add as CFDictionary, nil)
    }
}

enum APIProvider: String, CaseIterable, Identifiable {
    case openai, anthropic
    var id: String { rawValue }
    var title: String { self == .openai ? "OpenAI API" : "Anthropic API" }
    var hint: String {
        self == .openai
            ? "Admin key (sk-admin-…) from platform.openai.com › Settings › Organization › Admin keys"
            : "Admin key (sk-ant-admin…) from console.anthropic.com › Settings › Admin keys"
    }
    var prefix: String { self == .openai ? "sk-admin-" : "sk-ant-admin" }
    /// Why a key failed, in plain words, with what to do.
    func explain(code: Int, message: String?) -> String {
        let detail = message.map { " (\($0))" } ?? ""
        switch (self, code) {
        case (_, 401):
            return "The key wasn't accepted: it may be mistyped, revoked or expired. Create a new one and paste it again.\(detail)"
        case (.openai, 403):
            return "This key can't read billing. OpenAI's cost data needs an Admin key (starts sk-admin-), which only an organization Owner can create at platform.openai.com › Settings › Organization › Admin keys. Project keys (sk-proj-…) get this error.\(detail)"
        case (.anthropic, 403), (.anthropic, 404):
            return "This key can't read the cost report. It needs an Admin key (starts sk-ant-admin) from an Anthropic Console organization, created by an admin at console.anthropic.com › Settings › Admin keys. Claude.ai Max accounts aren't Console organizations, so they have no admin keys.\(detail)"
        default:
            return "The provider answered with HTTP \(code).\(detail)"
        }
    }
}

struct APISpend {
    var cost: Double = 0
    var code = 0
    var inputTokens = 0, outputTokens = 0, cachedTokens = 0
    var error: String?
    var updated: Date?
    var totalTokens: Int { inputTokens + outputTokens + cachedTokens }
}

struct Subscription: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var monthly: Double
    // Rows made from a detected plan (Plans tab). Hand-entered rows leave these nil.
    var account: String? = nil      // "claude:main", "codex:main", "cursor:main"
    var plan: String? = nil         // "Max 20x"
    var source: String? = nil       // "detected"
    var confirmed: Bool? = nil      // the user confirmed or corrected the price
    var priceAsOf: String? = nil    // list price date, nil once the user typed their own
    var changedAt: Date? = nil
    var renews: Date? = nil         // next (or a past) renewal date; monthly plans roll forward from it
    var renewsSource: String? = nil // "detected" (vendor data) or "entered"
    var pendingPlan: String? = nil  // a scheduled plan change, e.g. "Pro 100" from Nov 8
    var pendingMonthly: Double? = nil
    var pendingDate: Date? = nil
    var billedVia: String? = nil    // "grok.com" when Cursor bills as an X Subscription
}

final class Spend: ObservableObject {
    static let shared = Spend()
    @Published var api: [APIProvider: APISpend] = [:]
    @Published var connected: Set<APIProvider> = []
    @Published var subscriptions: [Subscription] = [] {
        didSet {
            if let d = try? JSONEncoder().encode(subscriptions) { UserDefaults.standard.set(d, forKey: "subscriptions") }
        }
    }
    private var lastRefresh = Date.distantPast

    init() {
        if let d = UserDefaults.standard.data(forKey: "subscriptions"),
           let s = try? JSONDecoder().decode([Subscription].self, from: d) { subscriptions = s }
        connected = Set(APIProvider.allCases.filter { Keychain.get("key.\($0.rawValue)") != nil })
    }

    var subscriptionTotal: Double { subscriptions.map(\.monthly).reduce(0, +) }

    // MARK: Payments ledger — actual charges (e.g. from a provider's billing page), kept on this Mac.
    struct Payment: Codable, Identifiable, Hashable {
        var id = UUID()
        var date: Date
        var provider: String
        var item: String
        var amount: Double
        /// "AI" (model subscriptions, credits, API), "Tech" (other software, hosting, hardware) or "Other".
        /// AI and Tech count toward the tech budget; Other is kept for completeness but left out of it.
        var category: String = "AI"
        /// ProjectInfo.id when the charge is a direct cost of one project.
        var project: String?
        var isTech: Bool { category != "Other" }

        init(date: Date, provider: String, item: String, amount: Double, category: String = "AI") {
            self.date = date; self.provider = provider; self.item = item; self.amount = amount; self.category = category
        }
        // Older ledgers have no category: everything in them was AI spend.
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            date = try c.decode(Date.self, forKey: .date)
            provider = try c.decode(String.self, forKey: .provider)
            item = try c.decode(String.self, forKey: .item)
            amount = try c.decode(Double.self, forKey: .amount)
            category = try c.decodeIfPresent(String.self, forKey: .category) ?? "AI"
            project = try c.decodeIfPresent(String.self, forKey: .project)
        }
    }
    static let categories = ["AI", "Tech", "Other"]

    /// Guesses a category from the description: AI vendors → AI, software/hosting words → Tech, else Other.
    /// Bookkeeping exports label rows with Schedule C categories: software is AI or
    /// Tech by vendor, equipment is Tech, everything else (meals, shipping, personal…) is Other.
    static func scheduleC(_ category: String, _ desc: String) -> String {
        let c = category.lowercased()
        if c.isEmpty { return guessCategory(desc) }
        if c.contains("software") { return guessCategory(desc) == "AI" ? "AI" : "Tech" }
        if c.contains("computer") || c.contains("equipment") { return guessCategory(desc) == "AI" ? "AI" : "Tech" }
        return guessCategory(desc) == "AI" ? "AI" : "Other"
    }

    static func guessCategory(_ text: String) -> String {
        let t = text.lowercased()
        let ai = ["anthropic", "claude", "openai", "chatgpt", "cursor", "codex", "gemini", "google ai", "perplexity", "midjourney", "elevenlabs", "replicate", "huggingface", "hugging face", "openrouter", "mistral", "cohere", "runway", "copilot"]
        if ai.contains(where: t.contains) { return "AI" }
        let tech = ["github", "vercel", "netlify", "aws", "amazon web", "google cloud", "gcp", "azure", "digitalocean", "cloudflare", "apple.com/bill", "apple developer", "jetbrains", "figma", "notion", "slack", "zoom", "dropbox", "icloud", "google workspace", "1password", "adobe", "domain", "namecheap", "godaddy", "heroku", "supabase", "neon", "render", "linear", "twilio", "stripe", "shopify", "software", "hosting", "saas", "app store", "microsoft"]
        if tech.contains(where: t.contains) { return "Tech" }
        return "Other"
    }

    /// Reads a bank, card or billing CSV: finds the date, description and amount columns by their
    /// header names (or position when there's no header) and returns ledger rows ready to review.
    /// Negative amounts are charges in most bank exports, so the sign is normalised to positive spend;
    /// refunds (the other sign) are kept as negative rows. Nothing is invented: rows without a parsable
    /// date or amount are reported back as skipped.
    static func importCSV(_ text: String) -> (rows: [Payment], skipped: Int) {
        func split(_ line: String) -> [String] {
            var out: [String] = [], cur = "", q = false
            for ch in line {
                if ch == "\"" { q.toggle() }
                else if ch == "," && !q { out.append(cur); cur = "" }
                else { cur.append(ch) }
            }
            out.append(cur)
            return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return ([], 0) }
        let fmts: [DateFormatter] = ["MM/dd/yyyy hh:mma", "MM/dd/yyyy h:mma", "MM/dd/yyyy HH:mm", "yyyy-MM-dd", "MM/dd/yyyy", "M/d/yyyy", "MM/dd/yy", "M/d/yy", "dd/MM/yyyy", "yyyy/MM/dd", "MMM d, yyyy", "MMM d yyyy", "d MMM yyyy", "MMMM d, yyyy", "yyyy-MM-dd'T'HH:mm:ss"].map {
            let f = DateFormatter(); f.dateFormat = $0; f.locale = Locale(identifier: "en_US_POSIX"); return f
        }
        func date(_ s: String) -> Date? {
            let t = s.trimmingCharacters(in: .whitespaces)
            for f in fmts { if let d = f.date(from: t) { return d } }
            if let d = ISO8601DateFormatter().date(from: t) { return d }
            return nil
        }
        func money(_ s: String) -> Double? {
            var t = s.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "USD", with: "").trimmingCharacters(in: .whitespaces)
            var neg = false
            if t.hasPrefix("(") && t.hasSuffix(")") { neg = true; t = String(t.dropFirst().dropLast()) }
            guard let v = Double(t) else { return nil }
            return neg ? -v : v
        }
        let header = split(lines[0]).map { $0.lowercased() }
        func col(_ names: [String]) -> Int? { header.firstIndex { h in names.contains { h == $0 || h.contains($0) } } }
        let hasHeader = header.contains { ["date", "amount", "description", "merchant", "vendor", "memo", "name", "total", "charge"].contains(where: $0.contains) }
        var dateCol = col(["transaction date", "date", "posted"]), amtCol = col(["amount", "total", "charge", "debit"]),
            descCol = col(["description", "merchant", "vendor", "name", "memo", "payee", "details", "narrative", "item"]),
            catCol = col(["category"])
        let body = hasHeader ? Array(lines.dropFirst()) : lines
        if !hasHeader || dateCol == nil || amtCol == nil {
            // No usable header: take the first column that parses as a date, the last that parses as money, and the longest text.
            let sample = split(body[0])
            dateCol = sample.firstIndex { date($0) != nil }
            amtCol = sample.indices.reversed().first { money(sample[$0]) != nil && $0 != dateCol }
            descCol = sample.indices.filter { $0 != dateCol && $0 != amtCol }.max { sample[$0].count < sample[$1].count }
        }
        guard let dc = dateCol, let ac = amtCol else { return ([], body.count) }
        var rows: [Payment] = [], skipped = 0
        var signs = 0
        for line in body {
            let f = split(line)
            guard f.count > max(dc, ac), let d = date(f[dc]), let a = money(f[ac]) else { skipped += 1; continue }
            let desc = descCol.flatMap { $0 < f.count ? f[$0] : nil } ?? ""
            let provider = desc.split(whereSeparator: { $0 == " " || $0 == "*" || $0 == "-" }).first.map(String.init) ?? "Import"
            let rawCat = catCol.flatMap { $0 < f.count ? f[$0] : nil } ?? ""
            let cat = categories.first { $0.lowercased() == rawCat.lowercased() } ?? scheduleC(rawCat, desc)
            signs += a < 0 ? -1 : 1
            rows.append(Payment(date: d, provider: provider.prefix(1).uppercased() + provider.dropFirst(), item: desc, amount: a, category: cat))
        }
        // Most bank exports list charges as negatives: flip so spend is positive and refunds negative.
        if signs < 0 { rows = rows.map { var r = $0; r.amount = -r.amount; return r } }
        return (rows, skipped)
    }
    /// YNAB's register export (Account, Date, Payee, Category Group/Category, Memo, Outflow, Inflow).
    /// Outflow minus inflow is the amount, so refunds come out negative and stay in the ledger: a card
    /// account's inflows are refunds, never income. Transfers (card payments) and starting balances are
    /// skipped. "Business Expenses" rows are AI or Tech by payee; everything else is Other, which is kept
    /// for reflection but left out of the tech budget. Returns nil for files that aren't YNAB exports.
    static func importYNAB(_ text: String) -> (rows: [Payment], skipped: Int)? {
        func split(_ line: String) -> [String] {
            var out: [String] = [], cur = "", q = false
            for ch in line {
                if ch == "\"" { q.toggle() } else if ch == "," && !q { out.append(cur); cur = "" } else { cur.append(ch) }
            }
            out.append(cur)
            return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = lines.first else { return nil }
        let header = split(first).map { $0.replacingOccurrences(of: "\u{feff}", with: "").lowercased() }
        func col(_ name: String) -> Int? { header.firstIndex(of: name) }
        guard let dc = col("date"), let pc = col("payee"), let oc = col("outflow"), let ic = col("inflow") else { return nil }
        let cc = col("category"), gc = col("category group"), mc = col("memo")
        let f = DateFormatter(); f.dateFormat = "MM/dd/yyyy"; f.locale = Locale(identifier: "en_US_POSIX")
        func money(_ s: String) -> Double { Double(s.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")) ?? 0 }
        var rows: [Payment] = [], skipped = 0
        for line in lines.dropFirst() {
            let c = split(line)
            guard c.count > max(dc, pc, oc, ic), let d = f.date(from: c[dc]) else { skipped += 1; continue }
            let payee = c[pc]
            let category = cc.flatMap { $0 < c.count ? c[$0] : nil } ?? ""
            let group = gc.flatMap { $0 < c.count ? c[$0] : nil } ?? ""
            if payee.hasPrefix("Transfer :") || payee == "Starting Balance" || group.lowercased().hasPrefix("inflow") { continue }
            let amount = money(c[oc]) - money(c[ic])
            if amount == 0 { continue }
            let memo = mc.flatMap { $0 < c.count ? c[$0] : nil } ?? ""
            let cat = category == "Business Expenses" ? (guessCategory(payee + " " + memo) == "AI" ? "AI" : "Tech") : "Other"
            let provider = payee.split(whereSeparator: { $0 == " " || $0 == "*" }).first.map(String.init) ?? "Import"
            rows.append(Payment(date: d, provider: provider, item: cat == "Other" && !category.isEmpty ? "\(payee) · \(category)" : payee,
                                amount: amount, category: cat))
        }
        return (rows, skipped)
    }

    static let paymentsFile = History.dir.appendingPathComponent("payments.json")
    @Published var payments: [Payment] = {
        guard let d = try? Data(contentsOf: Spend.paymentsFile) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return ((try? dec.decode([Payment].self, from: d)) ?? []).sorted { $0.date > $1.date }
    }() {
        didSet {
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
            try? FileManager.default.createDirectory(at: History.dir, withIntermediateDirectories: true)
            if let d = try? enc.encode(payments) { try? d.write(to: Spend.paymentsFile, options: .atomic) }
        }
    }

    func paid(inMonthOf day: Date, provider: String? = nil) -> Double {
        payments.filter {
            Calendar.current.isDate($0.date, equalTo: day, toGranularity: .month) && (provider == nil || $0.provider == provider)
        }.map(\.amount).reduce(0, +)
    }
    /// Ledger charges in a month by category ("AI", "Tech", "Other").
    func paid(inMonthOf day: Date, category: String) -> Double {
        payments.filter { Calendar.current.isDate($0.date, equalTo: day, toGranularity: .month) && $0.category == category }
            .map(\.amount).reduce(0, +)
    }
    var apiTotal: Double { api.values.map(\.cost).reduce(0, +) }

    func setKey(_ p: APIProvider, _ key: String?) {
        Keychain.set("key.\(p.rawValue)", key?.trimmingCharacters(in: .whitespacesAndNewlines))
        connected = Set(APIProvider.allCases.filter { Keychain.get("key.\($0.rawValue)") != nil })
        if key == nil { api[p] = nil }
        refresh(force: true)
    }

    func refresh(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastRefresh) > 1800 else { return }
        lastRefresh = Date()
        for p in APIProvider.allCases {
            guard let key = Keychain.get("key.\(p.rawValue)") else { continue }
            Task {
                let s = p == .openai ? await Self.openAI(key) : await Self.anthropic(key)
                await MainActor.run {
                    self.api[p] = s
                    if s.error == nil {
                        History.record(UsageSnapshot(t: Date(), provider: p.rawValue, account: "api", name: p.title,
                                                     session: nil, weekly: nil, limits: nil, extraUsed: s.cost,
                                                     extraLimit: nil, currency: "USD"))
                    }
                }
            }
        }
    }

    private static var monthStart: Date {
        Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? Date()
    }

    private static func num(_ any: Any?) -> Double {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) ?? 0 }
        if let d = any as? [String: Any] { return num(d["value"]) }
        return 0
    }

    /// GETs every page of a bucketed report and returns each bucket's results.
    private static func pages(_ base: String, page: String, headers: [String: String]) async throws -> [[String: Any]] {
        var results: [[String: Any]] = []
        var next: String?
        for _ in 0..<12 {
            var url = base
            if let next { url += "&\(page)=\(next.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? next)" }
            var req = URLRequest(url: URL(string: url)!)
            headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            guard code == 200 else {
                let raw = String(data: data.prefix(300), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let msg = ((obj["error"] as? [String: Any])?["message"] as? String) ?? (obj["error"] as? String)
                    ?? (raw?.hasPrefix("<") == false && raw?.isEmpty == false ? raw : nil)
                throw NSError(domain: "spend", code: code, userInfo: [NSLocalizedDescriptionKey: msg ?? ""])
            }
            for bucket in obj["data"] as? [[String: Any]] ?? [] {
                results += bucket["results"] as? [[String: Any]] ?? []
            }
            guard obj["has_more"] as? Bool == true, let n = obj["next_page"] as? String else { break }
            next = n
        }
        return results
    }

    static func openAI(_ key: String) async -> APISpend {
        var s = APISpend()
        let start = Int(monthStart.timeIntervalSince1970)
        let h = ["Authorization": "Bearer \(key)"]
        do {
            for r in try await pages("https://api.openai.com/v1/organization/costs?start_time=\(start)&bucket_width=1d&limit=31",
                                     page: "page", headers: h) {
                s.cost += num(r["amount"])
            }
            for r in try await pages("https://api.openai.com/v1/organization/usage/completions?start_time=\(start)&bucket_width=1d&limit=31",
                                     page: "page", headers: h) {
                let cached = Int(num(r["input_cached_tokens"]))
                s.cachedTokens += cached
                s.inputTokens += Int(num(r["input_tokens"])) - cached
                s.outputTokens += Int(num(r["output_tokens"]))
            }
            s.updated = Date()
        } catch {
            let e = error as NSError
            s.code = e.domain == "spend" ? e.code : 0
            s.error = s.code > 0 ? APIProvider.openai.explain(code: s.code, message: e.localizedDescription.isEmpty ? nil : e.localizedDescription)
                                 : "Couldn't reach OpenAI: \(e.localizedDescription)"
        }
        return s
    }

    static func anthropic(_ key: String) async -> APISpend {
        var s = APISpend()
        let iso = ISO8601DateFormatter()
        let start = iso.string(from: monthStart)
        let h = ["x-api-key": key, "anthropic-version": "2023-06-01"]
        do {
            // Amounts are decimal strings in cents.
            for r in try await pages("https://api.anthropic.com/v1/organizations/cost_report?starting_at=\(start)&bucket_width=1d&limit=31",
                                     page: "page", headers: h) {
                s.cost += num(r["amount"]) / 100
            }
            for r in try await pages("https://api.anthropic.com/v1/organizations/usage_report/messages?starting_at=\(start)&bucket_width=1d&limit=31",
                                     page: "page", headers: h) {
                s.inputTokens += Int(num(r["uncached_input_tokens"]))
                s.cachedTokens += Int(num(r["cache_read_input_tokens"]))
                if let c = r["cache_creation"] as? [String: Any] {
                    s.inputTokens += Int(num(c["ephemeral_1h_input_tokens"]) + num(c["ephemeral_5m_input_tokens"]))
                }
                s.outputTokens += Int(num(r["output_tokens"]))
            }
            s.updated = Date()
        } catch {
            let e = error as NSError
            s.code = e.domain == "spend" ? e.code : 0
            s.error = s.code > 0 ? APIProvider.anthropic.explain(code: s.code, message: e.localizedDescription.isEmpty ? nil : e.localizedDescription)
                                 : "Couldn't reach Anthropic: \(e.localizedDescription)"
        }
        return s
    }
}


/// The expense ledger (Report › Money): actual charges, editable in place, plus the one CSV import.
struct ExpensesView: View {
    @ObservedObject var spend = Spend.shared
    @ObservedObject var importer = SettingsWindow.state
    @State private var showAll = false
    @State private var payDate = Date()
    @State private var payProvider = "OpenAI"
    @State private var payItem = ""
    @State private var payAmount = ""
    @State private var payCategory = "AI"
    @State private var filter = "tech"

    /// One editable ledger line: date, provider, item, category and amount all change in place.
    private func ledgerRow(_ pay: Spend.Payment) -> some View {
        func bind<T>(_ get: @escaping (Spend.Payment) -> T, _ set: @escaping (inout Spend.Payment, T) -> Void) -> Binding<T> {
            Binding(get: { spend.payments.first { $0.id == pay.id }.map(get) ?? get(pay) },
                    set: { v in if let i = spend.payments.firstIndex(where: { $0.id == pay.id }) { set(&spend.payments[i], v) } })
        }
        return HStack(spacing: 6) {
            DatePicker("", selection: bind({ $0.date }, { $0.date = $1 }), displayedComponents: .date).labelsHidden().frame(width: 100)
            TextField("Provider", text: bind({ $0.provider }, { $0.provider = $1 })).textFieldStyle(.plain).font(.system(size: 11, weight: .medium)).frame(width: 80)
            TextField("Item", text: bind({ $0.item }, { $0.item = $1 })).textFieldStyle(.plain).font(.system(size: 11))
            Picker("", selection: bind({ $0.category }, { $0.category = $1 })) { ForEach(Spend.categories, id: \.self) { Text($0).tag($0) } }
                .labelsHidden().frame(width: 70)
            TextField("$", value: bind({ $0.amount }, { $0.amount = $1 }), format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.plain).font(.system(size: 11).monospacedDigit()).multilineTextAlignment(.trailing).frame(width: 70)
            Button { spend.payments.removeAll { $0.id == pay.id } } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(pay.isTech ? 0 : 0.03)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("", selection: $filter) {
                    Text("Tech & AI").tag("tech"); Text("All").tag("all")
                }.pickerStyle(.segmented).frame(width: 150)
                Spacer()
                Button("Import CSV…") { SettingsWindow.importCSV() }
                    .help("Any bank, card, YNAB or billing export, or a profit & loss summary. The format is detected; AI and tech vendors are categorised automatically.")
            }
            Text("Actual charges, in the month they were charged. AI = models, credits and API; Tech = other software, hosting and hardware; Other is kept but left out of the budget. Click a field to edit it.")
                .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let n = importer.note { Text(n).font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            let rows = spend.payments.filter { filter == "all" || $0.isTech }
            if rows.isEmpty {
                HStack {
                    Text("No charges yet. Import a bank or card CSV to fill the ledger.").font(Theme.body).foregroundStyle(.secondary)
                    Button("Open Setup…") { SettingsWindow.show(setup: true) }.controlSize(.small)
                }
            }
            ForEach(rows.prefix(showAll ? 2000 : 10)) { pay in ledgerRow(pay) }
            if rows.count > 10 {
                Button(showAll ? "Show fewer" : "Show all \(rows.count)") { showAll.toggle() }
                    .buttonStyle(.link).font(Theme.caption)
            }
            HStack {
                DatePicker("", selection: $payDate, displayedComponents: .date).labelsHidden().frame(width: 110)
                TextField("Provider", text: $payProvider).textFieldStyle(.roundedBorder).frame(width: 80)
                TextField("What, e.g. Credits", text: $payItem).textFieldStyle(.roundedBorder)
                Picker("", selection: $payCategory) { ForEach(Spend.categories, id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 70)
                TextField("$", text: $payAmount).textFieldStyle(.roundedBorder).frame(width: 70)
                Button("Add") {
                    spend.payments.append(Spend.Payment(date: payDate, provider: payProvider, item: payItem,
                                                        amount: Double(payAmount.replacingOccurrences(of: "$", with: "")) ?? 0, category: payCategory))
                    spend.payments.sort { $0.date > $1.date }
                    payItem = ""; payAmount = ""
                }
                .disabled(payProvider.isEmpty || Double(payAmount.replacingOccurrences(of: "$", with: "")) == nil)
            }
            let m = Date()
            Text("This month: AI \(Fmt.money(spend.paid(inMonthOf: m, category: "AI"), "USD")) · Tech \(Fmt.money(spend.paid(inMonthOf: m, category: "Tech"), "USD")) · Other \(Fmt.money(spend.paid(inMonthOf: m, category: "Other"), "USD"))")
                .font(Theme.caption.weight(.medium)).foregroundStyle(.secondary)
        }
    }
}

/// Settings (⌘,): the Claude API key, appearance, open at login, setup, and admin keys under Advanced.
struct SettingsView: View {
    @ObservedObject var spend = Spend.shared
    @ObservedObject var manager = Manager.shared
    var store: AccountStore?
    @State private var keys: [APIProvider: String] = [:]
    @State private var keyWarning: [APIProvider: String] = [:]
    @State private var claudeKey = ""
    @State private var claudeKeyWarning: String?
    @State private var appearance = AppAppearance.current
    @State private var atLogin = SMAppService.mainApp.status == .enabled
    @State private var advanced = false
    @AppStorage(Look.key) private var look = Look.glass.rawValue
    @AppStorage(MenuBarText.key) private var menuBarText = MenuBarText.icon.rawValue
    @AppStorage(HotKey.key) private var hotKey = HotKey.optCmdB.rawValue
    @AppStorage(DesktopStrip.key) private var desktopStrip = true
    @AppStorage(DesktopStrip.orientationKey) private var stripOrientation = DesktopStrip.Orientation.auto.rawValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) { Brand.mark(28); Text("Settings").font(Theme.headline(18)) }
                    .onAppear { if manager.hasKey && manager.keyStatus == .unknown { manager.verifyKey() } }
                setupSection
                group("Appearance") {
                    row("Look") {
                        Picker("", selection: $look) {
                            ForEach(Look.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                        }
                        .pickerStyle(.segmented).fixedSize()
                    }
                    row("Theme") {
                        Picker("", selection: $appearance) {
                            ForEach(AppAppearance.allCases, id: \.self) { Text($0 == .system ? "System" : $0.title).tag($0) }
                        }
                        .pickerStyle(.segmented).fixedSize()
                        .onChange(of: appearance) { _, a in AppAppearance.current = a }
                    }
                    Text("Glass needs macOS 26. Solid is used instead under Reduce Transparency or Increase Contrast.")
                        .font(Theme.caption).foregroundStyle(.secondary)
                }
                group("Menu bar and desktop") {
                    row("Menu bar shows") {
                        Picker("", selection: $menuBarText) {
                            ForEach(MenuBarText.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                        }
                        .fixedSize()
                    }
                    row("Panel shortcut") {
                        Picker("", selection: $hotKey) {
                            ForEach(HotKey.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                        }
                        .fixedSize()
                        .onChange(of: hotKey) { _, _ in HotKey.register() }
                    }
                    row("Show desktop strip") { Toggle("", isOn: $desktopStrip).toggleStyle(.switch).labelsHidden() }
                    row("Strip layout") {
                        Picker("", selection: $stripOrientation) {
                            ForEach(DesktopStrip.Orientation.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                        }
                        .fixedSize()
                        .help("Automatic: a row along the top or bottom, a column along the sides")
                        .onChange(of: stripOrientation) { _, v in DesktopStrip.orientation = DesktopStrip.Orientation(rawValue: v) ?? .auto }
                    }
                    if !AXIsProcessTrusted() {
                        row("Exact Dock edge") {
                            Button("Allow…") { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) }
                                .help("Optional. Accessibility lets the strip read the Dock's exact width; without it the width is worked out from the Dock's settings.")
                        }
                    }
                    row("Open at login") {
                        Toggle("", isOn: $atLogin).toggleStyle(.switch).labelsHidden()
                            .onChange(of: atLogin) { _, on in
                                if on != (SMAppService.mainApp.status == .enabled) { store?.toggleOpenAtLogin() }
                                atLogin = SMAppService.mainApp.status == .enabled
                            }
                    }
                    HStack {
                        Text("Plans, renewals and the budget live in the Report's Money tab.").font(Theme.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Money") { if let s = store { ReportNav.open("money", store: s) } }.controlSize(.small)
                    }
                }
                group("Keys") {
                    Text("Claude API key (Manager)").font(Theme.cardTitle)
                    claudeKeySection
                    Divider().padding(.vertical, 2)
                    DisclosureGroup("Advanced: admin keys for API spend (OpenAI, Anthropic) and Gemini", isExpanded: $advanced) {
                        VStack(alignment: .leading, spacing: 14) { adminKeys }.padding(.top, 8)
                    }
                    .font(Theme.body)
                }
                Text("Keys are stored in your Mac's Keychain and only sent to their own provider.")
                    .font(Theme.caption).foregroundStyle(.secondary)
            }
            .padding(18)
        }
        .frame(minWidth: 520, minHeight: 480)
        .onAppear { spend.refresh() }
    }

    @ViewBuilder var setupSection: some View {
        if let store { group("Setup") { SetupChecklist(store: store) } }
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack { Text(title).font(Theme.body); Spacer(); control() }
    }

    @ViewBuilder private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title).padding(.leading, 4)
            VStack(alignment: .leading, spacing: 8) { content() }.card(padding: 14, radius: 16)
        }
    }

    @ViewBuilder private var claudeKeySection: some View {
        HStack {
            Text("Optional. Powers the manager's briefs and idea ranking.").font(Theme.body)
            Spacer()
            if manager.hasKey {
                switch manager.keyStatus {
                case .ok: Label("Connected", systemImage: "checkmark.circle.fill").font(Theme.caption).foregroundStyle(.green)
                case .rejected: Label("Not working", systemImage: "xmark.octagon.fill").font(Theme.caption).foregroundStyle(Theme.alert)
                default: Label("Checking…", systemImage: "clock").font(Theme.caption).foregroundStyle(.secondary)
                }
            }
        }
        Text("A normal API key (sk-ant-…) from console.anthropic.com › API keys. It's only ever sent to api.anthropic.com, and each run's cost is counted in your spend.")
            .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if manager.hasKey, let e = manager.keyError {
            Text(e).font(Theme.caption).foregroundStyle(Theme.alert).fixedSize(horizontal: false, vertical: true)
        }
        if manager.hasKey {
            HStack {
                Picker("Model", selection: Binding(get: { manager.model }, set: { manager.model = $0 })) {
                    ForEach(Manager.models, id: \.self) { Text(Fmt.model($0)).tag($0) }
                }.fixedSize()
                Toggle("Send transcript excerpts", isOn: Binding(get: { manager.sendTranscripts }, set: { manager.sendTranscripts = $0 }))
                    .help("What you typed in your most expensive sessions, so tips can be specific. Off: numbers and session shapes only.")
                Spacer()
                Button("Remove key") { Keychain.set("key.claude", nil); manager.keyStatus = .unknown; manager.keyError = nil }
            }
            .font(Theme.body)
            HStack {
                Toggle("Daily brief", isOn: Binding(get: { manager.autoDaily }, set: { manager.autoDaily = $0 }))
                Picker("after", selection: Binding(get: { manager.autoHour }, set: { manager.autoHour = $0 })) {
                    ForEach(5..<22, id: \.self) { Text("\($0):00").tag($0) }
                }.fixedSize().disabled(!manager.autoDaily)
                Spacer()
                Text("This month: \(Fmt.money(manager.costThisMonth, "USD"))").font(Theme.caption).foregroundStyle(.secondary)
            }
            .font(Theme.body)
        } else {
            HStack {
                SecureField("Paste API key", text: $claudeKey).textFieldStyle(.roundedBorder)
                    .onChange(of: claudeKey) { _, _ in claudeKeyWarning = nil }
                Button("Connect") {
                    // Spaces, line breaks and quotes often come along when a key is copied.
                    let k = claudeKey.filter { !$0.isWhitespace && !"\"'“”‘’`".contains($0) }
                    // Anthropic has more than one key prefix (sk-ant-api…, sk-ant-usr…); verifyKey lets Anthropic decide.
                    if k.hasPrefix("sk-ant-") && !k.hasPrefix("sk-ant-admin") && !k.hasPrefix("sk-ant-oat") {
                        let status = Keychain.set("key.claude", k)
                        if status == errSecSuccess { claudeKey = ""; manager.verifyKey() }
                        else { claudeKeyWarning = "The Keychain refused to save the key (error \(status)). Unlock the login keychain in Keychain Access and try again." }
                    } else {
                        claudeKeyWarning = k.hasPrefix("sk-ant-admin") ? "That's an admin key. It goes under Advanced › Anthropic API; the manager needs a normal API key (sk-ant-…)."
                            : k.hasPrefix("sk-ant-oat") ? "That's a Claude sign-in token (from claude setup-token), not an API key. Claude Max and Pro plans don't include API access: an API key comes from console.anthropic.com › API keys and is billed separately from prepaid credits."
                            : "That isn't a Claude API key. Create one at console.anthropic.com › API keys; it starts with sk-ant-."
                    }
                }
                .disabled(claudeKey.count < 10)
            }
            if let w = claudeKeyWarning {
                Text(w).font(Theme.caption).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var adminKeys: some View {
        ForEach(APIProvider.allCases) { p in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(p.title).font(Theme.cardTitle)
                    Spacer()
                    if spend.connected.contains(p) {
                        if let s = spend.api[p] {
                            if s.error == nil {
                                Label("Connected", systemImage: "checkmark.circle.fill").font(Theme.caption).foregroundStyle(.green)
                            } else {
                                Label("Not working", systemImage: "xmark.octagon.fill").font(Theme.caption).foregroundStyle(Theme.alert)
                            }
                        } else {
                            Label("Checking…", systemImage: "clock").font(Theme.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text(p.hint).font(Theme.caption).foregroundStyle(.secondary)
                if spend.connected.contains(p) {
                    HStack {
                        if let s = spend.api[p] {
                            if let e = s.error {
                                Text(e).font(Theme.caption).foregroundStyle(Theme.alert).fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text("\(Fmt.money(s.cost, "USD")) this month · \(Fmt.tokens(s.totalTokens)) tokens").font(Theme.body.weight(.medium))
                            }
                        } else {
                            Text("Checking…").font(Theme.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Refresh") { spend.refresh(force: true) }
                        Button("Remove key") { spend.setKey(p, nil) }
                    }
                } else {
                    HStack {
                        SecureField("Paste admin key", text: Binding(get: { keys[p] ?? "" }, set: { keys[p] = $0; keyWarning[p] = nil }))
                            .textFieldStyle(.roundedBorder)
                        Button("Connect") {
                            let k = (keys[p] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            if k.hasPrefix(p.prefix) { spend.setKey(p, k); keys[p] = nil }
                            else { keyWarning[p] = "That isn't an admin key: \(p.title) admin keys start with \(p.prefix). " + (p == .openai ? "Project keys (sk-proj-…) can't read billing." : "Normal API keys (sk-ant-…) go in the Claude API key section above.") }
                        }
                        .disabled((keys[p] ?? "").count < 10)
                    }
                    if let w = keyWarning[p] {
                        Text(w).font(Theme.caption).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Gemini").font(Theme.cardTitle)
            Text("Google doesn't offer a usage or cost API for individual Gemini API keys. Its spend only shows up in Google Cloud Billing, so add your Gemini bill as a plan in Money › Plans or as a charge in the ledger.")
                .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// First-run checklist (Settings › Setup). Each step ticks itself off from real state; nothing is assumed.
struct SetupChecklist: View {
    @ObservedObject var store: AccountStore
    @ObservedObject var spend = Spend.shared
    @ObservedObject var manager = Manager.shared
    @ObservedObject var budget = Budget.shared
    @AppStorage("setup.expanded") private var expanded = false

    private enum State { case done, todo, optional }
    private struct Step: Identifiable {
        let id: String, title: String, detail: String, state: State
    }

    private var phoneCode: String? {
        (try? String(contentsOf: History.dir.appendingPathComponent("phone-code"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private var steps: [Step] {
        let codex = store.others.filter { $0.app == .codex }.count, cursor = store.others.filter { $0.app == .cursor }.count
        let found = ["\(store.accounts.count) Claude", codex > 0 ? "\(codex) Codex" : nil, cursor > 0 ? "\(cursor) Cursor" : nil].compactMap { $0 }.joined(separator: ", ")
        let detected = spend.subscriptions.filter { $0.source == "detected" }
        let unconfirmed = detected.filter { $0.confirmed != true }.count
        let ceilingSet = UserDefaults.standard.object(forKey: "spendCeiling") != nil
        let keyOK = manager.hasKey && manager.keyStatus == .ok
        return [
            Step(id: "accounts", title: "Accounts", detail: store.targets.isEmpty ? "\(found) found; no usage reading yet" : "\(found) found, with live usage",
                 state: store.targets.isEmpty ? .todo : .done),
            Step(id: "plans", title: "Plans", detail: detected.isEmpty ? "No plans detected yet"
                 : unconfirmed == 0 ? "\(detected.count) detected and confirmed" : "\(detected.count) detected, \(unconfirmed) to confirm",
                 state: !detected.isEmpty && unconfirmed == 0 ? .done : .todo),
            Step(id: "budget", title: "Budget ceiling", detail: ceilingSet ? "\(Fmt.money(budget.ceiling, "USD")) a month for AI and tech" : "Not set (showing the $1,000 default)",
                 state: ceilingSet ? .done : .todo),
            Step(id: "csv", title: "Expenses CSV", detail: spend.payments.isEmpty ? "No charges in the ledger yet" : "\(spend.payments.count) charges in the ledger",
                 state: spend.payments.isEmpty ? .todo : .done),
            Step(id: "key", title: "Claude API key", detail: keyOK ? "Connected: the manager and idea ranking are on"
                 : manager.hasKey ? "Saved, not working yet" : "Optional: turns on the manager brief and idea ranking",
                 state: keyOK ? .done : .optional),
            Step(id: "phone", title: "Phone pairing", detail: phoneCode.map { "Optional. Pairing code \($0): open \(Product.name) on your iPhone on the same Wi-Fi and allow it here, or type the code" }
                 ?? "Optional. The phone feed isn't set up on this Mac", state: .optional),
        ]
    }

    var body: some View {
        let all = steps
        let required = all.filter { $0.state != .optional }
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(all) { s in
                    HStack(spacing: 8) {
                        Image(systemName: s.state == .done ? "checkmark.circle.fill" : (s.state == .optional ? "circle.dashed" : "circle"))
                            .foregroundStyle(s.state == .done ? Color.green : Color.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.title).font(Theme.cardTitle)
                            Text(s.detail).font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        button(s.id).controlSize(.small)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Text("\(required.filter { $0.state == .done }.count) of \(required.count) steps done").font(Theme.body)
        }
    }

    @ViewBuilder private func button(_ id: String) -> some View {
        switch id {
        case "accounts":
            Menu("Add account") {
                Button("Claude account…") { store.addAccount() }
                ForEach(OtherApp.allCases.filter(\.installed)) { app in
                    Button("\(app.title) account…") { store.addOther(app) }
                }
            }
            .fixedSize()
        case "plans": Button("Confirm in Plans") { ReportNav.open("money", store: store) }
        case "budget": Button("Set budget") { ReportNav.open("money", store: store) }
        case "csv": Button("Import CSV…") { SettingsWindow.importCSV() }
        case "key": Button("Get a key…") { NSWorkspace.shared.open(URL(string: "https://console.anthropic.com/settings/keys")!) }
        default:
            Button("Copy code") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(phoneCode ?? "", forType: .string)
            }
            .disabled(phoneCode == nil)
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

enum SettingsWindow {
    private static var window: NSWindow?
    /// Set at launch so Settings can toggle the login item and open the Report.
    static weak var store: AccountStore?
    final class ImportState: ObservableObject { @Published var note: String? }
    static let state = ImportState()

    /// Picks a CSV and works out what it is: a profit & loss summary (monthly revenue), a YNAB register,
    /// or any bank, card or billing export (charges to the ledger, deposits to Money in). Exact duplicates
    /// already in the ledger (same day, amount and item, or the same vendor a day apart) are skipped.
    static func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.message = "Choose a bank, card or billing CSV export"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url,
              let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else { return }
        if let months = Budget.parseProfitAndLoss(text) {
            var added = 0, kept = 0
            for (key, v) in months {
                if Budget.shared.revenue[key] != nil { kept += 1 } else if v > 0 { Budget.shared.revenue[key] = v; added += 1 }
            }
            state.note = "\(url.lastPathComponent) is a profit & loss summary: monthly income filled in for \(added) months of the budget" + (kept > 0 ? " (\(kept) months you'd already entered were left as they were)" : "") + ". It has no individual deposits, so it can't be tied to projects; a transactions export can."
            return
        }
        let ynab = Spend.importYNAB(text)
        let (parsed, skipped) = ynab ?? Spend.importCSV(text)
        let spend = Spend.shared
        let cal = Calendar.current
        // Money in: refunds from AI/Tech vendors stay in the ledger; everything else is income.
        // A YNAB card register's inflows are all refunds, so nothing from it goes to income.
        let charges = ynab != nil ? parsed : parsed.filter { $0.amount >= 0 }
        let split = ProjectStore.splitMoneyIn(ynab != nil ? [] : parsed.filter { $0.amount < 0 }, knownCharges: spend.payments + charges)
        // Claude's charges are already in the budget as extra usage and plans; they only back project costs.
        let isClaude = { (p: Spend.Payment) in (p.provider + " " + p.item).lowercased().contains("anthropic") }
        let claudeRows = ynab != nil ? [] : charges.filter(isClaude)
        let bankAdded = BankCharges.add(claudeRows.map { .init(date: ProjectScan.dayKey($0.date), vendor: "Anthropic", amount: $0.amount) })
        let rows = charges.filter { ynab != nil || !isClaude($0) } + split.refunds
        let deposits = ProjectStore.shared.addIncome(split.deposits)
        let existing = Set(spend.payments.map { "\(cal.startOfDay(for: $0.date).timeIntervalSince1970)|\($0.amount)|\($0.item.lowercased())" })
        // The same charge from another source (billing page vs. bank) has a different description and can post a day apart.
        func near(_ p: Spend.Payment) -> [String] {
            (-1...1).compactMap { cal.date(byAdding: .day, value: $0, to: cal.startOfDay(for: p.date)) }
                .map { "\($0.timeIntervalSince1970)|\(p.amount)|\(p.provider.lowercased())" }
        }
        let sameVendor = Set(spend.payments.map { "\(cal.startOfDay(for: $0.date).timeIntervalSince1970)|\($0.amount)|\($0.provider.lowercased())" })
        let fresh = rows.filter { r in
            !existing.contains("\(cal.startOfDay(for: r.date).timeIntervalSince1970)|\(r.amount)|\(r.item.lowercased())")
                && !near(r).contains(where: sameVendor.contains)
        }
        spend.payments = (spend.payments + fresh).sorted { $0.date > $1.date }
        let tech = fresh.filter(\.isTech).count
        state.note = parsed.isEmpty
            ? "Nothing imported from \(url.lastPathComponent): no date and amount columns were found\(skipped > 0 ? " (\(skipped) rows skipped)" : "")."
            : "Imported \(fresh.count) of \(rows.count) charges from \(url.lastPathComponent) (\(tech) tagged AI or Tech, \(rows.count - fresh.count) already in the ledger\(skipped > 0 ? ", \(skipped) unreadable" : ""))" + (split.deposits.isEmpty ? "" : ", and \(deposits) of \(split.deposits.count) deposits to Money in (Report › Projects)") + (claudeRows.isEmpty ? "" : ", plus \(bankAdded) new Anthropic charges for project costs") + ". Check the categories below."
    }

    /// Opens Settings. `setup: true` also shows the Setup checklist expanded.
    static func show(setup: Bool = false) {
        if setup { UserDefaults.standard.set(true, forKey: "setup.expanded") }
        if let w = window { AppWindows.present(w); return }
        let w = make()
        window = w
        AppWindows.present(w)
    }

    static func make() -> NSWindow {
        let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(store: store).burnWindow()))
        AppWindows.configure(w, title: "Settings", autosave: "BurnRateConnections", size: NSSize(width: 600, height: 680), min: NSSize(width: 520, height: 460))
        return w
    }
}

// MARK: - Plans (subscription manager, phase 1)
//
// Detected plans become subscription rows; Report › Plans shows one card per account with links to
// the vendor's own billing pages. None of Claude, OpenAI or Cursor has a public API to change or
// cancel a consumer plan, so Burn Rate only opens the page: every money click (upgrade, add funds,
// cancel) is the user's own, on the vendor's site. Plans come from data Burn Rate already reads
// (claude.ai org info, Codex session logs, Cursor's state.vscdb / usage-summary); unknown stays unknown.

enum PlanVendor: String, Codable {
    case claude, chatgpt, cursor
    var title: String {
        switch self {
        case .claude: return "Claude"
        case .chatgpt: return "ChatGPT"
        case .cursor: return "Cursor"
        }
    }
}

enum PlanAction: String, CaseIterable, Identifiable {
    case billing, change, extra, invoices, cancel
    var id: String { rawValue }
    var title: String {
        switch self {
        case .billing: return "Open billing"
        case .change: return "Change plan"
        case .extra: return "Extra usage"
        case .invoices: return "Invoices"
        case .cancel: return "Cancel…"
        }
    }
}

/// List prices and vendor pages. Prices are the vendors' published monthly list prices as of `asOf`;
/// each one is shown as unconfirmed until the user confirms (or corrects) it on the Plans tab.
enum PlanCatalog {
    static let asOf = "Oct 2026"
    private static let prices: [PlanVendor: [String: (name: String, monthly: Double)]] = [
        .claude: ["pro": ("Pro", 20), "max5x": ("Max 5x", 100), "max20x": ("Max 20x", 200)],
        .chatgpt: ["free": ("Free", 0), "plus": ("Plus", 20), "pro": ("Pro", 200)],
        .cursor: ["free": ("Free", 0), "hobby": ("Hobby", 0), "pro": ("Pro", 20), "pro_plus": ("Pro+", 60), "ultra": ("Ultra", 200)],
    ]

    static func name(_ v: PlanVendor, _ key: String) -> String {
        prices[v]?[key]?.name ?? key.replacingOccurrences(of: "_", with: " ").capitalized
    }
    static func price(_ v: PlanVendor, _ key: String) -> Double? { prices[v]?[key]?.monthly }

    /// The vendor page for an action. Store-bought Claude plans are managed in the store instead.
    static func url(_ v: PlanVendor, _ a: PlanAction, store: String? = nil) -> URL {
        if v == .cursor, store == xBilling.absoluteString { return a == .extra ? URL(string: "https://grok.com/dashboard")! : xBilling }
        if let store, a != .extra { return URL(string: store)! }
        let s: String
        switch (v, a) {
        case (.claude, .extra): s = "https://claude.ai/settings/usage"
        // claude.ai/upgrade renders blank for a Max account (tested Oct 23); Billing has "Adjust plan".
        case (.claude, _): s = "https://claude.ai/settings/billing"
        // OpenAI's billing portal is reached from ChatGPT › Settings › Account › Manage (exact deep link unverified).
        case (.chatgpt, .change): s = "https://chatgpt.com/#pricing"
        case (.chatgpt, _): s = "https://chatgpt.com/#settings/Account"
        case (.cursor, .change): s = "https://cursor.com/pricing"
        case (.cursor, _): s = "https://cursor.com/dashboard"
        }
        return URL(string: s)!
    }
    static let xBilling = URL(string: "https://grok.com/dashboard/billing")!

    /// "default_claude_max_20x" / capabilities → plan key. nil when claude.ai doesn't say.
    static func claudeKey(tier: String?, capabilities: [String]) -> String? {
        let t = (tier ?? "").lowercased()
        if t.contains("max_20x") || t.contains("max20x") { return "max20x" }
        if t.contains("max_5x") || t.contains("max5x") { return "max5x" }
        if t.contains("pro") { return "pro" }
        if capabilities.contains("claude_max") { return "max" }     // Max, tier not reported → no price
        if capabilities.contains("claude_pro") { return "pro" }
        return nil
    }
    /// Codex `plan_type` ("pro", "plus", …) → plan key.
    static func chatgptKey(_ p: String?) -> String? { p?.lowercased() }
    /// Cursor `stripeMembershipType` / `membershipType` ("unified_ultra", "pro", "free_trial"…) → plan key.
    static func cursorKey(_ p: String?) -> String? {
        guard var k = p?.lowercased(), !k.isEmpty else { return nil }
        if k.hasPrefix("unified_") { k = String(k.dropFirst("unified_".count)) }
        if k == "pro+" || k == "proplus" { k = "pro_plus" }
        return k
    }
    /// Store-bought Claude plans (billing_type from claude.ai) are managed in the store's subscriptions page.
    static func storeURL(billingType: String?) -> String? {
        let b = (billingType ?? "").lowercased()
        if b.contains("apple") { return "https://apps.apple.com/account/subscriptions" }
        if b.contains("google") { return "https://play.google.com/store/account/subscriptions" }
        return nil
    }
}

/// One account's plan as Burn Rate can see it right now.
struct PlanCard: Identifiable {
    let id: String                 // "claude:main", "codex:main", "cursor:main"
    let vendor: PlanVendor
    let accountName: String
    let appURL: URL
    var email: String?
    var planKey: String?           // nil = unknown
    var planName: String? { planKey.map { PlanCatalog.name(vendor, $0) } }
    var storeURL: String?
    var claude: Account?
    var renews: String             // plain sentence, "not available" when no data says
    var extra: [String]            // plain lines about extra usage
    var autoReloadOn = false
    var detectedRenewal: Date?     // from vendor data (claude.ai, cursor.com)
    var detectedFrom = ""
    var maybe: [String] = []       // charges that can happen without a date (auto-reload, on-demand)

    /// The renewal to show, with where it came from: a detected date wins over an entered one.
    func renewal(_ row: Subscription?) -> (date: Date, source: String)? {
        // Cursor's usage cycle isn't its charge date (an X Subscription renews on its own date), so an entered date wins there.
        if vendor == .cursor, row?.renewsSource == "entered", let d = row?.renews { return (d, "entered") }
        if let d = detectedRenewal { return (d, "detected from \(detectedFrom)") }
        if let d = row?.renews { return (d, row?.renewsSource == "detected" ? "detected" : "entered") }
        return nil
    }
}

final class PlanStore: ObservableObject {
    static let shared = PlanStore()
    @Published private(set) var log: [Change] = []

    struct Change: Codable, Hashable {
        var date: Date
        var account: String
        var from: String?
        var to: String
        var monthly: Double?
    }

    private var logURL: URL { Paths.appSupport.appendingPathComponent("local.ai-orchestrator/plans.json") }

    init() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: logURL), let l = try? dec.decode([Change].self, from: d) { log = l }
    }

    private func append(_ c: Change) {
        log.append(c)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? enc.encode(log) { try? d.write(to: logURL, options: .atomic) }
    }

    /// Every account Burn Rate knows, with what it can see of each plan.
    func cards(_ store: AccountStore) -> [PlanCard] {
        var out: [PlanCard] = []
        for a in store.accounts {
            let u = store.usage[a.slug]
            let d = u?.details
            var extra: [String] = []
            if let d {
                if let used = d.extraUsed, let lim = d.extraLimit {
                    extra.append("Extra usage \(d.extraEnabled ? "on" : "off"): \(Fmt.money(used, d.currency)) of \(Fmt.money(lim, d.currency)) this month")
                } else {
                    extra.append("Extra usage \(d.extraEnabled ? "on" : "off")")
                }
                if let p = d.prepaid { extra.append("Prepaid credit \(Fmt.money(p, d.currency))") }
                if let ar = d.autoReload { extra.append(ar ? "Auto-reload on" : "Auto-reload off") }
            } else {
                extra.append("Usage not loaded yet")
            }
            out.append(PlanCard(id: "claude:\(a.slug)", vendor: .claude, accountName: a.name, appURL: Paths.claudeApp,
                                email: u?.email, planKey: PlanCatalog.claudeKey(tier: u?.rateLimitTier, capabilities: u?.capabilities ?? []),
                                storeURL: PlanCatalog.storeURL(billingType: u?.billingType), claude: a,
                                renews: "Renewal date: not available yet (read from claude.ai Billing when it loads)",
                                extra: extra, autoReloadOn: d?.autoReload == true,
                                detectedRenewal: u?.renews ?? detectedRenewals["claude:\(a.slug)"], detectedFrom: "claude.ai",
                                maybe: d.map(Self.claudeMaybe) ?? []))
        }
        var cursorEmails = Set<String>()
        for o in store.others {
            switch o.app {
            case .codex:
                let u = store.codexUsage[o.id]
                out.append(PlanCard(id: "codex:\(o.slug)", vendor: .chatgpt, accountName: o.isMain ? "Codex" : "Codex \(o.name)",
                                    appURL: o.app.appURL, email: nil, planKey: PlanCatalog.chatgptKey(u?.plan),
                                    renews: "Renewal date: not available (Codex logs don't include it)",
                                    extra: ["Codex credits: not reported locally"]))
            case .cursor:
                let email = CursorReader.email(dataDir: o.dataDir)
                if let e = email?.lowercased() {
                    if cursorEmails.contains(e) { continue }     // same login as a profile already listed
                    cursorEmails.insert(e)
                }
                let u = store.cursorUsage[o.id]
                let plan = u?.plan ?? (o.isMain ? store.mainLogins[.cursor]?.plan : nil)
                var extra: [String] = []
                if let u {
                    if let l = u.limit { extra.append("Included usage: \(Fmt.money(u.used, "USD")) of \(Fmt.money(l, "USD")) (\(Int(u.percent.rounded()))%)") }
                    extra.append("On-demand \(u.onDemand ? "on" : "off")" + (u.onDemandUsed > 0 ? ": \(Fmt.money(u.onDemandUsed, "USD")) this cycle" : ""))
                } else {
                    extra.append("Usage not loaded")
                }
                out.append(PlanCard(id: "cursor:\(o.slug)", vendor: .cursor, accountName: o.isMain ? "Cursor" : "Cursor \(o.name)",
                                    appURL: o.app.appURL, email: email, planKey: PlanCatalog.cursorKey(plan),
                                    storeURL: row(for: "cursor:\(o.slug)")?.billedVia == "grok.com" ? PlanCatalog.xBilling.absoluteString : nil,
                                    renews: "Renewal date: not available", extra: extra,
                                    detectedRenewal: u?.cycleEnd, detectedFrom: "cursor.com billing cycle",
                                    maybe: u?.onDemand == true ? ["On-demand usage is on: Cursor bills usage past the plan as it happens."] : []))
            }
        }
        return out
    }

    /// Turn detected plans into subscription rows (one per account), so spend and budgets include them.
    /// A plan change re-prices the row from the list and asks for confirmation again; hand-entered rows are left alone.
    func sync(_ store: AccountStore) {
        var subs = Spend.shared.subscriptions
        var changed = false
        for c in cards(store) {
            guard let key = c.planKey, let name = c.planName else { continue }
            let price = PlanCatalog.price(c.vendor, key)
            let label = "\(c.vendor.title) \(name) · \(c.accountName)"
            if let i = subs.firstIndex(where: { $0.account == c.id }) {
                // "Pro 100" (entered) still reads as "pro" in Codex logs: a more specific entered name wins.
                guard subs[i].plan != name, !(subs[i].plan ?? "").hasPrefix(name + " ") else { continue }
                append(Change(date: Date(), account: c.id, from: subs[i].plan, to: name, monthly: price))
                subs[i].plan = name
                subs[i].name = label
                if let price { subs[i].monthly = price; subs[i].priceAsOf = PlanCatalog.asOf }
                subs[i].confirmed = false
                subs[i].changedAt = Date()
                changed = true
            } else if let price {
                append(Change(date: Date(), account: c.id, from: nil, to: name, monthly: price))
                subs.append(Subscription(name: label, monthly: price, account: c.id, plan: name, source: "detected",
                                         confirmed: false, priceAsOf: PlanCatalog.asOf, changedAt: Date()))
                changed = true
            }
        }
        if applyDueChanges(&subs) { changed = true }
        if changed { Spend.shared.subscriptions = subs }
        notifyUpcoming(store)
    }

    func row(for id: String) -> Subscription? { Spend.shared.subscriptions.first { $0.account == id } }

    // MARK: Renewals and upcoming charges

    /// Renewal dates read from claude.ai (Billing page or subscription details), by account id.
    private(set) var detectedRenewals: [String: Date] = {
        (UserDefaults.standard.dictionary(forKey: "plan.renewals") as? [String: Double] ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
    }()

    func noteRenewal(_ id: String, _ date: Date, store: AccountStore) {
        guard detectedRenewals[id] != date else { return }
        detectedRenewals[id] = date
        UserDefaults.standard.set(detectedRenewals.mapValues(\.timeIntervalSince1970), forKey: "plan.renewals")
        objectWillChange.send()
        store.writeStatus()
    }

    static func claudeMaybe(_ d: UsageDetails) -> [String] {
        var out: [String] = []
        if d.autoReload == true {
            var s = "Auto-reload is on: Claude charges your card to top up credit"
            if let to = d.autoReloadTo, let below = d.autoReloadBelow { s += " to \(Fmt.money(to, d.currency)) whenever it falls below \(Fmt.money(below, d.currency))" }
            if let p = d.prepaid { s += " (balance now \(Fmt.money(p, d.currency)))" }
            out.append(s + ".")
        }
        return out
    }

    /// Monthly plans renew on the same day each month, so a past date rolls forward to the next one.
    static func next(after date: Date, from now: Date = Date()) -> Date {
        var d = date
        let cal = Calendar.current
        while cal.startOfDay(for: d) < cal.startOfDay(for: now) { d = cal.date(byAdding: .month, value: 1, to: d) ?? d.addingTimeInterval(30 * 86_400) }
        return d
    }

    struct Upcoming: Identifiable {
        var id: String { "\(account)-\(date.timeIntervalSince1970)" }
        let date: Date
        let account: String
        let title: String
        let amount: Double?
        let note: String
    }

    /// Dated plan charges in the next `days`, from renewal dates (detected or entered) and the row's price.
    /// A scheduled plan change takes over from its date. Amounts are plan prices before tax.
    func upcoming(_ store: AccountStore, days: Int = 45) -> [Upcoming] {
        let end = Date().addingTimeInterval(Double(days) * 86_400)
        var out: [Upcoming] = []
        for c in cards(store) {
            let row = row(for: c.id)
            guard let r = c.renewal(row) else { continue }
            var date = Self.next(after: r.date)
            while date <= end {
                var title = "\(c.vendor.title) \(row?.plan ?? c.planName ?? "plan") · \(c.accountName)"
                var amount = row?.monthly
                var note = "renews (\(r.source))"
                if let pd = row?.pendingDate, let pp = row?.pendingPlan, Calendar.current.startOfDay(for: pd) <= Calendar.current.startOfDay(for: date) {
                    title = "\(c.vendor.title) \(pp) · \(c.accountName)"
                    amount = row?.pendingMonthly
                    note = "changes from \(row?.plan ?? "current plan") on \(Fmt.day(pd)) (entered)"
                }
                if row?.confirmed != true, row?.pendingDate == nil || note.hasPrefix("renews") { note += row == nil ? "" : ", price not confirmed" }
                out.append(Upcoming(date: date, account: c.id, title: title, amount: amount, note: note))
                guard let n = Calendar.current.date(byAdding: .month, value: 1, to: date) else { break }
                date = n
            }
        }
        return out.sorted { $0.date < $1.date }
    }

    /// A heads-up notification two days before each dated charge (once per charge).
    func notifyUpcoming(_ store: AccountStore) {
        let now = Date()
        for u in upcoming(store, days: 3) where u.date.timeIntervalSince(now) <= 2 * 86_400 {
            Notify.once("charge.\(u.account).\(Fmt.day(u.date))") {
                Notify.send("Upcoming charge \(Fmt.day(u.date))",
                            "\(u.title): \(u.amount.map { Fmt.money($0, "USD") } ?? "amount unknown") (\(u.note)).")
            }
        }
    }

    func setRenewal(_ id: String) {
        guard let i = Spend.shared.subscriptions.firstIndex(where: { $0.account == id }) else { return }
        let sub = Spend.shared.subscriptions[i]
        let alert = NSAlert()
        alert.messageText = "When does \(sub.name) renew?"
        alert.informativeText = "Pick the next (or last) renewal date from the vendor's billing page. It repeats monthly from there."
        let picker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        picker.datePickerElements = .yearMonthDay
        picker.datePickerStyle = .textFieldAndStepper
        picker.dateValue = sub.renews ?? Date()
        alert.accessoryView = picker
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if sub.renews != nil { alert.addButton(withTitle: "Clear") }
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Spend.shared.subscriptions[i].renews = picker.dateValue
            Spend.shared.subscriptions[i].renewsSource = "entered"
        case .alertThirdButtonReturn:
            Spend.shared.subscriptions[i].renews = nil
            Spend.shared.subscriptions[i].renewsSource = nil
        default: return
        }
        objectWillChange.send()
    }

    func setPlanChange(_ id: String) {
        guard let i = Spend.shared.subscriptions.firstIndex(where: { $0.account == id }) else { return }
        let sub = Spend.shared.subscriptions[i]
        let alert = NSAlert()
        alert.messageText = "Scheduled plan change for \(sub.name)"
        alert.informativeText = "As shown on the vendor's billing page: the new plan, its monthly price and the date it starts."
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 88))
        let name = NSTextField(frame: NSRect(x: 0, y: 64, width: 260, height: 24)); name.placeholderString = "New plan, e.g. Pro 100"
        name.stringValue = sub.pendingPlan ?? ""
        let price = NSTextField(frame: NSRect(x: 0, y: 32, width: 120, height: 24)); price.placeholderString = "$/month"
        price.stringValue = sub.pendingMonthly.map { String(format: "%.2f", $0) } ?? ""
        let picker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        picker.datePickerElements = .yearMonthDay; picker.datePickerStyle = .textFieldAndStepper
        picker.dateValue = sub.pendingDate ?? Date()
        [name, price, picker].forEach(box.addSubview)
        alert.accessoryView = box
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if sub.pendingPlan != nil { alert.addButton(withTitle: "Remove change") }
        alert.window.initialFirstResponder = name
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let v = Double(price.stringValue.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: ""))
            guard !name.stringValue.isEmpty, let v else { return }
            Spend.shared.subscriptions[i].pendingPlan = name.stringValue
            Spend.shared.subscriptions[i].pendingMonthly = v
            Spend.shared.subscriptions[i].pendingDate = picker.dateValue
        case .alertThirdButtonReturn:
            Spend.shared.subscriptions[i].pendingPlan = nil
            Spend.shared.subscriptions[i].pendingMonthly = nil
            Spend.shared.subscriptions[i].pendingDate = nil
        default: return
        }
        objectWillChange.send()
    }

    /// When a scheduled change's date has passed, it becomes the plan (its price confirmed, since the user entered it).
    private func applyDueChanges(_ subs: inout [Subscription]) -> Bool {
        var changed = false
        for i in subs.indices {
            guard let pd = subs[i].pendingDate, pd <= Date(), let pp = subs[i].pendingPlan else { continue }
            append(Change(date: pd, account: subs[i].account ?? subs[i].name, from: subs[i].plan, to: pp, monthly: subs[i].pendingMonthly))
            subs[i].plan = pp
            if let m = subs[i].pendingMonthly { subs[i].monthly = m; subs[i].confirmed = true; subs[i].priceAsOf = nil }
            if let a = subs[i].account, let v = PlanVendor(rawValue: a.hasPrefix("codex") ? "chatgpt" : String(a.split(separator: ":")[0])) {
                subs[i].name = "\(v.title) \(pp) · " + (subs[i].name.components(separatedBy: " · ").last ?? "")
            }
            subs[i].pendingPlan = nil; subs[i].pendingMonthly = nil; subs[i].pendingDate = nil
            changed = true
        }
        return changed
    }

    func confirm(_ id: String) {
        guard let i = Spend.shared.subscriptions.firstIndex(where: { $0.account == id }) else { return }
        Spend.shared.subscriptions[i].confirmed = true
    }

    func editPrice(_ id: String) {
        guard let i = Spend.shared.subscriptions.firstIndex(where: { $0.account == id }) else { return }
        let sub = Spend.shared.subscriptions[i]
        let alert = NSAlert()
        alert.messageText = "What do you pay for \(sub.name)?"
        alert.informativeText = "Monthly price in dollars, as on your bill. This replaces the list price."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        field.stringValue = String(format: "%.2f", sub.monthly)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn,
              let v = Double(field.stringValue.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")), v >= 0
        else { return }
        Spend.shared.subscriptions[i].monthly = v
        Spend.shared.subscriptions[i].confirmed = true
        Spend.shared.subscriptions[i].priceAsOf = nil
    }

    /// Open the vendor's page for this account. Claude pages open in that account's own signed-in
    /// window; ChatGPT and Cursor open in the default browser (sign-in windows for them are phase 2).
    func perform(_ action: PlanAction, _ c: PlanCard, store: AccountStore) {
        let url = PlanCatalog.url(c.vendor, action, store: c.storeURL)
        if action == .cancel {
            let alert = NSAlert()
            alert.messageText = "Cancel \(c.vendor.title) for \(c.accountName)?"
            alert.informativeText = "\(Product.name) cancels nothing itself. This opens \(c.vendor == .cursor && c.storeURL != nil ? "grok.com billing (your X Subscription)" : c.storeURL != nil ? "the store's subscriptions page" : "\(c.vendor.title)'s own billing page"), where you can cancel if you choose to."
                + (c.vendor == .claude || c.storeURL != nil ? "" : " Make sure the browser is signed in to the right account.")
            alert.addButton(withTitle: "Open billing page")
            alert.addButton(withTitle: "Not now")
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        if c.vendor == .claude, c.storeURL == nil || action == .extra, let a = c.claude {
            store.openBilling(a, url, title: action == .cancel ? "Billing" : action.title)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Plans for status.json (no secrets, no card details).
    func json(_ store: AccountStore) -> [[String: Any]] {
        cards(store).map { c in
            var d: [String: Any] = ["account": c.id, "vendor": c.vendor.rawValue, "name": c.accountName,
                                    "source": c.planKey == nil ? "unknown" : "detected",
                                    "billingURL": PlanCatalog.url(c.vendor, .billing, store: c.storeURL).absoluteString]
            if let p = c.planName { d["plan"] = p }
            if let e = c.email { d["email"] = e }
            if let r = row(for: c.id) {
                d["monthly"] = r.monthly; d["confirmed"] = r.confirmed ?? false
                if let rn = c.renewal(r) { d["renews"] = ISO8601DateFormatter().string(from: Self.next(after: rn.date)); d["renewsSource"] = rn.source }
                if let pp = r.pendingPlan, let pd = r.pendingDate {
                    d["pendingPlan"] = pp; d["pendingDate"] = ISO8601DateFormatter().string(from: pd)
                    if let m = r.pendingMonthly { d["pendingMonthly"] = m }
                }
                if let a = r.priceAsOf { d["priceAsOf"] = a }
            }
            return d
        }
    }
}

/// Lets the Report open on a given tab (e.g. Plans from a tile's right-click menu).
/// The Report's tab: now, money, projects or ideas. Old names (from scripts and notifications) map onto them.
final class ReportNav: ObservableObject {
    static let shared = ReportNav()
    static let tabs = ["now", "money", "projects", "ideas"]
    @Published var tab = "now"
    static func normalized(_ t: String) -> String {
        switch t {
        case "usage": return "now"
        case "budget", "plans": return "money"
        case "trends": return "projects"
        case "manager": return "ideas"
        default: return tabs.contains(t) ? t : "now"
        }
    }
    /// Opens the Report on a tab (the one way into Ideas, the manager brief, plans and so on).
    static func open(_ tab: String, store: AccountStore) {
        shared.tab = normalized(tab)
        ReportWindow.show(store: store)
    }
}

struct PlansView: View {
    @ObservedObject var store: AccountStore
    @ObservedObject var spend = Spend.shared
    @ObservedObject var budget = Budget.shared
    @ObservedObject var plans = PlanStore.shared
    static let target = 480.0

    var body: some View {
        let cards = plans.cards(store)
        VStack(alignment: .leading, spacing: 12) {
            Text("\(Product.name) only opens each vendor's own page. Upgrades, adding funds and cancelling are your clicks there; it never sees card details.")
                .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if cards.isEmpty {
                HStack(spacing: 8) {
                    Text("No plans detected yet. Add an account so its plan can be read.").font(Theme.body).foregroundStyle(.secondary)
                    Button("Open Setup…") { SettingsWindow.show(setup: true) }.controlSize(.small)
                }
            } else {
                upcomingCard(cards)
            }
            ForEach(cards) { c in card(c) }
            otherPlans
            footer
        }
        .onAppear { plans.sync(store) }
    }

    @State private var newName = ""
    @State private var newAmount = ""

    /// Plans with no account on this Mac (Gemini, hosting, a seat billed elsewhere), entered by hand.
    private var otherPlans: some View {
        let rows = spend.subscriptions.filter { $0.account == nil }
        func amount(_ s: String) -> Double? { Double(s.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")) }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Other plans").font(Theme.cardTitle)
            Text("Monthly plans with no account here: Gemini, hosting, a seat billed elsewhere.").font(Theme.caption).foregroundStyle(.secondary)
            ForEach(rows) { sub in
                HStack {
                    Text(sub.name).font(Theme.body)
                    Spacer()
                    Text(Fmt.money(sub.monthly, "USD") + "/mo").font(Theme.body.monospacedDigit())
                    Button { spend.subscriptions.removeAll { $0.id == sub.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            HStack {
                TextField("Name, e.g. Gemini", text: $newName).textFieldStyle(.roundedBorder)
                TextField("$/month", text: $newAmount).textFieldStyle(.roundedBorder).frame(width: 90)
                Button("Add") {
                    spend.subscriptions.append(Subscription(name: newName, monthly: amount(newAmount) ?? 0))
                    newName = ""; newAmount = ""
                }
                .disabled(newName.isEmpty || amount(newAmount) == nil)
            }
        }
        .card(padding: 12, radius: 14)
    }

    private func card(_ c: PlanCard) -> some View {
        let row = plans.row(for: c.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AppIcon(url: c.appURL, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.accountName).font(Theme.cardTitle)
                    Text(c.email ?? "email not available").font(Theme.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(c.planName.map { "\(c.vendor.title) \($0)" } ?? "Plan unknown").font(.system(size: 13, weight: .semibold))
                        Text(c.planKey == nil ? "unknown" : (row?.source == "detected" || row == nil ? "detected" : "entered"))
                            .font(.system(size: 9, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.1)))
                    }
                    priceLine(c, row)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                if let r = c.renewal(row) {
                    Text("\(c.vendor == .cursor && c.detectedRenewal != nil ? "Billing cycle ends" : "Renews") \(Fmt.day(PlanStore.next(after: r.date))) (\(r.source)\(r.date < Calendar.current.startOfDay(for: Date()) ? ", monthly from \(Fmt.day(r.date))" : ""))")
                } else {
                    Text(c.renews)
                }
                if let pp = row?.pendingPlan, let pd = row?.pendingDate {
                    Text("Changes to \(pp) on \(Fmt.day(pd))" + (row?.pendingMonthly.map { " at \(Fmt.money($0, "USD"))/mo" } ?? "") + " (entered)")
                }
                ForEach(c.extra, id: \.self) { Text($0) }
                if c.vendor == .cursor, c.storeURL != nil { Text("X Subscription: billed through grok.com, so the buttons open grok.com billing.") }
                else if c.storeURL != nil { Text("Bought through an app store: plan and cancelling are managed in the store.") }
            }
            .font(Theme.caption).foregroundStyle(.secondary)
            if c.autoReloadOn {
                Label("Auto-reload is on: Claude buys more credit when the balance runs low. Turn it off under Extra usage.", systemImage: "arrow.clockwise")
                    .font(Theme.caption).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                ForEach(PlanAction.allCases) { a in
                    if !(a == .extra && c.vendor == .chatgpt) {
                        Button(a.title) { plans.perform(a, c, store: store) }.controlSize(.small)
                    }
                }
                Spacer()
                if c.vendor == .cursor, c.storeURL == nil {
                    Button("Billed by X?") { NSWorkspace.shared.open(PlanCatalog.xBilling) }
                        .controlSize(.small).help("If Cursor bills you as an X Subscription, billing is at grok.com")
                }
            }
            if c.vendor != .claude {
                Text("Opens in your browser: check it's signed in to \(c.email ?? "this account").")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 12, radius: 14)
    }

    @ViewBuilder private func priceLine(_ c: PlanCard, _ row: Subscription?) -> some View {
        if let row {
            HStack(spacing: 6) {
                Text(Fmt.money(row.monthly, "USD") + "/mo").font(Theme.body.monospacedDigit())
                if row.confirmed == true {
                    Text("confirmed").font(Theme.caption).foregroundStyle(.secondary)
                } else {
                    Text("list price as of \(row.priceAsOf ?? PlanCatalog.asOf), not confirmed").font(Theme.caption).foregroundStyle(Theme.warn)
                    Button("Confirm") { plans.confirm(c.id) }.controlSize(.mini)
                }
                Button("Edit…") { plans.editPrice(c.id) }.controlSize(.mini)
                Menu("Dates") {
                    Button(c.detectedRenewal != nil ? "Set renewal date… (vendor date wins)" : "Set renewal date…") { plans.setRenewal(c.id) }
                    Button(row.pendingPlan == nil ? "Add a scheduled plan change…" : "Edit scheduled plan change…") { plans.setPlanChange(c.id) }
                }
                .menuStyle(.borderlessButton).fixedSize().controlSize(.mini)
            }
        } else if c.planKey != nil {
            Text("No list price for this plan: add what you pay under Other plans below").font(Theme.caption).foregroundStyle(.secondary)
        } else {
            Text("Price unknown").font(Theme.caption).foregroundStyle(.secondary)
        }
    }

    private func upcomingCard(_ cards: [PlanCard]) -> some View {
        let list = plans.upcoming(store)
        let maybe = cards.flatMap { c in c.maybe.map { "\(c.accountName): \($0)" } }
        let missing = cards.filter { $0.planKey != nil && $0.renewal(plans.row(for: $0.id)) == nil }.map(\.accountName)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Upcoming charges · next 45 days").font(Theme.cardTitle)
                Spacer()
                let total = list.compactMap(\.amount).reduce(0, +)
                if !list.isEmpty { Text(Fmt.money(total, "USD")).font(.system(size: 13, weight: .semibold).monospacedDigit()) }
            }
            if list.isEmpty {
                Text("No renewal dates yet. Set them with Dates on each plan.").font(Theme.caption).foregroundStyle(.secondary)
            }
            ForEach(list) { u in
                HStack(alignment: .firstTextBaseline) {
                    Text(Fmt.day(u.date)).font(.system(size: 11).monospacedDigit()).frame(width: 52, alignment: .leading).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(u.title).font(Theme.body)
                        Text(u.note).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(u.amount.map { Fmt.money($0, "USD") } ?? "amount unknown").font(Theme.body.monospacedDigit())
                }
            }
            if !maybe.isEmpty {
                Divider().opacity(0.4)
                Text("Can charge without a date").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(maybe, id: \.self) { Text($0).font(Theme.caption).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true) }
            }
            Text("Plan prices before tax. You get a notification two days before each dated charge."
                 + (missing.isEmpty ? "" : " No renewal date for: \(missing.joined(separator: ", ")).")
                 + " Extra usage and Codex credits are billed as you use them and aren't listed.")
                .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .card(padding: 12, radius: 14)
    }

    private var footer: some View {
        let total = spend.subscriptionTotal
        let unconfirmed = spend.subscriptions.filter { $0.source == "detected" && $0.confirmed != true }.count
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Plans total").font(Theme.cardTitle)
                Spacer()
                Text(Fmt.money(total, "USD") + "/mo").font(.system(size: 15, weight: .semibold).monospacedDigit())
            }
            Text("Target \(Fmt.money(Self.target, "USD"))/mo · " + (total > Self.target ? "\(Fmt.money(total - Self.target, "USD")) over" : "\(Fmt.money(Self.target - total, "USD")) under")
                 + " · Ceiling \(Fmt.money(budget.ceiling, "USD"))/mo for all AI and tech")
                .font(Theme.caption).foregroundStyle(.secondary)
            if unconfirmed > 0 {
                Text("\(unconfirmed) price\(unconfirmed == 1 ? " is a list price" : "s are list prices") until you confirm \(unconfirmed == 1 ? "it" : "them").")
                    .font(Theme.caption).foregroundStyle(Theme.warn)
            }
        }
        .card(padding: 12, radius: 14)
    }
}

/// The same plan actions in a tile's right-click menu.
struct ManagePlanMenu: View {
    @ObservedObject var store: AccountStore
    let id: String
    var body: some View {
        if let c = PlanStore.shared.cards(store).first(where: { $0.id == id }) {
            Menu("Manage plan") {
                ForEach(PlanAction.allCases) { a in
                    if !(a == .extra && c.vendor == .chatgpt) {
                        Button(a.title) { PlanStore.shared.perform(a, c, store: store) }
                    }
                }
                Divider()
                Button("All plans…") { ReportNav.open("money", store: store) }
            }
        }
    }
}

// MARK: - Command center (budget, trends, ideas, manager)
//
// Everything here works from real, measured data: the saved daily token totals, the limit
// snapshots, the ledger and what the user typed in. Nothing is projected or estimated; where a
// figure can't be measured the UI says so. The manager is the one place that produces opinions,
// and it is labelled as Claude's reading of the numbers, with its own API cost shown next to it.

enum Brand {
    /// The mark used in window headers: a plain gauge glyph on a flat dark tile.
    static func mark(_ size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(Color.primary.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .overlay(Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: size * 0.52, weight: .medium))
                .foregroundStyle(.primary))
            .frame(width: size, height: size)
    }
}


// MARK: - Projects (time and cost to delivery, private P&L)
//
// A project is a working folder (its git root when it has one). Everything shown is measured:
// active time from Claude Code transcript timestamps, publish events from the commands Claude
// ran and from git, money from the ledgers. Where a figure is an allocation or a detection it is
// labelled so. The delivery end and the impact rating are the user's call. Income stays on this
// Mac: it is kept out of status.json, the phone feed and the manager's data pack.
// The tables roll folders up to their repo (RepoGroup); the folders stay as they are underneath, so a
// new worktree joins its repo by itself and the user can move a folder or keep it apart.

struct ProjectInfo: Codable, Identifiable, Hashable {
    var id: String                      // the folder it was first seen in
    var name: String
    var folders: [String]
    var hidden = false
    var start: Date?                    // set by the user; otherwise the first measured activity
    var end: Date?                      // confirmed by the user
    var rating: Int?                    // impact 1–5, the user's own rating
    var outcome = ""
    var manual: [ManualHours] = []
    var payers: [String] = []           // payer keys whose deposits tag here automatically
    var repo: String?                   // set by the user; otherwise detected (ProjectStore.repoName)
}

/// What git says a folder belongs to. `remote` means the name came from origin, so other folders may match it.
struct RepoRef: Codable, Hashable {
    var name: String
    var remote: Bool
}

struct ManualHours: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var hours: Double
    var note: String
}

struct Milestone: Codable, Identifiable, Hashable {
    var id: String
    var date: Date
    var folder: String
    var kind: String                    // Deploy, App upload, Release, Merge, Tag, Preview, Push
    var detail: String
    var source: String                  // "Claude Code" or "git"
    var failed = false
    var dismissed = false
    var major: Bool { !["Push", "Preview"].contains(kind) }
    /// git shows the same tag or push once per worktree of a repo; this makes them one event.
    var key: String { source == "git" ? "\(kind)|\(detail)|\(Int(date.timeIntervalSince1970))" : id }
}

struct DayStat: Codable, Hashable {
    var minutes = 0.0
    var tokens = 0
    var value = 0.0
    var sessions = 0
    var codexTokens = 0
    var codexThreads = 0
    /// API-price value by account name; nil on days counted before accounts were kept.
    var byAccount: [String: Double]?
}

struct Income: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var payer: String
    var memo: String
    var amount: Double
    var kind = "Income"                 // "Income" counts; "Transfer" is kept but left out of totals
    var project: String?
}

enum ProjectScan {
    /// A gap between two turns up to this long counts as working time; longer gaps are breaks.
    static let breakGap: TimeInterval = 15 * 60
    /// Days without any activity after a major publish before that publish reads as the (detected) end.
    static let quietDays = 14.0

    private struct Seen: Codable { var read: UInt64; var cwd: String? }
    private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.ai-orchestrator/project-scan.json")
    }
    private static var seen: [String: Seen] = {
        guard let d = try? Data(contentsOf: cacheURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Seen].self, from: d)) ?? [:]
    }()
    private static let transcripts = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    private static var roots: [String: String] = [:]
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    struct Result {
        var sessionFolder: [String: String] = [:]
        var milestones: [Milestone] = []
        var failed: Set<String> = []
    }

    /// The git root above a working directory, or the directory itself.
    static func root(_ cwd: String) -> String {
        if let r = roots[cwd] { return r }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var url = URL(fileURLWithPath: cwd).standardizedFileURL
        var found = url.path
        while url.path.count > home.count {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { found = url.path; break }
            url.deleteLastPathComponent()
        }
        roots[cwd] = found
        return found
    }

    static func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    static func date(ofKey k: String) -> Date? {
        let p = k.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    /// What kind of publish a command is, or nil. Commands are matched as typed; a compound
    /// command ("git commit && git push") counts as its strongest part.
    static func classify(_ raw: String) -> String? {
        let c = raw.lowercased()
        func has(_ s: String) -> Bool { c.contains(s) }
        if has("merge_pull_request") || has("gh pr merge") { return "Merge" }
        if has("gh release create") || has("create_release") || has("npm publish") || has("pnpm publish") || has("yarn publish")
            || has("yarn npm publish") || has("cargo publish") || has("twine upload") || has("gem push") { return "Release" }
        if (has("altool") && has("upload")) || has("eas submit") || has("-exportarchive") || has("upload-app")
            || (has("fastlane") && (has("pilot") || has("deliver") || has("upload"))) { return "App upload" }
        if has("create_deployment") || has("netlify deploy") || has("firebase deploy") || has("wrangler deploy")
            || has("wrangler pages deploy") || has("fly deploy") || has("railway up") || has("gcloud run deploy") || has("gcloud app deploy") {
            return "Deploy"
        }
        if has("vercel") && (has("deploy") || has("--prod") || c.hasSuffix("vercel")) {
            return has("--prod") || has("--production") ? "Deploy" : "Preview"
        }
        if has("git tag ") && !has("git tag -l") && !has("git tag --list") && !has("git tag -d") { return "Tag" }
        if has("git push") { return has("--tags") ? "Tag" : "Push" }
        return nil
    }

    private static let keywords: [String] = ["git push", "git tag", "gh pr merge", "gh release", "publish", "vercel", "deploy",
                                            "altool", "exportArchive", "upload", "fastlane", "eas submit", "merge_pull_request",
                                            "railway up", "twine", "gem push", "create_release"]

    private static func has(_ p: UnsafeRawPointer, _ len: Int, _ s: String) -> Bool {
        s.utf8CString.withUnsafeBufferPointer { b in memmem(p, len, b.baseAddress, b.count - 1) != nil }
    }

    /// A JSON string value after `"key":"`, unescaped.
    private static func jsonString(_ p: UnsafeRawPointer, _ len: Int, key: String) -> String? {
        let needle = "\"\(key)\":\""
        guard let r = needle.utf8CString.withUnsafeBufferPointer({ b in memmem(p, len, b.baseAddress, b.count - 1) }) else { return nil }
        let i = p.distance(to: UnsafeRawPointer(r)) + needle.utf8.count
        var j = i, escaped = false
        while j < len {
            let c = p.load(fromByteOffset: j, as: UInt8.self)
            if escaped { escaped = false } else if c == 0x5C { escaped = true } else if c == 0x22 { break }
            j += 1
        }
        let raw = Data(bytes: p + i, count: j - i)
        guard let wrapped = ("[\"" + String(decoding: raw, as: UTF8.self) + "\"]").data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: wrapped) as? [String] else { return String(decoding: raw, as: UTF8.self) }
        return arr.first
    }

    private static func when(_ s: String?) -> Date? {
        guard let s else { return nil }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }

    /// Reads every Claude Code transcript from where the last scan stopped: each session's working
    /// folder, publish commands Claude ran, and which of those commands failed. Call on TokenCounter.queue.
    static func scan() -> Result {
        var out = Result()
        let fm = FileManager.default
        let base = transcripts.standardizedFileURL.pathComponents.count
        guard let e = fm.enumerator(at: transcripts, includingPropertiesForKeys: nil) else { return out }
        for case let url as URL in e where url.pathExtension == "jsonl" {
            let comps = url.standardizedFileURL.pathComponents
            guard comps.count > base + 1 else { continue }
            let session = comps.count == base + 2 ? url.deletingPathExtension().lastPathComponent : comps[base + 1]
            let size = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
            var s = seen[url.path] ?? Seen(read: 0, cwd: nil)
            if size < s.read { s = Seen(read: 0, cwd: nil) }
            if size > s.read, let data = try? Data(contentsOf: url, options: .alwaysMapped), UInt64(data.count) > s.read {
                var consumed = 0
                data.withUnsafeBytes { (all: UnsafeRawBufferPointer) in
                    guard let start0 = all.baseAddress else { return }
                    let p0 = start0 + Int(s.read)
                    let n = all.count - Int(s.read)
                    var start = 0
                    while start < n {
                        guard let nl = memchr(p0 + start, 0x0A, n - start) else { break }
                        let end = p0.distance(to: UnsafeRawPointer(nl))
                        let p = p0 + start, len = end - start
                        let lineCwd = jsonString(p, len, key: "cwd")
                        if s.cwd == nil, let c = lineCwd, !c.isEmpty { s.cwd = c }
                        if has(p, len, "\"tool_use\""), keywords.contains(where: { has(p, len, $0) }) {
                            out.milestones += milestones(Data(bytes: p, count: len), cwd: lineCwd ?? s.cwd)
                        }
                        if has(p, len, "\"tool_result\""), has(p, len, "\"is_error\":true") {
                            out.failed.formUnion(failures(Data(bytes: p, count: len)))
                        }
                        start = end + 1
                        consumed = start
                    }
                }
                s.read += UInt64(consumed)
                seen[url.path] = s
            }
            if let c = s.cwd, out.sessionFolder[session] == nil { out.sessionFolder[session] = root(c) }
        }
        try? fm.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(seen) { try? d.write(to: cacheURL, options: .atomic) }
        return out
    }

    private static func milestones(_ line: Data, cwd: String?) -> [Milestone] {
        guard let cwd, let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let msg = obj["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]],
              let at = when(obj["timestamp"] as? String) else { return [] }
        var out: [Milestone] = []
        for item in content where item["type"] as? String == "tool_use" {
            guard let id = item["id"] as? String, let name = item["name"] as? String else { continue }
            let command = name == "Bash" ? ((item["input"] as? [String: Any])?["command"] as? String ?? "") : name
            guard let kind = classify(command) else { continue }
            let detail = command.split(separator: "\n").first.map { String($0.prefix(160)) } ?? ""
            out.append(Milestone(id: id, date: at, folder: root(cwd), kind: kind, detail: detail, source: "Claude Code"))
        }
        return out
    }

    private static func failures(_ line: Data) -> [String] {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let msg = obj["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] else { return [] }
        return content.compactMap { $0["is_error"] as? Bool == true ? $0["tool_use_id"] as? String : nil }
    }

    /// Measured active minutes, tokens and API-price value per folder and local day. Turns from all
    /// sessions in a folder are merged first, so two sessions running at once don't count twice.
    static func days(entries: [(entry: TokenCounter.Entry, session: String)], folderOf: [String: String], accountOf: [String: String]) -> [String: [String: DayStat]] {
        var byFolder: [String: [(entry: TokenCounter.Entry, session: String)]] = [:]
        for e in entries { if let f = folderOf[e.session] { byFolder[f, default: []].append(e) } }
        var out: [String: [String: DayStat]] = [:]
        for (folder, list) in byFolder {
            let sorted = list.sorted { $0.entry.date < $1.entry.date }
            var days: [String: DayStat] = [:]
            var sessions: [String: Set<String>] = [:]
            var prev: Date?
            for (en, session) in sorted {
                let k = dayKey(en.date)
                var d = days[k] ?? DayStat()
                if let prev, en.date.timeIntervalSince(prev) <= breakGap { d.minutes += en.date.timeIntervalSince(prev) / 60 }
                d.tokens += en.input + en.output + en.cacheWrite + en.cacheRead
                d.value += APIPrices.cost(en)
                d.byAccount = d.byAccount ?? [:]
                d.byAccount?[accountOf[session] ?? "Terminal & remote", default: 0] += APIPrices.cost(en)
                days[k] = d
                sessions[k, default: []].insert(session)
                prev = en.date
            }
            for (k, set) in sessions { days[k]?.sessions = set.count }
            out[folder] = days
        }
        return out
    }

    /// Codex threads with their working folder (newer Codex databases have a cwd column; older ones return nothing).
    static func codexThreads(home: URL) -> [CodexDays.Thread] {
        let db = home.appendingPathComponent("state_5.sqlite")
        guard FileManager.default.fileExists(atPath: db.path) else { return [] }
        var h: OpaquePointer?
        guard ReadOnlyDB.open(db, &h) == SQLITE_OK else { sqlite3_close(h); return [] }
        defer { sqlite3_close(h) }
        var st: OpaquePointer?
        defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(h, "SELECT cwd, created_at, tokens_used, model, rollout_path FROM threads WHERE tokens_used > 0", -1, &st, nil) == SQLITE_OK
                || sqlite3_prepare_v2(h, "SELECT cwd, created_at, tokens_used, '', '' FROM threads WHERE tokens_used > 0", -1, &st, nil) == SQLITE_OK else { return [] }
        var out: [CodexDays.Thread] = []
        while sqlite3_step(st) == SQLITE_ROW {
            guard let c = sqlite3_column_text(st, 0) else { continue }
            out.append(CodexDays.Thread(cwd: String(cString: c), created: Date(timeIntervalSince1970: Double(sqlite3_column_int64(st, 1))),
                                        tokens: Int(sqlite3_column_int64(st, 2)),
                                        model: sqlite3_column_text(st, 3).map { String(cString: $0) } ?? "",
                                        rollout: sqlite3_column_text(st, 4).map { String(cString: $0) } ?? ""))
        }
        return out
    }

    private static func git(_ folder: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", folder] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        // A scan runs hundreds of these; open pipes would use up the app's file limit and later folders fail.
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        do { try p.run() } catch { return "" }
        try? pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : ""
    }

    /// The repo a folder belongs to according to git: worktrees and clones resolve to one name, origin's
    /// or else the main checkout's folder. Nil when git can't say; a deleted worktree still names its repo.
    static func repoRef(_ folder: String) -> RepoRef? {
        var path = folder
        if let r = path.range(of: "/.claude/worktrees/") { path = String(path[..<r.lowerBound]) }
        let common = git(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !common.isEmpty else { return path == folder ? nil : RepoRef(name: URL(fileURLWithPath: path).lastPathComponent, remote: false) }
        let main = URL(fileURLWithPath: common).deletingLastPathComponent().path
        let remote = git(main, ["remote", "get-url", "origin"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = remote.split(whereSeparator: { $0 == "/" || $0 == ":" }).last else {
            return RepoRef(name: URL(fileURLWithPath: main).lastPathComponent, remote: false)
        }
        return RepoRef(name: last.hasSuffix(".git") ? String(last.dropLast(4)) : String(last), remote: true)
    }

    /// A worktree shares its tags and remote refs with the main checkout, so git is read there, once.
    static func mainCheckout(_ folder: String) -> String {
        guard let link = try? String(contentsOfFile: folder + "/.git", encoding: .utf8), link.hasPrefix("gitdir: "),
              let r = link.range(of: "/.git/worktrees/") else { return folder }
        return String(link[link.index(link.startIndex, offsetBy: 8)..<r.lowerBound])
    }

    /// Tags, pushes recorded in the remote-tracking reflogs (from any tool, not only Claude) and
    /// the first commit's date. Only runs in folders that have a .git directory.
    static func gitEvents(_ folder: String) -> (first: Date?, milestones: [Milestone]) {
        guard FileManager.default.fileExists(atPath: folder + "/.git") else { return (nil, []) }
        var ms: [Milestone] = []
        for line in git(folder, ["for-each-ref", "refs/tags", "--format=%(creatordate:unix)|%(refname:short)"]).split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, let t = Double(parts[0]) else { continue }
            ms.append(Milestone(id: "tag:\(folder):\(parts[1])", date: Date(timeIntervalSince1970: t), folder: folder,
                                kind: "Tag", detail: "tag \(parts[1])", source: "git"))
        }
        for ref in git(folder, ["for-each-ref", "refs/remotes", "--format=%(refname)"]).split(separator: "\n") where !ref.hasSuffix("/HEAD") {
            let branch = ref.replacingOccurrences(of: "refs/remotes/", with: "")
            for line in git(folder, ["reflog", "show", "--date=unix", "--format=%gd|%gs", String(ref)]).split(separator: "\n") where line.contains("update by push") {
                guard let a = line.range(of: "@{"), let b = line.range(of: "}|"), a.upperBound < b.lowerBound,
                      let t = Double(line[a.upperBound..<b.lowerBound]) else { continue }
                ms.append(Milestone(id: "push:\(folder):\(branch):\(Int(t))", date: Date(timeIntervalSince1970: t), folder: folder,
                                    kind: "Push", detail: "pushed \(branch)", source: "git"))
            }
        }
        let first = git(folder, ["log", "--max-parents=0", "--format=%ct"]).split(separator: "\n").compactMap { Double($0) }.min()
        return (first.map { Date(timeIntervalSince1970: $0) }, ms)
    }

    /// "ACH DEPOSIT ACME CO 4471" → "ach deposit acme co": the same payer's repeat deposits share a key.
    static func payerKey(_ s: String) -> String {
        let kept = s.lowercased().unicodeScalars.map { CharacterSet.letters.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }
}

final class ProjectStore: ObservableObject {
    static let shared = ProjectStore()

    struct Saved: Codable {
        var projects: [ProjectInfo] = []
        var milestones: [Milestone] = []
        var days: [String: [String: DayStat]] = [:]      // folder → yyyy-MM-dd → measured
        var firstCommit: [String: Date] = [:]
        var lastScan: Date?
        var repos: [String: RepoRef]?                    // folder → repo; kept after a worktree is deleted
    }

    static let file = History.dir.appendingPathComponent("projects.json")
    static let incomeFile = History.dir.appendingPathComponent("income.json")

    private static func load<T: Decodable>(_ url: URL, _ fallback: T) -> T {
        guard let d = try? Data(contentsOf: url) else { return fallback }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(T.self, from: d)) ?? fallback
    }
    private static func save<T: Encodable>(_ v: T, _ url: URL) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
        try? FileManager.default.createDirectory(at: History.dir, withIntermediateDirectories: true)
        if let d = try? enc.encode(v) { try? d.write(to: url, options: .atomic) }
    }

    private static let saves = DispatchQueue(label: "ai-orchestrator.projects-save")
    @Published var saved: Saved = ProjectStore.load(ProjectStore.file, Saved()) {
        didSet { let v = saved; Self.saves.async { Self.save(v, Self.file) }; refreshReport() }
    }
    @Published var income: [Income] = ProjectStore.load(ProjectStore.incomeFile, [Income]()) {
        didSet { let v = income; Self.saves.async { Self.save(v, Self.incomeFile) }; refreshReport() }
    }
    @Published var scanning = false
    @Published var unlocked = false
    @Published var targetRate: Double = UserDefaults.standard.object(forKey: "targetRate") as? Double ?? 250 {
        didSet { UserDefaults.standard.set(targetRate, forKey: "targetRate") }
    }
    private var lockTimer: Timer?

    // MARK: Private mode
    func unlock() {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "show project income and profit") { ok, _ in
            DispatchQueue.main.async {
                guard ok else { return }
                self.unlocked = true
                self.lockTimer?.invalidate()
                self.lockTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: false) { [weak self] _ in self?.lock() }
            }
        }
    }
    func lock() { unlocked = false; lockTimer?.invalidate(); lockTimer = nil }

    // MARK: Scanning
    /// Scans when the last scan is over five minutes old; the button under Projects always does.
    func refreshIfStale(accounts: [Account], codexHomes: [URL]) {
        if Date().timeIntervalSince(saved.lastScan ?? .distantPast) > 300 { refresh(accounts: accounts, codexHomes: codexHomes) }
    }

    func refresh(accounts: [Account], codexHomes: [URL]) {
        guard !scanning else { return }
        let profiles = accounts.map { ($0.profileURL, $0.name) }
        scanning = true
        let known = Set(saved.days.keys).union(saved.projects.flatMap(\.folders))
        TokenCounter.queue.async {
            let r = ProjectScan.scan()
            let entries = TokenCounter.everything(profiles: profiles.map(\.0), since: .distantPast)
            var accountOf: [String: String] = [:]
            for (url, name) in profiles { for id in TokenCounter.sessionIDs(profile: url) { accountOf[id] = name } }
            var fresh = ProjectScan.days(entries: entries, folderOf: r.sessionFolder, accountOf: accountOf)
            for home in codexHomes {
                for t in CodexDays.rows(home: home) where !t.cwd.isEmpty {
                    let f = ProjectScan.root(t.cwd)
                    var d = fresh[f]?[t.day] ?? DayStat()
                    d.codexTokens += t.tokens
                    d.codexThreads += t.threads
                    fresh[f, default: [:]][t.day] = d
                }
            }
            var ms = r.milestones
            var firsts: [String: Date] = [:]
            var repos: [String: RepoRef] = [:]
            var read = Set<String>()
            for f in known.union(fresh.keys) {
                repos[f] = ProjectScan.repoRef(f)
                let main = ProjectScan.mainCheckout(f)
                guard read.insert(main).inserted else { continue }
                let g = ProjectScan.gitEvents(main)
                ms += g.milestones
                if let d = g.first { firsts[main] = d }
            }
            DispatchQueue.main.async {
                self.merge(fresh: fresh, milestones: ms, failed: r.failed, firsts: firsts, repos: repos, oldest: entries.map(\.entry.date).min())
                self.scanning = false
            }
        }
    }

    private func merge(fresh: [String: [String: DayStat]], milestones: [Milestone], failed: Set<String>, firsts: [String: Date], repos: [String: RepoRef], oldest: Date? = nil) {
        var s = saved
        // Days whose transcripts are all still on disk (after the oldest one found, inside Claude Code's 30-day
        // cleanup) are recounted whole, so a session that moved to another folder stops counting in both.
        let cal = Calendar.current
        let whole = oldest.flatMap { o -> String? in
            guard let after = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: o)),
                  let recent = cal.date(byAdding: .day, value: -28, to: cal.startOfDay(for: Date())) else { return nil }
            return ProjectScan.dayKey(max(after, recent))
        }
        if let whole {
            for f in s.days.keys {
                for k in s.days[f]!.keys where k >= whole && fresh[f]?[k] == nil {
                    var d = s.days[f]![k]!
                    d.minutes = 0; d.tokens = 0; d.value = 0; d.sessions = 0; d.byAccount = nil
                    s.days[f]![k] = d
                }
            }
        }
        // Codex's database keeps every thread, so its tokens are recounted whole; that lets them move
        // from a thread's first day to the days they were really used.
        let total = { (m: [String: [String: DayStat]]) in m.values.flatMap(\.values).map(\.codexTokens).reduce(0, +) }
        if total(fresh) >= total(s.days) {
            for f in s.days.keys { for k in s.days[f]!.keys { s.days[f]![k]!.codexTokens = 0; s.days[f]![k]!.codexThreads = 0 } }
        }
        // Claude Code deletes old transcripts, so saved days are kept and only ever raised. Value follows
        // the tokens instead: while a day's transcripts are all still here, it reprices at current rates.
        for (folder, days) in fresh {
            for (k, d) in days {
                var o = s.days[folder]?[k] ?? DayStat()
                if let whole, k >= whole { o.minutes = 0; o.tokens = 0; o.sessions = 0 }
                s.days[folder, default: [:]][k] = DayStat(minutes: max(o.minutes, d.minutes), tokens: max(o.tokens, d.tokens),
                                                         value: d.tokens >= o.tokens ? d.value : o.value, sessions: max(o.sessions, d.sessions),
                                                         codexTokens: max(o.codexTokens, d.codexTokens), codexThreads: max(o.codexThreads, d.codexThreads),
                                                         byAccount: d.tokens >= o.tokens ? d.byAccount : o.byAccount)
            }
        }
        var ids = Set(s.milestones.map(\.id))
        for m in milestones where ids.insert(m.id).inserted { s.milestones.append(m) }
        for i in s.milestones.indices where failed.contains(s.milestones[i].id) { s.milestones[i].failed = true }
        s.milestones.sort { $0.date < $1.date }
        for (f, d) in firsts { s.firstCommit[f] = d }
        s.repos = (s.repos ?? [:]).merging(repos) { $1 }
        let claimed = Set(s.projects.flatMap(\.folders))
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        for folder in Set(s.days.keys).union(s.milestones.map(\.folder)).sorted() where !claimed.contains(folder) {
            let name = folder == home ? "Home folder (no project)" : URL(fileURLWithPath: folder).lastPathComponent
            s.projects.append(ProjectInfo(id: folder, name: name, folders: [folder], hidden: folder == home))
        }
        s.lastScan = Date()
        saved = s
    }

    func addFolder(_ path: String) {
        let folder = URL(fileURLWithPath: path).standardizedFileURL.path   // root() caches on the scan queue
        guard !saved.projects.contains(where: { $0.folders.contains(folder) }) else { return }
        saved.projects.append(ProjectInfo(id: folder, name: URL(fileURLWithPath: folder).lastPathComponent, folders: [folder]))
    }

    func update(_ p: ProjectInfo) {
        if p.id.hasPrefix("repo:") { updateRollup(p); return }
        if let i = saved.projects.firstIndex(where: { $0.id == p.id }) { saved.projects[i] = p }
        show(p)
    }

    /// Puts an edit on screen right away, ahead of the rebuild it started, so a text field keeps up with typing.
    private func show(_ p: ProjectInfo) {
        var r = report
        for i in r.all.indices where r.all[i].id == p.id { r.all[i].info = p }
        r.groups = r.groups.map { g in
            guard g.id == p.id else { return g }
            var total = g.total
            total.info = p
            return RepoGroup(repo: g.repo, total: total, folders: g.folders)
        }
        report = r
    }

    /// Moves a project's folders, hours, payers and tags into another project.
    func merge(_ from: ProjectInfo, into to: ProjectInfo) {
        guard from.id != to.id, var target = saved.projects.first(where: { $0.id == to.id }) else { return }
        target.folders += from.folders
        target.manual += from.manual
        target.payers += from.payers
        if target.start == nil { target.start = from.start }
        update(target)
        saved.projects.removeAll { $0.id == from.id }
        for i in income.indices where income[i].project == from.id { income[i].project = to.id }
        for i in Spend.shared.payments.indices where Spend.shared.payments[i].project == from.id { Spend.shared.payments[i].project = to.id }
    }

    func setMilestone(_ id: String, dismissed: Bool) {
        guard let key = saved.milestones.first(where: { $0.id == id })?.key else { return }
        for i in saved.milestones.indices where saved.milestones[i].key == key { saved.milestones[i].dismissed = dismissed }
    }

    // MARK: Income
    /// Adds deposits, skipping ones already kept (same day, amount and memo), and tags repeat payers.
    /// Returns how many were new.
    @discardableResult func addIncome(_ rows: [Income]) -> Int {
        let cal = Calendar.current
        func key(_ r: Income) -> String { "\(cal.startOfDay(for: r.date).timeIntervalSince1970)|\(r.amount)|\(r.memo.lowercased())" }
        let existing = Set(income.map(key))
        var fresh = rows.filter { !existing.contains(key($0)) }
        for i in fresh.indices {
            let k = ProjectScan.payerKey(fresh[i].memo)
            fresh[i].project = saved.projects.first { $0.payers.contains(k) }?.id
            let m = fresh[i].memo.lowercased()
            if m.contains("transfer") || m.contains("pocket") || m.contains("savings") { fresh[i].kind = "Transfer" }
        }
        income = (income + fresh).sorted { $0.date > $1.date }
        return fresh.count
    }

    /// Tags a deposit and remembers its payer, so later deposits from the same payer tag themselves.
    func tag(_ row: Income, project: String?) {
        guard let i = income.firstIndex(where: { $0.id == row.id }) else { return }
        income[i].project = project
        let k = ProjectScan.payerKey(row.memo)
        for j in saved.projects.indices { saved.projects[j].payers.removeAll { $0 == k } }
        if let project, let j = saved.projects.firstIndex(where: { $0.id == project }), !k.isEmpty {
            saved.projects[j].payers.append(k)
            for r in income.indices where income[r].project == nil && ProjectScan.payerKey(income[r].memo) == k { income[r].project = project }
        }
    }

    /// Generic first words of bank descriptions; a deposit starting with one is never taken for a vendor refund.
    static let genericWords: Set<String> = ["ach", "transfer", "deposit", "payment", "zelle", "wire", "mobile", "check", "incoming",
                                            "online", "direct", "credit", "venmo", "paypal", "stripe", "square", "from", "inbound", "import"]

    /// Splits money coming in (negative after the import's sign flip) into vendor refunds, which stay in
    /// the expense ledger, and deposits, which go to income. A refund is money in from a provider that
    /// also appears as an AI or Tech charge.
    static func splitMoneyIn(_ rows: [Spend.Payment], knownCharges: [Spend.Payment]) -> (refunds: [Spend.Payment], deposits: [Income]) {
        let vendors = Set(knownCharges.filter { $0.amount > 0 && $0.isTech }.map { $0.provider.lowercased() }).subtracting(genericWords)
        var refunds: [Spend.Payment] = [], deposits: [Income] = []
        for r in rows {
            if vendors.contains(r.provider.lowercased()) { refunds.append(r) }
            else { deposits.append(Income(date: r.date, payer: r.provider, memo: r.item, amount: -r.amount)) }
        }
        return (refunds, deposits)
    }

    /// Money-in rows already sitting in the expense ledger from earlier imports.
    var depositsInLedger: [Spend.Payment] {
        let pay = Spend.shared.payments
        let neg = pay.filter { $0.amount < 0 }
        let refunds = Set(Self.splitMoneyIn(neg, knownCharges: pay).refunds.map(\.id))
        return neg.filter { !refunds.contains($0.id) }
    }

    func moveDepositsFromLedger() {
        let rows = depositsInLedger
        guard !rows.isEmpty else { return }
        let backup = History.dir.appendingPathComponent("payments-before-income-\(ProjectScan.dayKey(Date())).json")
        try? FileManager.default.copyItem(at: Spend.paymentsFile, to: backup)
        addIncome(rows.map { Income(date: $0.date, payer: $0.provider, memo: $0.item, amount: -$0.amount) })
        let ids = Set(rows.map(\.id))
        Spend.shared.payments.removeAll { ids.contains($0.id) }
    }

    // MARK: Summaries
    struct Summary: Identifiable {
        var info: ProjectInfo
        var id: String { info.id }
        var start: Date?
        var startSource = ""
        var lastActive: Date?
        var minutes = 0.0
        var minutesToEnd = 0.0
        var manualHours = 0.0
        var tokens = 0, codexTokens = 0, codexThreads = 0, activeDays = 0
        /// Claude Code and Codex tokens this calendar month and in the last 30 days (today included).
        var monthTokens = 0, monthCodex = 0, recentTokens = 0, recentCodex = 0
        var value = 0.0
        var milestones: [Milestone] = []
        var detectedEnd: Date?
        var income = 0.0, expenses = 0.0, aiClaude = 0.0, aiCodex = 0.0
        var aiAllocated: Double { aiClaude + aiCodex }
        var members: [String] = []                       // project ids counted here, the repo's main folder first
        var primaryID: String { members.first ?? info.id }
        var isRollup: Bool { info.id.hasPrefix("repo:") }
        var allTokens: Int { tokens + codexTokens }
        var hours: Double { minutes / 60 + manualHours }
        var cost: Double { expenses + aiAllocated }
        var profit: Double { income - cost }
        var rate: Double? { hours > 0 && income > 0 ? income / hours : nil }
        var end: Date? { info.end ?? detectedEnd }
        var majors: [Milestone] { milestones.filter { $0.major && !$0.failed } }
        var firstMajor: Date? { majors.first?.date }
        var tokensPerHour: Double? { minutes >= 30 ? Double(tokens) / (minutes / 60) : nil }
        var daysToDeliver: Int? {
            guard let start, let end else { return nil }
            return max(0, Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: start), to: Calendar.current.startOfDay(for: end)).day ?? 0)
        }
    }

    /// One row of the tables: a repo's folders added together, or a single folder.
    struct RepoGroup: Identifiable {
        let repo: String
        let total: Summary
        let folders: [Summary]
        var id: String { total.id }
    }

    /// What the Projects tab draws, worked out away from the main thread.
    struct Report {
        var ready = false
        var all: [Summary] = []
        var groups: [RepoGroup] = []
        var unattributed = 0.0
        var bankThrough: String?
        var atFace = 0.0
        var check = TokenCheck()
    }

    /// Last 30 days: tokens the project folders hold against everything counted on this Mac, so the table can be checked.
    struct TokenCheck {
        var from = "", to = ""
        var projectClaude = 0, allClaude = 0, projectCodex = 0, allCodex = 0
        var lastCodex = ""             // newest day any project folder has Codex tokens
    }
    @Published private(set) var report = Report()
    private static let reports = DispatchQueue(label: "ai-orchestrator.projects-report", qos: .userInitiated)
    private var reportRun = 0
    private var watching: Set<AnyCancellable> = []

    private var books: Books { Books(saved: saved, income: income, pay: Spend.shared.payments, subs: Spend.shared.subscriptions, usage: DailyUsage.shared.days) }

    /// Rebuilds `report` in the background from what's here now; the latest call wins.
    func refreshReport() {
        reportRun += 1
        let run = reportRun, books = books
        Self.reports.async {
            guard self.isLatest(run) else { return }
            let r = books.report()
            DispatchQueue.main.async { if run == self.reportRun { self.report = r } }
        }
    }
    private func isLatest(_ run: Int) -> Bool { DispatchQueue.main.sync { run == reportRun } }

    /// Starts the first report and follows the money and usage it's built from.
    func prepare() {
        guard watching.isEmpty else { return }
        refreshReport()
        Spend.shared.$payments.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshReport() }.store(in: &watching)
        Spend.shared.$subscriptions.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshReport() }.store(in: &watching)
        DailyUsage.shared.$days.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshReport() }.store(in: &watching)
    }

    func repoName(_ info: ProjectInfo) -> String { books.repoName(info) }

    /// Saves every project folder's tokens by day, so each figure in Tokens by project can be checked.
    func exportTokens() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "project-tokens-\(ProjectScan.dayKey(Date())).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? books.tokenCSV().write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// An edit made on a repo row lands on its main folder; the folders underneath stay as they are.
    private func updateRollup(_ p: ProjectInfo) {
        guard let g = report.groups.first(where: { $0.id == p.id }) else { return }
        let keep = Set(p.manual.map(\.id)), had = Set(g.total.info.manual.map(\.id))
        var s = saved
        for i in s.projects.indices where g.total.members.contains(s.projects[i].id) {
            s.projects[i].manual.removeAll { !keep.contains($0.id) }
            s.projects[i].hidden = p.hidden
            guard s.projects[i].id == g.total.primaryID else {
                s.projects[i].start = nil; s.projects[i].end = nil; s.projects[i].rating = nil; s.projects[i].outcome = ""
                continue
            }
            s.projects[i].name = p.name
            s.projects[i].start = p.start; s.projects[i].end = p.end; s.projects[i].rating = p.rating; s.projects[i].outcome = p.outcome
            s.projects[i].manual += p.manual.filter { !had.contains($0.id) }
        }
        saved = s
        show(p)
    }
}

/// The sums behind the Projects tab, over a copy of the data, so they can run on any thread.
struct Books {
    typealias Summary = ProjectStore.Summary
    typealias RepoGroup = ProjectStore.RepoGroup
    let saved: ProjectStore.Saved
    let income: [Income]
    let pay: [Spend.Payment]
    let subs: [Subscription]
    let usage: [UsageDay]

    func report() -> ProjectStore.Report {
        let a = allocation()
        let all = summaries(a)
        return ProjectStore.Report(ready: true, all: all, groups: repoGroups(all, a), unattributed: a.unattributed, bankThrough: a.bankThrough, atFace: a.atFace, check: tokenCheck())
    }

    /// Window keys: this month ("yyyy-MM") and the first day of the last 30 ("yyyy-MM-dd").
    static func windows(_ now: Date = Date()) -> (month: String, recent: String) {
        let from = Calendar.current.date(byAdding: .day, value: -29, to: Calendar.current.startOfDay(for: now)) ?? now
        return (String(ProjectScan.dayKey(now).prefix(7)), ProjectScan.dayKey(from))
    }

    private func tokenCheck() -> ProjectStore.TokenCheck {
        let w = Self.windows()
        var c = ProjectStore.TokenCheck(from: w.recent, to: ProjectScan.dayKey(Date()))
        let mine = Set(saved.projects.flatMap(\.folders))
        for (f, days) in saved.days where mine.contains(f) { for (k, d) in days where d.codexTokens > 0 { c.lastCodex = max(c.lastCodex, k) } }
        for (f, days) in saved.days where mine.contains(f) { for (k, d) in days where k >= w.recent { c.projectClaude += d.tokens; c.projectCodex += d.codexTokens } }
        for d in usage where d.day >= w.recent {
            for x in d.accounts { if x.provider == "claude" { c.allClaude += x.tokens } else if x.provider == "codex" { c.allCodex += x.tokens } }
        }
        return c
    }

    /// Every folder's measured days as CSV, the rows behind the Tokens by project table.
    func tokenCSV() -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var csv = "repo,project,folder,date,claude_code_tokens,codex_tokens,codex_threads,claude_sessions,active_minutes,claude_api_value_usd\n"
        for p in saved.projects.sorted(by: { (repoName($0), $0.name) < (repoName($1), $1.name) }) {
            let repo = repoName(p)
            for f in p.folders {
                for (k, d) in (saved.days[f] ?? [:]).sorted(by: { $0.key < $1.key }) where d.tokens > 0 || d.codexTokens > 0 {
                    csv += "\(q(repo)),\(q(p.name)),\(q(f)),\(k),\(d.tokens),\(d.codexTokens),\(d.codexThreads),\(d.sessions),\(String(format: "%.1f", d.minutes)),\(String(format: "%.2f", d.value))\n"
                }
            }
        }
        return csv
    }

    /// What every summary needs: each month's AI dollars by vendor and the usage that shares them out.
    private struct Allocation {
        var pay: [Spend.Payment]
        var monthCodex: [String: Double] = [:], folderCodex: [String: [String: Double]] = [:]
        var claudeBy: [String: [String: Double]] = [:]   // folder, month, dollars
        var codex: [String: Double] = [:]
        var unattributed = 0.0
        var bankThrough: String?
        var atFace = 0.0
    }

    /// Real dollars. Claude: bank charges, then credits bought since the last bank date at face value;
    /// a month no statement reaches uses plans plus credits. Within a month plans follow their own
    /// account's value, and the rest follows extra usage: each day's billed dollars go to the repos that
    /// account worked on that day, up to the value they used. Extra billed before the widget's first reading
    /// follows the account's earlier days. Extra beyond Claude Code's value that day (chat, other devices),
    /// Cursor, and months with nothing recorded stay unattributed rather than landing on a repo. OpenAI's money follows Codex tokens.
    private func allocation() -> Allocation {
        var a = Allocation(pay: pay)
        var monthValue: [String: Double] = [:], folderMonth: [String: [String: Double]] = [:]
        var accountMonth: [String: [String: Double]] = [:], accountDay: [String: [String: Double]] = [:]
        var folderAccountMonth: [String: [String: [String: Double]]] = [:], folderAccountDay: [String: [String: [String: Double]]] = [:]
        for (folder, days) in saved.days {
            for (k, d) in days {
                let m = String(k.prefix(7))
                monthValue[m, default: 0] += d.value
                folderMonth[folder, default: [:]][m, default: 0] += d.value
                a.monthCodex[m, default: 0] += Double(d.codexTokens)
                a.folderCodex[folder, default: [:]][m, default: 0] += Double(d.codexTokens)
                for (acct, v) in d.byAccount ?? [:] {
                    accountMonth[acct, default: [:]][m, default: 0] += v
                    accountDay[acct, default: [:]][k, default: 0] += v
                    folderAccountMonth[folder, default: [:]][acct, default: [:]][m, default: 0] += v
                    folderAccountDay[folder, default: [:]][acct, default: [:]][k, default: 0] += v
                }
            }
        }
        var ledgerClaude: [String: Double] = [:], ledgerCodex: [String: Double] = [:]
        var lastBank = ""
        for p in a.pay where p.category == "AI" && p.project == nil {
            let t = (p.provider + " " + p.item).lowercased(), m = Fmt.monthKey(p.date)
            if t.contains("anthropic") || t.contains("claude") { ledgerClaude[m, default: 0] += p.amount; lastBank = max(lastBank, ProjectScan.dayKey(p.date)) }
            else if t.contains("openai") || t.contains("chatgpt") || t.contains("codex") { ledgerCodex[m, default: 0] += p.amount }
            else { a.unattributed += p.amount }
        }
        for c in BankCharges.load() where c.vendor == "Anthropic" {
            ledgerClaude[String(c.date.prefix(7)), default: 0] += c.amount
            lastBank = max(lastBank, c.date)
        }
        // A charge can post a day after the purchase shows up on Claude's side.
        let covered = ProjectScan.date(ofKey: lastBank).map { ProjectScan.dayKey($0.addingTimeInterval(36 * 3600)) } ?? ""
        a.bankThrough = lastBank.isEmpty ? nil : lastBank
        var credits: [String: Double] = [:], creditsSince: [String: Double] = [:]
        for p in PurchaseLog.load() {
            credits[Fmt.monthKey(p.date), default: 0] += p.amount
            if ProjectScan.dayKey(p.date) > covered { creditsSince[Fmt.monthKey(p.date), default: 0] += p.amount }
        }
        // Extra usage by account and day, from the snapshots; the month's highest reading holds what came before them.
        var extraDay: [String: [String: Double]] = [:], extraFirst: [String: String] = [:]
        for d in usage.reversed() {
            for x in d.accounts where x.provider == "claude" {
                guard let e = x.extra else { continue }
                extraDay[x.name, default: [:]][d.day] = e
                if extraFirst[x.name] == nil { extraFirst[x.name] = d.day }
            }
        }
        var extraHigh: [String: [String: Double]] = [:]
        for s in History.load(since: .distantPast) where s.provider == "claude" {
            if let e = s.extraUsed { extraHigh[s.name, default: [:]][Fmt.monthKey(s.t)] = max(extraHigh[s.name]?[Fmt.monthKey(s.t)] ?? 0, e) }
        }
        let now = Fmt.monthKey(Date())
        let months = Set(monthValue.keys).union(ledgerClaude.keys).union(ledgerCodex.keys).union(credits.keys).union([now]).filter { $0 <= now }
        for m in months {
            var plans = 0.0, codex = 0.0
            var accountPlans: [String: Double] = [:]
            for sub in subs where Fmt.monthKey(sub.changedAt ?? Date()) <= m {
                if let acc = sub.account, acc.hasPrefix("claude:") {
                    plans += sub.monthly
                    let name = accountMonth.keys.first { Self.simple($0) == Self.simple(String(acc.dropFirst(7))) } ?? ""
                    accountPlans[name, default: 0] += sub.monthly
                }
                else if sub.account?.hasPrefix("codex:") == true { codex += sub.monthly }
                else { a.unattributed += sub.monthly }
            }
            a.codex[m] = ledgerCodex[m] ?? codex
            if (a.monthCodex[m] ?? 0) <= 0 { a.unattributed += a.codex[m] ?? 0; a.codex[m] = nil }

            let since = covered.isEmpty ? 0 : creditsSince[m] ?? 0
            a.atFace += since
            let cash = ledgerClaude[m].map { $0 + since } ?? (covered >= m ? since : plans + (credits[m] ?? 0))
            guard (monthValue[m] ?? 0) > 0 else { a.unattributed += cash; continue }
            func give(_ folder: String, _ dollars: Double) { a.claudeBy[folder, default: [:]][m, default: 0] += dollars }
            func byMonth(_ dollars: Double) { for (f, v) in folderMonth where (v[m] ?? 0) > 0 { give(f, dollars * v[m]! / monthValue[m]!) } }

            // Plans first, each by its own account where that account has usage this month.
            var planLeft = min(plans, cash)
            let scale = plans > 0 ? planLeft / plans : 0
            for (acct, dollars) in accountPlans {
                guard let total = accountMonth[acct]?[m], total > 0 else { continue }
                for (f, accts) in folderAccountMonth { if let v = accts[acct]?[m] { give(f, dollars * scale * v / total) } }
                planLeft -= dollars * scale
            }
            byMonth(planLeft)

            // The rest in proportion to extra usage, day by day.
            let credit = max(0, cash - min(plans, cash))
            var weight: [String: Double] = [:], loose = 0.0
            for (acct, high) in extraHigh {
                guard let top = high[m] else { continue }
                let days = (extraDay[acct] ?? [:]).filter { $0.key.hasPrefix(m) }
                // Extra is billed at API prices, so a repo can't have used more of it than its own value.
                for (k, e) in days where e > 0 {
                    let total = accountDay[acct]?[k] ?? 0, tied = min(e, total)
                    loose += e - tied
                    guard tied > 0 else { continue }
                    for (f, accts) in folderAccountDay { if let v = accts[acct]?[k] { weight[f, default: 0] += tied * v / total } }
                }
                let before = max(0, top - days.values.reduce(0, +))
                let first = extraFirst[acct] ?? ""
                let earlier = (accountDay[acct] ?? [:]).filter { $0.key.hasPrefix(m) && $0.key <= first }.values.reduce(0, +)
                let tied = min(before, earlier)
                loose += before - tied
                guard tied > 0 else { continue }
                for (f, accts) in folderAccountDay {
                    let v = (accts[acct] ?? [:]).filter { $0.key.hasPrefix(m) && $0.key <= first }.values.reduce(0, +)
                    if v > 0 { weight[f, default: 0] += tied * v / earlier }
                }
            }
            let all = weight.values.reduce(0, +) + loose
            if all > 0 {
                for (f, w) in weight { give(f, credit * w / all) }
                a.unattributed += credit * loose / all
            } else { byMonth(credit) }
        }
        return a
    }

    private func summaries(_ a: Allocation) -> [Summary] {
        return saved.projects.map { summary($0, members: [$0.id], a) }
            .sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
    }

    private func summary(_ info: ProjectInfo, members: [String], _ a: Allocation) -> Summary {
        let cal = Calendar.current
        var s = Summary(info: info)
        s.members = members
        let folders = Set(info.folders), ids = Set(members)
        var firstDay: Date?, lastDay: Date?
        let w = Self.windows()
        for f in folders {
            for (k, d) in saved.days[f] ?? [:] where d.minutes > 0 || d.tokens > 0 || d.codexThreads > 0 || d.codexTokens > 0 {
                guard let day = ProjectScan.date(ofKey: k) else { continue }
                firstDay = min(firstDay ?? day, day); lastDay = max(lastDay ?? day, day)
                s.minutes += d.minutes; s.tokens += d.tokens; s.value += d.value
                s.codexTokens += d.codexTokens; s.codexThreads += d.codexThreads
                if k.hasPrefix(w.month) { s.monthTokens += d.tokens; s.monthCodex += d.codexTokens }
                if k >= w.recent { s.recentTokens += d.tokens; s.recentCodex += d.codexTokens }
            }
            s.aiClaude += (a.claudeBy[f] ?? [:]).values.reduce(0, +)
            for (m, v) in a.folderCodex[f] ?? [:] {
                if let total = a.monthCodex[m], total > 0, let ai = a.codex[m] { s.aiCodex += ai * v / total }
            }
        }
        s.activeDays = Set(folders.flatMap { (saved.days[$0] ?? [:]).filter { $0.value.minutes > 0 || $0.value.tokens > 0 }.map(\.key) }).count
        s.milestones = dedupe(saved.milestones.filter { folders.contains($0.folder) && !$0.dismissed })
        let commit = folders.compactMap { saved.firstCommit[$0] }.min()
        if let st = info.start { s.start = st; s.startSource = "set by you" }
        else if let c = commit, c < (firstDay ?? .distantFuture) { s.start = c; s.startSource = "first commit" }
        else if let d = firstDay { s.start = d; s.startSource = "first session" }
        s.lastActive = [lastDay, s.milestones.last?.date].compactMap { $0 }.max()
        if info.end == nil, let lastMajor = s.majors.last?.date, let last = s.lastActive,
           Date().timeIntervalSince(last) >= ProjectScan.quietDays * 86_400 {
            s.detectedEnd = lastMajor
        }
        s.manualHours = info.manual.map(\.hours).reduce(0, +)
        let endDay = s.end.map { cal.startOfDay(for: $0) }
        for f in folders {
            for (k, d) in saved.days[f] ?? [:] {
                if let endDay, let day = ProjectScan.date(ofKey: k), day > endDay { continue }
                s.minutesToEnd += d.minutes
            }
        }
        s.income = income.filter { $0.project.map(ids.contains) == true && $0.kind == "Income" }.map(\.amount).reduce(0, +)
        s.expenses = a.pay.filter { $0.project.map(ids.contains) == true }.map(\.amount).reduce(0, +)
        return s
    }

    // MARK: Repo rollup
    private static func simple(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter || $0.isNumber }) }
    private static func words(_ s: String) -> [String] { s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }

    /// The repo a project rolls up to: the user's choice, then git, then its path and name. A folder with
    /// no remote joins a repo when its name matches, or its first word does for one repo only ("MyApp",
    /// "MyApp on Codex"), or its first word is a repo's initials ("bb-…"; the repo with most folders on a tie).
    func repoName(_ info: ProjectInfo) -> String {
        if let r = info.repo { return r }
        guard let folder = info.folders.first else { return info.name }
        let known = saved.repos ?? [:]
        if let r = known[folder], r.remote { return r.name }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if folder == home { return info.name }
        if folder.contains("/Documents/Codex/") { return "Codex chats" }
        if folder.contains("/scratch-workspaces/") { return "Scratch" }
        var name = known[folder]?.name ?? URL(fileURLWithPath: folder).lastPathComponent
        if known[folder] == nil {
            for box in ["/Github/", "/Downloads/"] {
                if let r = folder.range(of: home + box), let top = folder[r.upperBound...].split(separator: "/").first { name = String(top) }
            }
            if name.hasSuffix("-wt") { name = String(name.dropLast(3)) }
        }
        let remotes = known.values.filter(\.remote).map(\.name)
        if let same = remotes.first(where: { Self.simple($0) == Self.simple(name) }) { return same }
        guard let first = Self.words(name).first else { return name }
        let byWord = Set(remotes.filter { Self.words($0).first == first })
        if byWord.count == 1, let only = byWord.first { return only }
        let byInitials = remotes.filter { Self.words($0).count > 1 && String(Self.words($0).compactMap(\.first)) == first }
        let counts = Dictionary(grouping: byInitials) { $0 }
        return counts.max { $0.value.count < $1.value.count }?.key ?? name
    }

    /// Rows for the tables, most tokens first. A folder's own figures stay in `folders`.
    private func repoGroups(_ all: [Summary], _ a: Allocation) -> [RepoGroup] {
        return Dictionary(grouping: all) { Self.simple(repoName($0.info)) }.map { key, members in
            let sorted = members.sorted { $0.allTokens > $1.allTokens }
            let repo = repoName(sorted[0].info)
            func folderName(_ s: Summary) -> String { URL(fileURLWithPath: s.id).lastPathComponent }
            let primary = sorted.first { Self.simple(folderName($0)) == key } ?? sorted[0]
            let name = primary.info.name != folderName(primary) ? primary.info.name : repo
            var info = primary.info
            info.name = name
            guard sorted.count > 1 else {
                var only = primary
                only.info = info
                return RepoGroup(repo: repo, total: only, folders: sorted)
            }
            let infos = sorted.map(\.info)
            info.id = "repo:" + key
            info.folders = infos.flatMap(\.folders)
            info.manual = infos.flatMap(\.manual)
            info.start = info.start ?? infos.compactMap(\.start).min()
            info.end = info.end ?? infos.compactMap(\.end).max()
            info.rating = info.rating ?? infos.compactMap(\.rating).first
            if info.outcome.isEmpty { info.outcome = infos.first { !$0.outcome.isEmpty }?.outcome ?? "" }
            info.hidden = infos.allSatisfy(\.hidden)
            let ids = [primary.id] + sorted.map(\.id).filter { $0 != primary.id }
            return RepoGroup(repo: repo, total: summary(info, members: ids, a), folders: sorted)
        }
        .sorted { ($0.total.allTokens, $1.total.info.name) > ($1.total.allTokens, $0.total.info.name) }
    }

    /// A push seen both in a transcript and in git's reflog is one event.
    private func dedupe(_ list: [Milestone]) -> [Milestone] {
        var seen = Set<String>(), nearClaude = Set<Int>()
        let once = list.filter { seen.insert($0.key).inserted }
        for m in once where m.source == "Claude Code" && ["Push", "Tag"].contains(m.kind) {
            for minute in -2...2 { nearClaude.insert(Int(m.date.timeIntervalSince1970 / 60) + minute) }
        }
        return once.filter { !($0.source == "git" && $0.kind == "Push" && nearClaude.contains(Int($0.date.timeIntervalSince1970 / 60))) }
    }
}

// MARK: Projects view

struct ProjectsView: View {
    @ObservedObject var store: AccountStore
    @ObservedObject var projects = ProjectStore.shared
    @ObservedObject var spend = Spend.shared
    @ObservedObject var importer = SettingsWindow.state
    @State private var selected: String?
    @State private var manualDate = Date()
    @State private var manualHours = 1.0
    @State private var manualNote = ""
    @State private var showHidden = false
    @State private var expanded: Set<String> = []
    @State private var allTokenRows = false

    var body: some View {
        let all = projects.report.all
        let groups = projects.report.groups
        let list = groups.filter { showHidden || !$0.total.info.hidden }
        VStack(alignment: .leading, spacing: 16) {
            header
            let untied = projects.report.unattributed + groups.filter { g in !list.contains { $0.id == g.id } }.map(\.total.cost).reduce(0, +)
            section("Tokens by project") { tokenTable(list) }
            section("Time to delivery") { deliveryTable(list, untied: untied) }
            section("Profit & loss · private") { pnl(list, untied: untied) }
            if let s = (groups.map(\.total) + all).first(where: { $0.id == (selected ?? list.first?.id) }) {
                section("Project · \(s.info.name)") { detail(s, groups: groups, others: all) }
            }
            section("Money in · private") { moneyIn(groups) }
        }
        .onAppear { projects.refreshIfStale(accounts: store.accounts, codexHomes: codexHomes) }
        .onDisappear { projects.lock() }
    }

    private var codexHomes: [URL] { store.others.filter { $0.app == .codex }.map(\.codexHome) }

    private func money(_ v: Double) -> String { projects.unlocked ? cash(v) : "••••" }
    /// Costs show without unlocking, as they do on Money; income, profit and rate stay behind the lock.
    private func cash(_ v: Double) -> String { Fmt.money(v.rounded(), "USD") }

    private var header: some View {
        HStack(spacing: 8) {
            if projects.unlocked {
                Button { projects.lock() } label: { Label("Lock", systemImage: "lock.open") }
            } else {
                Button { projects.unlock() } label: { Label("Unlock money", systemImage: "lock") }
                    .help("Income, costs and profit stay hidden until you unlock with Touch ID or your password. They lock again after 10 minutes or when you leave this tab.")
            }
            Button("Import Bank CSV…") { SettingsWindow.importCSV() }
                .help("Charges go to the expense ledger; deposits go to Money in, where you tag them to a project.")
            Button("Add folder…") { addFolder() }
            Spacer()
            if projects.scanning { ProgressView().controlSize(.small); Text("Reading sessions and git…").font(Theme.caption).foregroundStyle(.secondary) }
            else if let t = projects.saved.lastScan { Text("Updated \(t.formatted(date: .omitted, time: .shortened))").font(Theme.caption).foregroundStyle(.secondary) }
            Button { projects.refresh(accounts: store.accounts, codexHomes: codexHomes) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).disabled(projects.scanning)
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a project folder (useful for work done in Cursor or by hand)"
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { projects.addFolder(url.path); projects.refresh(accounts: store.accounts, codexHomes: codexHomes) }
    }

    private func short(_ d: Date?) -> String { d.map { $0.formatted(.dateTime.month(.abbreviated).day()) } ?? "–" }

    /// A table line: a repo, or one of its folders while the repo is open.
    private struct Line: Identifiable {
        let s: ProjectStore.Summary
        var folders = 0                 // on a repo line: how many folders it adds up
        var nested = false
        var id: String { s.id }
    }

    private func lines(_ groups: [ProjectStore.RepoGroup], keep: (ProjectStore.Summary) -> Bool = { _ in true }) -> [Line] {
        groups.filter { keep($0.total) }.flatMap { g -> [Line] in
            guard g.folders.count > 1 else { return [Line(s: g.total)] }
            let open = expanded.contains(g.id) ? g.folders.filter { keep($0) && (showHidden || !$0.info.hidden) } : []
            return [Line(s: g.total, folders: g.folders.count)] + open.map { Line(s: $0, nested: true) }
        }
    }

    @ViewBuilder private func nameCell(_ line: Line) -> some View {
        HStack(spacing: 4) {
            if line.folders > 0 {
                Button {
                    if expanded.remove(line.id) == nil { expanded.insert(line.id) }
                } label: {
                    Image(systemName: expanded.contains(line.id) ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold))
                        .frame(width: 10, height: 12).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.secondary).help("Show the folders added up in this row")
            } else {
                Color.clear.frame(width: line.nested ? 22 : 10, height: 1)
            }
            Button(line.s.info.name) { selected = line.id }.buttonStyle(.plain)
                .font(.system(size: 11, weight: selected == line.id ? .semibold : .regular))
                .foregroundStyle(line.nested ? Color.secondary : Color.primary).lineLimit(1).truncationMode(.middle)
            if line.folders > 0 { Text("\(line.folders)").font(.system(size: 10)).foregroundStyle(.tertiary) }
        }.frame(maxWidth: 190, alignment: .leading).gridColumnAlignment(.leading)
    }

    private func tok(_ n: Int) -> String { n > 0 ? Fmt.tokens(n) : "–" }

    /// Claude Code and Codex tokens per repo for this month, the last 30 days and all time, with a check against the Mac's totals.
    @ViewBuilder private func tokenTable(_ list: [ProjectStore.RepoGroup]) -> some View {
        let recent = list.filter { $0.total.recentTokens + $0.total.recentCodex > 0 }
            .sorted { ($0.total.recentTokens + $0.total.recentCodex) > ($1.total.recentTokens + $1.total.recentCodex) }
        let rows = allTokenRows ? recent + list.filter { g in g.total.allTokens > 0 && !recent.contains { $0.id == g.id } } : recent
        let c = projects.report.check
        if rows.isEmpty {
            Text(projects.scanning || !projects.report.ready ? "Reading sessions…" : "No project tokens in the last 30 days.")
                .font(Theme.body).foregroundStyle(.secondary)
        } else {
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("This month").gridCellColumns(2); Text("Last 30 days").gridCellColumns(2); Text("All time").gridCellColumns(2); Text("")
                }.font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                GridRow {
                    Text("Project").gridColumnAlignment(.leading)
                    Text("Claude"); Text("Codex"); Text("Claude"); Text("Codex"); Text("Claude"); Text("Codex"); Text("Share")
                }.font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(lines(rows)) { line in
                    let s = line.s
                    GridRow {
                        nameCell(line)
                        Text(tok(s.monthTokens)); Text(tok(s.monthCodex))
                        Text(tok(s.recentTokens)); Text(tok(s.recentCodex))
                        Text(tok(s.tokens)); Text(tok(s.codexTokens))
                        let share = Double(s.recentTokens + s.recentCodex) / Double(max(1, c.projectClaude + c.projectCodex))
                        Text(s.recentTokens + s.recentCodex > 0 ? String(format: "%.0f%%", share * 100) : "–")
                    }.font(.system(size: 11).monospacedDigit()).foregroundStyle(line.nested ? Color.secondary : Color.primary)
                }
                let t = rows.map(\.total)
                GridRow {
                    Text("Total").padding(.leading, 14).gridColumnAlignment(.leading)
                    Text(tok(t.map(\.monthTokens).reduce(0, +))); Text(tok(t.map(\.monthCodex).reduce(0, +)))
                    Text(tok(t.map(\.recentTokens).reduce(0, +))); Text(tok(t.map(\.recentCodex).reduce(0, +)))
                    Text(tok(t.map(\.tokens).reduce(0, +))); Text(tok(t.map(\.codexTokens).reduce(0, +))); Text("")
                }.font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            HStack(spacing: 10) {
                Toggle("Show projects with no tokens in the last 30 days", isOn: $allTokenRows).toggleStyle(.checkbox).font(Theme.caption)
                Spacer()
                Button("Export tokens CSV…") { projects.exportTokens() }
                    .help("Every project folder's Claude Code and Codex tokens by day, the rows these totals are added up from.")
            }
            Text(checkText(c)).font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Tokens are input, output and cache, counted from Claude Code's session logs (~/.claude/projects) and Codex's thread database, by the folder each session ran in. Rows are repos; the arrow shows their folders. Share is of all project tokens in the last 30 days. The CSV lists every folder and day, so any cell here can be added up by hand.")
                .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func checkText(_ c: ProjectStore.TokenCheck) -> String {
        guard !c.from.isEmpty else { return "" }
        func part(_ name: String, _ mine: Int, _ all: Int) -> String {
            guard all > 0 else { return "\(name): \(tok(mine)) in project folders; no daily total to compare with." }
            let pct = Double(mine) / Double(all) * 100
            if mine > all {
                let over = String(format: "%.1f", Double(mine - all) / Double(all) * 100)
                return "\(name): project folders hold \(mine.formatted()) tokens, \(Fmt.tokens(mine - all)) (\(over)%) more than the \(all.formatted()) in the daily totals. The cause of that gap isn't known yet."
            }
            return "\(name): \(Fmt.tokens(mine)) of \(Fmt.tokens(all)) (\(String(format: "%.0f", pct))%) ran in project folders; the other \(Fmt.tokens(all - mine)) ran elsewhere (home folder, chats, other tools)."
        }
        let range = "\(Fmt.dateKey(c.from)) to \(Fmt.dateKey(c.to))"
        let stale = !c.lastCodex.isEmpty && c.lastCodex < ProjectScan.dayKey(Date().addingTimeInterval(-2 * 86_400))
            ? " The newest Codex day in any project is \(Fmt.dateKey(c.lastCodex)), so Codex work since then isn't counted here yet." : ""
        return "Check, \(range), against Report › Now › Usage by day. " + part("Claude Code", c.projectClaude, c.allClaude) + " " + part("Codex", c.projectCodex, c.allCodex) + stale
    }

    @ViewBuilder private func deliveryTable(_ list: [ProjectStore.RepoGroup], untied: Double) -> some View {
        if list.isEmpty {
            Text(projects.scanning || !projects.report.ready ? "Reading sessions…" : "No projects yet. They appear once Claude Code or Codex has worked in a folder, or add one by hand.")
                .font(Theme.body).foregroundStyle(.secondary)
        } else {
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Project").gridColumnAlignment(.leading); Text("Start"); Text("First publish"); Text("Publishes")
                    Text("End"); Text("Days"); Text("Hours"); Text("Tokens"); Text("Tokens/h"); Text("Cost")
                }.font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(lines(list)) { line in
                    let s = line.s
                    GridRow {
                        nameCell(line)
                        Text(short(s.start))
                        Text(short(s.firstMajor))
                        Text(s.majors.isEmpty ? "–" : "\(s.majors.count)")
                        Text(s.info.end != nil ? short(s.info.end) : (s.detectedEnd != nil ? short(s.detectedEnd) + " ?" : "open"))
                            .foregroundStyle(s.info.end == nil && s.detectedEnd != nil ? Theme.warn : .primary)
                        Text(s.daysToDeliver.map { "\($0)" } ?? "–")
                        Text(s.hours > 0 ? String(format: "%.1f", s.hours) : "–")
                        Text(s.allTokens > 0 ? Fmt.tokens(s.allTokens) : "–")
                        Text(s.tokensPerHour.map { Fmt.tokens(Int($0)) } ?? "–")
                        Text(s.cost > 0 ? cash(s.cost) : "–")
                    }.font(.system(size: 11).monospacedDigit()).foregroundStyle(line.nested ? Color.secondary : Color.primary)
                }
                let shown = list.map(\.total)
                if untied >= 0.5 {
                    GridRow {
                        Text("Not tied to a repo").foregroundStyle(.secondary).padding(.leading, 14).gridColumnAlignment(.leading)
                        ForEach(0..<7, id: \.self) { _ in Text("") }
                        Text(""); Text(cash(untied)).foregroundStyle(.secondary)
                    }.font(.system(size: 11).monospacedDigit())
                }
                GridRow {
                    Text("Total").padding(.leading, 14).gridColumnAlignment(.leading)
                    ForEach(0..<5, id: \.self) { _ in Text("") }
                    Text(String(format: "%.1f", shown.map(\.hours).reduce(0, +)))
                    Text(Fmt.tokens(shown.map(\.allTokens).reduce(0, +))); Text("")
                    Text(cash(shown.map(\.cost).reduce(0, +) + untied))
                }.font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            Toggle("Show hidden", isOn: $showHidden).toggleStyle(.checkbox).font(Theme.caption)
            Text("Rows are repos: worktrees, clones and session folders add up under the repo they belong to, and the arrow shows them. Sessions run side by side each count their own hours. Tokens include Codex. Cost is real dollars; see Profit & loss for how it's worked out.")
                .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Start is your date if set, else the first commit or first session. Publishes are deploys, app uploads, releases, merged PRs and tags that didn't fail; plain pushes and preview deploys are listed but not counted. \"?\" marks an end detected from the last publish after \(Int(ProjectScan.quietDays)) quiet days; confirm it in the project. Hours are measured Claude Code time (turns less than 15 minutes apart) plus hours you add. Cursor work isn't visible, so add those hours by hand.")
                .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func pnl(_ list: [ProjectStore.RepoGroup], untied: Double) -> some View {
        let rows = list.map(\.total).filter { $0.income != 0 || $0.cost != 0 }
        if rows.isEmpty {
            Text("No income or costs tied to a project yet. Import a bank CSV, then tag deposits under Money in.")
                .font(Theme.body).foregroundStyle(.secondary)
        } else {
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Project").gridColumnAlignment(.leading); Text("Income"); Text("Direct costs"); Text("AI cost"); Text("Profit"); Text("Hours"); Text("Rate")
                }.font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(lines(list) { $0.income != 0 || $0.cost != 0 }) { line in
                    let s = line.s
                    GridRow {
                        nameCell(line)
                        Text(money(s.income)); Text(cash(s.expenses)); Text(cash(s.aiAllocated)); Text(money(s.profit))
                        Text(s.hours > 0 ? String(format: "%.1f", s.hours) : "–")
                        Text(rateText(s)).foregroundStyle(projects.unlocked && (s.rate ?? projects.targetRate) < projects.targetRate ? Theme.warn : .primary)
                    }.font(.system(size: 11).monospacedDigit()).foregroundStyle(line.nested ? Color.secondary : Color.primary)
                }
                let inc = rows.map(\.income).reduce(0, +), cost = rows.map(\.cost).reduce(0, +) + untied
                if untied >= 0.5 {
                    GridRow {
                        Text("Not tied to a repo").foregroundStyle(.secondary).padding(.leading, 14).gridColumnAlignment(.leading)
                        Text(""); Text(""); Text(cash(untied)).foregroundStyle(.secondary); Text(""); Text(""); Text("")
                    }.font(.system(size: 11).monospacedDigit())
                }
                GridRow {
                    Text("Total").padding(.leading, 14).gridColumnAlignment(.leading)
                    Text(money(inc)); Text(cash(rows.map(\.expenses).reduce(0, +))); Text(cash(rows.map(\.aiAllocated).reduce(0, +) + untied)); Text(money(inc - cost))
                    Text(""); Text("")
                }.font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            HStack(spacing: 6) {
                Text("Target rate").font(Theme.caption).foregroundStyle(.secondary)
                TextField("", value: $projects.targetRate, format: .number).textFieldStyle(.roundedBorder).frame(width: 60).font(Theme.caption)
                Text("per hour").font(Theme.caption).foregroundStyle(.secondary)
            }
            let basis = projects.report
            Text("AI cost is real dollars shared out by real usage. Claude's money is bank charges" + (basis.bankThrough.map { " through \(Fmt.dateKey($0))" } ?? " once imported") + (basis.atFace >= 0.5 ? ", then \(Fmt.money(basis.atFace, "USD")) of credits bought since at face value, which can overstate the cash until the next bank import" : "") + ". Extra usage follows the repos each account worked on the day it was billed, up to what their Claude Code tokens are worth, and each plan follows its own account's month. OpenAI money follows Codex tokens by the day they were used, where Codex still has the log. These are shares, not per-repo invoices: no provider bills by repo. Cursor, and extra usage beyond what Claude Code on this Mac accounts for (chats, other devices), stay under Not tied to a repo, so the total matches what was spent. Rate is income divided by measured plus added hours, so it reads high when hours are missing.")
                .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func rateText(_ s: ProjectStore.Summary) -> String {
        guard projects.unlocked else { return "••••" }
        guard let r = s.rate else { return "–" }
        let gap = r - projects.targetRate
        return Fmt.money(r.rounded(), "USD") + "/h" + (abs(gap) >= 1 ? " (\(gap > 0 ? "+" : "−")\(Fmt.money(abs(gap).rounded(), "USD")))" : "")
    }

    private func detail(_ s: ProjectStore.Summary, groups: [ProjectStore.RepoGroup], others: [ProjectStore.Summary]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            detailTop(s, groups: groups, others: others)
            detailHours(s.info)
            detailEvents(s.info)
            detailCosts(s)
        }
    }

    @ViewBuilder private func detailTop(_ s: ProjectStore.Summary, groups: [ProjectStore.RepoGroup], others: [ProjectStore.Summary]) -> some View {
        let info = s.info
        HStack {
            TextField("Name", text: Binding(get: { info.name }, set: { var p = info; p.name = $0; projects.update(p) }))
                .textFieldStyle(.roundedBorder).frame(width: 220)
            Toggle("Hidden", isOn: Binding(get: { info.hidden }, set: { var p = info; p.hidden = $0; projects.update(p) })).toggleStyle(.checkbox)
            Spacer()
            if !s.isRollup {
                Menu("Repo: \(projects.repoName(info))") {
                    Button("Detect automatically") { var p = info; p.repo = nil; projects.update(p) }
                    Button("Keep on its own") { var p = info; p.repo = info.name; projects.update(p) }
                    Divider()
                    ForEach(groups) { g in Button(g.total.info.name) { var p = info; p.repo = g.repo; projects.update(p) } }
                }.frame(width: 180)
                Menu("Merge into…") {
                    ForEach(others.filter { $0.id != info.id }) { o in Button(o.info.name) { projects.merge(info, into: o.info); selected = o.id } }
                }.frame(width: 120)
            }
        }
        Text(s.isRollup ? "Adds up \(s.members.count) folders. Edits here are kept on the main one, \(s.primaryID)." : info.folders.joined(separator: " · "))
            .font(Theme.caption).foregroundStyle(.secondary).lineLimit(2)
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Text("Start").foregroundStyle(.secondary)
                HStack {
                    Text(s.start.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "–")
                    Text(s.startSource).font(Theme.caption).foregroundStyle(.secondary)
                    DatePicker("", selection: Binding(get: { info.start ?? s.start ?? Date() }, set: { var p = info; p.start = $0; projects.update(p) }), displayedComponents: .date).labelsHidden().frame(width: 100)
                    if info.start != nil { Button("Use detected") { var p = info; p.start = nil; projects.update(p) } }
                }
            }
            GridRow {
                Text("End").foregroundStyle(.secondary)
                HStack {
                    if let e = info.end {
                        Text(e.formatted(date: .abbreviated, time: .omitted)); Text("confirmed").font(Theme.caption).foregroundStyle(.secondary)
                        Button("Reopen") { var p = info; p.end = nil; projects.update(p) }
                    } else if let d = s.detectedEnd {
                        Text(d.formatted(date: .abbreviated, time: .omitted)); Text("detected").font(Theme.caption).foregroundStyle(Theme.warn)
                        Button("Confirm") { var p = info; p.end = d; projects.update(p) }
                    } else {
                        Text("open").foregroundStyle(.secondary)
                        Button("Mark delivered today") { var p = info; p.end = Date(); projects.update(p) }
                    }
                }
            }
            GridRow {
                Text("Measured").foregroundStyle(.secondary)
                Text("\(String(format: "%.1f", s.minutes / 60)) h Claude Code over \(s.activeDays) active days · \(Fmt.tokens(s.tokens)) tokens · API-price value \(Fmt.money(s.value.rounded(), "USD"))" + (s.codexThreads > 0 ? " · Codex \(s.codexThreads) threads, \(Fmt.tokens(s.codexTokens))" : ""))
            }
            GridRow {
                Text("Cost").foregroundStyle(.secondary)
                Text("\(cash(s.cost)) · Claude \(cash(s.aiClaude)) · OpenAI \(cash(s.aiCodex)) · direct \(cash(s.expenses))")
            }
            if s.end != nil {
                GridRow {
                    Text("To delivery").foregroundStyle(.secondary)
                    Text("\(s.daysToDeliver.map { "\($0) days" } ?? "–") · \(String(format: "%.1f", s.minutesToEnd / 60 + s.manualHours)) h until the end date")
                }
            }
            GridRow {
                Text("Impact").foregroundStyle(.secondary)
                HStack {
                    Picker("", selection: Binding(get: { info.rating ?? 0 }, set: { var p = info; p.rating = $0 == 0 ? nil : $0; projects.update(p) })) {
                        Text("Not rated").tag(0)
                        ForEach(1...5, id: \.self) { Text("\($0) of 5").tag($0) }
                    }.labelsHidden().frame(width: 110)
                    TextField("What it delivered (your words)", text: Binding(get: { info.outcome }, set: { var p = info; p.outcome = $0; projects.update(p) }))
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
        .font(Theme.body)
    }

    @ViewBuilder private func detailHours(_ info: ProjectInfo) -> some View {
        SectionHeader(title: "Hours added by hand").padding(.top, 4)
        ForEach(info.manual) { m in
            HStack {
                Text(m.date.formatted(.dateTime.month(.abbreviated).day())).frame(width: 52, alignment: .leading).foregroundStyle(.secondary)
                Text(String(format: "%.1f h", m.hours)).frame(width: 50, alignment: .leading)
                Text(m.note).lineLimit(1)
                Spacer()
                Button { var p = info; p.manual.removeAll { $0.id == m.id }; projects.update(p) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }.font(Theme.body)
        }
        HStack {
            DatePicker("", selection: $manualDate, displayedComponents: .date).labelsHidden().frame(width: 100)
            TextField("Hours", value: $manualHours, format: .number).textFieldStyle(.roundedBorder).frame(width: 50)
            TextField("Calls, design, Cursor…", text: $manualNote).textFieldStyle(.roundedBorder)
            Button("Add") {
                guard manualHours > 0 else { return }
                var p = info; p.manual.append(ManualHours(date: manualDate, hours: manualHours, note: manualNote)); projects.update(p); manualNote = ""
            }
        }
    }

    @ViewBuilder private func detailEvents(_ info: ProjectInfo) -> some View {
        SectionHeader(title: "Publish events").padding(.top, 4)
        var seen = Set<String>()
        let events = projects.saved.milestones.filter { info.folders.contains($0.folder) && seen.insert($0.key).inserted }.suffix(40).reversed()
        if events.isEmpty { Text("None found in Claude Code sessions or git.").font(Theme.body).foregroundStyle(.secondary) }
        ForEach(Array(events)) { m in
            HStack(spacing: 6) {
                Text(m.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())).frame(width: 100, alignment: .leading).foregroundStyle(.secondary)
                Text(m.kind).font(.system(size: 9, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(m.major ? 0.16 : 0.06))).frame(width: 70)
                Text(m.detail).lineLimit(1).truncationMode(.middle).foregroundStyle(m.dismissed || m.failed ? Color.secondary : Color.primary)
                if m.failed { Text("failed").font(Theme.caption).foregroundStyle(Theme.alert) }
                Spacer()
                Text(m.source).font(Theme.caption).foregroundStyle(.secondary)
                Button(m.dismissed ? "Restore" : "Not a milestone") { projects.setMilestone(m.id, dismissed: !m.dismissed) }
                    .buttonStyle(.plain).font(Theme.caption).foregroundStyle(.secondary)
            }.font(Theme.body)
        }
    }

    @ViewBuilder private func detailCosts(_ s: ProjectStore.Summary) -> some View {
        SectionHeader(title: "Direct costs").padding(.top, 4)
        let tagged = spend.payments.filter { $0.project.map(s.members.contains) == true }
        ForEach(tagged) { pay in
            HStack {
                Text(pay.date.formatted(.dateTime.month(.abbreviated).day())).frame(width: 52, alignment: .leading).foregroundStyle(.secondary)
                Text("\(pay.provider) · \(pay.item)").lineLimit(1)
                Spacer()
                Text(cash(pay.amount)).monospacedDigit()
                Button { setProject(pay, nil) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }.font(Theme.body)
        }
        Menu("Tag an expense to this project…") {
            ForEach(spend.payments.filter { $0.project == nil && $0.amount > 0 }.prefix(40)) { pay in
                Button("\(pay.date.formatted(.dateTime.month(.abbreviated).day())) · \(pay.provider) · \(pay.item.prefix(40)) · \(Fmt.money(pay.amount, "USD"))") { setProject(pay, s.primaryID) }
            }
        }.frame(width: 260)
    }

    private func setProject(_ pay: Spend.Payment, _ project: String?) {
        if let i = spend.payments.firstIndex(where: { $0.id == pay.id }) { spend.payments[i].project = project }
    }

    @ViewBuilder private func moneyIn(_ groups: [ProjectStore.RepoGroup]) -> some View {
        let stray = projects.depositsInLedger
        if !stray.isEmpty {
            HStack {
                Text("\(stray.count) deposits from earlier imports are in the expense ledger, where they lower your spend.")
                    .font(Theme.body).foregroundStyle(Theme.warn)
                Button("Move to Money in") { projects.moveDepositsFromLedger() }
            }
        }
        if let note = importer.note { Text(note).font(Theme.caption).foregroundStyle(.secondary) }
        if !projects.unlocked {
            Text("\(projects.income.count) deposits kept. Unlock to see and tag them.").font(Theme.body).foregroundStyle(.secondary)
        } else if projects.income.isEmpty {
            Text("No deposits yet. Import a bank CSV.").font(Theme.body).foregroundStyle(.secondary)
        } else {
            let untagged = projects.income.filter { $0.project == nil && $0.kind == "Income" }
            if !untagged.isEmpty {
                Text("\(untagged.count) deposits (\(Fmt.money(untagged.map(\.amount).reduce(0, +).rounded(), "USD"))) aren't tied to a project yet.")
                    .font(Theme.body)
            }
            ForEach(projects.income.prefix(60)) { row in incomeRow(row, groups) }
            Text("Tagging one deposit tags the same payer's other deposits too. Transfer rows (between your own accounts) are kept but not counted as income.")
                .font(Theme.caption).foregroundStyle(.secondary)
        }
    }

    private func incomeRow(_ row: Income, _ groups: [ProjectStore.RepoGroup]) -> some View {
        HStack(spacing: 6) {
            Text(row.date.formatted(.dateTime.month(.abbreviated).day().year(.twoDigits))).frame(width: 70, alignment: .leading).foregroundStyle(.secondary)
            Text(row.memo).lineLimit(1).truncationMode(.middle)
            Spacer()
            Picker("", selection: Binding(get: { row.kind }, set: { k in
                if let i = projects.income.firstIndex(where: { $0.id == row.id }) { projects.income[i].kind = k }
            })) { Text("Income").tag("Income"); Text("Transfer").tag("Transfer") }.labelsHidden().frame(width: 90)
            Picker("", selection: Binding(get: { groups.first { $0.total.members.contains(row.project ?? "") }?.total.primaryID ?? "" }, set: { projects.tag(row, project: $0.isEmpty ? nil : $0) })) {
                Text("No project").tag("")
                ForEach(groups) { g in Text(g.total.info.name).tag(g.total.primaryID) }
            }.labelsHidden().frame(width: 150)
            Text(Fmt.money(row.amount, "USD")).monospacedDigit().frame(width: 80, alignment: .trailing)
                .foregroundStyle(row.kind == "Income" ? Color.primary : Color.secondary)
            Button { projects.income.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(.secondary)
        }.font(Theme.body)
    }

    @ViewBuilder private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title).padding(.leading, 4)
            VStack(alignment: .leading, spacing: 8) { content() }.card(padding: 14, radius: 16)
        }
    }
}

// MARK: - Usage by day

/// Codex tokens by local day and model. A thread with its session log on disk is split turn by turn from
/// the log's running total; any tokens the log doesn't hold stay on the day the thread started.
enum CodexDays {
    struct Thread { let cwd: String; let created: Date; let tokens: Int; let model: String; let rollout: String }
    struct Row { let cwd: String; let day: String; let model: String; let tokens: Int; let threads: Int }

    /// What's been read of one session log, so a growing file only has its new lines parsed.
    private struct Log: Codable { var read: UInt64 = 0; var total = 0; var model = ""; var days: [String: [String: Int]] = [:] }
    private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.ai-orchestrator/codex-days.json")
    }
    private static var logs: [String: Log] = {
        guard let d = try? Data(contentsOf: cacheURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Log].self, from: d)) ?? [:]
    }()

    private static func read(_ path: String) -> Log? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return logs[path] }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        var log = logs[path] ?? Log()
        if size < log.read { log = Log() }
        guard size > log.read, let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped),
              UInt64(data.count) > log.read else { return log }
        data.withUnsafeBytes { (all: UnsafeRawBufferPointer) in
            guard let start0 = all.baseAddress else { return }
            let base = start0 + Int(log.read), n = all.count - Int(log.read)
            var start = 0, consumed = 0
            while start < n {
                guard let nl = memchr(base + start, 0x0A, n - start) else { break }
                let end = base.distance(to: UnsafeRawPointer(nl))
                let p = base + start, len = end - start, head = min(len, 200)
                if TokenCounter.find(p, head, "\"type\":\"turn_context\"") != nil {
                    if let m = TokenCounter.string(p, len, after: "\"model\":\"") { log.model = m }
                } else if TokenCounter.find(p, head, "\"type\":\"token_count\"") != nil,
                          let u = TokenCounter.find(p, len, "\"total_token_usage\":{"),
                          let ts = TokenCounter.string(p, head, after: "\"timestamp\":\""), let when = TokenCounter.date(ts) {
                    let total = TokenCounter.int(p + u, len - u, after: "\"total_tokens\":")
                    if total > log.total {
                        log.days[ProjectScan.dayKey(when), default: [:]][log.model, default: 0] += total - log.total
                        log.total = total
                    }
                }
                start = end + 1
                consumed = start
            }
            log.read += UInt64(consumed)
        }
        logs[path] = log
        return log
    }

    /// Run on TokenCounter.queue: it shares the parsed-log cache.
    static func rows(home: URL) -> [Row] {
        var out: [Row] = []
        for t in ProjectScan.codexThreads(home: home) {
            let startDay = ProjectScan.dayKey(t.created)
            var inLog = 0
            if !t.rollout.isEmpty, let log = read(t.rollout) {
                for (day, models) in log.days {
                    for (m, n) in models { out.append(Row(cwd: t.cwd, day: day, model: m.isEmpty ? t.model : m, tokens: n, threads: 0)); inLog += n }
                }
            }
            out.append(Row(cwd: t.cwd, day: startDay, model: t.model, tokens: max(0, t.tokens - inLog), threads: 1))
        }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(logs) { try? d.write(to: cacheURL, options: .atomic) }
        return out
    }
}

struct UsageDayModel: Codable, Hashable {
    var model: String
    var tokens = 0
    /// API-price value; nil for Codex, and for saved days from before value was kept per model.
    var value: Double?
}

struct UsageDayAccount: Codable, Hashable, Identifiable {
    var name: String
    var provider: String
    var tokens = 0
    var value: Double?
    var models: [UsageDayModel] = []
    /// Percentage points of the weekly limit used that day, and the highest reading.
    var limitUsed: Double?
    var limitPeak: Double?
    /// Claude extra usage billed that day; nil on days before the widget's first reading.
    var extra: Double?
    var id: String { name }
}

struct UsageDay: Codable, Hashable, Identifiable {
    var day: String
    var accounts: [UsageDayAccount]
    var id: String { day }
    var tokens: Int { accounts.map(\.tokens).reduce(0, +) }
    var value: Double { accounts.compactMap(\.value).reduce(0, +) }
    var extra: Double { accounts.compactMap(\.extra).reduce(0, +) }
    var limits: String {
        accounts.compactMap { a in a.limitUsed.flatMap { $0 >= 0.5 ? "\(a.name) +\(Int($0.rounded()))" : nil } }.joined(separator: " · ")
    }
}

/// One day-by-day record of tokens, API-price value and limit use, by account and model. Tokens and value
/// come from the saved daily totals and Codex's logs; limit use and extra usage come from the snapshots.
/// Written to usage-daily.json, which bin/phone-feed serves as it is.
final class DailyUsage: ObservableObject {
    static let shared = DailyUsage()
    static let file = History.dir.appendingPathComponent("usage-daily.json")
    @Published private(set) var days: [UsageDay] = {
        guard let d = try? Data(contentsOf: DailyUsage.file) else { return [] }
        return (try? JSONDecoder().decode([UsageDay].self, from: d)) ?? []
    }()
    private var built = Date.distantPast

    /// Growth of a reading across snapshots, by local day. A fall counts as a reset: what shows after it was used since.
    static func growth(_ list: [UsageSnapshot], _ read: (UsageSnapshot) -> Double?, resetDrop: Double) -> [String: Double] {
        var out: [String: Double] = [:]
        var prev: Double?
        for s in list {
            guard let v = read(s) else { continue }
            let k = ProjectScan.dayKey(s.t)
            if let p = prev {
                if v > p { out[k, default: 0] += v - p }
                else if p - v >= resetDrop { out[k, default: 0] += v }
                else { out[k, default: 0] += 0 }
            } else { out[k, default: 0] += 0 }
            prev = v
        }
        return out
    }

    static func build(codex: [(home: URL, name: String)]) -> [UsageDay] {
        var map: [String: [String: UsageDayAccount]] = [:]
        func edit(_ day: String, _ name: String, _ provider: String, _ change: (inout UsageDayAccount) -> Void) {
            var a = map[day]?[name] ?? UsageDayAccount(name: name, provider: provider)
            change(&a)
            map[day, default: [:]][name] = a
        }
        for (key, s) in TokenHistory.load() {
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            edit(parts[0], parts[1], "claude") { a in
                a.tokens = s.total
                a.value = s.value
                a.models = s.byModel.map { UsageDayModel(model: $0.key, tokens: $0.value, value: s.valueByModel?[$0.key]) }
            }
        }
        for c in codex {
            var byDay: [String: [String: Int]] = [:]
            for r in CodexDays.rows(home: c.home) where r.tokens > 0 { byDay[r.day, default: [:]][r.model, default: 0] += r.tokens }
            for (day, models) in byDay {
                edit(day, c.name, "codex") { a in
                    a.tokens = models.values.reduce(0, +)
                    a.models = models.map { UsageDayModel(model: $0.key, tokens: $0.value) }
                }
            }
        }
        let snaps = History.load(since: .distantPast).filter { $0.provider == "claude" || $0.provider == "codex" }
        for (name, list) in Dictionary(grouping: snaps, by: \.name) {
            let provider = list[0].provider
            for (day, n) in growth(list, \.weekly, resetDrop: 20) { edit(day, name, provider) { $0.limitUsed = n } }
            for (day, n) in growth(list, \.extraUsed, resetDrop: 0.01) { edit(day, name, provider) { $0.extra = n } }
            for s in list { if let w = s.weekly { edit(ProjectScan.dayKey(s.t), name, provider) { $0.limitPeak = max($0.limitPeak ?? 0, w) } } }
        }
        return map.map { day, accounts in
            UsageDay(day: day, accounts: accounts.values.map { a in
                var a = a
                a.models.sort { $0.tokens > $1.tokens }
                return a
            }.sorted { ($0.tokens, $1.name) > ($1.tokens, $0.name) })
        }.sorted { $0.day > $1.day }
    }

    /// Rebuilds at most every two minutes. Run on TokenCounter.queue.
    func update(codex: [(home: URL, name: String)]) {
        guard Date().timeIntervalSince(built) > 120 else { return }
        built = Date()
        let list = Self.build(codex: codex)
        if let d = try? JSONEncoder().encode(list) { try? d.write(to: Self.file, options: .atomic) }
        DispatchQueue.main.async { self.days = list }
    }
}

/// Bank-statement charges for Claude, kept apart from the payments ledger: the budget already counts this
/// money through extra usage and plans, so these only tell project costs what was really paid.
enum BankCharges {
    struct Charge: Codable, Hashable { var date: String; var vendor: String; var amount: Double }
    static let file = History.dir.appendingPathComponent("bank-charges.json")
    static func load() -> [Charge] {
        guard let d = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Charge].self, from: d)) ?? []
    }
    /// Adds what a statement holds beyond the rows already kept: the same day and amount can repeat, so counts are compared.
    static func add(_ rows: [Charge]) -> Int {
        var have = Dictionary(load().map { ($0, 1) }, uniquingKeysWith: +)
        var all = load(), added = 0
        for r in rows {
            if let n = have[r], n > 0 { have[r] = n - 1 } else { all.append(r); added += 1 }
        }
        let enc = JSONEncoder(); enc.outputFormatting = .prettyPrinted
        if added > 0, let d = try? enc.encode(all.sorted { $0.date < $1.date }) { try? d.write(to: file, options: .atomic) }
        return added
    }
}

struct UsageDaysView: View {
    @ObservedObject private var daily = DailyUsage.shared
    let range: Int
    @State private var open: Set<String> = []
    @State private var all = false

    private func label(_ key: String) -> String {
        guard let d = ProjectScan.date(ofKey: key) else { return key }
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
    private func money(_ v: Double?) -> String { v.map { $0 >= 0.005 ? Fmt.money($0, "USD") : "–" } ?? "–" }
    private func points(_ a: UsageDayAccount) -> String {
        a.limitUsed.map { "+\(Int($0.rounded())) pts" + (a.limitPeak.map { ", peak \(Int($0))%" } ?? "") } ?? ""
    }

    var body: some View {
        let start = ProjectScan.dayKey(Date().addingTimeInterval(-Double(range - 1) * 86_400))
        let days = daily.days.filter { $0.day >= start }
        let shown = all ? days : Array(days.prefix(7))
        if days.isEmpty {
            Text("Counting tokens…").font(Theme.body).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Day")
                    Spacer()
                    Text("Tokens").frame(width: 72, alignment: .trailing)
                    Text("API value").frame(width: 72, alignment: .trailing)
                    Text("Extra").frame(width: 62, alignment: .trailing)
                }
                .font(Theme.caption).foregroundStyle(.secondary).padding(.bottom, 4)
                ForEach(shown) { d in
                    row(d)
                    if open.contains(d.day) { detail(d) }
                    Divider().opacity(0.5)
                }
                if days.count > 7 {
                    Button(all ? "Show fewer" : "Show all \(days.count) days") { all.toggle() }
                        .buttonStyle(.plain).font(Theme.caption).foregroundStyle(.secondary).padding(.top, 6)
                }
            }
            Text("Limit use is points of each weekly limit, from the widget's readings; a limit already at 100% can't show more. Extra is what Claude billed that day. API value is what Claude Code's tokens would cost at list prices, not what you paid. Codex has no value here, and Cursor reports only a monthly total.")
                .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ d: UsageDay) -> some View {
        Button {
            if open.contains(d.day) { open.remove(d.day) } else { open.insert(d.day) }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Image(systemName: open.contains(d.day) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).frame(width: 12)
                    Text(label(d.day))
                    Spacer()
                    Text(Fmt.tokens(d.tokens)).frame(width: 72, alignment: .trailing)
                    Text(money(d.value)).frame(width: 72, alignment: .trailing)
                    Text(money(d.extra)).frame(width: 62, alignment: .trailing)
                }
                .font(Theme.body.monospacedDigit())
                if !d.limits.isEmpty {
                    Text(d.limits).font(Theme.caption).foregroundStyle(.secondary).padding(.leading, 18).lineLimit(1)
                }
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(open.contains(d.day) ? "Hides accounts and models" : "Shows accounts and models")
    }

    private func detail(_ d: UsageDay) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(d.accounts) { a in
                HStack {
                    Text(a.name).fontWeight(.medium)
                    Text(points(a)).foregroundStyle(.secondary)
                    Spacer()
                    Text(Fmt.tokens(a.tokens)).frame(width: 72, alignment: .trailing)
                    Text(money(a.value)).frame(width: 72, alignment: .trailing)
                    Text(money(a.extra)).frame(width: 62, alignment: .trailing)
                }
                .font(Theme.caption.monospacedDigit())
                ForEach(a.models, id: \.model) { m in
                    HStack {
                        Text(Fmt.model(m.model)).foregroundStyle(.secondary).padding(.leading, 12)
                        Spacer()
                        Text(Fmt.tokens(m.tokens)).frame(width: 72, alignment: .trailing)
                        Text(money(m.value)).frame(width: 72, alignment: .trailing)
                        Text("").frame(width: 62)
                    }
                    .font(Theme.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, 18).padding(.bottom, 6)
    }
}

/// One line in the panel: today so far, opening the day-by-day table in the Report.
struct TodayRow: View {
    @ObservedObject private var daily = DailyUsage.shared
    @ObservedObject var store: AccountStore
    var close: () -> Void

    var body: some View {
        if let d = daily.days.first, d.day == ProjectScan.dayKey(Date()) {
            Button { close(); ReportNav.open("now", store: store) } label: {
                HStack(spacing: 6) {
                    Text("Today").foregroundStyle(.secondary)
                    Text(Fmt.tokens(d.tokens) + " tokens · " + Fmt.money(d.value, "USD") + " value"
                         + (d.extra >= 0.005 ? " · " + Fmt.money(d.extra, "USD") + " extra" : ""))
                        .lineLimit(1)
                    Spacer()
                    Text("By day").foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                .font(.system(size: 12).monospacedDigit())
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open usage by day")
        }
    }
}

// MARK: - App chrome (appearance, window style, menus)

/// Light / Dark / match the system. Dark by default; applies to the widget and every window.
enum AppAppearance: String, CaseIterable {
    case system, light, dark
    static var current: AppAppearance {
        get { AppAppearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "dark") ?? .dark }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "appearance"); newValue.apply() }
    }
    var title: String { ["system": "Match System", "light": "Light", "dark": "Dark"][rawValue]! }
    func apply() {
        NSApp.appearance = self == .system ? nil : NSAppearance(named: self == .dark ? .darkAqua : .aqua)
    }
}

/// Window backdrop: the panel's dense glass (Surface), or under Solid plain near-black in Dark and the
/// standard window colour in Light.
struct BurnBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        // Windows are always solid: glass let the wallpaper's colours tint the page.
        (scheme == .dark ? Color(red: 0.08, green: 0.08, blue: 0.085) : Color(nsColor: .windowBackgroundColor))
            .ignoresSafeArea()
    }
}

extension View {
    /// Root style for every Burn Rate window: the backdrop and a neutral tint.
    func burnWindow() -> some View { background(BurnBackdrop()).tint(Color.primary) }
}

/// Standard window behaviour for every Burn Rate window: transparent titlebar over the backdrop,
/// remembered size and position and a minimum size. Burn Rate stays a widget: no Dock icon, even with
/// a window open (the user parks it at a screen corner instead).
enum AppWindows {
    private static var open: Set<ObjectIdentifier> = []
    private static var observers: [ObjectIdentifier: NSObjectProtocol] = [:]
    static let glassRadius: CGFloat = 26

    static func configure(_ w: NSWindow, title: String, autosave: String, size: NSSize, min: NSSize) {
        w.title = title
        w.styleMask.insert([.titled, .closable, .miniaturizable, .resizable])
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.styleMask.insert(.fullSizeContentView)
        // Not movable by background: that swallowed clicks meant for fields on the page. The title bar still drags.
        w.tabbingMode = .disallowed
        w.backgroundColor = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.07, green: 0.06, blue: 0.06, alpha: 1) : NSColor(srgbRed: 0.97, green: 0.96, blue: 0.95, alpha: 1) }
        w.contentMinSize = min
        w.setContentSize(size)
        w.isReleasedWhenClosed = false
        if !w.setFrameUsingName(autosave) { w.center() }
        w.setFrameAutosaveName(autosave)
    }

    /// Bring a window forward.
    static func present(_ w: NSWindow) {
        let id = ObjectIdentifier(w)
        if !open.contains(id) {
            open.insert(id)
            observers[id] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                open.remove(id)
                if let o = observers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(o) }
            }
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

/// Monthly tech-spend ceiling and the revenue the user enters each month (revenue.json).
final class Budget: ObservableObject {
    static let shared = Budget()
    static let file = History.dir.appendingPathComponent("revenue.json")
    /// The one monthly budget. Mirrored to `extraBudget`, which bin/phone-feed still reads.
    @Published var ceiling: Double {
        didSet {
            UserDefaults.standard.set(ceiling, forKey: "spendCeiling")
            UserDefaults.standard.set(ceiling, forKey: "extraBudget")
        }
    }
    @Published var revenue: [String: Double] {
        didSet {
            try? FileManager.default.createDirectory(at: History.dir, withIntermediateDirectories: true)
            if let d = try? JSONEncoder().encode(revenue) { try? d.write(to: Self.file, options: .atomic) }
        }
    }
    private init() {
        let d = UserDefaults.standard
        // Oct 25 merge: the extra-usage budget and the ceiling became one budget. A ceiling the user set
        // wins; otherwise the extra-usage budget they typed carries over (default $1,000). The old value is kept.
        if d.object(forKey: "budgetMerged") == nil {
            d.set(true, forKey: "budgetMerged")
            let extra = d.double(forKey: "extraBudget")
            if extra > 0 { d.set(extra, forKey: "extraBudgetBeforeMerge") }
            if d.object(forKey: "spendCeiling") == nil && extra > 0 { d.set(extra, forKey: "spendCeiling") }
        }
        ceiling = d.object(forKey: "spendCeiling") == nil ? 1000 : d.double(forKey: "spendCeiling")
        if let data = try? Data(contentsOf: Self.file), let r = try? JSONDecoder().decode([String: Double].self, from: data) { revenue = r } else { revenue = [:] }
        d.set(ceiling, forKey: "extraBudget")
    }
    func revenue(for month: Date) -> Double? { revenue[Fmt.monthKey(month)] }

    /// A "Profit and Loss" export: a title block naming the period, then a "Category" header row of
    /// months ("Jan 1-31", …, "Total") and a "TOTAL INCOME" row. Returns income by yyyy-MM, or nil for other files.
    static func parseProfitAndLoss(_ text: String) -> [String: Double]? {
        let lines = text.components(separatedBy: .newlines)
        guard lines.prefix(3).contains(where: { $0.lowercased().contains("profit and loss") }) else { return nil }
        func cells(_ line: String) -> [String] {
            var out: [String] = [], cur = "", q = false
            for ch in line {
                if ch == "\"" { q.toggle() } else if ch == "," && !q { out.append(cur); cur = "" } else { cur.append(ch) }
            }
            out.append(cur)
            return out.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        guard let period = lines.prefix(5).first(where: { $0.range(of: #"\d{4}"#, options: .regularExpression) != nil }),
              let yr = period.range(of: #"\d{4}"#, options: .regularExpression).flatMap({ Int(period[$0]) }),
              let head = lines.first(where: { cells($0).first?.lowercased() == "category" }),
              let inc = lines.first(where: { cells($0).first?.lowercased() == "total income" }) else { return nil }
        let names = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let h = cells(head), v = cells(inc)
        var out: [String: Double] = [:]
        var year = yr, last = 0
        for i in 1..<min(h.count, v.count) {
            guard let m = names.firstIndex(of: String(h[i].lowercased().prefix(3))) else { continue }
            if m + 1 < last { year += 1 }       // a period that crosses into the next year
            last = m + 1
            let t = v[i].replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
            if let amount = Double(t) { out[String(format: "%04d-%02d", year, m + 1)] = amount }
        }
        return out.isEmpty ? nil : out
    }
    func setRevenue(_ v: Double?, for month: Date) {
        if let v, v > 0 { revenue[Fmt.monthKey(month)] = v } else { revenue.removeValue(forKey: Fmt.monthKey(month)) }
    }

    /// Where this month stands, all measured: Claude extra usage, API spend from connected keys,
    /// entered plans, and AI + Tech ledger charges. `maxPerDay` is plain arithmetic on what's left.
    struct Standing {
        var month: Date
        var spent: Double, ai: Double, tech: Double, plans: Double, extra: Double, api: Double
        var ceiling: Double
        var revenue: Double?
        var day: Int, daysInMonth: Int
        var left: Double { ceiling - spent }
        var daysLeft: Int { max(0, daysInMonth - day) }
        var maxPerDay: Double? { daysLeft > 0 && left > 0 ? left / Double(daysLeft) : nil }
        var perDaySoFar: Double { spent / Double(max(day, 1)) }
        var shareOfRevenue: Double? { revenue.map { $0 > 0 ? spent / $0 : nil } ?? nil }
    }

    func standing(store: AccountStore, spend: Spend = .shared) -> Standing {
        let cal = Calendar.current, now = Date()
        let extra = store.extraThisMonth
        let api = spend.apiTotal
        let plans = spend.subscriptionTotal
        let ai = spend.paid(inMonthOf: now, category: "AI"), tech = spend.paid(inMonthOf: now, category: "Tech")
        return Standing(month: now, spent: extra + api + plans + ai + tech, ai: ai, tech: tech, plans: plans, extra: extra, api: api,
                        ceiling: ceiling, revenue: revenue(for: now),
                        day: cal.component(.day, from: now), daysInMonth: cal.range(of: .day, in: .month, for: now)?.count ?? 30)
    }
}

/// Week-by-week measurements, newest last. Weeks start on the calendar's first weekday.
struct WeekTrend: Identifiable {
    let start: Date
    var tokens = 0, cacheRead = 0, output = 0, codex = 0, sessions = 0
    var value = 0.0
    var extra = 0.0          // Claude extra usage that grew during the week (snapshot deltas)
    var id: Date { start }
    var cacheShare: Double { tokens > 0 ? Double(cacheRead) / Double(tokens) : 0 }
}

enum Trends {
    static func weeks(claude: [DayTokens], codex: [DayTokens], snapshots: [UsageSnapshot], count: Int = 8) -> [WeekTrend] {
        let cal = Calendar.current
        func weekOf(_ d: Date) -> Date { cal.dateInterval(of: .weekOfYear, for: d)?.start ?? cal.startOfDay(for: d) }
        var rows: [Date: WeekTrend] = [:]
        for r in claude {
            var w = rows[weekOf(r.day)] ?? WeekTrend(start: weekOf(r.day))
            w.tokens += r.stats.total; w.cacheRead += r.stats.cacheRead; w.output += r.stats.output
            w.value += r.stats.value; w.sessions += r.stats.sessions
            rows[w.start] = w
        }
        for r in codex {
            var w = rows[weekOf(r.day)] ?? WeekTrend(start: weekOf(r.day))
            w.codex += r.stats.input
            rows[w.start] = w
        }
        // Extra usage: the rise in each account's month-to-date figure between consecutive snapshots.
        for (_, list) in Dictionary(grouping: snapshots.filter { $0.provider == "claude" && $0.extraUsed != nil }, by: \.account) {
            let sorted = list.sorted { $0.t < $1.t }
            for (a, b) in zip(sorted, sorted.dropFirst()) {
                let sameMonth = cal.isDate(a.t, equalTo: b.t, toGranularity: .month)
                let delta = sameMonth ? max(0, (b.extraUsed ?? 0) - (a.extraUsed ?? 0)) : (b.extraUsed ?? 0)
                guard delta > 0 else { continue }
                var w = rows[weekOf(b.t)] ?? WeekTrend(start: weekOf(b.t))
                w.extra += delta
                rows[w.start] = w
            }
        }
        let thisWeek = weekOf(Date())
        var out: [WeekTrend] = []
        for i in stride(from: count - 1, through: 0, by: -1) {
            guard let start = cal.date(byAdding: .weekOfYear, value: -i, to: thisWeek) else { continue }
            out.append(rows[start] ?? WeekTrend(start: start))
        }
        return out
    }

    /// "▲ 23%" / "▼ 8%" / "—" between two measured numbers. Nil when there's nothing to compare.
    static func change(_ now: Double, _ before: Double) -> (text: String, up: Bool?)? {
        guard before > 0 else { return now > 0 ? ("new", true) : nil }
        let pct = (now - before) / before * 100
        if abs(pct) < 1 { return ("—", nil) }
        return ((pct > 0 ? "▲ " : "▼ ") + "\(Int(abs(pct).rounded()))%", pct > 0)
    }

    struct ProjectRow: Identifiable { let name: String; var tokens = 0; var value = 0.0; var sessions = 0; var cacheRead = 0; var id: String { name } }
    static func projects(_ shapes: [TokenCounter.SessionShape]) -> [ProjectRow] {
        var rows: [String: ProjectRow] = [:]
        for s in shapes {
            var r = rows[s.project] ?? ProjectRow(name: s.project)
            r.tokens += s.total; r.value += s.value; r.sessions += 1; r.cacheRead += s.cacheRead
            rows[s.project] = r
        }
        return rows.values.sorted { $0.value > $1.value }
    }
}

/// The ideas backlog: anything the user wants to build, scored and stack-ranked. ideas.json is also
/// appended to by bin/idea so an idea can be captured from any terminal or Claude session.
struct Idea: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var notes = ""
    var value = 3        // 1–5: how much it matters (revenue, time saved, joy)
    var effort = 3       // 1–5: how much work
    var size = 2         // 1–3: how many tokens it'll eat (S / M / L)
    var status = "inbox" // inbox, next, doing, done, dropped
    var created = Date()
    var source = "widget"
    var managerRank: Int?
    var managerNote: String?
    /// Value against cost: the higher the better. Manager rank, when present, wins the sort.
    var score: Double { Double(value * 2) / Double(effort + size) }

    init(title: String, source: String = "widget") { self.title = title; self.source = source }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        value = try c.decodeIfPresent(Int.self, forKey: .value) ?? 3
        effort = try c.decodeIfPresent(Int.self, forKey: .effort) ?? 3
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 2
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "inbox"
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "widget"
        managerRank = try c.decodeIfPresent(Int.self, forKey: .managerRank)
        managerNote = try c.decodeIfPresent(String.self, forKey: .managerNote)
    }
}

final class IdeaStore: ObservableObject {
    static let shared = IdeaStore()
    static let file = History.dir.appendingPathComponent("ideas.json")
    static let statuses = ["inbox", "next", "doing", "done", "dropped"]
    @Published var ideas: [Idea] = []
    private var loadedAt = Date.distantPast
    private var saving = false

    private init() { load() }

    func load() {
        guard let d = try? Data(contentsOf: Self.file) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let list = try? dec.decode([Idea].self, from: d) { ideas = list }
        loadedAt = (try? FileManager.default.attributesOfItem(atPath: Self.file.path)[.modificationDate] as? Date) ?? Date()
    }
    /// Picks up ideas added from the command line (bin/idea) while the window is open.
    func reloadIfChanged() {
        let m = (try? FileManager.default.attributesOfItem(atPath: Self.file.path)[.modificationDate] as? Date) ?? .distantPast
        if m > loadedAt { load() }
    }
    func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: History.dir, withIntermediateDirectories: true)
        if let d = try? enc.encode(ideas) { try? d.write(to: Self.file, options: .atomic) }
        loadedAt = Date()
    }
    func add(_ title: String, notes: String = "") {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        reloadIfChanged()
        var i = Idea(title: t); i.notes = notes
        ideas.insert(i, at: 0)
        save()
    }
    func update(_ idea: Idea) {
        if let i = ideas.firstIndex(where: { $0.id == idea.id }) { ideas[i] = idea; save() }
    }
    func remove(_ idea: Idea) { ideas.removeAll { $0.id == idea.id }; save() }

    /// Open ideas, best first: the manager's rank when it has one, otherwise the score.
    var ranked: [Idea] {
        ideas.filter { $0.status != "done" && $0.status != "dropped" }.sorted {
            switch ($0.managerRank, $1.managerRank) {
            case let (a?, b?): return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.score == $1.score ? $0.created > $1.created : $0.score > $1.score
            }
        }
    }
}

/// Notes the user filed on the iPhone's Inbox (Claude on the phone structured them; the user tapped Send).
/// bin/phone-feed writes ideas straight to ideas.json and expenses and plan changes to phone-inbox.json;
/// this imports each of those once. Amounts and dates are only what the user wrote.
enum PhoneInbox {
    static let file = History.dir.appendingPathComponent("phone-inbox.json")
    struct Note: Decodable {
        var id: String
        var kind: String
        var text: String?
        var expense: Expense?
        var planChange: PlanChange?
        struct Expense: Decodable { var vendor: String; var item: String?; var amount: Double?; var date: String?; var category: String? }
        struct PlanChange: Decodable { var vendor: String; var account: String?; var plan: String?; var monthly: Double?; var date: String? }
    }

    static func importNew() {
        IdeaStore.shared.reloadIfChanged()
        guard let d = try? Data(contentsOf: file), let notes = try? JSONDecoder().decode([Note].self, from: d) else { return }
        var done = Set(UserDefaults.standard.stringArray(forKey: "phoneInboxImported") ?? [])
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"; day.locale = Locale(identifier: "en_US_POSIX")
        var added: [Spend.Payment] = []
        for n in notes where !done.contains(n.id) {
            done.insert(n.id)
            if n.kind == "expense", let e = n.expense, let amount = e.amount {
                let cat = Spend.categories.contains(e.category ?? "") ? e.category! : "AI"
                var p = Spend.Payment(date: e.date.flatMap(day.date(from:)) ?? Date(), provider: e.vendor,
                                      item: (e.item?.isEmpty == false ? e.item! : e.vendor) + " (from iPhone)", amount: amount, category: cat)
                if let id = UUID(uuidString: n.id) { p.id = id }
                added.append(p)
            } else if n.kind == "planChange", let c = n.planChange {
                let subs = Spend.shared.subscriptions
                let vendor = c.vendor == "chatgpt" ? "codex" : c.vendor
                let matches = subs.indices.filter { i in
                    if let a = c.account, !a.isEmpty { return subs[i].account == a }
                    return subs[i].account?.hasPrefix(vendor + ":") == true
                }
                if matches.count == 1, let plan = c.plan, let monthly = c.monthly, let date = c.date.flatMap(day.date(from:)) {
                    let i = matches[0]
                    Spend.shared.subscriptions[i].pendingPlan = plan
                    Spend.shared.subscriptions[i].pendingMonthly = monthly
                    Spend.shared.subscriptions[i].pendingDate = date
                    Notify.send("Plan change from your iPhone", "\(subs[i].name): \(plan) at \(Fmt.money(monthly, "USD"))/mo from \(Fmt.day(date)). Saved under Plans.")
                } else {
                    let why = matches.count == 1 ? "it didn't say the plan, price and date" : "it didn't match exactly one plan"
                    Notify.send("Plan change from your iPhone", "\(n.text ?? c.vendor). Not saved because \(why): enter it under Report › Plans › Dates.")
                }
            }
        }
        if !added.isEmpty {
            let have = Set(Spend.shared.payments.map(\.id))
            Spend.shared.payments = (Spend.shared.payments + added.filter { !have.contains($0.id) }).sorted { $0.date > $1.date }
        }
        UserDefaults.standard.set(Array(done), forKey: "phoneInboxImported")
    }
}

/// Asks the user's own Claude API key for a reading of the real numbers: a short brief, where
/// tokens were wasted in specific sessions, how to prompt better, a ranking of the ideas backlog
/// and what to work on next. Every run's token cost is recorded and shown.
final class Manager: ObservableObject {
    static let shared = Manager()
    static let file = History.dir.appendingPathComponent("manager.json")
    static let spendFile = History.dir.appendingPathComponent("manager-spend.json")
    static let models = ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5"]

    struct Finding: Codable, Identifiable, Hashable {
        var session: String = ""      // short id or project the finding refers to
        var project: String = ""
        var waste: String             // what happened, in measured terms
        var fix: String               // what to do differently
        var id: String { session + waste }
    }
    struct RankItem: Codable, Hashable { var id: String; var rank: Int; var reason: String }
    struct Brief: Codable, Identifiable {
        var date: Date
        var model: String
        var headline: String = ""
        var brief: String = ""
        var findings: [Finding] = []
        var promptTips: [String] = []
        var workflow: [String] = []
        var nextActions: [String] = []
        var budgetMove: String = ""
        var ranking: [RankItem] = []
        var inputTokens = 0, outputTokens = 0
        var cost = 0.0
        var id: Date { date }
    }
    struct Run: Codable { var date: Date; var model: String; var input: Int; var output: Int; var cost: Double }

    @Published var running = false
    @Published var error: String?
    enum KeyStatus { case unknown, checking, ok, rejected }
    @Published var keyStatus: KeyStatus = .unknown
    @Published var keyError: String?

    /// Checks the manager's key with the free models list (no tokens used).
    func verifyKey() {
        guard let key = Keychain.get("key.claude"), let url = URL(string: "https://api.anthropic.com/v1/models?limit=1") else {
            keyStatus = .unknown; return
        }
        keyStatus = .checking; keyError = nil
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let obj = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            let msg = (obj?["error"] as? [String: Any])?["message"] as? String
            DispatchQueue.main.async {
                if code == 200 { self.keyStatus = .ok; return }
                self.keyStatus = .rejected
                self.keyError = code == 0 ? "Couldn't reach api.anthropic.com: \(err?.localizedDescription ?? "no connection")."
                    : code == 401 ? "The key wasn't accepted: it may be mistyped or revoked. Create a new one at console.anthropic.com › API keys." + (msg.map { " (\($0))" } ?? "")
                    : "api.anthropic.com answered HTTP \(code)." + (msg.map { " (\($0))" } ?? "")
            }
        }.resume()
    }
    @Published var briefs: [Brief] = []
    @Published var runs: [Run] = []
    var latest: Brief? { briefs.first }

    var hasKey: Bool { Keychain.get("key.claude") != nil }
    var model: String {
        get { UserDefaults.standard.string(forKey: "managerModel") ?? Self.models[0] }
        set { UserDefaults.standard.set(newValue, forKey: "managerModel"); objectWillChange.send() }
    }
    var sendTranscripts: Bool {
        get { UserDefaults.standard.object(forKey: "managerTranscripts") == nil ? true : UserDefaults.standard.bool(forKey: "managerTranscripts") }
        set { UserDefaults.standard.set(newValue, forKey: "managerTranscripts"); objectWillChange.send() }
    }
    var autoDaily: Bool {
        get { UserDefaults.standard.bool(forKey: "managerAuto") }
        set { UserDefaults.standard.set(newValue, forKey: "managerAuto"); objectWillChange.send() }
    }
    var autoHour: Int {
        get { UserDefaults.standard.object(forKey: "managerHour") == nil ? 8 : UserDefaults.standard.integer(forKey: "managerHour") }
        set { UserDefaults.standard.set(newValue, forKey: "managerHour"); objectWillChange.send() }
    }
    /// Spend on the manager itself this month, from its own usage figures at API list prices.
    var costThisMonth: Double {
        runs.filter { Calendar.current.isDate($0.date, equalTo: Date(), toGranularity: .month) }.map(\.cost).reduce(0, +)
    }

    private init() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: Self.file), let b = try? dec.decode([Brief].self, from: d) { briefs = b }
        if let d = try? Data(contentsOf: Self.spendFile), let r = try? dec.decode([Run].self, from: d) { runs = r }
    }
    private func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: History.dir, withIntermediateDirectories: true)
        if let d = try? enc.encode(Array(briefs.prefix(60))) { try? d.write(to: Self.file, options: .atomic) }
        if let d = try? enc.encode(runs) { try? d.write(to: Self.spendFile, options: .atomic) }
    }

    /// Runs the daily brief once a day after `autoHour`, when enabled and a key exists.
    func tick(store: AccountStore) {
        guard autoDaily, hasKey, !running else { return }
        let cal = Calendar.current
        guard cal.component(.hour, from: Date()) >= autoHour else { return }
        if let last = latest?.date, cal.isDateInToday(last) { return }
        run(store: store, reason: "daily")
    }

    // MARK: The data pack sent to Claude

    struct Pack { var text: String; var sessionIDs: [String] }
    /// What the pack needs from the main thread; the heavy transcript work then runs in the background.
    struct Inputs {
        var standing: Budget.Standing
        var limits: [String]
        var profiles: [URL]
        var codexHomes: [(name: String, home: URL)]
        var notes: [ReportModel.Note]
        var previous: Brief?
        var sendTranscripts: Bool
    }

    func inputs(store: AccountStore) -> Inputs {
        let limits = store.targets.map { t in
            "- \(t.name): 5h \(t.short.map { "\(Int($0))%" } ?? "–"), weekly/monthly \(t.weekly.map { "\(Int($0))%" } ?? "–")\(t.paysExtra ? " (extra usage ON)" : "")\(t.weeklyResets.map { ", resets \(Fmt.when($0))" } ?? "")."
        }
        return Inputs(standing: Budget.shared.standing(store: store), limits: limits, profiles: store.accounts.map(\.profileURL),
                      codexHomes: store.others.filter { $0.app == .codex }.map { ("Codex \($0.name)", $0.codexHome) },
                      notes: ReportModel.loadNotes(), previous: latest, sendTranscripts: sendTranscripts)
    }

    /// Builds the pack from saved totals and transcripts. Call off the main thread.
    static func pack(_ x: Inputs) -> Pack {
        let standing = x.standing
        let allDays = TokenHistory.rows(since: .distantPast, missingFrom: [])
        var codexDays: [DayTokens] = []
        for (name, home) in x.codexHomes {
            for (day, s) in CodexHistory.daily(home: home) { codexDays.append(DayTokens(day: day, account: name, stats: s)) }
        }
        let snaps = History.load(since: .distantPast)
        let months = ReportModel.months(allDays: allDays, codexDays: codexDays, snapshots: snaps)
        let since14 = Date().addingTimeInterval(-14 * 86_400)
        let shapes = TokenCounter.shapes(profiles: x.profiles, since: since14)
        let weeks = Trends.weeks(claude: allDays, codex: codexDays, snapshots: snaps)
        let heat = TokenCounter.heat(profiles: x.profiles, since: Date().addingTimeInterval(-28 * 86_400))
        let f = DateFormatter(); f.dateFormat = "MMM d"
        let dow = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        var L: [String] = []
        L.append("# \(Product.name) data pack · \(Date().formatted(date: .abbreviated, time: .shortened))")
        L.append("All figures below are measured on this Mac (transcripts, limit snapshots, the user's ledger). Tokens are Claude Code unless noted.")
        L.append("")
        L.append("## Budget this month (\(Fmt.monthKey(standing.month)))")
        L.append("- Ceiling for AI + tech spend: \(Fmt.money(standing.ceiling, "USD")). Spent so far: \(Fmt.money(standing.spent, "USD")) on day \(standing.day) of \(standing.daysInMonth).")
        L.append("  Claude extra usage \(Fmt.money(standing.extra, "USD")), plans \(Fmt.money(standing.plans, "USD"))\(standing.plans == 0 ? " (NOT entered — plan costs are missing)" : ""), API keys \(Fmt.money(standing.api, "USD")), AI charges in ledger \(Fmt.money(standing.ai, "USD")), other tech charges \(Fmt.money(standing.tech, "USD")).")
        if let r = standing.revenue { L.append("- Revenue entered for this month: \(Fmt.money(r, "USD")) → spend is \(Int(((standing.spent / r) * 100).rounded()))% of revenue.") }
        else { L.append("- Revenue: not entered for this month.") }
        if let m = standing.maxPerDay { L.append("- To finish under the ceiling, the remaining \(standing.daysLeft) days can add at most \(Fmt.money(m, "USD")) a day on average; the month so far averaged \(Fmt.money(standing.perDaySoFar, "USD")) a day.") }
        else if standing.left < 0 { L.append("- Already \(Fmt.money(-standing.left, "USD")) over the ceiling with \(standing.daysLeft) days left.") }
        L.append("- Reference prices (list): Claude Max 20x $200/mo, Max 5x $100/mo, Pro $20/mo. Claude extra usage this month ÷ $200 = \(String(format: "%.1f", standing.extra / 200)) Max 20x seats.")
        L.append("")
        L.append("## Month by month (newest first)")
        for m in months.prefix(4) {
            L.append("- \(Fmt.monthKey(m.month)): \(Fmt.tokens(m.tokens.total)) Claude Code tokens (API-price value \(Fmt.money(m.tokens.value.rounded(), "USD"))), Codex \(Fmt.tokens(m.codex)) tokens, Claude extra \(Fmt.money(m.extra, "USD")) [\(m.extraBy.map { "\($0.key) \(Fmt.money($0.value, "USD"))" }.joined(separator: ", "))], ledger charges \(Fmt.money(m.payments, "USD")), API \(Fmt.money(m.api, "USD")).")
        }
        L.append("")
        L.append("## Week by week (oldest first; extra = Claude extra usage that grew that week)")
        for w in weeks {
            L.append("- w/o \(f.string(from: w.start)): \(Fmt.tokens(w.tokens)) tokens, \(Int((w.cacheShare * 100).rounded()))% cache reads, output \(Fmt.tokens(w.output)), value \(Fmt.money(w.value.rounded(), "USD")), \(w.sessions) sessions, Codex \(Fmt.tokens(w.codex)), extra \(Fmt.money(w.extra.rounded(), "USD")).")
        }
        L.append("")
        L.append("## Limits right now")
        L += x.limits
        L.append("")
        L.append("## When the work happens (tokens by weekday × hour, last 28 days; top cells, share of all)")
        var cells: [(String, Int)] = []
        for d in 0..<7 { for h in 0..<24 where heat[d][h] > 0 { cells.append(("\(dow[d]) \(h):00", heat[d][h])) } }
        let allHeat = max(cells.map(\.1).reduce(0, +), 1)
        L.append(cells.sorted { $0.1 > $1.1 }.prefix(10).map { "\($0.0) \(Int(Double($0.1) / Double(allHeat) * 100))%" }.joined(separator: ", "))
        L.append("")
        L.append("## Projects, last 14 days (by API-price value)")
        for p in Trends.projects(shapes).prefix(10) {
            L.append("- \(p.name): \(p.sessions) sessions, \(Fmt.tokens(p.tokens)) tokens, value \(Fmt.money(p.value.rounded(), "USD")), \(p.tokens > 0 ? Int(Double(p.cacheRead) / Double(p.tokens) * 100) : 0)% cache reads.")
        }
        L.append("")
        L.append("## Most expensive sessions, last 14 days")
        let top = Array(shapes.prefix(12))
        for s in top {
            L.append("- [\(s.id.prefix(8))] \(s.project): \(s.turns) turns over \(s.minutes) min, \(Fmt.tokens(s.total)) tokens (\(Int((s.cacheShare * 100).rounded()))% cache reads, \(s.heavyTurns) turns re-sent >300K context), output \(Fmt.tokens(s.output)), value \(Fmt.money(s.value.rounded(), "USD")), mostly \(Fmt.model(s.topModel)), started \(s.start.formatted(date: .abbreviated, time: .shortened)).")
        }
        if x.sendTranscripts {
            L.append("")
            L.append("## What the user typed in the 6 most expensive sessions (excerpts, oldest first)")
            for s in top.prefix(6) {
                let ps = TokenCounter.prompts(session: s.id, limit: 14, chars: 320)
                guard !ps.isEmpty else { continue }
                L.append("### [\(s.id.prefix(8))] \(s.project)")
                for p in ps { L.append("> " + p.replacingOccurrences(of: "\n", with: " ")) }
            }
        }
        L.append("")
        L.append("## Ideas backlog (id · title · status · user's value 1–5 / effort 1–5 / token size 1–3 · notes)")
        let ideas = IdeaStore.shared.ideas.filter { $0.status != "done" && $0.status != "dropped" }
        if ideas.isEmpty { L.append("(empty)") }
        for i in ideas { L.append("- \(i.id.uuidString.prefix(8)) · \(i.title) · \(i.status) · \(i.value)/\(i.effort)/\(i.size)" + (i.notes.isEmpty ? "" : " · \(i.notes.prefix(200))")) }
        if !x.notes.isEmpty {
            L.append("")
            L.append("## The user's own notes")
            for n in x.notes.prefix(8) { L.append("- \(n.date.formatted(date: .abbreviated, time: .omitted)): \(n.text)") }
        }
        if let prev = x.previous {
            L.append("")
            L.append("## Your previous brief (\(prev.date.formatted(date: .abbreviated, time: .omitted)))")
            L.append(prev.headline)
            for a in prev.nextActions { L.append("- next: \(a)") }
        }
        return Pack(text: L.joined(separator: "\n"), sessionIDs: top.map(\.id))
    }

    static let system = """
    You are the user's personal AI-spend manager inside \(Product.name), a macOS app that measures what their AI tools (Claude, Codex, Cursor) really cost. \
    You get a data pack of measured numbers and, when allowed, excerpts of what they typed in their most expensive Claude Code sessions. \
    Be direct and specific; never flatter. Only state numbers that appear in the pack; never invent or extrapolate figures. \
    Where the pack says something is missing (plans not entered, revenue not entered), say what that hides and ask for it in nextActions. \
    Point at specific sessions by their [id] and project. Prefer concrete moves: which account to use when, when to start a fresh session, \
    /compact, /clear, smaller tasks, a lighter model for routine edits, planning before building, batching questions, writing a spec first, \
    and whether another subscription seat would be cheaper than the extra usage shown. \
    Rank the ideas backlog by value against effort and token cost given the user's budget, and say what to work on next. \
    Reply with ONLY a JSON object, no markdown fences, with these keys: \
    headline (one sentence), brief (3–6 sentences), findings (array of {session, project, waste, fix}; waste cites measured facts), \
    promptTips (array of strings, each tied to something seen), workflow (array of strings), nextActions (array of 3–6 strings, imperative), \
    budgetMove (one sentence on the single change with the biggest effect on this month's spend), \
    ranking (array of {id, rank, reason} covering every backlog id, 1 = do first).
    """

    func run(store: AccountStore, reason: String = "manual") {
        guard !running else { return }
        guard let key = Keychain.get("key.claude") else { error = "Add a Claude API key in Settings first."; return }
        running = true; error = nil
        let model = self.model
        let inputs = self.inputs(store: store)
        Task.detached(priority: .utility) {
            do {
                let pack = Self.pack(inputs)
                let (text, inTok, outTok) = try await Self.call(key: key, model: model, system: Self.system, user: pack.text)
                let cost = APIPrices.cost(model: model, input: inTok, output: outTok, cacheWrite: 0, cacheRead: 0)
                var brief = try Self.parse(text, model: model)
                brief.inputTokens = inTok; brief.outputTokens = outTok; brief.cost = cost
                let done = brief
                await MainActor.run {
                    let brief = done
                    self.briefs.insert(brief, at: 0)
                    self.runs.append(Run(date: Date(), model: model, input: inTok, output: outTok, cost: cost))
                    self.applyRanking(brief.ranking)
                    self.save()
                    self.running = false
                    Notify.send("\(Product.name) brief", brief.headline)
                    store.writeStatus()
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.running = false
                }
            }
        }
    }

    private func applyRanking(_ ranking: [RankItem]) {
        let store = IdeaStore.shared
        store.reloadIfChanged()
        var changed = false
        for i in store.ideas.indices {
            let short = String(store.ideas[i].id.uuidString.prefix(8)).lowercased()
            if let r = ranking.first(where: { $0.id.lowercased().hasPrefix(short) || short.hasPrefix($0.id.lowercased().prefix(8)) }) {
                store.ideas[i].managerRank = r.rank
                store.ideas[i].managerNote = r.reason
                changed = true
            }
        }
        if changed { store.save() }
    }

    static func parse(_ text: String, model: String) throws -> Brief {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let a = t.firstIndex(of: "{"), let b = t.lastIndex(of: "}") { t = String(t[a...b]) }
        guard let data = t.data(using: .utf8), let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw NSError(domain: "manager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Claude didn't return the expected JSON. Raw reply:\n" + String(text.prefix(600))])
        }
        func strs(_ k: String) -> [String] { (obj[k] as? [Any] ?? []).compactMap { $0 as? String } }
        var b = Brief(date: Date(), model: model)
        b.headline = obj["headline"] as? String ?? ""
        b.brief = obj["brief"] as? String ?? ""
        b.budgetMove = obj["budgetMove"] as? String ?? ""
        b.promptTips = strs("promptTips"); b.workflow = strs("workflow"); b.nextActions = strs("nextActions")
        b.findings = (obj["findings"] as? [[String: Any]] ?? []).map {
            Finding(session: $0["session"] as? String ?? "", project: $0["project"] as? String ?? "",
                    waste: $0["waste"] as? String ?? "", fix: $0["fix"] as? String ?? "")
        }
        b.ranking = (obj["ranking"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["id"] as? String else { return nil }
            return RankItem(id: id, rank: ($0["rank"] as? NSNumber)?.intValue ?? 99, reason: $0["reason"] as? String ?? "")
        }
        return b
    }

    /// One Messages API call. The key goes only to api.anthropic.com.
    static func call(key: String, model: String, system: String, user: String) async throws -> (String, Int, Int) {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = ["model": model, "max_tokens": 4000, "system": system,
                                   "messages": [["role": "user", "content": user]]]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let msg = ((obj["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(code)"
            throw NSError(domain: "manager", code: code, userInfo: [NSLocalizedDescriptionKey: code == 401 ? "Key rejected: \(msg)" : msg])
        }
        let text = (obj["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
        let usage = obj["usage"] as? [String: Any] ?? [:]
        return (text, (usage["input_tokens"] as? NSNumber)?.intValue ?? 0, (usage["output_tokens"] as? NSNumber)?.intValue ?? 0)
    }
}

// MARK: Command center views

/// This month against the ceiling, with revenue the user enters. Everything measured; the only
/// arithmetic is what's left divided by the days left.
struct BudgetCard: View {
    @ObservedObject var store: AccountStore
    @ObservedObject var budget = Budget.shared
    @ObservedObject var spend = Spend.shared

    var body: some View {
        let s = budget.standing(store: store)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spent this month").font(Theme.body).foregroundStyle(.secondary)
                    Text(Fmt.money(s.spent.rounded(), "USD")).font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(s.spent > s.ceiling ? Theme.alert : Color.primary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ceiling").font(Theme.body).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text("$").font(Theme.bigNumber)
                        TextField("1000", value: $budget.ceiling, format: .number.precision(.fractionLength(0)))
                            .textFieldStyle(.plain).font(Theme.bigNumber).frame(width: 84)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Revenue · \(monthName(s.month))").font(Theme.body).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        RevenueField(month: s.month, font: Theme.bigNumber, width: 120)
                    }
                }
                Spacer()
            }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(s.spent > s.ceiling ? Theme.alert : (s.spent > s.ceiling * 0.8 ? Theme.warn : Color.primary.opacity(0.75)))
                    .frame(width: max(4, min(1, s.spent / max(s.ceiling, 1)) * 520))
                Rectangle().fill(Color.primary.opacity(0.35)).frame(width: 1.5, height: 14)
                    .offset(x: 520 * CGFloat(Double(s.day) / Double(max(s.daysInMonth, 1))))
            }
            .frame(width: 520, height: 8)
            .help("Bar: spend against the ceiling. Tick: how far through the month today is.")
            HStack(spacing: 14) {
                if s.left >= 0 {
                    Text("\(Fmt.money(s.left.rounded(), "USD")) left · \(s.daysLeft) days to go" + (s.maxPerDay.map { " · at most \(Fmt.money($0.rounded(), "USD"))/day to stay under" } ?? ""))
                } else {
                    Text("\(Fmt.money((-s.left).rounded(), "USD")) over the ceiling with \(s.daysLeft) days to go").foregroundStyle(Theme.alert)
                }
                Text("Averaging \(Fmt.money(s.perDaySoFar.rounded(), "USD"))/day so far").foregroundStyle(.secondary)
                if let r = s.revenue, r > 0 {
                    Text("\(Int((s.spent / r * 100).rounded()))% of revenue").foregroundStyle(s.spent > r ? Theme.alert : .secondary)
                }
            }
            .font(Theme.body)
            HStack(spacing: 10) {
                part("Claude extra", s.extra)
                part("Plans", s.plans, note: s.plans == 0 ? "not entered" : nil)
                part("API keys", s.api)
                part("AI charges", s.ai)
                part("Other tech", s.tech)
                if Manager.shared.costThisMonth > 0 { part("Manager", Manager.shared.costThisMonth) }
            }
            if s.extra >= 200 {
                Label("Claude extra usage this month (\(Fmt.money(s.extra.rounded(), "USD"))) is \(String(format: "%.1f", s.extra / 200))× a Max 20x seat at its $200 list price.", systemImage: "exclamationmark.triangle")
                    .font(Theme.body).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
            }
            Text("Measured: Claude extra usage, API spend from connected keys, your plans, and AI + Tech charges in the ledger. Ledger rows marked Other are left out.")
                .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func part(_ label: String, _ v: Double, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Fmt.money(v.rounded(), "USD")).font(.system(size: 12, weight: .semibold).monospacedDigit())
            Text(note.map { "\(label) · \($0)" } ?? label).font(.system(size: 9)).foregroundStyle(note == nil ? Color.secondary : Theme.warn)
        }
    }
    private func monthName(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "MMM"; return f.string(from: d) }
}

/// Revenue for one month, typed right on the page. Saves on Return and when the field loses focus.
struct RevenueField: View {
    let month: Date
    var font: Font = Theme.body
    var width: CGFloat = 110
    var alignment: TextAlignment = .leading
    @ObservedObject private var budget = Budget.shared
    @State private var text = ""
    @FocusState private var focused: Bool

    private var stored: String { budget.revenue(for: month).map { Fmt.plain($0) } ?? "" }
    /// "$2,500" while you're not typing; the plain number while you are.
    private var shown: String { budget.revenue(for: month).map { Fmt.money($0.rounded(), "USD") } ?? "" }

    var body: some View {
        TextField("enter", text: $text)
            .textFieldStyle(.plain).font(font).multilineTextAlignment(alignment)
            .frame(width: width)
            .focused($focused)
            .onSubmit(save)
            .onChange(of: focused) { _, now in if now { text = stored } else { save() } }
            .onAppear { text = shown }
            .onChange(of: shown) { _, v in if !focused { text = v } }
            .help("Type this month's revenue in dollars and press Return. Empty clears it.")
    }

    private func save() {
        let t = text.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        let v = t.isEmpty ? nil : Double(t)
        if t.isEmpty || v != nil { budget.setRevenue(v, for: month) }
        text = focused ? stored : shown
    }
}

/// Month over month: revenue (entered or imported), what AI and tech cost, and what's left. Real data only:
/// a month with no revenue says so, and plans count only from this month (they have no start dates).
struct RevenueMonths: View {
    @ObservedObject var store: AccountStore
    let months: [ReportModel.MonthRow]
    @ObservedObject private var budget = Budget.shared
    @ObservedObject private var spend = Spend.shared

    private struct Row: Identifiable { let month: Date; let revenue: Double?; let spent: Double?; var id: Date { month } }

    private var rows: [Row] {
        let cal = Calendar.current
        func monthOf(_ d: Date) -> Date { cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d }
        let now = monthOf(Date())
        let kf = DateFormatter(); kf.dateFormat = "yyyy-MM"
        var all = Set(months.map(\.month))
        for k in budget.revenue.keys { if let d = kf.date(from: k) { all.insert(monthOf(d)) } }
        all.insert(now)
        let st = budget.standing(store: store)
        return all.sorted(by: >).prefix(12).map { m in
            if m == now { return Row(month: m, revenue: st.revenue, spent: st.spent) }
            let r = months.first { $0.month == m }
            let ledger = spend.paid(inMonthOf: m, category: "AI") + spend.paid(inMonthOf: m, category: "Tech")
            // No usage history or ledger rows that month: spend wasn't tracked yet, so it shows "–", not $0.
            return Row(month: m, revenue: budget.revenue(for: m), spent: r == nil && ledger == 0 ? nil : (r?.extra ?? 0) + (r?.api ?? 0) + ledger)
        }
    }

    var body: some View {
        let mf: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM yyyy"; return f }()
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Month").frame(width: 90, alignment: .leading)
                Text("Revenue").frame(width: 110, alignment: .trailing)
                Text("AI + tech").frame(width: 100, alignment: .trailing)
                Text("Left").frame(width: 100, alignment: .trailing)
                Text("Share").frame(width: 60, alignment: .trailing)
                Spacer()
            }
            .font(Theme.caption).foregroundStyle(.secondary)
            ForEach(rows) { r in
                HStack {
                    Text(mf.string(from: r.month)).frame(width: 90, alignment: .leading)
                    RevenueField(month: r.month, width: 110, alignment: .trailing)
                    Text(r.spent.map { Fmt.money($0.rounded(), "USD") } ?? "–").frame(width: 100, alignment: .trailing)
                        .foregroundStyle(r.spent == nil ? .secondary : .primary)
                    let left: Double? = r.revenue.flatMap { rev in r.spent.map { rev - $0 } }
                    Text(left.map { Fmt.money($0.rounded(), "USD") } ?? "–").frame(width: 100, alignment: .trailing)
                        .foregroundStyle((left ?? 0) < 0 ? Theme.alert : .primary)
                    Text(r.revenue.flatMap { rev in r.spent.flatMap { rev > 0 ? "\(Int(($0 / rev * 100).rounded()))%" : nil } } ?? "–").frame(width: 60, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .font(Theme.body.monospacedDigit())
            }
            Text("Revenue is what you enter or import. A dash under AI + tech means spend wasn't tracked yet that month. AI + tech is Claude extra usage, API spend and AI or Tech ledger charges; plans count from this month only, since they have no start dates. Share is AI + tech as a part of revenue.")
                .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension Fmt {
    static func plain(_ v: Double) -> String { v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(format: "%.2f", v) }
}

/// Week over week, when the work happens, which projects and models eat the tokens.
struct TrendsView: View {
    @ObservedObject var model: ReportModel
    @ObservedObject var store: AccountStore
    @State private var shapes: [TokenCounter.SessionShape] = []
    @State private var heat: [[Int]] = []
    @State private var computing = false
    @State private var weeks: [WeekTrend] = []
    @State private var computed = Date.distantPast

    var body: some View {
        let now = weeks.last, prev = weeks.dropLast().last
        VStack(alignment: .leading, spacing: 16) {
            section("This week vs. last week") {
                HStack(spacing: 10) {
                    trendCard("Claude Code tokens", Double(now?.tokens ?? 0), Double(prev?.tokens ?? 0)) { Fmt.tokens(Int($0)) }
                    trendCard("Extra usage", now?.extra ?? 0, prev?.extra ?? 0) { Fmt.money($0.rounded(), "USD") }
                    trendCard("API-price value", now?.value ?? 0, prev?.value ?? 0) { Fmt.money($0.rounded(), "USD") }
                    trendCard("Cache reads", (now?.cacheShare ?? 0) * 100, (prev?.cacheShare ?? 0) * 100) { "\(Int($0.rounded()))%" }
                }
                Text("This week is partial (it runs \(weekRange(now?.start))). Arrows compare measured totals; nothing is projected.")
                    .font(Theme.caption).foregroundStyle(.secondary)
            }
            section("Eight weeks") {
                Chart {
                    ForEach(weeks) { w in
                        BarMark(x: .value("Week", w.start, unit: .weekOfYear), y: .value("Tokens", Double(w.tokens) / 1e6))
                            .foregroundStyle(Color.secondary)
                    }
                }
                .chartYAxisLabel("Million tokens")
                .frame(height: 130)
                Chart {
                    ForEach(weeks) { w in
                        LineMark(x: .value("Week", w.start, unit: .weekOfYear), y: .value("Extra", w.extra))
                            .foregroundStyle(Theme.alert)
                            .symbol(Circle())
                    }
                }
                .chartYAxisLabel("Extra usage, USD")
                .frame(height: 110)
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 3) {
                    GridRow {
                        Text("Week of").gridColumnAlignment(.leading); Text("Tokens"); Text("Cache"); Text("Output"); Text("Sessions"); Text("Codex"); Text("Value"); Text("Extra")
                    }.font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(weeks) { w in
                        GridRow {
                            Text(w.start, format: .dateTime.month(.abbreviated).day()).gridColumnAlignment(.leading)
                            Text(Fmt.tokens(w.tokens)); Text("\(Int((w.cacheShare * 100).rounded()))%"); Text(Fmt.tokens(w.output)); Text("\(w.sessions)")
                            Text(w.codex > 0 ? Fmt.tokens(w.codex) : "–"); Text(Fmt.money(w.value.rounded(), "USD")); Text(Fmt.money(w.extra.rounded(), "USD"))
                        }.font(.system(size: 11).monospacedDigit())
                    }
                }
            }
            section("When the work happens · last 28 days") {
                if heat.isEmpty {
                    Text(computing ? "Reading transcripts…" : "No sessions in range.").font(Theme.body).foregroundStyle(.secondary)
                } else {
                    let peak = max(heat.flatMap { $0 }.max() ?? 1, 1)
                    let dow = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 2) {
                            Text("").frame(width: 30)
                            ForEach(0..<24, id: \.self) { h in
                                Text(h % 6 == 0 ? "\(h)" : "").font(.system(size: 8)).foregroundStyle(.secondary).frame(width: 16)
                            }
                        }
                        ForEach(0..<7, id: \.self) { d in
                            HStack(spacing: 2) {
                                Text(dow[d]).font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
                                ForEach(0..<24, id: \.self) { h in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.primary.opacity(heat[d][h] == 0 ? 0.05 : 0.12 + 0.7 * Double(heat[d][h]) / Double(peak)))
                                        .frame(width: 16, height: 12)
                                        .help("\(dow[d]) \(h):00 · \(Fmt.tokens(heat[d][h])) tokens")
                                }
                            }
                        }
                    }
                    let total = max(heat.flatMap { $0 }.reduce(0, +), 1)
                    let byDay = heat.map { $0.reduce(0, +) }
                    let byHour = (0..<24).map { h in heat.map { $0[h] }.reduce(0, +) }
                    let topDay = byDay.enumerated().max { $0.element < $1.element }!
                    let topHours = byHour.enumerated().sorted { $0.element > $1.element }.prefix(3).map(\.offset).sorted()
                    Text("\(dow[topDay.offset]) carries \(Int(Double(topDay.element) / Double(total) * 100))% of tokens. Busiest hours: \(topHours.map { "\($0):00" }.joined(separator: ", ")). Heavy work started at the top of a fresh 5-hour window on the account with the most weekly room has the most headroom.")
                        .font(Theme.body).fixedSize(horizontal: false, vertical: true)
                }
            }
            section("Most expensive sessions · last 14 days") {
                ForEach(shapes.prefix(10)) { s in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.project).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            Text("\(s.start.formatted(date: .abbreviated, time: .shortened)) · \(s.turns) turns · \(s.minutes) min · \(Fmt.model(s.topModel))")
                                .font(Theme.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(Fmt.money(s.value.rounded(), "USD")).font(.system(size: 11, weight: .semibold).monospacedDigit())
                            Text("\(Fmt.tokens(s.total)) · \(Int((s.cacheShare * 100).rounded()))% cache" + (s.heavyTurns > 0 ? " · \(s.heavyTurns) heavy turns" : ""))
                                .font(Theme.caption).foregroundStyle(s.heavyTurns > 0 ? Theme.warn : .secondary)
                        }
                    }
                }
                Text("Heavy turns re-send over 300K tokens of context. A session with many of them is one to split or /compact.")
                    .font(Theme.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: compute)
        .onReceive(ReportNav.shared.$tab) { t in
            if ReportNav.normalized(t) == "projects", Date().timeIntervalSince(computed) > 300 { compute() }
        }
        .onChange(of: model.codexDays.count) { _, _ in weeks = Self.weeks(model) }
        .onChange(of: model.allSnapshots.count) { _, _ in weeks = Self.weeks(model) }
    }

    private static func weeks(_ model: ReportModel) -> [WeekTrend] {
        Trends.weeks(claude: TokenHistory.rows(since: .distantPast, missingFrom: []), codex: model.codexDays, snapshots: model.allSnapshots)
    }

    private func compute() {
        weeks = Self.weeks(model)
        guard !computing else { return }
        computing = true
        computed = Date()
        let profiles = store.accounts.map(\.profileURL)
        TokenCounter.queue.async {
            let s = TokenCounter.shapes(profiles: profiles, since: Date().addingTimeInterval(-14 * 86_400))
            let h = TokenCounter.heat(profiles: profiles, since: Date().addingTimeInterval(-28 * 86_400))
            DispatchQueue.main.async { shapes = s; heat = h.flatMap { $0 }.reduce(0, +) > 0 ? h : []; computing = false }
        }
    }

    private func weekRange(_ start: Date?) -> String {
        guard let start, let end = Calendar.current.date(byAdding: .day, value: 6, to: start) else { return "this week" }
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return "\(f.string(from: start))–\(f.string(from: end))"
    }

    private func trendCard(_ title: String, _ now: Double, _ before: Double, _ fmt: @escaping (Double) -> String) -> some View {
        let c = Trends.change(now, before)
        let good: Bool? = c?.up.map { !$0 }   // more spend, tokens or cache share is never the good direction
        return VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.body).foregroundStyle(.secondary)
            Text(fmt(now)).font(Theme.bigNumber).lineLimit(1).minimumScaleFactor(0.7)
            HStack(spacing: 4) {
                Text(c?.text ?? "no prior week").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(good == nil ? Color.secondary : (good! ? Color.green : Theme.alert))
                Text("vs \(fmt(before))").font(Theme.caption).foregroundStyle(.secondary)
            }
        }
        .card(padding: 12, radius: 14)
    }

    @ViewBuilder private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title).padding(.leading, 4)
            VStack(alignment: .leading, spacing: 8) { content() }.card(padding: 14, radius: 16)
        }
    }
}

/// The backlog: add, score, rank, move through inbox → next → doing → done.
struct IdeasView: View {
    @ObservedObject var ideas = IdeaStore.shared
    @ObservedObject var manager = Manager.shared
    var store: AccountStore
    @State private var draft = ""
    @State private var filter = "open"
    @State private var expanded: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Collect everything, then let the score and the manager say what's next.").font(Theme.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $filter) {
                    Text("Open").tag("open"); Text("Doing").tag("doing"); Text("Done").tag("done"); Text("All").tag("all")
                }.pickerStyle(.segmented).frame(width: 240)
            }
            HStack {
                TextField("New idea… (⏎ to add)", text: $draft, onCommit: add).textFieldStyle(.roundedBorder)
                Button("Add", action: add).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                Button {
                    manager.run(store: store)
                } label: { Label(manager.running ? "Ranking…" : "Rank with Claude", systemImage: "sparkles") }
                .disabled(manager.running || !manager.hasKey)
                .help(manager.hasKey ? "Sends the backlog and your usage to Claude for a ranking (uses your API key)" : "Add a Claude API key in Settings")
            }
            if let e = manager.error { Text(e).font(Theme.caption).foregroundStyle(Theme.alert) }
            Text("Score = value × 2 ÷ (effort + token size). Ranked by the manager's order when it has run, otherwise by score. From a terminal: `idea \"your idea\"`.")
                .font(Theme.caption).foregroundStyle(.secondary)
            let closed = ideas.ideas.filter { $0.status == "done" || $0.status == "dropped" }
            let list: [Idea] = filter == "doing" ? ideas.ranked.filter { $0.status == "doing" }
                : filter == "done" ? closed : filter == "all" ? ideas.ranked + closed : ideas.ranked
            if list.isEmpty {
                Text(filter == "open" ? "Nothing here yet. Add the first idea above." : "Nothing in this view.").font(Theme.body).foregroundStyle(.secondary).padding(.top, 8)
            }
            VStack(spacing: 6) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, idea in
                    row(i + 1, idea)
                }
            }
        }
        .onAppear { ideas.reloadIfChanged() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in ideas.reloadIfChanged() }
    }

    private func add() { ideas.add(draft); draft = "" }

    private func row(_ n: Int, _ idea: Idea) -> some View {
        let open = expanded == idea.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(idea.managerRank != nil && idea.status != "done" ? "#\(idea.managerRank!)" : "\(n)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundStyle(idea.managerRank != nil ? Theme.accent : .secondary).frame(width: 28)
                Text(idea.title).font(.system(size: 12, weight: .medium)).strikethrough(idea.status == "done" || idea.status == "dropped")
                    .lineLimit(open ? nil : 1)
                Spacer()
                Text(String(format: "%.1f", idea.score)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary).help("Score")
                Picker("", selection: Binding(get: { idea.status }, set: { var i = idea; i.status = $0; ideas.update(i) })) {
                    ForEach(IdeaStore.statuses, id: \.self) { Text($0.capitalized).tag($0) }
                }.labelsHidden().frame(width: 90)
                Button { expanded = open ? nil : idea.id } label: { Image(systemName: open ? "chevron.up" : "chevron.down") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            if let note = idea.managerNote, !note.isEmpty {
                Label(note, systemImage: "sparkles").font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if open {
                HStack(spacing: 14) {
                    stepper("Value", idea.value, 1...5) { var i = idea; i.value = $0; ideas.update(i) }
                    stepper("Effort", idea.effort, 1...5) { var i = idea; i.effort = $0; ideas.update(i) }
                    stepper("Tokens", idea.size, 1...3) { var i = idea; i.size = $0; ideas.update(i) }
                    Spacer()
                    Text("Added \(idea.created.formatted(date: .abbreviated, time: .omitted)) · \(idea.source)").font(Theme.caption).foregroundStyle(.secondary)
                    Button(role: .destructive) { ideas.remove(idea) } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                TextField("Notes", text: Binding(get: { idea.notes }, set: { var i = idea; i.notes = $0; ideas.update(i) }), axis: .vertical)
                    .textFieldStyle(.roundedBorder).font(Theme.body).lineLimit(1...4)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(idea.status == "doing" ? 0.07 : 0.035)))
    }

    private func stepper(_ label: String, _ v: Int, _ range: ClosedRange<Int>, _ set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label).font(Theme.caption).foregroundStyle(.secondary)
            Stepper("\(v)", value: Binding(get: { v }, set: set), in: range).font(.system(size: 11).monospacedDigit()).fixedSize()
        }
    }
}

/// The manager's latest brief, with the run button, cost and history.
struct ManagerView: View {
    @ObservedObject var manager = Manager.shared
    var store: AccountStore
    @State private var showPack = false
    @State private var packText = ""
    @State private var which = 0
    @State private var full = false

    var body: some View {
        let brief = manager.briefs.indices.contains(which) ? manager.briefs[which] : manager.latest
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Claude reads your real numbers and says what to change. Its own cost is counted.").font(Theme.caption).foregroundStyle(.secondary)
                Spacer()
                if manager.briefs.count > 1 {
                    Picker("", selection: $which) {
                        ForEach(Array(manager.briefs.prefix(20).enumerated()), id: \.offset) { i, b in
                            Text(b.date.formatted(date: .abbreviated, time: .shortened)).tag(i)
                        }
                    }.labelsHidden().frame(width: 170)
                }
                Button { manager.run(store: store) } label: {
                    Label(manager.running ? "Thinking…" : "Run brief now", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .disabled(manager.running || !manager.hasKey)
            }
            if !manager.hasKey {
                HStack {
                    Text("Add a Claude API key to turn the manager on.").font(Theme.body).foregroundStyle(.secondary)
                    Button("Open Setup…") { SettingsWindow.show(setup: true) }.controlSize(.small)
                }
            }
            if let e = manager.error { Text(e).font(Theme.body).foregroundStyle(Theme.alert).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 12) {
                Text("Model: \(Fmt.model(manager.model))")
                Text("Transcript excerpts: \(manager.sendTranscripts ? "sent" : "not sent")")
                Text("Daily brief: \(manager.autoDaily ? "on, after \(manager.autoHour):00" : "off")")
                Text("Manager cost this month: \(Fmt.money(manager.costThisMonth, "USD"))")
                Spacer()
                Button("What gets sent…") {
                    let x = manager.inputs(store: store)
                    TokenCounter.queue.async {
                        let t = Manager.pack(x).text
                        DispatchQueue.main.async { packText = t; showPack = true }
                    }
                }.buttonStyle(.link)
            }
            .font(Theme.caption).foregroundStyle(.secondary)
            Group {
                if let b = brief {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(b.headline).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        Text(b.brief).font(Theme.body).fixedSize(horizontal: false, vertical: true)
                        if !b.budgetMove.isEmpty {
                            Label(b.budgetMove, systemImage: "dollarsign.circle").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent).fixedSize(horizontal: false, vertical: true)
                        }
                        group("Do next", b.nextActions, "checkmark.circle")
                        DisclosureGroup("Full brief", isExpanded: $full) {
                        VStack(alignment: .leading, spacing: 10) {
                        if !b.findings.isEmpty {
                            SectionHeader(title: "Where tokens went to waste")
                            ForEach(b.findings) { f in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text((f.session.isEmpty ? "" : "[\(f.session)] ") + f.project).font(.system(size: 11, weight: .semibold))
                                    Text(f.waste).font(Theme.body).fixedSize(horizontal: false, vertical: true)
                                    Text("→ " + f.fix).font(Theme.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                            }
                        }
                        group("Prompting", b.promptTips, "text.bubble")
                        group("Workflow", b.workflow, "arrow.triangle.branch")
                        if !b.ranking.isEmpty {
                            SectionHeader(title: "Backlog, ranked")
                            ForEach(b.ranking.sorted { $0.rank < $1.rank }, id: \.id) { r in
                                let title = IdeaStore.shared.ideas.first { $0.id.uuidString.lowercased().hasPrefix(r.id.lowercased().prefix(8)) }?.title ?? r.id
                                HStack(alignment: .top, spacing: 6) {
                                    Text("#\(r.rank)").font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundStyle(Theme.accent).frame(width: 28, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(title).font(.system(size: 11, weight: .medium))
                                        Text(r.reason).font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                        }.padding(.top, 6)
                        }
                        .font(Theme.body)
                        Text("\(b.date.formatted(date: .abbreviated, time: .shortened)) · \(Fmt.model(b.model)) · \(Fmt.tokens(b.inputTokens)) in / \(Fmt.tokens(b.outputTokens)) out · \(Fmt.money(b.cost, "USD")) at list price. This is Claude's reading of measured data; check any number against the report.")
                            .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                } else if manager.running {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading transcripts and asking Claude… about a minute.").font(Theme.body).foregroundStyle(.secondary) }
                } else {
                    Text("No brief yet. Run one to get a reading of this month: where the money went, which sessions wasted tokens, what to prompt differently, and what to build next.")
                        .font(Theme.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .sheet(isPresented: $showPack) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Exactly what the manager sends to Claude").font(.system(size: 13, weight: .semibold))
                TextEditor(text: .constant(packText)).font(.system(size: 10.5, design: .monospaced)).frame(width: 640, height: 440)
                HStack { Spacer(); Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(packText, forType: .string) }; Button("Close") { showPack = false }.keyboardShortcut(.cancelAction) }
            }.padding(16)
        }
    }

    @ViewBuilder private func group(_ title: String, _ items: [String], _ icon: String) -> some View {
        if !items.isEmpty {
            SectionHeader(title: title)
            ForEach(Array(items.enumerated()), id: \.offset) { _, s in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Theme.accent).frame(width: 14)
                    Text(s).font(Theme.body).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Menu bar (status item, panel, shared status)
//
// A gauge in the menu bar whose needle shows the active account's tightest limit, a right-click app menu,
// and a non-activating panel under it holding the same tile strip, a focus card, three stats and a footer.
// Spec: docs/menubar-spec.html (approved Oct 30). The desktop strip stays as an option (Settings).

enum Product {
    /// The name shown in the interface. One string, so a rename is a one-line change; the bundle id,
    /// executable and data paths stay `local.ai-orchestrator` / AIOrchestrator.
    static let name = "AI Orchestrator"
}

/// Settings › Appearance › Look. Glass needs macOS 26 and is never used under Reduce Transparency or
/// Increase Contrast; Solid is today's opaque look.
enum Look: String, CaseIterable {
    case glass, solid
    static let key = "look"
    static var current: Look { Look(rawValue: UserDefaults.standard.string(forKey: key) ?? "glass") ?? .glass }
    var title: String { self == .glass ? "Glass" : "Solid" }
    /// Glass is really on screen. Glass windows have no window shadow: it draws a dark ring around the shape.
    static var glassActive: Bool {
        guard #available(macOS 26, *), current == .glass else { return false }
        let ws = NSWorkspace.shared
        return !ws.accessibilityDisplayShouldReduceTransparency && !ws.accessibilityDisplayShouldIncreaseContrast
    }
}

/// The frosted layer behind the glass: a strong behind-window blur, so text and bars stay readable over anything.
struct FrostBacking: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// material.panel: glass (macOS 26, Look = Glass) or a solid fill. Only for the panel, the pinned strip and
/// controls; anything inside uses Theme.platter, never a second glass layer.
struct Surface: ViewModifier {
    var radius: CGFloat
    var solid: Color = Theme.panelSolid
    /// The desktop strip: light, see-through glass like the Dock beside it. The panel stays dense.
    var dockLike = false
    /// Radius in Solid mode, when it differs from the glass radius.
    var solidRadius: CGFloat?
    @AppStorage(Look.key) private var look = Look.glass.rawValue
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let glass = look == Look.glass.rawValue && !reduceTransparency && contrast != .increased
        if #available(macOS 26, *) {
            if glass {
                // Dock-style: frosted backing, glass, a neutral tint over it, and a bright top edge fading to almost nothing.
                content
                    .background(shape.fill(dockLike ? Color.black.opacity(scheme == .dark ? 0.08 : 0)
                                                    : (scheme == .dark ? Color.black.opacity(0.56) : Color.white.opacity(0.55))))
                    .glassEffect(.regular, in: shape)
                    .background { if !dockLike { FrostBacking().clipShape(shape) } }
                    .overlay(shape.strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(0.6), location: 0),
                                                                       .init(color: .white.opacity(0.1), location: 0.3),
                                                                       .init(color: .white.opacity(0.04), location: 1)],
                                                               startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
                        .allowsHitTesting(false))
            } else {
                solidBody(content, RoundedRectangle(cornerRadius: solidRadius ?? radius, style: .continuous))
            }
        } else {
            solidBody(content, RoundedRectangle(cornerRadius: solidRadius ?? radius, style: .continuous))
        }
    }

    private func solidBody(_ content: Content, _ shape: RoundedRectangle) -> some View {
        content.background(solid).clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.4 : 0.2), lineWidth: contrast == .increased ? 1 : 0.5))
    }
}

/// One status for the icon, the panel's status line and status.json, so they never disagree.
struct MenuBarStatus {
    /// In priority order: when several apply, the lowest raw value wins the icon.
    enum State: Int, CaseIterable {
        case signedOut = 1, payingExtra, atLimit, gettingClose, otherAtLimit, normal, refreshing, stale
        var key: String { ["", "signedOut", "payingExtra", "atLimit", "gettingClose", "otherAtLimit", "normal", "refreshing", "stale"][rawValue] }
    }
    enum Badge: String { case alert, warn, ring, pay }

    var state: State = .normal
    var all: [State] = []
    /// The active account's tightest limit, 0…1 (nil: no reading yet).
    var fraction: Double?
    var limitName = ""
    var activeName = ""
    /// Everything that applies, most important first.
    var lines: [String] = []
    var updated: Date?

    var badge: Badge? {
        switch state {
        case .payingExtra: return .pay
        case .atLimit: return .alert
        case .gettingClose: return .warn
        case .otherAtLimit: return .ring
        default: return nil
        }
    }

    var percentText: String { fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "–" }

    /// VoiceOver: "AI Budgeting. Claude Main, 24 percent of 5-hour limit. Work weekly limit reached."
    var label: String {
        var parts = [Product.name]
        if let f = fraction { parts.append("Claude \(activeName), \(Int((f * 100).rounded())) percent of \(limitName) limit") }
        parts += lines.filter { !$0.hasPrefix(activeName + " at ") && !$0.hasPrefix(activeName + " has room") }
        return parts.joined(separator: ". ") + "."
    }

    var json: [String: Any] {
        var d: [String: Any] = ["state": state.key, "priority": state.rawValue, "states": all.map(\.key), "lines": lines, "label": label]
        if let f = fraction { d["percent"] = (f * 1000).rounded() / 10 }
        if let b = badge { d["badge"] = b.rawValue }
        if !limitName.isEmpty { d["limit"] = limitName }
        if let u = updated { d["updated"] = ISO8601DateFormatter().string(from: u) }
        return d
    }
}

extension AccountStore {
    /// The active Claude account's tightest limit: (percent, name).
    func tightest(_ a: Account) -> (Double, String)? {
        guard let u = usage[a.slug] else { return nil }
        if let l = u.details?.limits.max(by: { $0.percent < $1.percent }) { return (l.percent, l.name.lowercased()) }
        let rows: [(Double?, String)] = [(u.session?.percent, "5-hour"), (u.weekly?.percent, "weekly")]
        return rows.compactMap { p, n in p.map { ($0, n) } }.max { $0.0 < $1.0 }
    }

    var menuBarStatus: MenuBarStatus {
        var s = MenuBarStatus()
        guard !accounts.isEmpty else { return s }
        let active = current
        s.activeName = active.name
        s.updated = usage[active.slug]?.updated
        var states: [MenuBarStatus.State] = []
        var lines: [(MenuBarStatus.State, String)] = []

        let signedOut = accounts.filter { usage[$0.slug]?.state == .needsSignIn }
        if !signedOut.isEmpty {
            states.append(.signedOut)
            signedOut.forEach { lines.append((.signedOut, "\($0.name) needs sign-in")) }
        }
        let all = targets
        let paying = all.filter { $0.paysExtra && $0.blocked }
        if !paying.isEmpty {
            states.append(.payingExtra)
            paying.forEach { lines.append((.payingExtra, "\($0.name) is billing extra usage")) }
        }
        if let (p, name) = tightest(active) {
            s.fraction = min(max(p / 100, 0), 1)
            s.limitName = name
            if p >= 90 { states.append(.atLimit); lines.append((.atLimit, "\(active.name) at \(Int(p.rounded()))% of \(name) limit")) }
            else if p >= 70 { states.append(.gettingClose); lines.append((.gettingClose, "\(active.name) at \(Int(p.rounded()))% of \(name) limit")) }
        }
        for t in all where t.id != "claude:\(active.slug)" {
            let short = t.short ?? 0, weekly = t.weekly ?? 0
            let p = max(short, weekly)
            guard p >= 90 else { continue }
            let label = weekly >= short ? (t.id.hasPrefix("cursor:") ? "monthly" : "weekly") : "5-hour"
            if !states.contains(.otherAtLimit) { states.append(.otherAtLimit) }
            lines.append((.otherAtLimit, p >= 100 ? "\(t.name) \(label) limit reached" : "\(t.name) at \(Int(p.rounded()))% of \(label)"))
        }
        let refreshing = !fetching.isEmpty && Date().timeIntervalSince(fetchStarted) > 1 && Date().timeIntervalSince(fetchStarted) < 90
        if refreshing { states.append(.refreshing); lines.append((.refreshing, "Refreshing…")) }
        if isStale(active) || (s.fraction == nil && usage[active.slug]?.state != .loading && usage[active.slug] != nil && !signedOut.contains(active)) {
            states.append(.stale)
            lines.append((.stale, s.updated.map { "\(active.name) " + Fmt.measured($0) } ?? "\(active.name) has no reading"))
        }
        if !states.contains(where: { [.atLimit, .gettingClose, .refreshing, .stale].contains($0) }), s.fraction != nil {
            states.append(.normal)
            lines.append((.normal, "\(active.name) has room"))
        }
        if s.fraction == nil, usage[active.slug] == nil || usage[active.slug]?.state == .loading, !refreshing {
            lines.append((.normal, "Loading usage…"))
        }
        s.all = states.sorted { $0.rawValue < $1.rawValue }
        s.state = s.all.first ?? .normal
        s.lines = lines.sorted { $0.0.rawValue < $1.0.rawValue }.map(\.1)
        return s
    }

    /// "Claude Main, active. 5-hour 24 percent. Weekly 17 percent."
    func accessibilityLabel(for a: Account) -> String {
        var parts = ["Claude \(a.name)" + (current.slug == a.slug ? ", active" : "")]
        let u = usage[a.slug]
        if u?.state == .needsSignIn { parts.append("Usage not connected") }
        if let p = u?.session?.percent { parts.append("5-hour \(Int(p.rounded())) percent") }
        if let p = u?.weekly?.percent { parts.append("Weekly \(Int(p.rounded())) percent") }
        if isStale(a) { parts.append("reading over 6 hours old") }
        if let t = targets.first(where: { $0.id == "claude:\(a.slug)" }), t.paysExtra && t.blocked { parts.append("billing extra usage") }
        if pick?.id == "claude:\(a.slug)" { parts.append("use next") }
        return parts.joined(separator: ". ")
    }

    func accessibilityLabel(for o: OtherAccount) -> String {
        var parts = [o.isMain ? o.app.title : "\(o.app.title) \(o.name)"]
        if o.app == .cursor, let u = cursorUsage[o.id] {
            parts.append("Month \(Int(u.percent.rounded())) percent")
            if let l = u.limit { parts.append(Fmt.money(max(0, l - u.used).rounded(), "USD") + " left") }
        } else if let u = codexUsage[o.id] {
            if let p = u.shortPercent { parts.append("5-hour \(Int(p.rounded())) percent") }
            if let p = u.weeklyPercent { parts.append("Weekly \(Int(p.rounded())) percent") }
            if u.stale { parts.append("reading over 6 hours old") }
        } else if let why = otherProblem[o.id] {
            parts.append("No usage: \(why)")
        }
        if pick?.id == o.id { parts.append("use next") }
        return parts.joined(separator: ". ")
    }
}

/// The menu-bar gauge, drawn in code on an 18 × 18 pt grid (spec section 01). The gauge is a template image;
/// the coloured badge is a separate layer (`GaugeBadgeView`), so only the gauge follows the menu bar's tint.
enum GaugeIcon {
    static func point(_ deg: Double, _ r: Double) -> NSPoint {
        let a = deg * .pi / 180
        return NSPoint(x: 9 + r * cos(a), y: 10 - r * sin(a))
    }

    /// `needle` in degrees (nil = no needle), `badge` cuts a knockout where the badge sits.
    static func image(needle: Double?, stale: Bool, signedOut: Bool, badge: MenuBarStatus.Badge?) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current else { return false }
            let ink = NSColor.black.withAlphaComponent(stale ? 0.45 : 1)
            ink.set()
            let arc = NSBezierPath()
            for i in 0...48 {
                let p = point(210 - 240 * Double(i) / 48, 7)
                if i == 0 { arc.move(to: p) } else { arc.line(to: p) }
            }
            arc.lineWidth = 1.6
            arc.lineCapStyle = .round
            arc.lineJoinStyle = .round
            if stale { arc.setLineDash([1.6, 2.2], count: 2, phase: 0) }
            arc.stroke()
            if let deg = needle, !stale, !signedOut {
                let n = NSBezierPath()
                n.move(to: NSPoint(x: 9, y: 10))
                n.line(to: point(deg, 5.2))
                n.lineWidth = 1.6
                n.lineCapStyle = .round
                n.stroke()
            }
            NSBezierPath(ovalIn: NSRect(x: 9 - 1.4, y: 10 - 1.4, width: 2.8, height: 2.8)).fill()
            if signedOut {
                // Slash with a knockout either side, so it reads against the arc.
                ctx.compositingOperation = .clear
                let k = NSBezierPath(); k.move(to: NSPoint(x: 3, y: 3.2)); k.line(to: NSPoint(x: 15.5, y: 16)); k.lineWidth = 3; k.stroke()
                ctx.compositingOperation = .sourceOver
                NSColor.black.set()
                let sl = NSBezierPath(); sl.move(to: NSPoint(x: 3, y: 3.2)); sl.line(to: NSPoint(x: 15.5, y: 16)); sl.lineWidth = 1.5; sl.lineCapStyle = .round; sl.stroke()
            }
            if let badge {
                ctx.compositingOperation = .clear
                let r: CGFloat = badge == .pay ? 4.2 : 3.6
                let c = NSPoint(x: badge == .pay ? 14.4 : 14.6, y: 4)
                NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
                ctx.compositingOperation = .sourceOver
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

/// The badge layer over the gauge: keeps its colour (alert, warn, hollow ring, $). Drawn in the gauge's 18 pt grid.
final class GaugeBadgeView: NSView {
    var badge: MenuBarStatus.Badge? { didSet { needsDisplay = true; isHidden = badge == nil } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let badge else { return }
        let s = bounds.width / 18
        func oval(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> NSBezierPath {
            NSBezierPath(ovalIn: NSRect(x: (cx - r) * s, y: (cy - r) * s, width: 2 * r * s, height: 2 * r * s))
        }
        let alert = NSColor(srgbRed: 0xF0/255, green: 0x6B/255, blue: 0x6B/255, alpha: 1)
        let warn = NSColor(srgbRed: 0xE6/255, green: 0xC7/255, blue: 0x7A/255, alpha: 1)
        switch badge {
        case .alert: alert.setFill(); oval(14.6, 4, 2.5).fill()
        case .warn: warn.setFill(); oval(14.6, 4, 2.5).fill()
        case .ring:
            alert.setStroke()
            let p = oval(14.6, 4, 2.4); p.lineWidth = 1.4 * s; p.stroke()
        case .pay:
            alert.setFill(); oval(14.4, 4, 3.4).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 5.5 * s, weight: .black),
                                                        .foregroundColor: NSColor(srgbRed: 0.106, green: 0.106, blue: 0.122, alpha: 1)]
            let str = NSAttributedString(string: "$", attributes: attrs)
            let sz = str.size()
            str.draw(at: NSPoint(x: 14.4 * s - sz.width / 2, y: 4 * s - sz.height / 2))
        }
    }
}

/// The menu-bar text option: icon only, icon and %, or icon and dollars left this month.
enum MenuBarText: String, CaseIterable {
    case icon, percent, dollars
    static let key = "menubar.show"
    var title: String { ["icon": "Icon only", "percent": "Icon and %", "dollars": "Icon and dollars left"][rawValue]! }
}

/// The global panel shortcut (Carbon hot key: no Accessibility permission needed).
enum HotKey: String, CaseIterable {
    case optCmdB, ctrlOptCmdB, optCmdG, off
    static let key = "panel.hotkey"
    static var current: HotKey { HotKey(rawValue: UserDefaults.standard.string(forKey: key) ?? "optCmdB") ?? .optCmdB }
    var title: String { ["optCmdB": "⌥⌘B", "ctrlOptCmdB": "⌃⌥⌘B", "optCmdG": "⌥⌘G", "off": "Off"][rawValue]! }

    private static var ref: EventHotKeyRef?
    private static var handler: EventHandlerRef?
    static var action: () -> Void = {}

    static func register() {
        if let r = ref { UnregisterEventHotKey(r); ref = nil }
        let (code, mods): (Int, Int)
        switch current {
        case .optCmdB: (code, mods) = (kVK_ANSI_B, cmdKey | optionKey)
        case .ctrlOptCmdB: (code, mods) = (kVK_ANSI_B, cmdKey | optionKey | controlKey)
        case .optCmdG: (code, mods) = (kVK_ANSI_G, cmdKey | optionKey)
        case .off: return
        }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.action() }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        RegisterEventHotKey(UInt32(code), UInt32(mods), EventHotKeyID(signature: OSType(0x41494247), id: 1),
                            GetApplicationEventTarget(), 0, &ref)
    }
}

/// What the panel is showing: the hovered (or arrow-key) tile, and whether it's open (for the open animation).
final class PanelModel: ObservableObject {
    @Published var shown = false
    @Published var hovered: String?
    @Published var keyFocus: String?
    private var pending: (id: String, work: DispatchWorkItem)?

    /// The pointer entered or left a tile. Focus moves 80 ms after entering, so crossing tiles doesn't flicker;
    /// leaving keeps the last focused account (the gaps between tiles and the card itself don't clear it).
    func hover(_ id: String, inside: Bool) {
        if !inside {
            if pending?.id == id { pending?.work.cancel(); pending = nil }
            return
        }
        pending?.work.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            if self.hovered != id { self.hovered = id }
        }
        pending = (id, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// Set right away (keyboard, opening on an account).
    func setFocus(_ id: String?) {
        pending?.work.cancel()
        pending = nil
        hovered = id
    }
}

final class MenuPanel: NSPanel {
    var onEscape: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape() }
}

final class MenuBarController: NSObject, NSMenuDelegate {
    let store: AccountStore
    let model = PanelModel()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let badgeView = GaugeBadgeView()
    private var panel: MenuPanel?
    private var monitors: [Any] = []
    private var bag: Set<AnyCancellable> = []
    private var lastState: MenuBarStatus.State?
    /// Needle animation: shown angle eases to the target (600 ms sweep); spins while a slow fetch runs.
    private var shownDeg: Double?
    private var targetDeg: Double?
    private var animTimer: Timer?
    private var spin: Double = 90
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(store: AccountStore) {
        self.store = store
        super.init()
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(clicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading
        button.addSubview(badgeView)
        item.autosaveName = "local.ai-orchestrator.gauge"
        store.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.update() } }
            .store(in: &bag)
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.update() }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.update()
        }
        HotKey.action = { [weak self] in self?.toggle() }
        HotKey.register()
        update()
    }

    // MARK: Icon

    func update() {
        guard let button = item.button else { return }
        let s = store.menuBarStatus
        let target = s.fraction.map { 210 - 240 * $0 }
        if s.state == .refreshing && !reduceMotion {
            startAnimating()
        } else if target != targetDeg {
            targetDeg = target
            if shownDeg == nil || target == nil || reduceMotion { shownDeg = target } else { startAnimating() }
        }
        drawIcon(s)
        switch MenuBarText(rawValue: UserDefaults.standard.string(forKey: MenuBarText.key) ?? "icon") ?? .icon {
        case .icon: button.title = ""
        case .percent: button.title = s.percentText
        case .dollars:
            let st = Budget.shared.standing(store: store)
            button.title = st.ceiling > 0 ? Fmt.money(st.left.rounded(), "USD") : "–"
        }
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button.setAccessibilityLabel(s.label)
        button.toolTip = ([Product.name] + s.lines).joined(separator: "\n")
        if s.state == .atLimit && lastState != nil && lastState != .atLimit { pulse() }
        lastState = s.state
    }

    /// The usage badge wins; otherwise a dot says an agent is waiting on you.
    private func shownBadge(_ s: MenuBarStatus) -> MenuBarStatus.Badge? {
        s.badge ?? (MainActor.assumeIsolated { T3Board.shared.rows.contains { $0.group == .needsYou } } ? .warn : nil)
    }

    private func drawIcon(_ s: MenuBarStatus) {
        guard let button = item.button else { return }
        let needle: Double? = s.state == .refreshing && !reduceMotion ? spin : (s.state == .refreshing ? 90 : shownDeg)
        button.image = GaugeIcon.image(needle: needle, stale: s.state == .stale, signedOut: s.state == .signedOut, badge: shownBadge(s))
        badgeView.badge = shownBadge(s)
        if let cell = button.cell as? NSButtonCell {
            badgeView.frame = cell.imageRect(forBounds: button.bounds)
        }
    }

    private func startAnimating() {
        guard animTimer == nil else { return }
        let start = Date(), from = shownDeg ?? targetDeg ?? 90
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let s = self.store.menuBarStatus
            if s.state == .refreshing && !self.reduceMotion {
                self.spin -= 12
                if self.spin < -150 { self.spin = 210 }
            } else {
                let k = min(1, Date().timeIntervalSince(start) / 0.6)
                let e = 1 - pow(1 - k, 3)
                if let to = self.targetDeg { self.shownDeg = from + (to - from) * e } else { self.shownDeg = nil }
                if k >= 1 || self.targetDeg == nil { t.invalidate(); self.animTimer = nil; self.spin = 90 }
            }
            self.drawIcon(s)
        }
    }

    /// Crossing 90%: two pulses of the badge, then still. Nothing under Reduce Motion.
    private func pulse() {
        guard !reduceMotion else { return }
        var steps = [0.25, 1, 0.25, 1]
        func next() {
            guard !steps.isEmpty else { return }
            let a = steps.removeFirst()
            NSAnimationContext.runAnimationGroup({ c in c.duration = 0.18; badgeView.animator().alphaValue = a }, completionHandler: next)
        }
        next()
    }

    // MARK: Clicks and menu

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true { showMenu() } else { toggle() }
    }

    private func showMenu() {
        close()
        let m = NSMenu()
        func add(_ title: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, _ run: @escaping () -> Void) -> NSMenuItem {
            let i = ClosureMenuItem(title: title, keyEquivalent: key, run: run)
            i.keyEquivalentModifierMask = mods
            m.addItem(i)
            return i
        }
        let s = store
        _ = add("Open \(Product.name)…", "r") { ReportWindow.show(store: s) }
        _ = add("New request…", "k") { OrchestratorWindow.show(view: "board") }
        _ = add("Ideas", "i", [.command, .shift]) { ReportNav.open("ideas", store: s) }
        _ = add("Refresh all usage", "r", [.command, .shift]) { s.refreshUsage() }
        m.addItem(.separator())
        let strip = add("Show desktop strip") { DesktopStrip.shown.toggle() }
        strip.state = DesktopStrip.shown ? .on : .off
        if store.hasHidden { _ = add("Show hidden accounts") { s.unhideAll() } }
        m.addItem(.separator())
        _ = add("Settings…", ",") { SettingsWindow.show() }
        _ = add("Quit \(Product.name)", "q") { NSApp.terminate(nil) }
        m.delegate = self
        item.menu = m
        item.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) { item.menu = nil }

    // MARK: Panel

    var isOpen: Bool { panel?.isVisible == true }

    func toggle() { isOpen ? close() : open() }

    func open(focus: String? = nil) {
        let p = panel ?? makePanel()
        p.hasShadow = !Look.glassActive
        model.setFocus(focus)
        model.keyFocus = nil
        store.lookedAt()
        position(p)
        p.alphaValue = 1
        p.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { self.model.shown = true }
        installMonitors()
    }

    func close() {
        guard let p = panel, p.isVisible else { return }
        model.shown = false
        removeMonitors()
        let fade = reduceMotion ? 0.12 : 0.15
        NSAnimationContext.runAnimationGroup({ c in c.duration = fade; p.animator().alphaValue = 0 }) {
            if !self.model.shown { p.orderOut(nil); p.alphaValue = 1 }
        }
    }

    private func makePanel() -> MenuPanel {
        let p = MenuPanel(contentRect: NSRect(x: 0, y: 0, width: 544, height: 300),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = !Look.glassActive
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.onEscape = { [weak self] in self?.close() }
        let host = FirstMouseHostingView(rootView: AnyView(PanelView(store: store, model: model, close: { [weak self] in self?.close() })))
        host.sizingOptions = [.intrinsicContentSize]
        p.contentView = host
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
            self?.close()
        }
        store.objectWillChange.merge(with: model.objectWillChange)
            .sink { [weak self] _ in DispatchQueue.main.async { if let self, let p = self.panel, p.isVisible { self.position(p) } } }
            .store(in: &bag)
        panel = p
        return p
    }

    /// Under the icon, top edge fixed, clamped to the screen; height fits content (max 640).
    private func position(_ p: MenuPanel) {
        guard let host = p.contentView, let bw = item.button?.window else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.intrinsicContentSize
        guard size.width > 0, size.height > 0 else { return }
        let icon = bw.frame
        let screen = bw.screen ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = icon.midX - size.width / 2
        x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
        let frame = NSRect(x: x, y: icon.minY - 6 - size.height, width: size.width, height: size.height)
        if frame != p.frame { p.setFrame(frame, display: true) }
    }

    /// Esc, a click outside, arrows/Return, ⌘1–⌘9, ⌘R, ⌘, and ⇧⌘R while the panel is open.
    private func installMonitors() {
        removeMonitors()
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in self?.close() }) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] e in
            guard let self, let p = self.panel else { return e }
            if e.window !== p && e.window !== self.item.button?.window { self.close() }
            return e
        }) { monitors.append(l) }
        if let k = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard let self, self.isOpen, e.window === self.panel else { return e }
            return self.handleKey(e) ? nil : e
        }) { monitors.append(k) }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
    }

    private var tileIDs: [String] { store.accounts.map { "claude:\($0.slug)" } + store.others.map(\.id) }

    private func activate(_ id: String) {
        if id.hasPrefix("claude:"), let a = store.accounts.first(where: { "claude:\($0.slug)" == id }) { store.switchTo(a) }
        else if let o = store.others.first(where: { $0.id == id }) { store.switchTo(o) }
        close()
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let ids = tileIDs
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""
        switch e.keyCode {
        case UInt16(kVK_Escape): close(); return true
        case UInt16(kVK_LeftArrow), UInt16(kVK_RightArrow):
            guard !ids.isEmpty else { return true }
            let cur = (model.keyFocus ?? model.hovered).flatMap { ids.firstIndex(of: $0) } ?? ids.firstIndex(of: "claude:\(store.current.slug)") ?? 0
            let next = e.keyCode == UInt16(kVK_LeftArrow) ? max(0, cur - 1) : min(ids.count - 1, cur + 1)
            model.keyFocus = ids[next]
            model.setFocus(ids[next])
            return true
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            if let f = model.keyFocus ?? model.hovered { activate(f) }
            return true
        default: break
        }
        if mods == .command, let n = Int(chars), (1...9).contains(n) {
            if n <= ids.count { activate(ids[n - 1]) }
            return true
        }
        if mods == .command && chars == "r" { close(); ReportWindow.show(store: store); return true }
        if mods == .command && chars == "," { close(); SettingsWindow.show(); return true }
        if mods == .command && chars == "n" { close(); store.addAccount(); return true }
        if mods == [.command, .shift] && chars == "r" { store.refreshUsage(); return true }
        if mods == [.command, .shift] && chars == "i" { close(); ReportNav.open("ideas", store: store); return true }
        return false
    }
}

/// An NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, keyEquivalent: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

/// Settings › Menu bar and desktop › Show desktop strip. On for anyone updating (they had the strip);
/// off for a brand-new install, where the menu bar is the front door.
enum DesktopStrip {
    static let key = "desktopStrip"
    /// A short column instead of a row. Swipe any direction to scroll it.
    static let verticalKey = "strip.vertical"
    static var vertical: Bool {
        get { UserDefaults.standard.bool(forKey: verticalKey) }
        set {
            guard newValue != vertical else { return }
            UserDefaults.standard.set(newValue, forKey: verticalKey)
            NotificationCenter.default.post(name: StripLayout.didResize, object: nil)
        }
    }
    /// Auto (default): a row along the top or bottom of the screen, a column along the sides, decided while dragging.
    /// Horizontal or Vertical pins it.
    enum Orientation: String, CaseIterable { case auto, horizontal, vertical
        var title: String { self == .auto ? "Automatic" : (self == .horizontal ? "Horizontal" : "Vertical") }
    }
    static let orientationKey = "strip.orientation"
    static var orientation: Orientation {
        get { Orientation(rawValue: UserDefaults.standard.string(forKey: orientationKey) ?? "") ?? .auto }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: orientationKey)
            if newValue != .auto { vertical = newValue == .vertical }
        }
    }
    static var shown: Bool {
        get {
            if UserDefaults.standard.object(forKey: key) == nil {
                let existing = FileManager.default.fileExists(atPath: History.dir.appendingPathComponent("history.jsonl").path)
                UserDefaults.standard.set(existing, forKey: key)
            }
            return UserDefaults.standard.bool(forKey: key)
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

// MARK: Desktop strip beside the Dock

/// The Dock's visible bar, in screen coordinates (origin bottom-left), when it's along the bottom of a screen.
/// Accessibility gives the exact sides when allowed; otherwise they come from the Dock's own settings and
/// what's running (measured Oct 30: predicts its 1150 pt exactly), with a little slack. Never prompts on its own.
enum DockBar {
    struct Info { var frame: NSRect; var padding: CGFloat; var measured: Bool; var screen: NSRect }
    /// The bar floats this far above the screen edge; the Dock reserves one point more above it.
    private static let floatGap: CGFloat = 5

    /// `screens` (frame, visibleFrame) lets a background thread call this without touching NSScreen.
    static func current(screens: [(NSRect, NSRect)]? = nil) -> Info? {
        let d = UserDefaults(suiteName: "com.apple.dock")
        let all = screens ?? NSScreen.screens.map { ($0.frame, $0.visibleFrame) }
        guard (d?.string(forKey: "orientation") ?? "bottom") == "bottom",
              let (frame, visible) = all.first(where: { $0.1.minY - $0.0.minY > 20 }) else { return nil }
        let inset = visible.minY - frame.minY
        let height = inset - floatGap - 1
        let y = frame.minY + floatGap
        let tile = CGFloat(d?.double(forKey: "tilesize") ?? 48)
        let padding = (tile * 0.2).rounded()
        if let (x, w) = accessibilitySides() {
            return Info(frame: NSRect(x: x, y: y, width: w, height: height), padding: padding, measured: true, screen: frame)
        }
        let w = estimatedWidth(tile: tile, padding: padding, d: d) + 12
        return Info(frame: NSRect(x: frame.midX - w / 2, y: y, width: w, height: height), padding: padding, measured: false, screen: frame)
    }

    private static func accessibilitySides() -> (CGFloat, CGFloat)? {
        guard AXIsProcessTrusted(), let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &kids) == .success,
              let list = (kids as? [AXUIElement])?.first else { return nil }
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(list, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(list, kAXSizeAttribute as CFString, &size) == .success else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p)
        AXValueGetValue(size as! AXValue, .cgSize, &s)
        return s.width > 0 ? (p.x, s.width) : nil
    }

    private static func estimatedWidth(tile: CGFloat, padding: CGFloat, d: UserDefaults?) -> CGFloat {
        func ids(_ key: String) -> [String] {
            ((d?.array(forKey: key) as? [[String: Any]]) ?? []).compactMap { ($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String }
        }
        let pinned = Set(ids("persistent-apps"))
        // Every running copy gets its own Dock icon (several Claude instances share one bundle id); a pinned app's first copy uses its pinned icon.
        var copies: [String: Int] = [:]
        for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular {
            copies[a.bundleIdentifier ?? "pid:\(a.processIdentifier)", default: 0] += 1
        }
        var extras = 0
        for (id, n) in copies where id != "com.apple.finder" { extras += pinned.contains(id) ? n - 1 : n }
        if d?.object(forKey: "show-recents") == nil || d?.bool(forKey: "show-recents") == true {
            extras += Set(ids("recent-apps")).subtracting(pinned).subtracting(copies.keys).count
        }
        let others = (d?.array(forKey: "persistent-others") ?? []).count
        let items = CGFloat(1 + (d?.array(forKey: "persistent-apps") ?? []).count + extras + others + 1)   // Finder … Trash
        let separators: CGFloat = extras == 0 ? 1 : 2
        return padding * 2 + items * (tile * 1.057) + separators * (tile * 0.37)
    }
}

/// The strip's size: matches the Dock's bar beside it, the user's chosen width, and a guard that keeps it clear of the Dock.
final class StripLayout: ObservableObject {
    static let shared = StripLayout()
    static let widthKey = "strip.width"
    /// The tile area's width. The row scrolls when the tiles need more.
    @Published var viewport: CGFloat = 300
    @Published var rowHeight: CGFloat = 34
    @Published var radius: CGFloat = 8
    /// Keeps the outer edges clear of the larger corner radius.
    @Published var sidePadding: CGFloat = 2
    var dock: DockBar.Info?
    /// The widths around the tile area: padding, drag handle, resize grip, spacing.
    var chrome: CGFloat { sidePadding * 2 + 9 + StripResizeGrip.width + 2 }
    private static let tile: CGFloat = TileStrip.tileWidth + 1
    private static let addTile: CGFloat = 26
    var minViewport: CGFloat { Self.tile + Self.addTile }
    var fullViewport: CGFloat = 300
    /// While dragging the grip.
    var anchorLeft = true
    /// Vertical mode: the column's tile area height, set with the bottom grip. Three tiles by default.
    static let columnKey = "strip.columnHeight"
    @Published var columnHeight: CGFloat = UserDefaults.standard.object(forKey: StripLayout.columnKey) as? CGFloat
        ?? CGFloat(TileStrip.visibleVertical) * (TileMetrics.height + 1) - 1
    /// The same gap between the screen edge and the strip as between the strip and the Dock's bar.
    static let dockGap: CGFloat = 8
    /// Parked beside the Dock: the strip's outer x, `dockGap` in from the screen edge. Nil elsewhere.
    var parkedX: CGFloat?

    private var cachedDock: DockBar.Info?
    private var cachedAt = Date.distantPast
    /// The latest Dock reading from the background check, so a layout doesn't make its own Accessibility call.
    func cache(_ d: DockBar.Info?) { cachedDock = d; cachedAt = Date() }

    /// Fits the strip to the Dock and returns the row's bottom edge when it's parked beside the bar.
    /// `anchor` is the parked corner.
    @discardableResult
    func update(tiles: Int, anchor: NSPoint, left: Bool) -> CGFloat? {
        if Date().timeIntervalSince(cachedAt) < 5 { dock = cachedDock } else { dock = DockBar.current(); cache(dock) }
        anchorLeft = left
        if DesktopStrip.vertical {      // the column isn't matched to the Dock; it keeps the same 8 pt from the screen edge
            let sf = (NSScreen.screens.first { $0.frame.minX <= anchor.x && anchor.x <= $0.frame.maxX } ?? NSScreen.main)?.frame
            // Snaps to 8 pt from the edge only when it's left close to it, so it can sit anywhere else.
            let x = sf.flatMap { f -> CGFloat? in
                let edge = left ? f.minX + Self.dockGap : f.maxX - Self.dockGap
                return abs(anchor.x - edge) < 40 ? edge : nil
            }
            if parkedX != x { parkedX = x }
            return nil
        }
        fullViewport = CGFloat(tiles) * Self.tile + Self.addTile
        var limit = fullViewport
        var bottom: CGFloat?
        var parked: CGFloat?
        if let d = dock, anchor.y < d.frame.maxY {      // same band as the bar
            bottom = d.frame.minY
            // Only beside the Dock (not over it) does its width cap the strip.
            if (left && anchor.x < d.frame.minX) || (!left && anchor.x > d.frame.maxX) {
                // Equal gaps: screen edge to strip, and strip to the Dock's bar.
                // Snaps to the edge only when dropped near it; elsewhere it stays where it was put (drag edge to edge).
                let g = Self.dockGap
                let edge = left ? d.screen.minX + g : d.screen.maxX - g
                let outer = abs(anchor.x - edge) < 40 ? edge : anchor.x
                let room = left ? d.frame.minX - g - outer : outer - (d.frame.maxX + g)
                limit = min(limit, max(minViewport, room - chrome))
                if outer == edge { parked = outer }
            }
        }
        if parkedX != parked { parkedX = parked }
        let saved = UserDefaults.standard.object(forKey: Self.widthKey) as? Double
        let v = max(minViewport, min(limit, saved.map { CGFloat($0) } ?? fullViewport))
        let row = dock.map { max(34, $0.frame.height - 4) } ?? 34
        let r = dock.map { ($0.frame.height * 0.38).rounded() } ?? 8
        let side: CGFloat = dock == nil ? 2 : 6
        if viewport != v { viewport = v }
        if rowHeight != row { rowHeight = row }
        if radius != r { radius = r }
        if sidePadding != side { sidePadding = side }
        // Written only when it changes: every write posts UserDefaults.didChange, which wakes several observers.
        let note = dock.map { "\(NSStringFromRect($0.frame)) \($0.measured ? "accessibility" : "estimate")" } ?? "none"
        if UserDefaults.standard.string(forKey: "strip.dockFrame") != note { UserDefaults.standard.set(note, forKey: "strip.dockFrame") }
        return bottom
    }

    func resize(to width: CGFloat) {
        UserDefaults.standard.set(Double(max(minViewport, min(fullViewport, width))), forKey: Self.widthKey)
        NotificationCenter.default.post(name: Self.didResize, object: nil)
    }
    static let didResize = Notification.Name("StripLayout.didResize")
}

/// The far edge of the strip (away from the parked corner): drag to resize.
struct StripResizeGrip: NSViewRepresentable {
    static let width: CGFloat = 8
    final class Grip: NSView {
        private var startX: CGFloat = 0, startWidth: CGFloat = 0
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func mouseDown(with event: NSEvent) {
            startX = NSEvent.mouseLocation.x
            startWidth = StripLayout.shared.viewport
        }
        override func mouseDragged(with event: NSEvent) {
            let delta = NSEvent.mouseLocation.x - startX
            StripLayout.shared.resize(to: startWidth + (StripLayout.shared.anchorLeft ? delta : -delta))
        }
        override func draw(_ dirtyRect: NSRect) {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            (dark ? NSColor(white: 1, alpha: 0.45) : NSColor(white: 0, alpha: 0.35)).setFill()
            let h = min(bounds.height, 18)
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - 1, y: bounds.midY - h / 2, width: 2, height: h), xRadius: 1, yRadius: 1).fill()
        }
    }
    func makeNSView(context: Context) -> Grip { Grip() }
    func updateNSView(_ v: Grip, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Grip, context: Context) -> CGSize? { CGSize(width: Self.width, height: 30) }
}

/// Vertical mode: the bottom edge of the column. Drag down to show more tiles, up for fewer; the top stays put.
struct StripColumnGrip: NSViewRepresentable {
    final class Grip: NSView {
        private var startY: CGFloat = 0, startH: CGFloat = 0, startAnchor: Double = 0
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
        override func mouseDown(with event: NSEvent) {
            startY = NSEvent.mouseLocation.y
            startH = StripLayout.shared.columnHeight
            startAnchor = UserDefaults.standard.double(forKey: "anchorY")
        }
        override func mouseDragged(with event: NSEvent) {
            let step = TileMetrics.height + 1
            let raw = startH + (startY - NSEvent.mouseLocation.y)
            // Whole tiles only, so the column never ends on a half-cut tile.
            let h = max(step - 1, ((raw + 1) / step).rounded() * step - 1)
            guard h != StripLayout.shared.columnHeight else { return }
            StripLayout.shared.columnHeight = h
            UserDefaults.standard.set(Double(h), forKey: StripLayout.columnKey)
            UserDefaults.standard.set(max(0, startAnchor - Double(h - startH)), forKey: "anchorY")
            NotificationCenter.default.post(name: StripLayout.didResize, object: nil)
        }
        override func draw(_ dirtyRect: NSRect) {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            (dark ? NSColor(white: 1, alpha: 0.45) : NSColor(white: 0, alpha: 0.35)).setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - 9, y: bounds.midY - 1, width: 18, height: 2), xRadius: 1, yRadius: 1).fill()
        }
    }
    func makeNSView(context: Context) -> Grip { Grip() }
    func updateNSView(_ v: Grip, context: Context) {}
}

// MARK: Panel views

struct PanelView: View {
    @ObservedObject var store: AccountStore
    @ObservedObject var model: PanelModel
    var close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let focus = model.hovered ?? "claude:\(store.current.slug)"
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(store: store, close: close)
            TileStrip(store: store)
                .environment(\.tileMetrics, .panel)
                .environment(\.tileHover, { id, inside in model.hover(id, inside: inside) })
                .environment(\.tileTapped, close)
                .environment(\.tileFocus, model.keyFocus)
            FocusCard(store: store, id: focus)
            StatsRow(store: store, close: close)
            TodayRow(store: store, close: close)
            WorkRow(close: close)
            PanelFooter(store: store, close: close)
        }
        .padding(14)
        .frame(width: 544, alignment: .leading)
        .frame(maxHeight: 640)
        .modifier(Surface(radius: 22))
        .scaleEffect(model.shown || reduceMotion ? 1 : 0.94, anchor: .top)
        .opacity(model.shown ? 1 : 0)
        .animation(reduceMotion ? .linear(duration: 0.12) : .spring(response: 0.32, dampingFraction: 0.85), value: model.shown)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(Product.name) panel")
    }
}

/// "Needs you 2 · Running 1", opening the Overview. Hidden when no agent is waiting or working.
struct WorkRow: View {
    let close: () -> Void
    @ObservedObject private var board = T3Board.shared
    var body: some View {
        let needs = board.rows.filter { $0.group == .needsYou }.count
        let running = board.rows.filter { $0.group == .running }.count
        if needs + running > 0 {
            Button {
                close()
                OrchestratorWindow.show(view: "board")
            } label: {
                HStack(spacing: 6) {
                    Text([needs > 0 ? "Needs you \(needs)" : nil, running > 0 ? "Running \(running)" : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// A small round control on the panel: fill.platter, not a second glass layer.
struct PanelButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10).frame(height: 26)
            .background(Capsule().fill(prominent ? Color.primary.opacity(configuration.isPressed ? 0.22 : 0.16)
                                                 : (configuration.isPressed ? Theme.platterHover : Theme.platter)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .contentShape(Capsule())
    }
}

struct PanelHeader: View {
    @ObservedObject var store: AccountStore
    var close: () -> Void
    @State private var now = Date()

    var body: some View {
        let s = store.menuBarStatus
        HStack(spacing: 10) {
            Brand.mark(30)
            VStack(alignment: .leading, spacing: 2) {
                Text(Product.name).font(.system(size: 15, weight: .semibold))
                Text((s.lines + [s.updated.map { "updated " + Fmt.ago($0, now: now) }].compactMap { $0 }).joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
            }
            Spacer(minLength: 8)
            Button { store.refreshUsage() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold)) }
                .buttonStyle(PanelButtonStyle())
                .help("Refresh all usage (⇧⌘R)")
                .accessibilityLabel("Refresh all usage")
            Menu {
                Button("Settings…") { close(); SettingsWindow.show() }
                Button("Open \(Product.name)…") { close(); ReportWindow.show(store: store) }
                Button("Refresh all usage") { store.refreshUsage() }
                Divider()
                Toggle("Show desktop strip", isOn: Binding(get: { DesktopStrip.shown }, set: { DesktopStrip.shown = $0 }))
                if store.hasHidden { Button("Show hidden accounts") { store.unhideAll() } }
                Divider()
                Button("Quit \(Product.name)") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape").font(.system(size: 13, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .buttonStyle(PanelButtonStyle())
            .padding(.horizontal, 6).frame(height: 26)
            .background(Capsule().fill(Theme.platter))
            .help("Settings")
            .accessibilityLabel("Settings menu")
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
    }
}

extension Fmt {
    /// "just now", "2 min ago", "3 h ago".
    static func ago(_ d: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(d))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86_400 { return "\(Int(s / 3600)) h ago" }
        return "\(Int(s / 86_400)) d ago"
    }
}

/// The hovered (or active) account in full: every limit with its reset, extra usage, prepaid credit and this
/// week's Claude Code tokens; Codex and Cursor details when one of those tiles is focused. Replaces the hover panel.
struct FocusCard: View {
    @ObservedObject var store: AccountStore
    let id: String
    /// On the desktop strip the card is the same lighter glass as the tiles, so it blends into the bar.
    var glass = false

    /// Every account is laid out and only the focused one shown, so the card always has the height of the
    /// tallest and the panel never resizes on hover. Shorter accounts sit at the top.
    var body: some View {
        let known = store.accounts.contains { "claude:\($0.slug)" == id } || store.others.contains { $0.id == id }
        let shown = known ? id : "claude:\(store.current.slug)"
        Group {
            if glass {
                // Desktop strip: only the focused account, so the card fits its content (the window resizes anyway).
                if let a = store.accounts.first(where: { "claude:\($0.slug)" == shown }) {
                    AccountDetails(store: store, account: a)
                } else if let o = store.others.first(where: { $0.id == shown }) {
                    OtherDetails(store: store, account: o)
                }
            } else {
                ZStack(alignment: .topLeading) {
                    ForEach(store.accounts) { a in
                        layer(AccountDetails(store: store, account: a), on: "claude:\(a.slug)" == shown)
                    }
                    ForEach(store.others) { o in
                        layer(OtherDetails(store: store, account: o), on: o.id == shown)
                    }
                }
            }
        }
        .padding(.horizontal, glass ? 14 : 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            if glass {
                // Sits in the strip's own glass (WidgetGlass), so it reads as the same surface.
                shape.fill(LinearGradient(colors: [Color.white.opacity(0.10), .clear], startPoint: .top, endPoint: .center))
            } else {
                shape.fill(Theme.platter)
            }
        }
    }
}

private extension FocusCard {
    func layer<V: View>(_ v: V, on: Bool) -> some View {
        v.frame(maxWidth: .infinity, alignment: .topLeading)
            .opacity(on ? 1 : 0)
            .allowsHitTesting(on)
            .accessibilityHidden(!on)
    }
}

/// Codex or Cursor in the focus card: limits with resets and reading age, plan, sign-in, and why usage is missing.
struct OtherDetails: View {
    @ObservedObject var store: AccountStore
    let account: OtherAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                StatusDot(running: store.otherRunning.contains(account.id))
                AppIcon(url: account.app.appURL)
                Text(account.isMain ? account.app.title : "\(account.app.title) · \(account.name)").font(Theme.cardTitle)
                if account.isMain, let login = store.mainLogins[account.app] {
                    Text(login.signedIn ? (login.email ?? "signed in") : "not signed in")
                        .font(Theme.caption).foregroundStyle(login.signedIn ? .secondary : Theme.warn)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if store.pick?.id == account.id {
                    Text("Use next").font(Theme.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.ok.opacity(0.18)))
                }
            }
            if account.app == .cursor {
                if let u = store.cursorUsage[account.id] {
                    DetailRow(label: "Month", percent: u.percent, value: "\(Int(u.percent.rounded()))%" + (u.limit.map { " · " + Fmt.money(u.used.rounded(), "USD") + " of " + Fmt.money($0.rounded(), "USD") } ?? ""),
                              note: u.cycleEnd.map { "resets " + Fmt.when($0) } ?? "")
                    if let l = u.limit { line("Left this month: " + Fmt.money(max(0, l - u.used).rounded(), "USD")) }
                    if u.onDemand || u.onDemandUsed > 0 {
                        line("On-demand (pay as you go) " + (u.onDemand ? "on" : "off") + (u.onDemandUsed > 0 ? " · " + Fmt.money(u.onDemandUsed, "USD") + " this cycle" : ""),
                             color: u.onDemand ? Theme.warn : .secondary)
                    }
                    if let p = u.plan { line("Plan: " + p.replacingOccurrences(of: "_", with: " ").capitalized) }
                } else {
                    line(store.otherProblem[account.id].map { "No usage: \($0)" } ?? "Loading usage…")
                }
            } else if let u = store.codexUsage[account.id] {
                if u.hasShortWindow { DetailRow(label: "5-hour", percent: u.shortResetPassed ? nil : u.shortPercent,
                          value: u.shortResetPassed ? "–" : (u.shortPercent.map { "\(Int($0.rounded()))%" } ?? "–"),
                          note: u.shortResetPassed ? "reset; not measured since" : Fmt.reset(u.shortResets)) }
                DetailRow(label: "Weekly", percent: u.weeklyResetPassed ? nil : u.weeklyPercent,
                          value: u.weeklyResetPassed ? "–" : (u.weeklyPercent.map { "\(Int($0.rounded()))%" } ?? "–"),
                          note: u.weeklyResetPassed ? "reset; not measured since" : Fmt.reset(u.weeklyResets))
                if let at = u.measuredAt { line("Limits " + Fmt.measured(at) + (u.stale ? " (Codex logs them only while it runs)" : ""), color: u.stale ? Theme.warn : .secondary) }
                if u.tokensWeek > 0 { line("This week: \(Fmt.tokens(u.tokensWeek)) tokens · \(u.sessionsWeek) session\(u.sessionsWeek == 1 ? "" : "s")") }
                if let p = u.plan { line("Plan: " + p.capitalized) }
            } else {
                line(store.otherProblem[account.id].map { "No usage: \($0)" } ?? (store.codexChecked ? "No Codex sessions yet" : "Checking…"))
            }
        }
    }

    private func line(_ s: String, color: Color = .secondary) -> some View {
        Text(s).font(Theme.caption).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }
}

/// Use next, Frees up next, and Spend this month against the one ceiling.
struct StatsRow: View {
    @ObservedObject var store: AccountStore
    @ObservedObject var budget = Budget.shared
    var close: () -> Void

    var body: some View {
        let all = store.targets
        let next = store.pick
        let frees = all.flatMap { t in
            [("5h", t.short, t.shortResets), (t.id.hasPrefix("cursor:") ? "month" : "7d", t.weekly, t.weeklyResets)].compactMap { l, p, r -> (String, Date)? in
                guard let p, p >= 50, let r, r > Date() else { return nil }
                return ("\(t.name) \(l)", r)
            }
        }.min { $0.1 < $1.1 }
        let st = Budget.shared.standing(store: store)
        HStack(alignment: .top, spacing: 8) {
            stat("Use next") {
                if let n = next {
                    Button { store.open(n); close() } label: {
                        Text("\(n.name) · \(Int(n.room))% left").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("Switch to \(n.name)")
                } else {
                    Text(all.isEmpty ? "Waiting for usage…" : "Everything is at its limit")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(all.isEmpty ? Color.secondary : Theme.alert).lineLimit(1)
                }
            }
            stat("Frees up next") {
                Text(frees.map { "\($0.0) · \(Fmt.when($0.1))" } ?? "Nothing near a limit")
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            stat("Spend this month") {
                VStack(alignment: .leading, spacing: 5) {
                    Text(Fmt.money(st.spent.rounded(), "USD") + " of " + Fmt.money(st.ceiling, "USD"))
                        .font(.system(size: 13, weight: Theme.valueWeight(st.ceiling > 0 ? st.spent / st.ceiling * 100 : nil)).monospacedDigit())
                        .foregroundStyle(st.left < 0 ? Theme.alert : .primary).lineLimit(1)
                    let p = st.ceiling > 0 ? min(st.spent / st.ceiling, 1) : 0
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.13))
                            Capsule().fill(meterColor(p * 100)).frame(width: max(p > 0 ? 3 : 0, g.size.width * p))
                        }
                    }
                    .frame(height: 4)
                }
            }
        }
    }

    private func stat<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 62, maxHeight: 62, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.platter))
        .accessibilityElement(children: .combine)
    }
}

/// Add account (Claude, Codex, Cursor) and Open AI Budgeting ⌘R.
struct PanelFooter: View {
    @ObservedObject var store: AccountStore
    var close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button { close(); store.addAccount() } label: {
                    Label { Text("Claude account…") } icon: { Image(nsImage: NSWorkspace.shared.icon(forFile: Paths.claudeApp.path)) }
                }
                ForEach(OtherApp.allCases.filter(\.installed)) { app in
                    Divider()
                    if let login = store.mainLogins[app], login.signedIn {
                        Label { Text("\(app.title) connected" + (login.email.map { " · \($0)" } ?? "")) } icon: {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.appURL.path))
                        }
                    }
                    Button { close(); store.addOther(app) } label: {
                        Label { Text(store.mainLogins[app]?.signedIn == true ? "A different \(app.title) account…" : "\(app.title) account…") } icon: {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.appURL.path))
                        }
                    }
                }
            } label: {
                Label("Add account", systemImage: "plus").font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 10).frame(height: 26)
            .background(Capsule().fill(Theme.platter))
            .help("Sign in to another Claude, Codex or Cursor account (⌘N)")
            Spacer()
            Button { close(); ReportWindow.show(store: store) } label: {
                HStack(spacing: 6) {
                    Text("Open \(Product.name)").font(.system(size: 12, weight: .semibold))
                    Text("⌘R").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(PanelButtonStyle(prominent: true))
            .help("Now, Money, Projects and Ideas")
        }
    }
}

// MARK: - Window

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    var onHoverChange: (Bool) -> Void = { _ in }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private lazy var hoverArea = NSTrackingArea(
        rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(hoverArea) { addTrackingArea(hoverArea) }
    }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); onHoverChange(true) }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); onHoverChange(false) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// The menu bar shown while a Burn Rate window is open (and the shortcuts behind it at all times).
    private func installMenus() {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(); main.addItem(item)
            let m = NSMenu(title: title); item.submenu = m
            return m
        }
        func add(_ m: NSMenu, _ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let i = m.addItem(withTitle: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
        }
        let app = submenu(Product.name)
        add(app, "About \(Product.name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "")
        app.addItem(.separator())
        add(app, "Settings…", #selector(openSettings), ",", target: self)
        app.addItem(.separator())
        add(app, "Hide \(Product.name)", #selector(NSApplication.hide(_:)), "h")
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        app.addItem(.separator())
        add(app, "Quit \(Product.name)", #selector(NSApplication.terminate(_:)), "q")

        let file = submenu("File")
        add(file, "Usage Report", #selector(openReport), "r", target: self)
        add(file, "Ideas", #selector(openIdeas), "i", [.command, .shift], target: self)
        add(file, "Manager Brief", #selector(openManager), "m", [.command, .shift], target: self)
        file.addItem(.separator())
        add(file, "Refresh Usage", #selector(refreshAll), "r", [.command, .shift], target: self)
        file.addItem(.separator())
        add(file, "Close Window", #selector(closeWindow), "w", target: self)

        let edit = submenu("Edit")
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")

        let view = submenu("View")
        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let appearance = NSMenu(title: "Appearance")
        for a in AppAppearance.allCases {
            let i = appearance.addItem(withTitle: a.title, action: #selector(setAppearance(_:)), keyEquivalent: "")
            i.representedObject = a.rawValue
            i.target = self
        }
        appearanceItem.submenu = appearance
        view.addItem(appearanceItem)
        view.addItem(.separator())
        add(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        let window = submenu("Window")
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, "Zoom", #selector(NSWindow.performZoom(_:)), "")
        window.addItem(.separator())
        add(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), "")
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }

    @objc private func openReport() { ReportWindow.show(store: store) }
    @objc private func openIdeas() { ReportNav.open("ideas", store: store) }
    @objc private func openManager() { ReportNav.open("ideas", store: store) }
    @objc private func openSettings() { SettingsWindow.show() }
    @objc private func refreshAll() { store.refreshUsage() }
    /// ⌘W closes the window in front, but never the widget itself.
    @objc private func closeWindow() {
        if let w = NSApp.keyWindow, !(w is FloatingPanel) { w.performClose(nil) }
    }
    @objc private func setAppearance(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let a = AppAppearance(rawValue: raw) { AppAppearance.current = a }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(setAppearance(_:)) {
            item.state = (item.representedObject as? String) == AppAppearance.current.rawValue ? .on : .off
        }
        if item.action == #selector(closeWindow) { return NSApp.keyWindow.map { !($0 is FloatingPanel) } ?? false }
        return true
    }

    private var panel: FloatingPanel!
    private var store: AccountStore!
    private var menuBar: MenuBarController!
    private var bag: Set<AnyCancellable> = []
    private var movingProgrammatically = false
    private var hoverWork: DispatchWorkItem?
    private let focus = PanelModel()
    private var card: FloatingPanel!
    private var stripIn = false, cardIn = false
    private let cardPlace = CardPlacement()
    /// While the row and column morph, the window holds both sizes so nothing is clipped; it shrinks to fit after.
    private var morphUntil = Date.distantPast
    private var morphSize = NSSize.zero
    private var lastVertical = DesktopStrip.vertical


    /// The pointer is over the strip or the card: open right away-ish, close after a short pause so crossing the gap doesn't flicker.
    private func hoverChanged() {
        hoverWork?.cancel()
        let inside = stripIn || cardIn
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.store.hovering != inside else { return }
            self.store.hovering = inside
            self.card.ignoresMouseEvents = !inside
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.25 : 0.35), execute: work)
    }

    // Morphing drag (see MorphStripView).
    private let morph = MorphModel()
    private var morphWindow: FloatingPanel?
    private var morphMonitor: Any?
    /// True from a grip press until the strip is back in place: no re-layout of the hidden strip meanwhile.
    private var morphing = false
    /// One coalesced re-layout per burst of store changes (each forced layout re-renders the whole strip).
    private var layoutPending = false
    private var dockCheckBusy = false
    private var lastDockSignature = ""
    private var grip = NSPoint.zero, grabOffset = NSPoint.zero
    private var t0: CGFloat = 0, d0: CGFloat = 0

    /// Toward a side (+) or toward the top/bottom (−), in points, for the grip at `p`.
    private func sidePull(_ p: NSPoint) -> CGFloat {
        guard let sf = (NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main)?.frame else { return 0 }
        return min(p.y - sf.minY, sf.maxY - p.y) - min(p.x - sf.minX, sf.maxX - p.x)
    }

    /// `strip.morphdemo:<dx>,<dy>`: a scripted 1.2 s drag from the grip by (dx, dy), for screenshot checks (the shell can't drag).
    private func morphDemo(dx: CGFloat, dy: CGFloat) {
        let f = panel.frame
        let start = DesktopStrip.vertical ? NSPoint(x: f.midX, y: f.maxY - 9.5)
            : NSPoint(x: store.growsRight ? f.minX + StripLayout.shared.sidePadding + 4.5 : f.maxX - StripLayout.shared.sidePadding - 4.5, y: f.midY)
        _ = beginMorph(at: start, mouse: start, monitor: false)
        for k in 1...24 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(k)) { [weak self] in
                let u = CGFloat(k) / 24
                self?.dragMorph(to: NSPoint(x: start.x + dx * u, y: start.y + dy * u))
                if k == 24 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.endMorph() } }
            }
        }
    }

    private func beginMorph(at handle: NSPoint, mouse given: NSPoint? = nil, monitor: Bool = true) -> Bool {
        if morphMonitor != nil { return false }
        morphing = true
        let mouse = given ?? NSEvent.mouseLocation
        grip = handle
        grabOffset = NSPoint(x: mouse.x - handle.x, y: mouse.y - handle.y)
        morph.right = store.growsRight
        morph.t = DesktopStrip.vertical ? 1 : 0
        t0 = morph.t
        d0 = sidePull(handle)
        hoverWork?.cancel(); stripIn = false; cardIn = false
        if store.hovering { store.hovering = false }
        if morphWindow == nil {
            let w = FloatingPanel(contentRect: NSRect(origin: .zero, size: MorphStripView.canvas), styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = NSHostingView(rootView: MorphStripView(store: store, model: morph))
            w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false; w.ignoresMouseEvents = true
            w.level = .floating; w.hidesOnDeactivate = false; w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            morphWindow = w
        }
        placeMorph()
        morphWindow?.alphaValue = 1
        morphWindow?.orderFrontRegardless()
        panel.alphaValue = 0
        guard monitor else { return true }
        morphMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] e in
            guard let self else { return e }
            if e.type == .leftMouseUp { self.endMorph() } else { self.dragMorph() }
            return nil
        }
        return true
    }

    private func placeMorph() {
        let c = MorphStripView.canvas
        morphWindow?.setFrameOrigin(NSPoint(x: (grip.x - c.width / 2).rounded(), y: (grip.y - c.height / 2).rounded()))
    }

    private func dragMorph(to point: NSPoint? = nil) {
        // A lost mouse-up (pointer released over another app) must never leave the strip stuck mid-drag.
        if point == nil, NSEvent.pressedMouseButtons & 1 == 0 { endMorph(); return }
        let m = point ?? NSEvent.mouseLocation
        grip = NSPoint(x: m.x - grabOffset.x, y: m.y - grabOffset.y)
        placeMorph()
        let sf = (NSScreen.screens.first { $0.frame.contains(grip) } ?? NSScreen.main)?.frame
        let right = grip.x < (sf?.midX ?? 0)
        // 140 pt of travel toward a side (or toward the top/bottom) turns the row fully into a column (or back).
        let target = DesktopStrip.orientation == .auto ? min(max(t0 + (sidePull(grip) - d0) / 140, 0), 1)
            : (DesktopStrip.orientation == .vertical ? 1 : 0)
        if abs(target - morph.t) > 0.004 || right != morph.right {
            withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.72, blendDuration: 0.2)) {
                morph.t = target
                morph.right = right
            }
        }
    }

    private func endMorph() {
        if let m = morphMonitor { NSEvent.removeMonitor(m); morphMonitor = nil }
        let vertical = morph.t > 0.5
        withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { morph.t = vertical ? 1 : 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { [weak self] in self?.finishMorph(vertical: vertical) }
    }

    /// Back to the normal strip, placed so its grip sits exactly where the morph's grip is.
    private func finishMorph(vertical: Bool) {
        guard let host = panel.contentView else { return }
        let right = morph.right
        RootView.animateSwap = false
        if store.growsRight != right { store.growsRight = right }
        UserDefaults.standard.set(vertical, forKey: DesktopStrip.verticalKey)
        lastVertical = vertical
        // Let SwiftUI pick up the new shape before measuring it.
        DispatchQueue.main.async { DispatchQueue.main.async { [weak self] in self?.placeAfterMorph(host: host, vertical: vertical, right: right) } }
    }

    private func placeAfterMorph(host: NSView, vertical: Bool, right: Bool) {
        host.layoutSubtreeIfNeeded()
        let size = host.intrinsicContentSize
        let off: NSPoint = vertical
            ? NSPoint(x: right ? 5 + RootView.columnGripInset + 15 : size.width - 5 - RootView.columnGripInset - 15, y: size.height - 5 - 4.5)
            : NSPoint(x: right ? StripLayout.shared.sidePadding + 4.5 : size.width - StripLayout.shared.sidePadding - 4.5, y: size.height / 2)
        let origin = NSPoint(x: grip.x - off.x, y: grip.y - off.y)
        UserDefaults.standard.set(right ? "left" : "right", forKey: "anchorEdge")
        UserDefaults.standard.set(right ? origin.x : origin.x + size.width, forKey: "anchorX")
        UserDefaults.standard.set(origin.y, forKey: "anchorY")
        morphing = false
        layoutPanel()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
            morphWindow?.animator().alphaValue = 0
        } completionHandler: { [weak self] in self?.morphWindow?.orderOut(nil); RootView.animateSwap = true }
    }

    /// Keeps the card window above the row (or beside the column), on the side the strip grows toward.
    private func positionCard() {
        guard let panel, let card else { return }
        let f = panel.frame, s = CardRoot.size, g = CardRoot.gap
        let sf = (panel.screen ?? NSScreen.main)?.frame ?? .zero
        let right = store.growsRight
        var o: NSPoint
        // The card needs about this much room; the canvas itself is taller than any card.
        let need: CGFloat = 300
        if DesktopStrip.vertical {
            let side = f.maxX + g + 330 <= sf.maxX ? (right || f.minX - g - 330 < sf.minX) : false
            if cardPlace.right != side { cardPlace.right = side }
            o = NSPoint(x: side ? f.maxX + g : f.minX - g - s.width, y: f.minY)
        } else {
            let below = f.maxY + g + need > sf.maxY && f.minY - g - need >= sf.minY
            if cardPlace.below != below { cardPlace.below = below }
            o = NSPoint(x: right ? f.minX : f.maxX - s.width, y: below ? f.minY - g - s.height : f.maxY + g)
        }
        if sf != .zero {
            o.x = min(max(o.x, sf.minX), sf.maxX - s.width)
            o.y = min(o.y, sf.maxY - s.height)
        }
        let frame = NSRect(origin: o, size: s)
        if card.frame != frame { card.setFrame(frame, display: false) }
    }

    /// Opening the app again (Spotlight, Finder, Launchpad) shows the Report, which works even when
    /// macOS has tucked the menu-bar icon into its overflow.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ReportNav.open("now", store: store)
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard FileManager.default.fileExists(atPath: Paths.claudeApp.path) else {
            showAlert("Claude isn't installed", "Install the Claude desktop app in /Applications first: claude.ai/download")
            NSApp.terminate(nil)
            return
        }
        // Only one widget at a time: if another copy is already running, bow out.
        let me = NSRunningApplication.current
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != me && !$0.isTerminated }) {
            NSApp.terminate(nil)
            return
        }
        store = AccountStore()
        SettingsWindow.store = store
        // First run only: open Setup. Someone updating (usage history already on disk) is already set up.
        if UserDefaults.standard.object(forKey: "setup.seen") == nil {
            UserDefaults.standard.set(true, forKey: "setup.seen")
            if !FileManager.default.fileExists(atPath: History.dir.appendingPathComponent("history.jsonl").path) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { SettingsWindow.show(setup: true) }
            }
        }
        AppAppearance.current.apply()
        installMenus()

        // Scriptable: `bin/plans` (or any local tool) can open the Plans tab or one account's vendor page.
        // Object "plans", a Report tab ("now", "money", "projects", "ideas"), "panel" / "panel:<tile id>" /
        // "panel.close" (the menu-bar panel), or "<account id>:<action>"
        // e.g. "claude:main:billing". Opening a page is all it does.
        OrchEngine.shared.startInbox()   // phone requests (Orchestrator.swift)
        GlobalHotKey.register()
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("local.ai-orchestrator.open"), object: nil, queue: .main) { [weak self] note in
            guard let self, let what = note.object as? String else { return }
            if what == "plans" { ReportNav.open("money", store: self.store); return }
            if what == "panel" { self.menuBar.open(); return }
            if what == "requests" { OrchestratorWindow.show(view: "board"); return }
            if what == "close" { OneWindow.close(); return }
            if what.hasPrefix("thread:") { OrchestratorWindow.show(thread: String(what.dropFirst(7))); return }
            // "merge:<run id>" / "discard:<run id>": the window's Merge and Discard buttons, for `orch` and tests.
            if what.hasPrefix("merge:") || what.hasPrefix("discard:") {
                let merge = what.hasPrefix("merge:")
                let rid = String(what.drop(while: { $0 != ":" }).dropFirst()).uppercased()
                Task { @MainActor in
                    let e = OrchEngine.shared
                    guard rid.count >= 6, let run = e.runs.first(where: { $0.id.uuidString.hasPrefix(rid) }) else { return }
                    if merge { await e.merge(run) } else { await e.discard(run) }
                }
                return
            }
            if what.hasPrefix("send:") { Task { @MainActor in OrchestratorWindow.sendFromTerminal(String(what.dropFirst(5))) }; return }
            // From `orch`: "board", or "requests:<folder>" to open on that project.
            if what == "board" { OrchestratorWindow.show(view: "board"); return }
            if what.hasPrefix("requests:") { OrchestratorWindow.show(view: "board", folder: String(what.dropFirst(9))); return }
            if what == "panel.close" { self.menuBar.close(); return }
            // "strip.peek" / "strip.peek:<tile id>": open the strip's focus card for 4 s (screenshot checks; the shell can't hover).
            // "strip.layout:auto|horizontal|vertical": same as Settings › Strip layout.
            if what.hasPrefix("strip.morphdemo:") {
                let v = what.dropFirst(16).split(separator: ",").compactMap { Double($0) }
                if v.count == 2 { self.morphDemo(dx: v[0], dy: v[1]) }
                return
            }
            if what.hasPrefix("strip.layout:"), let o = DesktopStrip.Orientation(rawValue: String(what.dropFirst(13))) {
                DesktopStrip.orientation = o; return
            }
            if what.hasPrefix("strip.peek") {
                if what.count > 11 { self.focus.setFocus(String(what.dropFirst(11))) }
                self.stripIn = true; self.hoverChanged()
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.stripIn = false; self.hoverChanged() }
                return
            }
            if what.hasPrefix("panel:") { self.menuBar.open(focus: String(what.dropFirst(6))); return }
            if ReportNav.tabs.contains(what) { ReportNav.open(what, store: self.store); return }
            let parts = what.split(separator: ":").map(String.init)
            guard parts.count == 3, let action = PlanAction(rawValue: parts[2]),
                  let card = PlanStore.shared.cards(self.store).first(where: { $0.id == "\(parts[0]):\(parts[1])" }) else { return }
            PlanStore.shared.perform(action, card, store: self.store)
        }

        // Start at login by default (once); the right-click menu can turn it off again. Never in demo mode.
        if !Demo.on, !UserDefaults.standard.bool(forKey: "loginItemDefaulted") {
            UserDefaults.standard.set(true, forKey: "loginItemDefaulted")
            if SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
        }

        let host = FirstMouseHostingView(rootView: RootView(store: store, focus: focus))
        host.onHoverChange = { [weak self] inside in self?.stripIn = inside; self?.hoverChanged() }
        // Report the SwiftUI content size without letting AppKit resize the panel itself;
        // layoutPanel() sizes it so it grows up/left from the saved bottom-right anchor.
        host.sizingOptions = [.intrinsicContentSize]

        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 46),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        panel.contentView = host
        panel.delegate = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = !Look.glassActive
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let cardHost = NSHostingView(rootView: CardRoot(store: store, focus: focus, place: cardPlace) { [weak self] inside in
            self?.cardIn = inside; self?.hoverChanged()
        })
        card = FloatingPanel(contentRect: NSRect(origin: .zero, size: CardRoot.size), styleMask: [.borderless], backing: .buffered, defer: false)
        card.contentView = cardHost
        card.isOpaque = false
        card.backgroundColor = .clear
        card.hasShadow = false
        card.ignoresMouseEvents = true
        card.level = .floating
        card.hidesOnDeactivate = false
        card.isReleasedWhenClosed = false
        card.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.addChildWindow(card, ordered: .above)
        DragHandle.onBegin = { [weak self] p in self?.beginMorph(at: p) ?? false }

        layoutPanel()
        if DesktopStrip.shown { panel.orderFrontRegardless() }
        menuBar = MenuBarController(store: store)
        // Settings or the icon menu turn the desktop strip on and off; there's only ever one.
        var stripShown = DesktopStrip.shown
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, DesktopStrip.shown != stripShown else { return }
            stripShown = DesktopStrip.shown
            if stripShown { self.layoutPanel(); self.panel.orderFrontRegardless() } else { self.panel.orderOut(nil) }
        }
        // Glass has no window shadow; Solid and the accessibility fallbacks keep theirs.
        let syncShadow: (Notification) -> Void = { [weak self] _ in
            guard let self, self.panel.hasShadow == Look.glassActive else { return }
            self.panel.hasShadow = !Look.glassActive
            self.panel.invalidateShadow()
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main, using: syncShadow)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main, using: syncShadow)

        store.objectWillChange
            .sink { [weak self] _ in self?.scheduleLayout() }
            .store(in: &bag)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.layoutPanel()
        }
        NotificationCenter.default.addObserver(forName: StripLayout.didResize, object: nil, queue: .main) { [weak self] _ in
            self?.layoutPanel()
        }
        // The Dock grows and shrinks as apps open and close: re-check so the strip narrows and scrolls instead of overlapping.
        // Reading the Dock (Accessibility IPC) happens off the main thread; the strip is re-laid out only when something changed.
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.checkDock() }
        // Belt and braces for anything the checks above miss.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.scheduleLayout() }
        // A plain mouse wheel scrolls the tile row sideways (trackpads and shift-scroll already do).
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard e.window === self?.panel, let cg = e.cgEvent?.copy() else { return e }
            if DesktopStrip.vertical {
                // Column: a sideways swipe scrolls it too, so any direction works.
                guard abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) else { return e }
                for (y, x) in [(CGEventField.scrollWheelEventDeltaAxis1, CGEventField.scrollWheelEventDeltaAxis2),
                               (.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2),
                               (.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2)] {
                    cg.setIntegerValueField(y, value: cg.getIntegerValueField(x))
                    cg.setIntegerValueField(x, value: 0)
                }
                return NSEvent(cgEvent: cg) ?? e
            }
            guard !e.hasPreciseScrollingDeltas, e.scrollingDeltaX == 0 else { return e }
            cg.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: cg.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
            return NSEvent(cgEvent: cg) ?? e
        }
    }

    /// The widget grows upward and leftward from its bottom-right corner.
    /// The widget is pinned by its bottom-left or bottom-right corner, whichever side of the
    /// screen you parked it on, and grows up and away from that corner.
    private func anchor(width: CGFloat) -> (point: NSPoint, left: Bool) {
        let d = UserDefaults.standard
        guard d.object(forKey: "anchorX") != nil else {
            let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            return (NSPoint(x: vf.maxX - 16, y: vf.minY + 16), false)
        }
        var x = d.double(forKey: "anchorX")
        let y = d.double(forKey: "anchorY")
        guard let edge = d.string(forKey: "anchorEdge") else {
            // Older builds saved the right edge only; convert once.
            let screen = NSScreen.screens.first { $0.frame.minX <= x && x <= $0.frame.maxX } ?? NSScreen.main
            let left = x < (screen?.frame.midX ?? 0)
            if left { x -= width }
            d.set(left ? "left" : "right", forKey: "anchorEdge")
            d.set(x, forKey: "anchorX")
            return (NSPoint(x: x, y: y), left)
        }
        return (NSPoint(x: x, y: y), edge == "left")
    }

    private func scheduleLayout() {
        guard !layoutPending else { return }
        layoutPending = true
        // objectWillChange fires before the change lands: wait a beat, then lay out once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.layoutPending = false
            self.layoutPanel()
        }
    }

    /// Every 3 s: has the Dock (or the strip's shape) changed? Only then re-lay out the strip.
    private func checkDock() {
        guard !dockCheckBusy, !morphing, panel?.isVisible == true, NSEvent.pressedMouseButtons == 0 else { return }
        dockCheckBusy = true
        let screens = NSScreen.screens.map { ($0.frame, $0.visibleFrame) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let dock = DockBar.current(screens: screens)
            DispatchQueue.main.async {
                guard let self else { return }
                self.dockCheckBusy = false
                StripLayout.shared.cache(dock)
                let d = UserDefaults.standard
                let sig = [dock.map { NSStringFromRect($0.frame) } ?? "none",
                           "\(DesktopStrip.vertical)", "\(d.double(forKey: StripLayout.widthKey))",
                           NSScreen.screens.map { NSStringFromRect($0.frame) }.joined(separator: ";")].joined(separator: "|")
                if sig != self.lastDockSignature {
                    self.lastDockSignature = sig
                    self.layoutPanel()
                }
            }
        }
    }

    private func layoutPanel() {
        // While the grip is held the strip is hidden behind the morph window; it's laid out once on release.
        guard !morphing, let panel, let host = panel.contentView else { return }
        // Width and height follow the Dock first, so the size measured below is the one to use.
        let (a0, left0) = anchor(width: panel.frame.width)
        let dockBottom = StripLayout.shared.update(tiles: store.accounts.count + store.others.count, anchor: a0, left: left0)
        host.layoutSubtreeIfNeeded()
        var size = host.intrinsicContentSize
        guard size.width > 0, size.height > 0 else { return }
        if DesktopStrip.vertical != lastVertical {
            lastVertical = DesktopStrip.vertical
            morphSize = panel.frame.size
            morphUntil = Date().addingTimeInterval(0.6)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in self?.layoutPanel() }
        }
        if Date() < morphUntil { size = NSSize(width: max(size.width, morphSize.width), height: max(size.height, morphSize.height)) }
        let (a, left) = anchor(width: size.width)
        if store.growsRight != left { store.growsRight = left }
        // Parked beside the Dock: top and bottom line up with its bar. The saved anchor itself doesn't change.
        let outer = StripLayout.shared.parkedX ?? a.x
        var frame = NSRect(x: left ? outer : outer - size.width, y: dockBottom ?? a.y, width: size.width, height: size.height)
        let screen = NSScreen.screens.first { $0.frame.contains(a) } ?? NSScreen.main
        // Clamp to the whole screen, not visibleFrame: the user may park it beside the Dock,
        // and it must stay exactly there instead of jumping above the Dock on every redraw.
        if let sf = screen?.frame {
            frame.origin.x = min(max(frame.origin.x, sf.minX), sf.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, sf.minY), sf.maxY - frame.height)
        }
        defer { positionCard() }
        guard frame != panel.frame else { return }
        movingProgrammatically = true
        panel.setFrame(frame, display: true)
        movingProgrammatically = false
        panel.invalidateShadow()
    }

    func windowDidMove(_ notification: Notification) {
        guard !movingProgrammatically else { return }
        let screen = panel.screen ?? NSScreen.main
        let left = panel.frame.midX < (screen?.frame.midX ?? 0)
        UserDefaults.standard.set(left ? "left" : "right", forKey: "anchorEdge")
        UserDefaults.standard.set(left ? panel.frame.minX : panel.frame.maxX, forKey: "anchorX")
        UserDefaults.standard.set(panel.frame.minY, forKey: "anchorY")
        if store.growsRight != left { store.growsRight = left }
        positionCard()
    }
}

@main
struct BurnRateApp {
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}
