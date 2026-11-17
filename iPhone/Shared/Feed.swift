import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif
#if canImport(WidgetKit)
import WidgetKit
#endif

// MARK: - Feed model (matches bin/phone-feed, version 1). Every value is copied from the Mac widget's files.

struct Feed: Codable, Equatable {
    var version: Int
    var updated: Date?
    var served: Date?
    var pick: String?
    var accounts: [Account]
    var claudeCode: [CodeTokens]
    var tokensByDay: [DayTokens]
    /// Newest first, as AI Orchestrator wrote them; older Macs don't send this.
    var usageDays: [UsageDay]?
    var paymentsThisMonth: Payments
    var footprint: Footprint?
    var projects: Projects?
    var commandCenter: CommandCenter?
    /// Subscriptions from AI Orchestrator's Plans tab and the charges it expects next, passed through unchanged.
    var plans: [Plan]?
    var upcomingCharges: [Charge]?

    struct UsageDay: Codable, Equatable, Identifiable {
        var day: String
        var accounts: [UsageAccount]
        var id: String { day }
        var tokens: Int { accounts.map(\.tokens).reduce(0, +) }
        var value: Double { accounts.compactMap(\.value).reduce(0, +) }
        var extra: Double { accounts.compactMap(\.extra).reduce(0, +) }
    }
    struct UsageAccount: Codable, Equatable, Identifiable {
        var name: String
        var tokens: Int
        var value: Double?
        var models: [UsageModel]
        var limitUsed: Double?
        var limitPeak: Double?
        var extra: Double?
        var id: String { name }
    }
    struct UsageModel: Codable, Equatable {
        var model: String
        var tokens: Int
        var value: Double?
    }

    struct Plan: Codable, Equatable {
        var account: String?
        var vendor: String?
        var name: String
        var plan: String?
        var monthly: Double
        var confirmed: Bool?
        var renews: Date?
        var pendingPlan: String?
        var pendingMonthly: Double?
        var pendingDate: Date?
    }
    struct Charge: Codable, Equatable {
        var account: String?
        var title: String
        var amount: Double?
        var date: Date?
        var note: String?
    }

    /// AI Orchestrator's budget standing, ranked ideas and latest manager brief, passed through unchanged.
    struct CommandCenter: Codable, Equatable {
        var budget: Budget?
        var ideas: [Idea]?
        var manager: Manager?

        struct Budget: Codable, Equatable {
            var month: String?
            var ceiling: Double
            var spent: Double
            var extra: Double?
            var plans: Double?
            var plansEntered: Bool?
            var api: Double?
            var ai: Double?
            var tech: Double?
            var day: Int
            var daysInMonth: Int
            var left: Double
            var perDaySoFar: Double?
            var revenue: Double?
            var maxPerDay: Double?
        }
        struct Idea: Codable, Equatable, Identifiable {
            var id: String
            var title: String
            var status: String?
            var rank: Int?
            var score: Double?
            var value: Int?
            var effort: Int?
            var size: Int?
            var managerRank: Int?
            var managerNote: String?
            var notes: String?
        }
        struct Manager: Codable, Equatable {
            var enabled: Bool?
            var costThisMonth: Double?
            var date: Date?
            var model: String?
            var headline: String?
            var brief: String?
            var budgetMove: String?
            var nextActions: [String]?
            var promptTips: [String]?
            var workflow: [String]?
            var findings: [Finding]?
            var cost: Double?
            struct Finding: Codable, Equatable { var session: String?; var project: String?; var waste: String?; var fix: String? }
        }
    }
    var budget: Budget?

    struct Budget: Codable, Equatable {
        var monthlyClaudeExtra: Double?
        var daysInMonth: Int
        var day: Int
    }

    /// Where tokens went, saved on the Mac so it outlives Claude Code's 30-day transcript cleanup.
    struct Projects: Codable, Equatable {
        var savedSince: String?
        var projects: [Project]
        var sessions: [Session]
        var note: String?

