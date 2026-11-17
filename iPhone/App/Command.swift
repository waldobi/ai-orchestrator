import SwiftUI

/// Money: spend against the monthly ceiling, plans, the charges coming up, payments this month, the manager's brief
/// and ranked ideas. Costs only; income never reaches the phone.
struct MoneyView: View {
    var feed: Feed
    var body: some View {
        GlassList {
            Section(feed.commandCenter?.budget?.month.map { "Spend vs the ceiling · \($0)" } ?? "Spend vs the ceiling") {
                if let b = feed.commandCenter?.budget { CeilingBudget(b: b) } else { LegacyBudget(feed: feed) }
            }
            plansSection
            upcomingSection
            paymentsSection
            if let cc = feed.commandCenter {
                managerSection(cc.manager)
                ideasSection(cc.ideas ?? [])
            } else {
                Text("Update AI Orchestrator on your Mac to see the manager brief and ideas here.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var plansSection: some View {
        let plans = (feed.plans ?? []).sorted { $0.monthly > $1.monthly }
        if !plans.isEmpty {
            Section {
                ForEach(Array(plans.enumerated()), id: \.offset) { _, p in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text([p.vendor, p.name].compactMap { $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: " "))
                            Spacer()
                            Text("\(Fmt.money(p.monthly))/mo").monospacedDigit()
                        }
                        let sub = [p.plan, p.account, p.renews.map { "renews \($0.formatted(date: .abbreviated, time: .omitted))" },
                                   p.confirmed == false ? "not confirmed" : nil].compactMap { $0 }
                        if !sub.isEmpty { Text(sub.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                        if let np = p.pendingPlan {
                            Text("Changes to \(np)\(p.pendingMonthly.map { " at \(Fmt.money($0))/mo" } ?? "")\(p.pendingDate.map { " on \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "")")
                                .font(.caption).foregroundStyle(Theme.warn)
                        }
                    }
                }
            } header: { Text("Plans") }
              footer: { Text("\(Fmt.money(plans.reduce(0) { $0 + $1.monthly })) a month in plans, from the Plans tab on the Mac.") }
        }
    }

    @ViewBuilder private var upcomingSection: some View {
        let up = (feed.upcomingCharges ?? []).sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        if !up.isEmpty {
            Section("Upcoming charges") {
                ForEach(Array(up.prefix(12).enumerated()), id: \.offset) { _, c in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title)
                            let sub = [c.date.map { $0.formatted(date: .abbreviated, time: .omitted) }, c.note].compactMap { $0 }
                            if !sub.isEmpty { Text(sub.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Text(c.amount.map { Fmt.money($0) } ?? "–").monospacedDigit()
                    }
                }
            }
        }
    }

    private var paymentsSection: some View {
        Section {
            if feed.paymentsThisMonth.byProvider.isEmpty {
                Text("No payments logged this month.").foregroundStyle(.secondary)
            } else {
                ForEach(feed.paymentsThisMonth.byProvider.sorted { $0.value > $1.value }, id: \.key) { k, v in
                    HStack { Text(k); Spacer(); Text(Fmt.money(v)).monospacedDigit() }
                }
                HStack { Text("Total").bold(); Spacer(); Text(Fmt.money(feed.paymentsThisMonth.total)).bold().monospacedDigit() }
            }
        } header: { Text("Payments this month") }
          footer: { Text("From the payments ledger in Connections & spend on the Mac. Claude extra usage is on the Usage tab.") }
    }

    @ViewBuilder private func managerSection(_ m: Feed.CommandCenter.Manager?) -> some View {
        Section {
            if let m, let headline = m.headline, !headline.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(headline).font(.headline)
                    if let b = m.brief, !b.isEmpty { Text(b).font(.callout) }
                    Text([m.date.map { $0.formatted(date: .abbreviated, time: .shortened) }, m.model,
                          m.cost.map { "cost \(Fmt.money($0))" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let move = m.budgetMove, !move.isEmpty { labeled("Budget move", [move]) }
                if let a = m.nextActions, !a.isEmpty { labeled("Next actions", a) }
                if let f = m.findings, !f.isEmpty {
                    ForEach(Array(f.enumerated()), id: \.offset) { _, x in
                        VStack(alignment: .leading, spacing: 3) {
                            Text([x.project.map(displayName), x.session].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            if let w = x.waste { Text(w).font(.callout) }
                            if let fix = x.fix { Text("Fix: \(fix)").font(.callout).foregroundStyle(Theme.ok) }
                        }
                    }
                }
                if let t = m.promptTips, !t.isEmpty { labeled("Prompt tips", t) }
                if let w = m.workflow, !w.isEmpty { labeled("Workflow", w) }
            } else if m?.enabled == true {
                Text("No brief yet. Run Manager brief in AI Orchestrator on the Mac.").foregroundStyle(.secondary)
            } else {
                Text("The Mac's manager is off: it needs a Claude API key in AI Orchestrator › Connections on the Mac. Notes on this phone use their own key.")
                    .foregroundStyle(.secondary)
            }
        } header: { Text("Manager") }
          footer: {
              if let c = m?.costThisMonth, c > 0 { Text("Manager runs this month: \(Fmt.money(c)) at API list prices.") }
          }
    }

    private func labeled(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(Array(items.enumerated()), id: \.offset) { _, s in
                HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•"); Text(s) }.font(.callout)
            }
        }
    }

    @ViewBuilder private func ideasSection(_ ideas: [Feed.CommandCenter.Idea]) -> some View {
        Section {
            if ideas.isEmpty {
                Text("No ideas yet. Add them in AI Orchestrator's Ideas window on the Mac.").foregroundStyle(.secondary)
            } else {
                ForEach(ideas) { i in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(i.rank ?? 0).").foregroundStyle(.secondary).monospacedDigit()
                            Text(i.title).bold()
                            Spacer()
                            if let s = i.status { Text(s.capitalized).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(.quaternary)) }
                        }
                        Text(["Value \(i.value ?? 0)/5", "effort \(i.effort ?? 0)/5", ["", "S", "M", "L"][min(max(i.size ?? 0, 0), 3)].isEmpty ? nil : "size " + ["", "S", "M", "L"][min(max(i.size ?? 0, 0), 3)],
                              i.score.map { String(format: "score %.1f", $0) }].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        if let n = i.managerNote { Text(n).font(.caption) }
                    }
                }
            }
        } header: { Text("Ideas") }
          footer: { Text("Ranked by value against effort and token size; the manager's ranking wins when it has one.") }
    }
}
