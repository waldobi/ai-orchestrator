import SwiftUI
import Security
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Anthropic API key (this phone's Keychain only; sent nowhere but api.anthropic.com)

enum ClaudeKey {
    private static let service = "local.ai-orchestrator.phone", account = "anthropic"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func get() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Returns the Keychain status, so a failed save is reported instead of silently dropped.
    @discardableResult static func set(_ value: String?) -> OSStatus {
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return errSecSuccess }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil)
    }

    /// What gets copied along with a key: spaces, line breaks, quotes (straight or curly).
    static func clean(_ s: String) -> String {
        s.filter { !$0.isWhitespace && !"\"'“”‘’`".contains($0) }
    }

    /// Why a pasted value can't be an Anthropic API key, before any network call.
    static func problem(_ k: String) -> String? {
        if k.hasPrefix("sk-ant-oat") {
            return "That's a Claude sign-in token (from claude setup-token), not an API key. Claude Max and Pro plans don't include API access: an API key comes from console.anthropic.com › API keys and is billed separately from prepaid credits."
        }
        if k.hasPrefix("sk-ant-admin") { return "That's an Admin key. It can read billing but can't run Claude. Use a normal API key (sk-ant-…)." }
        // Anthropic has more than one key prefix (sk-ant-api…, sk-ant-usr…); Anthropic itself decides whether it works.
        if k.hasPrefix("sk-ant-") { return k.count < 40 ? "That key looks cut short. Copy it again from console.anthropic.com › API keys." : nil }
        if k.hasPrefix("sk-") { return "That looks like an OpenAI key. This needs an Anthropic API key (it starts with sk-ant-) from console.anthropic.com › API keys." }
        return "That isn't an Anthropic API key. Create one at console.anthropic.com › API keys; it starts with sk-ant-api."
    }
}

// MARK: - Claude: turns a note into an expense, a plan change, an idea or a budget answer

/// What Claude made of one note. Amounts and dates are only what the note said; missing ones stay empty.
struct Processed: Codable, Equatable {
    var kind: String            // expense, planChange, idea, question, note
    var title: String
    var budget: String?         // effect on the budget, from AI Orchestrator's figures only
    var answer: String?
    var missing: [String]?
    var expense: Expense?
    var planChange: PlanChange?
    var idea: IdeaFields?

    struct Expense: Codable, Equatable {
        var vendor: String
        var item: String?
        var amount: Double?
        var date: String?       // yyyy-MM-dd
        var category: String?   // AI, Tech, Other
        var recurring: Bool?
    }
    struct PlanChange: Codable, Equatable {
        var vendor: String      // claude, codex, cursor, other
        var account: String?
        var plan: String?
        var monthly: Double?
        var date: String?
    }
    struct IdeaFields: Codable, Equatable {
        var title: String
        var notes: String?
        var value: Int?
        var effort: Int?
        var size: Int?
    }

    /// Only these reach the Mac: the ledger, Plans, or the ideas backlog.
    var sendable: Bool {
        switch kind {
        case "expense": return expense?.amount != nil
        case "planChange": return planChange != nil
        case "idea": return idea != nil
        default: return false
        }
    }
}