        struct Project: Codable, Equatable, Identifiable {
            var name: String
            var tool: String
            var tokens30: Int
            var tokensAll: Int
            var byType30: [String: Int]?
            var days: [DayTokens]
            var id: String { tool + "|" + name }
        }
        struct Session: Codable, Equatable, Identifiable {
            var id: String
            var tool: String
            var project: String
            var title: String?
            var first: String?
            var last: String?
            var tokens: Int
            var tokens30: Int
            var model: String?
        }
    }

    struct Account: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var provider: String
        var email: String?
        var room: Double
        var blocked: Bool
        var paysExtra: Bool
        var pick: Bool
        var shortPercent: Double?
        var weeklyPercent: Double?
        var shortResets: Date?
        var weeklyResets: Date?
        var freesAt: Date?
        var snapshotAt: Date?
        var limits: [String: Double]?
        var extraUsed: Double?
        var extraLimit: Double?
        var currency: String?
        var extraNote: String?
        var spendCaps: [SpendCap]?
        var weeklyShares: [WeeklyShare]?
        var recentRise: Rise?
        /// The Claude instance running and last in front on the Mac (the strip outlines the same one).
        var inUse: Bool?

        /// How far a window actually moved over the last hour, measured on the Mac.
        struct Rise: Codable, Equatable { var window: String; var points: Double; var minutes: Int }
        struct SpendCap: Codable, Equatable { var used: Double; var limit: Double; var percent: Double?; var resets: Date? }
        struct WeeklyShare: Codable, Equatable { var name: String; var used: Double; var allowed: Double }

        var providerTitle: String {
            switch provider {
            case "claude": return "Claude"
            case "codex": return "Codex"
            case "cursor": return "Cursor"
            default: return provider.capitalized
            }
        }
        /// Cursor reports one monthly limit; Claude and Codex a weekly one.
        var longLabel: String { provider == "cursor" ? "Month" : "Week" }
        var title: String { provider == "claude" ? name : providerTitle == name ? name : "\(providerTitle) \(name)" }
    }

    struct CodeTokens: Codable, Equatable, Identifiable {
        var name: String
        var todayTokens: Int
        var weekTokens: Int
        var weekValue: Double
        var weekSessions: Int
        var id: String { name }
    }

    struct DayTokens: Codable, Equatable, Identifiable {
        var day: String
        var tokens: Int
        var id: String { day }
        var date: Date? { DateFormatter.day.date(from: day) }
    }

    struct Payments: Codable, Equatable {
        var month: String
        var byProvider: [String: Double]
        var total: Double
    }

    var pickAccount: Account? { accounts.first { $0.pick } }

    /// Tokens and dollars are measured; energy, carbon and water are estimates with a low/mid/high range.
    struct Footprint: Codable, Equatable {
        var scope: String?
        var historySince: String?
        var today: Period
        var month: Period
        var byAccount: [Named]?
        var lastMonthSameDays: Period?
        var paid: Paid?
        var sources: String?
        var codex: Codex?
        var daily: [Day]?
        var factors: Factors?
        var tokensSince: String?
        var extraSince: String?

        /// Measured inputs for one local day; the app adds up any date range with `factors`.
        struct Day: Codable, Equatable {
            var day: String
            var input: Int
            var output: Int
            var cacheWrite: Int
            var cacheRead: Int
            var sessions: Int
            var codexTokens: Int
            var claudeExtra: Double
            var ledger: Double
        }
        struct Factors: Codable, Equatable {
            var whPerMTok: [String: Double]
            var low: Double
            var high: Double
            var codexWhPerMTok: Range?
            var gCO2ePerKWh: Double
            var waterLPerKWh: Double
            var gCO2PerMile: Double
            var homeKWhPerMonth: Double
        }

        /// Codex reports no token types, so its estimate is rougher (Mac widget: ~53 Wh per million tokens).
        struct Codex: Codable, Equatable { var today: Period?; var month: Period? }

        struct Range: Codable, Equatable { var low: Double; var mid: Double; var high: Double }
        struct Period: Codable, Equatable {
            var tokens: Int
            var sessions: Int?
            var cacheReadShare: Double?
            var tokensPerSession: Int?
            var kWh: Range
            var kgCO2e: Range
            var waterL: Range
            var carMiles: Range?
            var homeMonthShare: Range?
        }
        struct Named: Codable, Equatable, Identifiable {
            var name: String
            var tokens: Int
            var kWh: Range
            var kgCO2e: Range
            var waterL: Range
            var id: String { name }
        }
        struct Paid: Codable, Equatable {
            var todayLedger: Double
            var monthLedger: Double
            var todayClaudeExtra: Double
            var monthClaudeExtra: Double
        }
    }
}

