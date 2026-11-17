import SwiftUI
import Charts
import WidgetKit

@main
struct AIOrchestratorPhoneApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = FeedModel()
    @StateObject private var inbox = InboxStore()
    @StateObject private var orch = OrchModel.shared
    @Environment(\.scenePhase) private var phase
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model).environmentObject(inbox).environmentObject(orch)
                .tint(.primary)
                .preferredColorScheme(Appearance(rawValue: appearance)?.scheme)
                .onChange(of: phase) { _, p in
                    if p == .active { Task { await model.refresh(); await orch.refresh() } }
                    if p == .background { Notifier.schedule() }
                }
        }
        .backgroundTask(.appRefresh(Notifier.refreshTask)) { await Notifier.runInBackground() }
    }
}

@MainActor
final class FeedModel: ObservableObject {
    @Published var feed: Feed? = Shared.loadCache()
    @Published var error: String?
    @Published var loading = false
    @Published var searching = false
    @Published var host = Shared.host
    @Published var code = Shared.code
    private let finder = MacFinder()

    var paired: Bool { !Shared.host.isEmpty && !Shared.code.isEmpty }

    func refresh() async {
        guard paired, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            feed = try await FeedClient.fetch()
            error = nil
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Can't reach your Mac. Is it awake and on the same Wi-Fi?"
            if !(error is FeedError) { rediscover() }
        }
    }

    /// The Mac's address can change; look it up again after a failed fetch.
    private func rediscover() {
        finder.find { [weak self] h in
            guard let self, let h, h != Shared.host else { return }
            Shared.host = h; self.host = h
            Task { await self.refresh() }
        }
    }

    @Published var waitingForMac = false

    /// Finds the Mac, then (if there's no code yet) asks it to approve this phone once.
    func search() {
        searching = true
        error = nil
        finder.find { [weak self] h in
            guard let self else { return }
            self.searching = false
            if let h {
                self.host = h
                if Shared.code.isEmpty { Task { await self.pair() } }
            } else {
                self.error = "Didn't find your Mac. Check that it's awake and on the same Wi-Fi, or type its name."
            }
        }
    }

    /// One-time approval: the Mac shows "Allow / Don't Allow"; on Allow it hands over the code, saved for good.
    func pair() async {
        guard !host.isEmpty, !waitingForMac else { return }
        waitingForMac = true
        defer { waitingForMac = false }
        do {
            code = try await FeedClient.pair(host: host.trimmingCharacters(in: .whitespaces))
            await save()
        } catch {
            self.error = "Your Mac didn't allow this iPhone. Tap Ask my Mac to try again, or enter the code."
        }
    }

    func save() async {
        Shared.host = host.trimmingCharacters(in: .whitespaces)
        Shared.code = code
        code = Shared.code
        await refresh()
    }
}