enum Claude {
    static let models = ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"]
    static func modelName(_ m: String) -> String {
        ["claude-haiku-5-5": "Haiku 5.5", "claude-sonnet-5-5": "Sonnet 5.5", "claude-opus-5-5": "Opus 5.5"][m] ?? m
    }
    /// API list prices per million tokens (input, output), the same table AI Orchestrator uses on the Mac.
    static func cost(_ model: String, input: Int, output: Int) -> Double {
        let p: (Double, Double) = model.hasPrefix("claude-haiku-5-5") ? (0.10, 0.50) : model.hasPrefix("claude-sonnet-5-5") ? (2, 10) : (4, 20)
        return (Double(input) * p.0 + Double(output) * p.1) / 1_000_000
    }

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    private static func request(_ path: String, key: String, body: [String: Any]? = nil) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com\(path)")!, timeoutInterval: 60)
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    /// Plain words for what api.anthropic.com answered (or why it couldn't be reached).
    static func explain(status: Int, data: Data?, error: Error?) -> String {
        let obj = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        let msg = (obj?["error"] as? [String: Any])?["message"] as? String
        let detail = msg.map { " (\($0))" } ?? ""
        switch status {
        case 0: return "Couldn't reach api.anthropic.com: \(error?.localizedDescription ?? "no connection")."
        case 401: return "The key wasn't accepted: it may be mistyped, revoked or from another workspace. Create a new one at console.anthropic.com › API keys." + detail
        case 403: return "This key isn't allowed to do that. Check the key's workspace permissions in the Console." + detail
        case 400 where (msg ?? "").localizedCaseInsensitiveContains("credit"):
            return "The key works, but the Console account has no credits. Add credits at console.anthropic.com › Billing (a Claude Max plan doesn't cover the API)." + detail
        case 429: return "Rate limited or over the spend limit set in the Console. Try again in a minute." + detail
        case 500...599: return "Anthropic's API is having trouble (HTTP \(status)). Your note is saved; try again later." + detail
        default: return "api.anthropic.com answered HTTP \(status)." + detail
        }
    }

    /// The free models list: proves the key is accepted without spending tokens.
    static func check(key: String) async -> String? {
        do {
            let (data, resp) = try await URLSession.shared.data(for: request("/v1/models?limit=1", key: key))
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return status == 200 ? nil : explain(status: status, data: data, error: nil)
        } catch {
            return explain(status: 0, data: nil, error: error)
        }
    }

    static let system = """
    You file quick notes for the user's budget app, AI Orchestrator. Each note is one of:
    - expense: money already spent or charged (a receipt, a bill, a renewal that happened).
    - planChange: a subscription plan was or will be changed, upgraded, downgraded or cancelled (Claude, ChatGPT/Codex, Cursor or another vendor).
    - idea: something to build or try.
    - question: a question about the budget or spending.
    - note: anything else.
    Rules:
    - Never invent amounts, dates or prices. Use only what the note says. If the note doesn't state an amount or date, leave it out and list it in `missing`.
    - Resolve relative dates ("yesterday", "on the 13th") against today's date, given below.
    - `budget`: one or two sentences on what this does to the budget, using only the AI Orchestrator figures given (name the figure). If the figure you'd need isn't in the data, say what's missing. Don't estimate or project.
    - Category: AI = model subscriptions, credits and API; Tech = other software, hosting, hardware; Other = everything else.
    - For a planChange, set vendor to claude, codex (ChatGPT), cursor or other, and account to the matching plan's account id from the data when exactly one matches.
    - For a question, put the answer in `answer`, from the figures given only.
    Be brief and plain.
    """

    static let tool: [String: Any] = [
        "name": "file_note",
        "description": "File the note as structured data for AI Orchestrator.",
        "input_schema": [
            "type": "object",
            "properties": [
                "kind": ["type": "string", "enum": ["expense", "planChange", "idea", "question", "note"]],
                "title": ["type": "string", "description": "A short label, a few words."],
                "budget": ["type": "string"],
                "answer": ["type": "string"],
                "missing": ["type": "array", "items": ["type": "string"]],
                "expense": ["type": "object", "properties": [
                    "vendor": ["type": "string"], "item": ["type": "string"], "amount": ["type": "number"],
                    "date": ["type": "string", "description": "yyyy-MM-dd"],
                    "category": ["type": "string", "enum": ["AI", "Tech", "Other"]], "recurring": ["type": "boolean"],
                ], "required": ["vendor"]],
                "planChange": ["type": "object", "properties": [
                    "vendor": ["type": "string", "enum": ["claude", "codex", "cursor", "other"]], "account": ["type": "string"],
                    "plan": ["type": "string"], "monthly": ["type": "number"], "date": ["type": "string", "description": "yyyy-MM-dd"],
                ], "required": ["vendor"]],
                "idea": ["type": "object", "properties": [
                    "title": ["type": "string"], "notes": ["type": "string"],
                    "value": ["type": "integer", "minimum": 1, "maximum": 5], "effort": ["type": "integer", "minimum": 1, "maximum": 5],
                    "size": ["type": "integer", "minimum": 1, "maximum": 3],
                ], "required": ["title"]],
            ],
            "required": ["kind", "title", "budget"],
        ],
    ]