extension DateFormatter {
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - Countdown

/// The window that matters most right now, always a real reset time from the Mac.
struct LimitClock: Equatable {
    var title: String
    var window: String
    var ends: Date
    var left: Double
    var blocked: Bool
    var rise: Feed.Account.Rise?
}

extension Feed {
    /// A blocked account's way back comes first; otherwise the tightest window still running.
    func clock(at now: Date = Date()) -> LimitClock? {
        let back = accounts.compactMap { a -> LimitClock? in
            guard a.blocked, let d = a.freesAt ?? a.weeklyResets, d > now else { return nil }
            return LimitClock(title: a.title, window: a.longLabel, ends: d, left: 0, blocked: true, rise: nil)
        }
        if let first = back.min(by: { $0.ends < $1.ends }) { return first }
        let live = accounts.flatMap { a -> [LimitClock] in
            var out: [LimitClock] = []
            if let d = a.shortResets, d > now, let p = a.shortPercent {
                out.append(LimitClock(title: a.title, window: "5h", ends: d, left: 100 - p, blocked: false, rise: a.recentRise?.window == "5h" ? a.recentRise : nil))
            }
            if let d = a.weeklyResets, d > now, let p = a.weeklyPercent {
                out.append(LimitClock(title: a.title, window: a.longLabel, ends: d, left: 100 - p, blocked: false, rise: a.recentRise?.window == a.longLabel ? a.recentRise : nil))
            }
            return out
        }
        return live.min { ($0.left, $0.ends) < ($1.left, $1.ends) }
    }
}

// MARK: - Shared storage (App Group, so the widgets see what the app fetched)

enum Shared {
    static let group = "group.local.ai-orchestrator.phone"
    static let defaults = UserDefaults(suiteName: group) ?? .standard
    static var cacheURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("feed.json")
    }

    static var host: String {
        get { defaults.string(forKey: "host") ?? "" }
        set { defaults.set(newValue, forKey: "host") }
    }
    static var code: String {
        get { defaults.string(forKey: "code") ?? "" }
        set { defaults.set(newValue.uppercased().trimmingCharacters(in: .whitespaces), forKey: "code") }
    }
    /// When the phone last reached the Mac (not when the Mac last measured; that's Feed.updated).
    static var lastReached: Date? {
        get { defaults.object(forKey: "lastReached") as? Date }
        set { defaults.set(newValue, forKey: "lastReached") }
    }

