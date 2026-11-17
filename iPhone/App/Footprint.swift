import SwiftUI

/// Cost and estimated environmental footprint. Tokens and dollars are measured; every energy, carbon and
/// water figure is an estimate and is shown with its low–high range.
struct FootprintView: View {
    @EnvironmentObject var model: FeedModel
    var feed: Feed
    @AppStorage("footprintRange") private var rangeKey = FootprintRange.month.rawValue
    @State private var customFrom = Calendar.current.date(byAdding: .day, value: -29, to: Date())!
    @State private var customTo = Date()
    private var range: FootprintRange { FootprintRange(rawValue: rangeKey) ?? .month }

    var body: some View {
        GlassList {
            if let fp = feed.footprint {
                rangePicker
                let b = range.bounds(customFrom: customFrom, customTo: customTo)
                if let r = fp.period(from: b.0, to: b.1) {
                    rangeSpending(r.extra, r.ledger, fp: fp, from: b.0)
                    periodSection(range.title, r.claude, codex: r.codex)
                    coverage(fp, from: b.0)
                } else {
                    if let paid = fp.paid { paidSection(paid) }
                    periodSection("Today", fp.today, codex: fp.codex?.today)
                    periodSection("This month", fp.month, codex: fp.codex?.month)
                }
                comparison(fp)
                if let accts = fp.byAccount, !accts.isEmpty {
                    Section("By account, this month") {
                        ForEach(accts) { a in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack { Text(a.name).bold(); Spacer(); Text("\(Fmt.tokens(a.tokens)) tokens").monospacedDigit() }
                                Text("≈ \(kwh(a.kWh.mid)) · \(kg(a.kgCO2e.mid)) CO₂e · \(liters(a.waterL.mid)) water")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Text("What the words mean: **kWh** is the unit on your power bill. **CO₂e** is the climate effect of all greenhouse gases, counted as if it were CO₂. **Water** is what data centers and power plants use, mostly for cooling.")
                    Text("Comparisons use the middle estimate: phone charge 0.019 kWh (EPA); US home 865 kWh a month (EIA 2024); gas car 400 g CO₂ a mile (EPA); shower 65 L (EPA WaterSense); typical chatbot question 0.24 Wh (Google, 2025).")
                    Text("Energy, carbon and water are estimates. \"≈\" is the middle value; the range runs from low to high. The main figures cover \(fp.scope ?? "Claude Code"); Codex is shown separately as a rougher estimate, and Cursor isn't included because it doesn't report tokens. Tokens and dollars are measured.")
                    if let s = fp.sources { Text(s) }
                } header: { Text("About these numbers") }
                .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Your Mac's feed doesn't include footprint figures yet. Update AI Orchestrator's phone feed on the Mac.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func phrase(_ title: String) -> String {
        switch title {
        case "Today": return "today"
        case "This month": return "this month"
        case "All time": return "across all saved history"
        case "Custom": return "in this range"
        default: return "over the " + title.lowercased()
        }
    }

    private var rangePicker: some View {
        Section {
            Picker("Range", selection: $rangeKey) {
                ForEach(FootprintRange.allCases) { Text($0.title).tag($0.rawValue) }
            }
            if range == .custom {
                DatePicker("From", selection: $customFrom, in: ...Date(), displayedComponents: .date)
                DatePicker("To", selection: $customTo, in: ...Date(), displayedComponents: .date)
            }
        }
    }

    private func rangeSpending(_ extra: Double, _ ledger: Double, fp: Feed.Footprint, from: String?) -> some View {
        Section {
            row(range.title, Fmt.money(extra + ledger),
                "Claude extra used \(Fmt.money(extra)) · ledger \(Fmt.money(ledger))")
        } header: { Text("Spending") }
          footer: {
              Text("Measured. Claude extra is the usage Claude reports at face value, not what your card was charged (credit packs can cost less)\(fp.extraSince.map { from == nil || from! < $0 ? ". Snapshots start \($0); what was used earlier that month is counted on the 1st" : "" } ?? ""). Ledger is what you logged as paid. Plans aren't included until they're entered on the Mac.")
          }
    }

    @ViewBuilder private func coverage(_ fp: Feed.Footprint, from: String?) -> some View {
        if let since = fp.tokensSince, from == nil || from! < since {
            Section {
                Label("Token history is saved from \(since), so this range only counts from then.", systemImage: "calendar.badge.clock")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func paidSection(_ p: Feed.Footprint.Paid) -> some View {
        Section {
            row("Today", Fmt.money(p.todayLedger + p.todayClaudeExtra),
                "Claude extra used \(Fmt.money(p.todayClaudeExtra)) · ledger \(Fmt.money(p.todayLedger))")
            row("This month", Fmt.money(p.monthLedger + p.monthClaudeExtra),
                "Claude extra used \(Fmt.money(p.monthClaudeExtra)) · ledger \(Fmt.money(p.monthLedger))")
        } header: { Text("Spending") }
          footer: { Text("Measured. Claude extra is the usage Claude reports at face value, not what your card was charged (credit packs can cost less). Ledger is what you logged as paid. Plans aren't included until they're entered on the Mac.") }
    }

    private func periodSection(_ title: String, _ p: Feed.Footprint.Period, codex: Feed.Footprint.Period?) -> some View {
        Section {
            Text(Plain.summary(p, period: Self.phrase(title)))
                .font(.callout).padding(.vertical, 2)
            measuredRow("Tokens", Fmt.tokens(p.tokens),
                        "Small chunks of text the AI reads and writes, about ¾ of a word each. That's roughly \(Plain.words(p.tokens)) words.")
            if let c = p.cacheReadShare {
                measuredRow("Re-read from memory", "\(Int((c * 100).rounded()))%",
                            "Share of tokens the AI re-read from a cache instead of processing fresh. These are about 10× cheaper in energy, so a high number is good.")
            }
            if let s = p.sessions, s > 0, let per = p.tokensPerSession {
                measuredRow("Sessions", "\(s)", "About \(Fmt.tokens(per)) tokens each, because long sessions re-read their whole history every turn.")
            }
            estimateRow("Electricity", p.kWh, kwh, Plain.energy(p.kWh.mid))
            estimateRow("Carbon", p.kgCO2e, { kg($0) + " CO₂e" }, Plain.carbon(p.kgCO2e.mid))
            estimateRow("Water", p.waterL, liters, Plain.water(p.waterL.mid))
            if let c = codex, c.tokens > 0 {
                estimateRow("Codex electricity", c.kWh, kwh,
                            "\(Fmt.tokens(c.tokens)) Codex tokens. Codex doesn't say which tokens were fresh or re-read, so this one is rougher. \(Plain.energy(c.kWh.mid))")
            }
        } header: { Text(title) }
    }

    private func measuredRow(_ label: String, _ value: String, _ plain: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(label); Spacer(); Text(value).monospacedDigit() }
            Text(plain).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func comparison(_ fp: Feed.Footprint) -> some View {
        Section("Trend vs. last month") {
            if let last = fp.lastMonthSameDays, last.tokens > 0 {
                let change = Double(fp.month.tokens - last.tokens) / Double(last.tokens)
                HStack {
                    Text("Tokens, same days")
                    Spacer()
                    Text("\(change >= 0 ? "+" : "")\(Int((change * 100).rounded()))%").monospacedDigit()
                }
                estimateRow("Electricity last month", last.kWh, kwh, Plain.energy(last.kWh.mid))
            } else {
                Text("Not enough history yet\(fp.historySince.map { " (saved since \($0))" } ?? "").")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ label: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(label); Spacer(); Text(value).bold().monospacedDigit() }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func estimateRow(_ label: String, _ r: Feed.Footprint.Range, _ f: (Double) -> String, _ plain: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                Text("estimate").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
                Spacer()
                Text("≈ \(f(r.mid))").monospacedDigit()
            }
            Text(plain).font(.caption)
            Text("Could be \(f(r.low)) to \(f(r.high))").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func kwh(_ v: Double) -> String { v < 1 ? "\(Int((v * 1000).rounded())) Wh" : String(format: "%.1f kWh", v) }
    private func kg(_ v: Double) -> String { v < 1 ? "\(Int((v * 1000).rounded())) g" : String(format: "%.1f kg", v) }
    private func liters(_ v: Double) -> String { String(format: v < 10 ? "%.1f L" : "%.0f L", v) }
    private func miles(_ v: Double) -> String { String(format: v < 10 ? "%.1f mi" : "%.0f mi", v) }
    private func pct(_ v: Double) -> String { v < 0.01 ? String(format: "%.1f%%", v * 100) : "\(Int((v * 100).rounded()))%" }
}

/// Everyday comparisons for footprint numbers. Same constants as the Mac widget; sources in the About section.
enum Plain {
    static let phoneChargeKWh = 0.019        // EPA greenhouse gas equivalencies
    static let homeKWhPerDay = 865.0 / 30    // EIA 2024: 865 kWh a month
    static let carGramsPerMile = 400.0       // EPA
    static let showerL = 65.0                // EPA WaterSense: 17.2 gallons
    static let bottleL = 0.5
    static let chatbotQuestionWh = 0.24      // Google, Aug 2025: median Gemini text prompt

    static func n(_ v: Double) -> String {
        if v >= 100 { return Int(v.rounded()).formatted() }
        if v >= 10 { return String(Int(v.rounded())) }
        return String(format: "%.1f", v)
    }

    static func words(_ tokens: Int) -> String { Fmt.tokens(Int(Double(tokens) * 0.75)) }

    static func homeTime(_ kwh: Double) -> String {
        let hours = kwh / homeKWhPerDay * 24
        return hours < 48 ? "\(n(hours)) hours" : "\(n(hours / 24)) days"
    }

    static func energy(_ kwh: Double) -> String {
        "Like charging a phone \(n(kwh / phoneChargeKWh)) times, or running an average US home for \(homeTime(kwh)). A typical chatbot question uses about 0.24 Wh, so this is the energy of \(n(kwh * 1000 / chatbotQuestionWh)) of them."
    }

    static func carbon(_ kg: Double) -> String {
        "About the same as driving a gas car \(n(kg * 1000 / carGramsPerMile)) miles."
    }

    static func water(_ l: Double) -> String {
        l >= showerL
            ? "About \(n(l / showerL)) showers' worth, or \(n(l / bottleL)) half-liter bottles."
            : "About \(n(l / bottleL)) half-liter water bottles."
    }

    static func summary(_ p: Feed.Footprint.Period, period: String) -> String {
        guard p.tokens > 0 else { return "No Claude Code use recorded \(period)." }
        return "In plain terms, \(period) your Claude Code work used roughly the electricity of \(n(p.kWh.mid / phoneChargeKWh)) phone charges, the carbon of a \(n(p.kgCO2e.mid * 1000 / carGramsPerMile))-mile drive, and \(n(p.waterL.mid / bottleL)) bottles of water. That's about \(n(p.kWh.mid * 1000 / chatbotQuestionWh)) typical chatbot questions."
    }
}