    /// AI Orchestrator's own figures, as the Mac last reported them. Nothing here is estimated; absent values are left out.
    static func context(_ feed: Feed?) -> String {
        guard let feed else { return "No AI Orchestrator data on this phone yet." }
        func dict(_ pairs: [(String, Any?)]) -> [String: Any] {
            var d: [String: Any] = [:]
            for (k, v) in pairs { if let v { d[k] = v } }
            return d
        }
        let day = { (d: Date?) in d.map { DateFormatter.day.string(from: $0) } }
        var c: [String: Any] = ["paymentsThisMonthByVendor": feed.paymentsThisMonth.byProvider]
        if let b = feed.commandCenter?.budget {
            c["budgetThisMonth"] = dict([("month", b.month), ("ceiling", b.ceiling), ("spent", b.spent), ("left", b.left),
                                         ("plans", b.plans), ("claudeExtraUsage", b.extra), ("ai", b.ai), ("tech", b.tech),
                                         ("api", b.api), ("day", b.day), ("daysInMonth", b.daysInMonth)])
        }
        if let plans = feed.plans {
            c["plans"] = plans.map { p in
                dict([("account", p.account), ("name", p.name), ("plan", p.plan), ("monthly", p.monthly),
                      ("priceConfirmed", p.confirmed ?? false), ("renews", day(p.renews)),
                      ("scheduledChange", p.pendingPlan.map { dict([("plan", $0), ("monthly", p.pendingMonthly), ("from", day(p.pendingDate))]) })])
            }
        }
        if let up = feed.upcomingCharges {
            c["upcomingCharges"] = up.map { dict([("title", $0.title), ("amount", $0.amount), ("date", day($0.date))]) }
        }
        let data = (try? JSONSerialization.data(withJSONObject: c, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The first {...} object in Claude's text blocks, for an answer that came as text instead of a tool call.
    private static func jsonInText(_ blocks: [[String: Any]]) -> Any? {
        let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b,
              let obj = try? JSONSerialization.jsonObject(with: Data(text[a...b].utf8)) as? [String: Any], obj["kind"] != nil else { return nil }
        return obj
    }

    static func process(_ text: String, feed: Feed?, key: String, model: String) async throws -> (Processed, Double) {
        let today = DateFormatter.day.string(from: Date())
        let body: [String: Any] = [
            // Forcing the tool (tool_choice "tool") isn't supported by every model (Opus 5.5 rejects it), so it's "auto"
            // with the system prompt asking for the tool, and a JSON answer in text is accepted too.
            "model": model, "max_tokens": 4096, "system": system + "\nAlways answer by calling file_note.",
            "tools": [tool], "tool_choice": ["type": "auto"],
            "messages": [["role": "user", "content": "Today is \(today).\n\nAI Orchestrator data:\n\(context(feed))\n\nNote:\n\(text)"]],
        ]
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: request("/v1/messages", key: key, body: body)) }
        catch { throw Failure.message(explain(status: 0, data: nil, error: error)) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.message(explain(status: status, data: data, error: nil)) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = obj["content"] as? [[String: Any]],
              let input = blocks.first(where: { $0["type"] as? String == "tool_use" })?["input"] ?? jsonInText(blocks) else {
            throw Failure.message("Claude answered without filing the note. Try again.")
        }
        let usage = obj["usage"] as? [String: Any]
        let cost = Claude.cost(model, input: usage?["input_tokens"] as? Int ?? 0, output: usage?["output_tokens"] as? Int ?? 0)
        let p = try JSONDecoder().decode(Processed.self, from: JSONSerialization.data(withJSONObject: input))
        return (p, cost)
    }
}

// MARK: - Inbox: notes saved on the phone first, processed when there's a key, sent to the Mac when paired

struct InboxItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var created = Date()
    var result: Processed?
    var model: String?
    var cost: Double?
    var error: String?
    var sentAt: Date?
    var sentTo: String?
}

@MainActor
final class InboxStore: ObservableObject {
    @Published var items: [InboxItem] = []
    @Published var working: Set<UUID> = []
    @Published var hasKey = ClaudeKey.get() != nil
    @Published var model = Shared.defaults.string(forKey: "claudeModel") ?? Claude.models[0] {
        didSet { Shared.defaults.set(model, forKey: "claudeModel") }
    }