    static func loadCache() -> Feed? {
        guard let url = cacheURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? FeedClient.decoder.decode(Feed.self, from: data)
    }
    static func saveCache(_ data: Data) {
        guard let url = cacheURL else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Client

enum FeedError: LocalizedError {
    case notSetUp, wrongCode, badResponse(Int)
    var errorDescription: String? {
        switch self {
        case .notSetUp: return "Not paired with your Mac yet."
        case .wrongCode: return "The pairing code doesn't match. Run bin/phone-feed code on the Mac."
        case .badResponse(let c): return "The Mac answered with an error (\(c))."
        }
    }
}

enum FeedClient {
    static let port = 47615
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Fetches the feed from the Mac, caches it for the widgets and returns it.
    static func fetch(timeout: TimeInterval = 8) async throws -> Feed {
        // Away from home, fall back to the Mac's private-network (Tailscale) address set on the Requests tab.
        let remote = Shared.defaults.string(forKey: "remoteHost") ?? ""
        do { return try await fetch(host: Shared.host, timeout: timeout) }
        catch is URLError where !remote.isEmpty && remote != Shared.host { return try await fetch(host: remote, timeout: timeout) }
    }

    private static func fetch(host: String, timeout: TimeInterval) async throws -> Feed {
        let code = Shared.code
        guard !host.isEmpty, !code.isEmpty else { throw FeedError.notSetUp }
        let h = host.contains(":") ? "[\(host)]" : host   // IPv6 literal
        guard let url = URL(string: "http://\(h):\(port)/feed") else { throw FeedError.notSetUp }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.setValue(code, forHTTPHeaderField: "X-Pairing-Code")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw FeedError.wrongCode }
        guard status == 200 else { throw FeedError.badResponse(status) }
        let feed = try decoder.decode(Feed.self, from: data)
        Shared.saveCache(data)
        Shared.reached(host)
        return feed
    }
}

extension FeedClient {
    /// Asks the Mac to approve this phone; waits while the Mac shows its Allow dialog.
    static func pair(host: String) async throws -> String {
        let h = host.contains(":") ? "[\(host)]" : host
        var comps = URLComponents(string: "http://\(h):\(port)/pair")
        comps?.queryItems = [URLQueryItem(name: "device", value: deviceName)]
        guard let url = comps?.url else { throw FeedError.notSetUp }
        let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 140))
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = obj["code"] as? String else { throw FeedError.wrongCode }
        return code
    }

    static var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return "An iPhone"
        #endif
    }
}

// MARK: - Finding the Mac (Bonjour _claudeswitch._tcp, advertised by bin/phone-feed)

final class MacFinder {
    private var browser: NWBrowser?
    private var connection: NWConnection?

    /// Calls back once with an IPv4 address (or host name) of the first Mac found.
    func find(_ done: @escaping (String?) -> Void) {
        stop()
        let b = NWBrowser(for: .bonjour(type: "_claudeswitch._tcp", domain: nil), using: .tcp)
        browser = b
        var finished = false
        let finish: (String?) -> Void = { [weak self] host in
            guard !finished else { return }
            finished = true
            self?.stop()
            DispatchQueue.main.async { done(host) }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, let r = results.first, self.connection == nil else { return }
            let params = NWParameters.tcp
            (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
            let c = NWConnection(to: r.endpoint, using: params)
            self.connection = c
            c.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, _)? = c.currentPath?.remoteEndpoint {
                        let text: String
                        switch host {
                        case .ipv4(let a): text = "\(a)"
                        case .ipv6(let a): text = "\(a)"
                        case .name(let n, _): text = n
                        @unknown default: text = ""
                        }
                        finish(text.components(separatedBy: "%").first)
                    } else { finish(nil) }
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            c.start(queue: .main)
        }
        b.stateUpdateHandler = { state in
            if case .failed = state { finish(nil) }
        }
        b.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { finish(nil) }
    }

    func stop() {
        browser?.cancel(); browser = nil
        connection?.cancel(); connection = nil
    }
}

// MARK: - Formatting

enum Fmt {
    static func percent(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))%" } ?? "–" }
    static func money(_ v: Double, _ currency: String? = "USD") -> String {
        v.formatted(.currency(code: currency ?? "USD").precision(.fractionLength(v >= 100 ? 0 : 2)))
    }
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        switch d {
        case 1e9...: return String(format: "%.1fB", d / 1e9)
        case 1e6...: return String(format: "%.1fM", d / 1e6)
        case 1e3...: return String(format: "%.0fK", d / 1e3)
        default: return "\(n)"
        }
    }
    static func resets(_ d: Date?) -> String? {
        guard let d else { return nil }
        if d < Date() { return "reset" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        return d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
    /// "5d 18:53:12", "1:53:12": what a running clock shows.
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let hms = String(format: "%d:%02d:%02d", s / 3600 % 24, s / 60 % 60, s % 60)
        return s >= 86400 ? "\(s / 86400)d \(hms)" : hms
    }
    static func ago(_ d: Date?) -> String {
        guard let d else { return "never" }
        let s = Date().timeIntervalSince(d)
        if s < 60 { return "just now" }
        return d.formatted(.relative(presentation: .named))
    }
}
