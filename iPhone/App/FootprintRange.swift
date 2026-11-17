import SwiftUI

/// Date ranges for the Footprint tab. Totals are added up on the phone from the Mac's per-day figures,
/// with the Mac's factor table, so they match the widget.
enum FootprintRange: String, CaseIterable, Identifiable {
    case today, month, d30, d60, d90, d365, all, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: return "Today"
        case .month: return "This month"
        case .d30: return "Last 30 days"
        case .d60: return "Last 60 days"
        case .d90: return "Last 90 days"
        case .d365: return "Last 365 days"
        case .all: return "All time"
        case .custom: return "Custom"
        }
    }

    /// First and last day (inclusive, yyyy-MM-dd). `nil` start means everything saved.
    func bounds(customFrom: Date, customTo: Date) -> (String?, String) {
        let cal = Calendar.current, now = Date()
        let f = DateFormatter.day
        let today = f.string(from: now)
        func back(_ n: Int) -> String { f.string(from: cal.date(byAdding: .day, value: -(n - 1), to: now)!) }
        switch self {
        case .today: return (today, today)
        case .month: return (f.string(from: cal.dateInterval(of: .month, for: now)!.start), today)
        case .d30: return (back(30), today)
        case .d60: return (back(60), today)
        case .d90: return (back(90), today)
        case .d365: return (back(365), today)
        case .all: return (nil, today)
        case .custom: return (f.string(from: min(customFrom, customTo)), f.string(from: max(customFrom, customTo)))
        }
    }
}

extension Feed.Footprint {
    /// Adds up the days in a range. Claude Code: energy by token type; Codex: its rougher per-token rate.
    func period(from: String?, to: String) -> (claude: Period, codex: Period?, extra: Double, ledger: Double)? {
        guard let daily, let f = factors else { return nil }
        let days = daily.filter { (from == nil || $0.day >= from!) && $0.day <= to }
        let t = (input: days.reduce(0) { $0 + $1.input }, output: days.reduce(0) { $0 + $1.output },
                 cw: days.reduce(0) { $0 + $1.cacheWrite }, cr: days.reduce(0) { $0 + $1.cacheRead })
        let total = t.input + t.output + t.cw + t.cr
        let wh = (Double(t.input) * (f.whPerMTok["input"] ?? 0) + Double(t.output) * (f.whPerMTok["output"] ?? 0)
                  + Double(t.cw) * (f.whPerMTok["cacheWrite"] ?? 0) + Double(t.cr) * (f.whPerMTok["cacheRead"] ?? 0)) / 1e6
        let sessions = days.reduce(0) { $0 + $1.sessions }
        func range(_ kwh: Range) -> (Range, Range, Range, Range, Range) {
            (kwh,
             Range(low: kwh.low * f.gCO2ePerKWh / 1000, mid: kwh.mid * f.gCO2ePerKWh / 1000, high: kwh.high * f.gCO2ePerKWh / 1000),
             Range(low: kwh.low * f.waterLPerKWh, mid: kwh.mid * f.waterLPerKWh, high: kwh.high * f.waterLPerKWh),
             Range(low: kwh.low * f.gCO2ePerKWh / f.gCO2PerMile, mid: kwh.mid * f.gCO2ePerKWh / f.gCO2PerMile, high: kwh.high * f.gCO2ePerKWh / f.gCO2PerMile),
             Range(low: kwh.low / f.homeKWhPerMonth, mid: kwh.mid / f.homeKWhPerMonth, high: kwh.high / f.homeKWhPerMonth))
        }
        let mid = wh / 1000
        let r = range(Range(low: mid * f.low, mid: mid, high: mid * f.high))
        let claude = Period(tokens: total, sessions: sessions,
                            cacheReadShare: total > 0 ? Double(t.cr) / Double(total) : nil,
                            tokensPerSession: sessions > 0 ? total / sessions : nil,
                            kWh: r.0, kgCO2e: r.1, waterL: r.2, carMiles: r.3, homeMonthShare: r.4)
        var codex: Period?
        let ct = days.reduce(0) { $0 + $1.codexTokens }
        if ct > 0, let c = f.codexWhPerMTok {
            let k = Double(ct) / 1e9
            let cr = range(Range(low: k * c.low, mid: k * c.mid, high: k * c.high))
            codex = Period(tokens: ct, sessions: nil, cacheReadShare: nil, tokensPerSession: nil,
                           kWh: cr.0, kgCO2e: cr.1, waterL: cr.2, carMiles: cr.3, homeMonthShare: cr.4)
        }
        return (claude, codex, days.reduce(0) { $0 + $1.claudeExtra }, days.reduce(0) { $0 + $1.ledger })
    }
}