    private static var file: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Shared.group)?.appendingPathComponent("inbox.json")
    }
    private static let enc: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()

    init() {
        if let url = Self.file, let d = try? Data(contentsOf: url) { items = (try? FeedClient.decoder.decode([InboxItem].self, from: d)) ?? [] }
    }
    private func save() {
        guard let url = Self.file, let d = try? Self.enc.encode(items) else { return }
        try? d.write(to: url, options: .atomic)
    }

    var spentOnClaudeThisMonth: Double {
        items.filter { Calendar.current.isDate($0.created, equalTo: Date(), toGranularity: .month) }.compactMap(\.cost).reduce(0, +)
    }

    func add(_ text: String, feed: Feed?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let item = InboxItem(text: t)
        items.insert(item, at: 0)
        save()
        if hasKey { Task { await process(item.id, feed: feed) } }
    }

    func delete(_ id: UUID) { items.removeAll { $0.id == id }; save() }

    func process(_ id: UUID, feed: Feed?) async {
        guard let key = ClaudeKey.get(), let i = items.firstIndex(where: { $0.id == id }), !working.contains(id) else { return }
        working.insert(id)
        defer { working.remove(id) }
        let m = model
        do {
            let (p, cost) = try await Claude.process(items[i].text, feed: feed, key: key, model: m)
            guard let j = items.firstIndex(where: { $0.id == id }) else { return }
            items[j].result = p; items[j].model = m; items[j].cost = (items[j].cost ?? 0) + cost; items[j].error = nil
        } catch {
            guard let j = items.firstIndex(where: { $0.id == id }) else { return }
            items[j].error = error.localizedDescription
        }
        save()
    }

    /// Fills in an amount the note didn't have, typed on the phone.
    func setAmount(_ id: UUID, _ amount: Double) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].result?.expense?.amount = amount
        items[i].result?.missing?.removeAll { $0.localizedCaseInsensitiveContains("amount") }
        save()
    }

    /// Hands the filed note to AI Orchestrator on the Mac (phone-feed /inbox).
    func send(_ id: UUID) async {
        guard let i = items.firstIndex(where: { $0.id == id }), let p = items[i].result, p.sendable else { return }
        working.insert(id)
        defer { working.remove(id) }
        do {
            let place = try await FeedClient.sendInbox(id: id, text: items[i].text, created: items[i].created, processed: p)
            guard let j = items.firstIndex(where: { $0.id == id }) else { return }
            items[j].sentAt = Date(); items[j].sentTo = place; items[j].error = nil
        } catch {
            guard let j = items.firstIndex(where: { $0.id == id }) else { return }
            items[j].error = (error as? LocalizedError)?.errorDescription ?? "Couldn't reach your Mac. It's saved here; send it when you're on the same Wi-Fi."
        }
        save()
    }
}

extension FeedClient {
    /// POST /inbox: the Mac adds expenses to the ledger, plan changes to Plans and ideas to the backlog.
    static func sendInbox(id: UUID, text: String, created: Date, processed: Processed) async throws -> String {
        let host = Shared.host, code = Shared.code
        guard !host.isEmpty, !code.isEmpty else { throw FeedError.notSetUp }
        let h = host.contains(":") ? "[\(host)]" : host
        guard let url = URL(string: "http://\(h):\(port)/inbox") else { throw FeedError.notSetUp }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue(code, forHTTPHeaderField: "X-Pairing-Code")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { var id: String; var text: String; var created: Date; var kind: String
            var expense: Processed.Expense?; var planChange: Processed.PlanChange?; var idea: Processed.IdeaFields? }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        req.httpBody = try enc.encode(Body(id: id.uuidString, text: text, created: created, kind: processed.kind,
                                           expense: processed.expense, planChange: processed.planChange, idea: processed.idea))
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw FeedError.wrongCode }
        if status == 404 { throw Claude.Failure.message("Your Mac's AI Orchestrator is older and can't take notes yet. Reinstall AI Orchestrator on the Mac.") }
        guard status == 200 else { throw FeedError.badResponse(status) }
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["where"] as? String ?? "Mac"
    }
}