struct RootView: View {
    @EnvironmentObject var model: FeedModel
    @EnvironmentObject var orch: OrchModel
    /// Opens on the Inbox; `-startTab money` (screen checks) or a notification can pick another.
    @State private var tab = UserDefaults.standard.string(forKey: "startTab") ?? "inbox"
    var body: some View {
        Group {
            if let feed = model.feed {
                TabView(selection: $tab) {
                    OrchInboxView().tabItem { Label("Inbox", systemImage: "tray.full") }.tag("inbox")
                        .badge(orch.board.filter { $0.group == "needsYou" }.count)
                    OrchProjectsView(feed: feed).tabItem { Label("Projects", systemImage: "folder") }.tag("projects")
                    NavigationStack { FeedView(feed: feed).navigationTitle("Usage").appChrome().refreshable { await model.refresh() } }
                        .tabItem { Label("Usage", systemImage: "gauge.with.dots.needle.33percent") }.tag("usage")
                    NavigationStack { MoneyView(feed: feed).navigationTitle("Money").appChrome().refreshable { await model.refresh() } }
                        .tabItem { Label("Money", systemImage: "dollarsign.circle") }.tag("money")
                    NavigationStack { InboxView().navigationTitle("Notes").appChrome() }
                        .tabItem { Label("Notes", systemImage: "square.and.pencil") }.tag("notes")
                }
                .toolbarBackground(.ultraThinMaterial, for: .tabBar)
            } else {
                NavigationStack { SetupView(first: true).navigationTitle("Connect to your Mac") }
            }
        }
        .onOpenURL { url in
            // aiorchestrator://inbox (widgets) or aiorchestrator://thread/<id>
            tab = "inbox"
            if url.host == "thread", let id = url.pathComponents.dropFirst().first { orch.open(id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openThread)) { n in
            tab = "inbox"
            if let id = n.object as? String { orch.open(id) }
        }
        .task {
            if let id = UserDefaults.standard.string(forKey: "openThread"), !id.isEmpty { orch.open(id) }   // screen checks
            if model.feed != nil && ProcessInfo.processInfo.environment["ORCH_FIXTURE"] == nil { Notifier.requestAuthorization() }
            // The board every 5 s while the Inbox or a thread is on screen, else every 60 s; usage every 60 s.
            var last = Date.distantPast, lastBoard = Date.distantPast
            while !Task.isCancelled {
                let fast = tab == "inbox" || orch.threadsOpen > 0
                if Date().timeIntervalSince(lastBoard) >= (fast ? 5 : 60) { await orch.refresh(); lastBoard = Date() }
                if Date().timeIntervalSince(last) >= 60 { await model.refresh(); last = Date() }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

// MARK: - Pairing

struct SetupView: View {
    @EnvironmentObject var model: FeedModel
    @Environment(\.dismiss) private var dismiss
    var first: Bool
    @State private var remote = Shared.remoteHost
    var body: some View {
        Form {
            Section {
                if model.waitingForMac {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Click **Allow** on your Mac. You only do this once.")
                    }
                } else if model.searching {
                    HStack(spacing: 10) { ProgressView(); Text("Looking for your Mac on this Wi-Fi…") }
                } else {
                    Text("This connects to AI Orchestrator on your Mac over the same Wi-Fi: its Inbox, projects and usage. No sign-ins on the phone.")
                        .font(.callout)
                    if !model.host.isEmpty {
                        Button("Ask my Mac") { Task { await model.pair() } }
                    }
                }
            }
            Section("Mac") {
                HStack {
                    TextField("Mac address or name.local", text: $model.host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    if model.searching { ProgressView() }
                    else { Button("Find") { model.search() } }
                }
                TextField("Pairing code (optional)", text: $model.code)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
            }
            Section {
                Button(model.loading ? "Connecting…" : "Connect") {
                    Task { await model.save(); if model.error == nil && !first { dismiss() } }
                }
                .disabled(model.host.isEmpty || model.code.count < 6 || model.loading)
            }
            if let e = model.error {
                Section { Text(e).foregroundStyle(Theme.alert).font(.callout) }
            }
            if !first {
                Section {
                    TextField("Mac's Tailscale name, e.g. my-mac", text: $remote)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .onSubmit { Shared.remoteHost = remote }
                } header: { Text("Away from home") } footer: {
                    Text("Install Tailscale on this iPhone and your Mac and sign in to both with the same account. The phone then reaches the Mac over cellular through that private link; nothing is opened to the internet. The Wi-Fi address is tried first.")
                }
                Section { NavigationLink("Claude API key and model") { ClaudeKeyView() } }
                  footer: { Text("Lets Claude file what you jot in Notes.") }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: remote) { _, v in Shared.remoteHost = v }
        .navigationTitle(first ? "Connect to your Mac" : "Mac connection")
        .toolbar { if !first { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } } }
        .onAppear {
            if model.host.isEmpty { model.search() }
            else if Shared.code.isEmpty { Task { await model.pair() } }
        }
    }
}

// MARK: - Usage

struct FeedView: View {
    @EnvironmentObject var model: FeedModel
    var feed: Feed
    var body: some View {
        GlassList {
            if feed.clock() != nil {
                Section { ClockCard(feed: feed).glassHero() }
            }
            Section {
                HStack {
                    Image(systemName: model.error == nil ? "checkmark.circle" : "wifi.exclamationmark")
                        .foregroundStyle(model.error == nil ? Theme.ok : Theme.warn)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Measured \(Fmt.ago(feed.updated))").font(.subheadline)
                        if let e = model.error {
                            Text(e).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if model.loading { ProgressView() }
                }
                if let p = feed.pickAccount {
                    HStack {
                        Label("Use next", systemImage: "arrow.right.circle.fill").foregroundStyle(Theme.ok)
                        Spacer()
                        Text("\(p.title) · \(Int(p.room))% left").bold()
                    }
                } else {
                    Label("Every account is at its limit", systemImage: "hourglass").foregroundStyle(Theme.warn)
                }
            }

            UsageDaysLink(days: feed.usageDays ?? [])

            Section("Right now") {
                ForEach(feed.accounts) { AccountRow(account: $0).listRowBackground(AccountTint(account: $0)) }
            }

            if !feed.claudeCode.isEmpty {
                Section {
                    ForEach(feed.claudeCode) { c in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(c.name).bold()
                                Spacer()
                                Text("\(Fmt.tokens(c.weekTokens)) tokens").monospacedDigit()
                            }
                            HStack {
                                Text("Today \(Fmt.tokens(c.todayTokens)) · \(c.weekSessions) sessions")
                                Spacer()
                                Text("\(Fmt.money(c.weekValue)) at API prices")
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    TokenChart(days: feed.tokensByDay).frame(height: 120).padding(.vertical, 4)
                } header: { Text("Claude Code, last 7 days") }
                  footer: { Text("Chart: all Claude Code tokens per day, last 14 days.") }
            }

            Section {
                NavigationLink { FootprintView(feed: feed).navigationTitle("Footprint") } label: {
                    Label(feed.footprint == nil ? "Footprint" : "Energy, water and CO₂ of your AI use", systemImage: "leaf")
                }
            } header: { Text("Footprint") }
        }
    }
}

struct AccountRow: View {
    var account: Feed.Account
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: account.symbol).foregroundStyle(account.tint)
                Text(account.title).bold()
                AccountBadge(account: account)
                Spacer()
                if let e = account.email { Text(e).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            if let s = account.shortPercent {
                LimitLine(label: "5h", percent: s)
                if let r = Fmt.resets(account.shortResets) { resetText("5h", account.shortResets, r) }
            }
            LimitLine(label: account.longLabel, percent: account.weeklyPercent)
            if let r = Fmt.resets(account.weeklyResets) { resetText(account.longLabel, account.weeklyResets, r) }
            ForEach(otherLimits, id: \.0) { LimitLine(label: $0.0, percent: $0.1, compact: true) }
            ForEach(account.weeklyShares ?? [], id: \.name) { s in
                Text("\(s.name): \(Int(s.used.rounded()))% of weekly used, \(Int(s.allowed.rounded()))% allowed")
                    .font(.caption2).foregroundStyle(.secondary).padding(.leading, 50)
            }
            ForEach(Array((account.spendCaps ?? []).enumerated()), id: \.offset) { _, c in
                if let p = c.percent { LimitLine(label: "Cap", percent: p, compact: true) }
                HStack {
                    Text("Spend cap").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Fmt.money(c.used, account.currency)) of \(Fmt.money(c.limit, account.currency))")
                        .font(.caption.monospacedDigit())
                }
                if let r = Fmt.resets(c.resets) { resetText("Cap", c.resets, r) }
            }
            if let used = account.extraUsed, let cap = account.extraLimit {
                HStack {
                    Text(account.extraNote.map { "Extra usage · \($0)" } ?? "Extra usage").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Fmt.money(used, account.currency)) of \(Fmt.money(cap, account.currency))")
                        .font(.caption.monospacedDigit()).foregroundStyle(account.paysExtra ? Theme.alert : .primary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Limits beyond 5-hour and Weekly (e.g. "Weekly · Fable"), as the Mac reports them.
    private var otherLimits: [(String, Double)] {
        (account.limits ?? [:]).filter { $0.key != "5-hour" && $0.key != "Weekly" }
            .sorted { $0.key < $1.key }
            .map { ($0.key.replacingOccurrences(of: "Weekly · ", with: ""), $0.value) }
    }

    private func resetText(_ label: String, _ date: Date?, _ at: String) -> some View {
        HStack(spacing: 4) {
            Text("\(label) resets in")
            if let date { LiveCountdown(date: date) }
            Text("· \(at)")
        }
        .font(.caption2).foregroundStyle(.secondary).padding(.leading, 50)
    }
}

/// The live clock at the top of Usage: how long until the tightest limit resets, and how much of it is left.
struct ClockCard: View {
    @EnvironmentObject var model: FeedModel
    var feed: Feed
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { t in
            if let c = feed.clock(at: t.date) {
                HStack(spacing: 16) {
                    ring(c)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.blocked ? "\(c.title) is back in" : "\(c.title) \(c.window) resets in")
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        Text(Fmt.clock(c.ends.timeIntervalSince(t.date)))
                            .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText(countsDown: true))
                            .lineLimit(1).minimumScaleFactor(0.6)
                        if let r = c.rise {
                            Text(r.points == 0 ? "No change in the last \(r.minutes) min" : "Up \(Int(r.points))% in the last \(r.minutes) min")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .animation(.smooth, value: Int(c.ends.timeIntervalSince(t.date)))
                .task(id: c.ends) {
                    // Ask the Mac again as soon as this window ends, so the card moves on to real numbers.
                    try? await Task.sleep(for: .seconds(max(1, c.ends.timeIntervalSinceNow + 5)))
                    if !Task.isCancelled { await model.refresh() }
                }
            }
        }
    }

    private func ring(_ c: LimitClock) -> some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 6)
            Circle().trim(from: 0, to: min(max(c.left, 0), 100) / 100)
                .stroke(usageColor(100 - c.left), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(c.left))%").font(.caption.bold().monospacedDigit())
        }
        .frame(width: 58, height: 58)
        .accessibilityLabel("\(Int(c.left)) percent left")
    }
}

struct TokenChart: View {
    var days: [Feed.DayTokens]
    var body: some View {
        Chart(days) { d in
            if let date = d.date {
                BarMark(x: .value("Day", date, unit: .day), y: .value("Tokens", d.tokens))
                    .foregroundStyle(Theme.neutral)
            }
        }
        .chartYAxis { AxisMarks { v in AxisValueLabel { if let n = v.as(Int.self) { Text(Fmt.tokens(n)) } } } }
        .chartXAxis { AxisMarks(values: .stride(by: .day, count: 3)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
    }
}
