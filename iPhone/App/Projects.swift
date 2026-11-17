import SwiftUI
import Charts

/// Where tokens went: by project (folder) and by session or Codex thread. Measured from Claude Code
/// transcripts and Codex's thread list, saved on the Mac.
struct ProjectsView: View {
    var feed: Feed
    @AppStorage("projectsRange") private var range = "30"

    var body: some View { GlassList { ProjectTokenSections(feed: feed) } }
}

/// Tokens by project, for the bottom of the Projects tab.
struct ProjectTokenSections: View {
    var feed: Feed
    @AppStorage("projectsRange") private var range = "30"

    var body: some View {
        Group {
            if let p = feed.projects {
                Section {
                    Picker("Range", selection: $range) {
                        Text("Last 30 days").tag("30")
                        Text("All saved").tag("all")
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                let projects = p.projects.filter { tokens($0) > 0 }.sorted { tokens($0) > tokens($1) }
                let total = max(projects.reduce(0) { $0 + tokens($1) }, 1)
                Section {
                    ForEach(projects) { pr in
                        NavigationLink {
                            ProjectDetail(project: pr, sessions: p.sessions.filter { $0.project == pr.name && $0.tool == pr.tool })
                        } label: {
                            ProjectRow(name: pr.name, tool: pr.tool, tokens: tokens(pr), share: Double(tokens(pr)) / Double(total))
                        }
                    }
                } header: { Text("Tokens by project") }
                  footer: { Text("\(Fmt.tokens(total)) tokens in total. A project is the folder the work ran in; worktrees count toward their repo.") }

                let sessions = p.sessions.filter { sessionTokens($0) > 0 }.sorted { sessionTokens($0) > sessionTokens($1) }.prefix(25)
                Section("Biggest sessions and threads") {
                    ForEach(Array(sessions)) { SessionRow(session: $0, tokens: sessionTokens($0)) }
                }
                Section {
                    Text("Saved on your Mac\(p.savedSince.map { " since \($0)" } ?? "") and kept after Claude Code deletes old transcripts. \(p.note ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Your Mac's feed doesn't include project history yet.").foregroundStyle(.secondary)
            }
        }
    }

    private func tokens(_ p: Feed.Projects.Project) -> Int { range == "30" ? p.tokens30 : p.tokensAll }
    private func sessionTokens(_ s: Feed.Projects.Session) -> Int { range == "30" ? s.tokens30 : s.tokens }
}

struct ProjectRow: View {
    var name: String
    var tool: String
    var tokens: Int
    var share: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: tool == "Codex" ? "terminal" : "sparkle")
                    .foregroundStyle(.secondary)
                Text(displayName(name)).lineLimit(1)
                Spacer()
                Text(Fmt.tokens(tokens)).monospacedDigit()
            }
            HStack(spacing: 6) {
                UsageBarPlain(fraction: share)
                Text("\(Int((share * 100).rounded()))%").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }
        }
    }
}

/// "~/Code/my-app" → "my-app", keeping the parent when it helps.
func displayName(_ path: String) -> String {
    guard path.hasPrefix("~") || path.hasPrefix("/") else { return path }
    let parts = path.split(separator: "/")
    return parts.last.map(String.init) ?? path
}

struct UsageBarPlain: View {
    var fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(Theme.neutral).frame(width: max(4, g.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 5)
    }
}

struct SessionRow: View {
    var session: Feed.Projects.Session
    var tokens: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.title ?? "Untitled session").lineLimit(2)
                Spacer()
                Text(Fmt.tokens(tokens)).monospacedDigit()
            }
            Text([session.tool, displayName(session.project), dates].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
    private var dates: String? {
        guard let f = session.first else { return nil }
        return session.last.map { $0 == f ? f : "\(f) to \($0)" } ?? f
    }
}