// MARK: - Views

struct InboxView: View {
    @EnvironmentObject var model: FeedModel
    @EnvironmentObject var inbox: InboxStore
    @State private var draft = ""
    @State private var showKey = false
    @FocusState private var focused: Bool

    var body: some View {
        GlassList {
            Section {
                TextField("Spent $42 on Figma today · Cursor drops to Premium on the 13th · Idea: …", text: $draft, axis: .vertical)
                    .lineLimit(2...6).focused($focused)
                HStack {
                    Button("Save") { inbox.add(draft, feed: model.feed); draft = ""; focused = false }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    if !inbox.hasKey {
                        Button("Add API key") { showKey = true }.font(.callout)
                    }
                }
            } footer: {
                Text(inbox.hasKey
                     ? "Saved here first, then \(Claude.modelName(inbox.model)) files it as an expense, plan change, idea or budget question using AI Orchestrator's numbers. Send puts it on your Mac."
                     : "Notes are saved on this phone. Add an Anthropic API key to have Claude file them; until then they wait here.")
            }

            if inbox.items.isEmpty {
                Text("Nothing captured yet.").foregroundStyle(.secondary)
            }
            ForEach(inbox.items) { item in
                InboxRow(item: item).swipeActions {
                    Button("Delete", role: .destructive) { inbox.delete(item.id) }
                }
            }

            if inbox.spentOnClaudeThisMonth > 0 {
                Section { } footer: { Text("Claude processing this month: \(Fmt.money(inbox.spentOnClaudeThisMonth)) at API list prices, billed to your Console account.") }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { hideKeyboard() }
            }
        }
        .sheet(isPresented: $showKey) { NavigationStack { ClaudeKeyView() } }
    }
}

