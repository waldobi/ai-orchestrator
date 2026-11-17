import SwiftUI

/// The Usage tab's row for today, opening the day-by-day list.
struct UsageDaysLink: View {
    var days: [Feed.UsageDay]
    var body: some View {
        if let latest = days.first {
            Section("By day") {
                NavigationLink {
                    UsageDaysList(days: days)
                } label: {
                    LabeledContent(UsageDayText.label(latest.day), value: UsageDayText.summary(latest))
                }
            }
        }
    }
}

enum UsageDayText {
    static func label(_ key: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: key) else { return key }
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
    static func summary(_ d: Feed.UsageDay) -> String {
        Fmt.tokens(d.tokens) + (d.value >= 0.005 ? " · " + Fmt.money(d.value) : "")
    }
    /// "claude-opus-5-5" → "Opus 5.5"
    static func model(_ id: String) -> String {
        var parts = id.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().prefix { Int($0) != nil }.joined(separator: ".")
        return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " " + version)
    }
}

struct UsageDaysList: View {
    var days: [Feed.UsageDay]
    var body: some View {
        GlassList {
            ForEach(days) { d in
                Section(UsageDayText.label(d.day)) {
                    NavigationLink { UsageDayDetail(day: d) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(UsageDayText.summary(d) + (d.extra >= 0.005 ? " · " + Fmt.money(d.extra) + " extra" : ""))
                                .font(.body.monospacedDigit())
                            let limits = d.accounts.compactMap { a in a.limitUsed.flatMap { $0 >= 0.5 ? "\(a.name) +\(Int($0.rounded()))" : nil } }
                            if !limits.isEmpty {
                                Text(limits.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section {
                Text("Limit use is points of each weekly limit. API value is what Claude Code's tokens would cost at list prices, not what you paid. Codex has no value here, and Cursor reports only a monthly total.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("By day")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct UsageDayDetail: View {
    var day: Feed.UsageDay
    var body: some View {
        GlassList {
            ForEach(day.accounts) { a in
                Section(a.name) {
                    LabeledContent("Tokens", value: Fmt.tokens(a.tokens))
                    if let v = a.value { LabeledContent("API value", value: Fmt.money(v)) }
                    if let n = a.limitUsed {
                        LabeledContent("Weekly limit", value: "+\(Int(n.rounded())) pts" + (a.limitPeak.map { ", peak \(Int($0))%" } ?? ""))
                    }
                    if let e = a.extra, e >= 0.005 { LabeledContent("Extra usage", value: Fmt.money(e)) }
                    ForEach(a.models, id: \.model) { m in
                        LabeledContent(UsageDayText.model(m.model), value: Fmt.tokens(m.tokens) + (m.value.map { " · " + Fmt.money($0) } ?? ""))
                            .font(.footnote)
                    }
                }
            }
        }
        .navigationTitle(UsageDayText.label(day.day))
        .navigationBarTitleDisplayMode(.inline)
    }
}