struct ProjectDetail: View {
    var project: Feed.Projects.Project
    var sessions: [Feed.Projects.Session]
    var body: some View {
        GlassList {
            Section {
                HStack { Text("Last 30 days"); Spacer(); Text(Fmt.tokens(project.tokens30)).monospacedDigit() }
                HStack { Text("All saved"); Spacer(); Text(Fmt.tokens(project.tokensAll)).monospacedDigit() }
                if let t = project.byType30, project.tokens30 > 0 {
                    let read = Double(t["cacheRead"] ?? 0) / Double(project.tokens30)
                    HStack { Text("Re-read from memory"); Spacer(); Text("\(Int((read * 100).rounded()))%").monospacedDigit() }
                }
                if !project.days.isEmpty {
                    TokenChart(days: project.days).frame(height: 130).padding(.vertical, 4)
                }
            } header: { Text(project.name).textCase(nil) }
            Section("Sessions") {
                ForEach(sessions.sorted { $0.tokens > $1.tokens }) { SessionRow(session: $0, tokens: $0.tokens) }
            }
        }
        .navigationTitle(displayName(project.name))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Budget

struct BudgetCard: View {
    var feed: Feed
    var body: some View {
        if let b = feed.commandCenter?.budget { CeilingBudget(b: b, compact: true) }
        else { LegacyBudget(feed: feed) }
    }
}

/// AI Orchestrator's monthly AI + tech ceiling. Only arithmetic on measured spend: no projections.
struct CeilingBudget: View {
    var b: Feed.CommandCenter.Budget
    var compact = false
    var body: some View {
        let daysLeft = max(b.daysInMonth - b.day, 0)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("AI + tech this month")
                Spacer()
                Text("\(Fmt.money(b.spent)) of \(Fmt.money(b.ceiling))").bold().monospacedDigit()
                    .foregroundStyle(b.spent > b.ceiling ? Theme.alert : .primary)
            }
            UsageBar(percent: b.ceiling > 0 ? b.spent / b.ceiling * 100 : nil, height: 8)
            Text(b.left < 0
                 ? "Over the ceiling by \(Fmt.money(-b.left)), with \(daysLeft) days left."
                 : "\(Fmt.money(b.left)) left for \(daysLeft) days\(b.maxPerDay.map { ", up to \(Fmt.money($0)) a day" } ?? "").")
                .font(.caption)
            if let d = b.perDaySoFar {
                Text("So far: \(Fmt.money(d)) a day over \(b.day) days.").font(.caption).foregroundStyle(.secondary)
            }
            if !compact {
                Divider()
                if let v = b.extra { line("Claude extra used", v) }
                if let v = b.plans { line(b.plansEntered == true ? "Plans" : "Plans (not entered yet)", v) }
                if let v = b.api { line("API", v) }
                if let v = b.ai { line("Other AI (ledger)", v) }
                if let v = b.tech { line("Tech (ledger)", v) }
                Text("Claude extra is usage at face value, not what your card was charged (credit packs can cost less). Set the ceiling in AI Orchestrator on the Mac.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    private func line(_ label: String, _ v: Double) -> some View {
        HStack { Text(label).font(.callout); Spacer(); Text(Fmt.money(v)).font(.callout.monospacedDigit()) }
    }
}

/// Older Macs without AI Orchestrator's command center: Claude extra against the extra-usage budget.
struct LegacyBudget: View {
    var feed: Feed
    var body: some View {
        let spent = feed.footprint?.paid?.monthClaudeExtra
            ?? feed.accounts.filter { $0.provider == "claude" }.compactMap(\.extraUsed).reduce(0, +)
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text("Claude extra used this month"); Spacer(); Text(Fmt.money(spent)).bold() }
            if let cap = feed.budget?.monthlyClaudeExtra {
                UsageBar(percent: spent / cap * 100, height: 8)
                Text("Budget \(Fmt.money(cap)).").font(.caption)
            }
        }
    }
}

// MARK: - Appearance

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct AppearanceMenu: View {
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue
    var body: some View {
        Menu {
            Picker("Appearance", selection: $appearance) {
                ForEach(Appearance.allCases) { Label($0.title, systemImage: $0.symbol).tag($0.rawValue) }
            }
        } label: {
            Image(systemName: (Appearance(rawValue: appearance) ?? .system).symbol)
        }
        .accessibilityLabel("Appearance")
    }
}
