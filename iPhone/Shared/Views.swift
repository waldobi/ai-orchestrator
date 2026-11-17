import SwiftUI

// Small pieces used by both the app and the widgets.

extension Feed.Account {
    var tint: Color {
        switch provider {
        case "claude": return .secondary
        case "codex": return .secondary
        case "cursor": return .secondary
        default: return .gray
        }
    }
    var symbol: String {
        switch provider {
        case "claude": return "sparkle"
        case "codex": return "terminal"
        case "cursor": return "cursorarrow.rays"
        default: return "circle"
        }
    }
}

/// Same palette as AI Orchestrator on the Mac: neutral until it matters, no orange.
enum Theme {
    /// Warnings: a muted gold rather than orange.
    static let warn = Color(red: 0.90, green: 0.78, blue: 0.48)
    /// Over a limit or budget: a softened red.
    static let alert = Color(red: 0.94, green: 0.42, blue: 0.42)
    /// Under 70% used: the Mac's meter green (meter.ok).
    static let ok = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0x5F/255, green: 0xC4/255, blue: 0x7C/255, alpha: 1)
        : UIColor(red: 0x2F/255, green: 0x9A/255, blue: 0x50/255, alpha: 1) })
    /// Neutral fill for charts and share bars.
    static let neutral = Color.primary.opacity(0.6)
}

func usageColor(_ percent: Double?) -> Color {
    guard let p = percent else { return .secondary }
    if p >= 90 { return Theme.alert }
    if p >= 70 { return Theme.warn }
    return Theme.ok
}

extension Feed.Account {
    /// The fuller of its limits, which is what the Mac tints a tile by.
    var fullest: Double? { [shortPercent, weeklyPercent].compactMap { $0 }.max() }
}

/// An account row's glass, tinted by how much is used; the instance in use gets a stronger tint and an edge.
struct AccountTint: View {
    var account: Feed.Account
    var body: some View {
        let inUse = account.inUse == true
        ZStack(alignment: .leading) {
            Rectangle().fill(.ultraThinMaterial)
            if let p = account.fullest {
                Rectangle().fill(usageColor(p).opacity(inUse ? 0.24 : 0.10))
                if inUse { Rectangle().fill(usageColor(p)).frame(width: 3) }
            }
        }
    }
}

struct UsageBar: View {
    var percent: Double?
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if let p = percent, p > 0 {
                    Capsule().fill(usageColor(p))
                        .frame(width: max(height, g.size.width * min(max(p, 0), 100) / 100))
                }
            }
        }
        .frame(height: height)
    }
}

/// One labelled bar: "5h  ▓▓▓░░  16%".
struct LimitLine: View {
    var label: String
    var percent: Double?
    var compact = false
    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(compact ? .caption2 : .caption).foregroundStyle(.secondary)
                .frame(width: compact ? 34 : 44, alignment: .leading)
            UsageBar(percent: percent, height: compact ? 5 : 6)
            Text(Fmt.percent(percent)).font((compact ? Font.caption2 : .caption).monospacedDigit())
                .frame(width: compact ? 30 : 36, alignment: .trailing)
        }
    }
}

/// A reset time that ticks. Past zero it says so until the next measurement arrives.
struct LiveCountdown: View {
    var date: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { t in
            Text(date > t.date ? Fmt.clock(date.timeIntervalSince(t.date)) : "reset").monospacedDigit()
        }
    }
}

struct AccountBadge: View {
    var account: Feed.Account
    var body: some View {
        HStack(spacing: 4) {
            if account.inUse == true {
                Text("In use").font(.caption2.bold()).foregroundStyle(.secondary)
            }
            if account.pick {
                Label("Next", systemImage: "arrow.right.circle.fill").font(.caption2.bold()).foregroundStyle(Theme.ok)
            }
            if account.paysExtra {
                Label("Paying", systemImage: "dollarsign.circle.fill").font(.caption2.bold()).foregroundStyle(Theme.alert)
            } else if account.blocked {
                Text("At limit").font(.caption2.bold()).foregroundStyle(Theme.warn)
            }
        }
        .labelStyle(.titleOnly)
    }
}