struct InboxRow: View {
    @EnvironmentObject var model: FeedModel
    @EnvironmentObject var inbox: InboxStore
    var item: InboxItem
    @State private var amount = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.result?.title ?? item.text).bold().lineLimit(2)
                Spacer()
                if let k = item.result?.kind { Text(label(k)).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(.quaternary)) }
            }
            if item.result != nil { Text(item.text).font(.caption).foregroundStyle(.secondary) }
            if let p = item.result { details(p) }
            if let e = item.error { Text(e).font(.caption).foregroundStyle(Theme.alert) }
            HStack(spacing: 14) {
                if inbox.working.contains(item.id) { ProgressView() }
                else {
                    if inbox.hasKey && (item.result == nil || item.error != nil && item.sentAt == nil) {
                        Button(item.result == nil ? "Process" : "Process again") { Task { await inbox.process(item.id, feed: model.feed) } }
                    }
                    if let p = item.result, p.sendable, item.sentAt == nil {
                        Button("Send to Mac") { Task { await inbox.send(item.id) } }.disabled(!model.paired)
                    }
                }
                Spacer()
                Text(meta).font(.caption2).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless).font(.callout)
        }
        .padding(.vertical, 2)
    }

    private var meta: String {
        if let s = item.sentAt, let w = item.sentTo { return "Sent to \(w) \(Fmt.ago(s))" }
        return [Fmt.ago(item.created), item.cost.map { Fmt.money($0) }].compactMap { $0 }.joined(separator: " · ")
    }

    private func label(_ k: String) -> String {
        ["expense": "Expense", "planChange": "Plan change", "idea": "Idea", "question": "Question", "note": "Note"][k] ?? k
    }

    @ViewBuilder private func details(_ p: Processed) -> some View {
        if let e = p.expense, p.kind == "expense" {
            HStack {
                Text([e.vendor, e.item, e.category, e.date, e.recurring == true ? "recurring" : nil].compactMap { $0 }.joined(separator: " · "))
                Spacer()
                if let a = e.amount { Text(Fmt.money(a)).bold().monospacedDigit() }
            }.font(.callout)
            if e.amount == nil && item.sentAt == nil {
                HStack {
                    TextField("Amount", text: $amount).keyboardType(.decimalPad).frame(maxWidth: 120)
                    Button("Set") { if let v = Double(amount.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")) { inbox.setAmount(item.id, v) } }
                        .buttonStyle(.borderless)
                }.font(.callout)
            }
        }
        if let c = p.planChange, p.kind == "planChange" {
            Text([c.vendor.capitalized, c.plan, c.monthly.map { "\(Fmt.money($0))/mo" }, c.date.map { "from \($0)" }].compactMap { $0 }.joined(separator: " · "))
                .font(.callout)
        }
        if let i = p.idea, p.kind == "idea" {
            Text(["Value \(i.value ?? 3)/5", "effort \(i.effort ?? 3)/5", i.notes].compactMap { $0 }.joined(separator: " · ")).font(.callout)
        }
        if let a = p.answer, !a.isEmpty { Text(a).font(.callout) }
        if let b = p.budget, !b.isEmpty { Text(b).font(.caption).foregroundStyle(.secondary) }
        if let m = p.missing, !m.isEmpty { Text("Not in the note: \(m.joined(separator: ", "))").font(.caption).foregroundStyle(Theme.warn) }
    }
}

struct ClaudeKeyView: View {
    @EnvironmentObject var inbox: InboxStore
    @Environment(\.dismiss) private var dismiss
    @State private var entry = ""
    @State private var checking = false
    @State private var message: String?
    @State private var ok = false

    var body: some View {
        Form {
            Section {
                if inbox.hasKey {
                    Label(ok ? "Key accepted by Anthropic" : "Key saved on this iPhone", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                    Button("Check again") { Task { await check() } }.disabled(checking)
                    Button("Remove key", role: .destructive) { ClaudeKey.set(nil); inbox.hasKey = false; ok = false; message = nil }
                } else {
                    SecureField("sk-ant-…", text: $entry).textInputAutocapitalization(.never).autocorrectionDisabled()
                    #if canImport(UIKit)
                    Button("Paste from clipboard") { entry = UIPasteboard.general.string ?? "" }
                    #endif
                    Button(checking ? "Checking…" : "Save and check") { Task { await save() } }
                        .disabled(entry.isEmpty || checking)
                }
                if let m = message { Text(m).font(.callout).foregroundStyle(ok ? Theme.ok : Theme.alert) }
            } header: { Text("Anthropic API key") }
              footer: { Text("A normal API key from console.anthropic.com › API keys. It's kept in this iPhone's Keychain and only sent to api.anthropic.com. Usage is billed to that Console account's credits, separately from a Claude Max plan.") }
            Section("Model") {
                Picker("Model", selection: $inbox.model) {
                    ForEach(Claude.models, id: \.self) { Text(Claude.modelName($0)).tag($0) }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Claude")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    private func save() async {
        let k = ClaudeKey.clean(entry)
        if let p = ClaudeKey.problem(k) { message = p; ok = false; return }
        checking = true
        defer { checking = false }
        if let e = await Claude.check(key: k) { message = e; ok = false; return }   // not saved until Anthropic accepts it
        let s = ClaudeKey.set(k)
        guard s == errSecSuccess else { message = "Anthropic accepted the key, but this iPhone's Keychain refused to save it (error \(s))."; return }
        entry = ""; inbox.hasKey = true; ok = true; message = nil
    }

    private func check() async {
        guard let k = ClaudeKey.get() else { inbox.hasKey = false; return }
        checking = true
        defer { checking = false }
        if let e = await Claude.check(key: k) { message = e; ok = false } else { message = nil; ok = true }
    }
}

/// Closes the keyboard from any field (the multi-line note and the number pad have no return key that does it).
@MainActor func hideKeyboard() {
    #if canImport(UIKit)
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    #endif
}
