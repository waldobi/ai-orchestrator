import SwiftUI
import WidgetKit

@main
struct UsageWidgets: WidgetBundle {
    var body: some Widget { InboxWidget(); UsageWidget() }
}

struct UsageEntry: TimelineEntry {
    var date: Date
    var feed: Feed?
    var reached: Bool   // false = showing the last saved copy
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { UsageEntry(date: Date(), feed: nil, reached: false) }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(UsageEntry(date: Date(), feed: Shared.loadCache(), reached: true))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        Task {
            var entry: UsageEntry
            if let f = try? await FeedClient.fetch(timeout: 6) {
                entry = UsageEntry(date: Date(), feed: f, reached: true)
            } else {
                entry = UsageEntry(date: Date(), feed: Shared.loadCache(), reached: false)
            }
            // Also wake when the clock on screen runs out, so a finished window doesn't sit at zero.
            let next = min(Date().addingTimeInterval(15 * 60), entry.feed?.clock()?.ends.addingTimeInterval(60) ?? .distantFuture)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "UsageWidget", provider: Provider()) { entry in
            UsageWidgetView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("AI Orchestrator usage")
        .description("Claude, Codex and Cursor limits from AI Orchestrator on your Mac.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) var family
    var entry: UsageEntry

    var body: some View {
        if let feed = entry.feed {
            switch family {
            case .accessoryInline: inline(feed)
            case .accessoryCircular: circular(feed)
            case .accessoryRectangular: rectangular(feed)
            case .systemSmall: small(feed)
            default: list(feed, max: family == .systemLarge ? 8 : 4)
            }
        } else {
            VStack(spacing: 4) {
                Image(systemName: "iphone.and.arrow.forward")
                Text("Open the app to connect to your Mac").font(.caption2).multilineTextAlignment(.center)
            }
        }
    }

    /// Ticks by itself under a day; a week-long clock in a widget would just be noise, so it shows the day.
    @ViewBuilder private func countdown(_ c: LimitClock) -> some View {
        if c.ends.timeIntervalSince(entry.date) < 86400 {
            Text(timerInterval: entry.date...c.ends, countsDown: true).monospacedDigit()
        } else {
            Text(c.ends, format: .dateTime.weekday(.abbreviated).hour().minute())
        }
    }

    private func clockLine(_ feed: Feed) -> some View {
        Group {
            if let c = feed.clock(at: entry.date) {
                HStack(spacing: 4) {
                    Image(systemName: "timer")
                    Text(c.blocked ? c.title : "\(c.title) \(c.window)").lineLimit(1)
                    Spacer(minLength: 2)
                    countdown(c).multilineTextAlignment(.trailing).frame(maxWidth: 76, alignment: .trailing)
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func footer(_ feed: Feed) -> some View {
        HStack(spacing: 3) {
            if !entry.reached { Image(systemName: "wifi.slash") }
            Text("Measured \(Fmt.ago(feed.updated))")
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
    }

    // Lock Screen
    private func inline(_ feed: Feed) -> some View {
        if let p = feed.pickAccount { return Text("\(p.title): \(Int(p.room))% left") }
        return Text("All AI accounts at limit")
    }

    private func circular(_ feed: Feed) -> some View {
        let p = feed.pickAccount
        return Gauge(value: p?.room ?? 0, in: 0...100) {
            Text(p.map { String($0.title.prefix(1)) } ?? "–")
        } currentValueLabel: {
            Text(p.map { "\(Int($0.room))" } ?? "0")
        }
        .gaugeStyle(.accessoryCircular)
    }

    private func rectangular(_ feed: Feed) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            clockLine(feed)
            ForEach(feed.accounts.prefix(2)) { a in
                HStack(spacing: 4) {
                    Image(systemName: a.pick ? "arrow.right.circle.fill" : a.symbol).font(.system(size: 10))
                    Text(a.title).font(.caption2).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(Fmt.percent(a.weeklyPercent)).font(.caption2.monospacedDigit())
                }
            }
        }
    }

    // Home Screen
    private func small(_ feed: Feed) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let p = feed.pickAccount {
                Text("Use next").font(.caption2).foregroundStyle(.secondary)
                Text(p.title).font(.headline).lineLimit(1)
                Text("\(Int(p.room))% left").font(.caption.bold()).foregroundStyle(Theme.ok)
            } else {
                Text("All at limit").font(.headline).foregroundStyle(Theme.warn)
            }
            Spacer(minLength: 0)
            clockLine(feed)
            ForEach(feed.accounts.prefix(2)) { a in
                HStack(spacing: 4) {
                    Image(systemName: a.symbol).font(.system(size: 9)).foregroundStyle(a.tint)
                    UsageBar(percent: a.weeklyPercent, height: 4)
                    Text(Fmt.percent(a.weeklyPercent)).font(.system(size: 10).monospacedDigit()).frame(width: 30, alignment: .trailing)
                }
            }
            footer(feed)
        }
    }

    private func list(_ feed: Feed, max: Int) -> some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 8 : 5) {
            ForEach(feed.accounts.prefix(max)) { a in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: a.symbol).font(.caption2).foregroundStyle(a.tint)
                        Text(a.title).font(.caption.bold()).lineLimit(1)
                        AccountBadge(account: a)
                        Spacer()
                        if family == .systemLarge, let used = a.extraUsed, let cap = a.extraLimit {
                            Text("Extra \(Fmt.money(used, a.currency)) / \(Fmt.money(cap, a.currency))")
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 8) {
                        if a.shortPercent != nil { LimitLine(label: "5h", percent: a.shortPercent, compact: true) }
                        LimitLine(label: a.longLabel, percent: a.weeklyPercent, compact: true)
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 12) { footer(feed).layoutPriority(1); clockLine(feed) }
        }
    }
}

// MARK: - Inbox: what needs you and what's running, from the Mac's board

struct InboxEntry: TimelineEntry {
    var date: Date
    var needsYou: Int
    var running: Int
    var waiting: Int
    var known: Bool        // false = never reached the Mac's board
    var reached: Bool
    var feed: Feed?
}

struct InboxProvider: TimelineProvider {
    private func saved(reached: Bool) -> InboxEntry {
        let c = Shared.boardCounts
        return InboxEntry(date: Date(), needsYou: c.needsYou, running: c.running, waiting: c.waiting, known: c.updated != nil,
                          reached: reached, feed: Shared.loadCache())
    }
    func placeholder(in context: Context) -> InboxEntry {
        InboxEntry(date: Date(), needsYou: 1, running: 2, waiting: 0, known: true, reached: true, feed: nil)
    }
    func getSnapshot(in context: Context, completion: @escaping (InboxEntry) -> Void) { completion(saved(reached: true)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<InboxEntry>) -> Void) {
        Task {
            let ok = (try? await OrchClient.fetch(timeout: 6)) != nil
            _ = try? await FeedClient.fetch(timeout: 6)
            completion(Timeline(entries: [saved(reached: ok)], policy: .after(Date().addingTimeInterval(15 * 60))))
        }
    }
}

struct InboxWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "InboxWidget", provider: InboxProvider()) { entry in
            InboxWidgetView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "aiorchestrator://inbox"))
        }
        .configurationDisplayName("AI Orchestrator Inbox")
        .description("What needs you and what's running on your Mac, and which account has room.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct InboxWidgetView: View {
    @Environment(\.widgetFamily) var family
    var entry: InboxEntry

    var body: some View {
        if !entry.known {
            VStack(spacing: 4) {
                Image(systemName: "tray.full")
                Text("Open the app to connect to your Mac").font(.caption2).multilineTextAlignment(.center)
            }
        } else if family == .systemMedium {
            HStack(alignment: .top, spacing: 14) {
                counts.frame(maxWidth: .infinity, alignment: .leading)
                rooms.frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            counts
        }
    }

    private var counts: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Inbox").font(.caption.bold()).foregroundStyle(.secondary)
            count(entry.needsYou, "Needs you", entry.needsYou > 0 ? Theme.warn : .secondary)
            count(entry.running, "Running", .primary)
            if entry.waiting > 0 { Text("\(entry.waiting) waiting for room").font(.caption2).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            HStack(spacing: 3) {
                if !entry.reached { Image(systemName: "wifi.slash") }
                Text(entry.reached ? "Updated \(entry.date.formatted(date: .omitted, time: .shortened))" : "Last saved")
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func count(_ n: Int, _ label: String, _ tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(n)").font(.title2.bold().monospacedDigit()).foregroundStyle(tint)
            Text(label).font(.caption)
        }
    }

    /// The account with the most room and the tightest one, tinted like the Mac's strip.
    @ViewBuilder private var rooms: some View {
        let accounts = entry.feed?.accounts ?? []
        let most = accounts.max { $0.room < $1.room }
        let tight = accounts.max { ($0.fullest ?? 0) < ($1.fullest ?? 0) }
        VStack(alignment: .leading, spacing: 6) {
            if let most {
                Text("Most room").font(.caption2).foregroundStyle(.secondary)
                room(most)
            }
            if let tight, tight.title != most?.title {
                Text("Tightest").font(.caption2).foregroundStyle(.secondary)
                room(tight)
            }
            Spacer(minLength: 0)
        }
    }

    private func room(_ a: Feed.Account) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: a.symbol).font(.system(size: 9)).foregroundStyle(a.tint)
                Text(a.title).font(.caption.bold()).lineLimit(1)
            }
            HStack(spacing: 4) {
                UsageBar(percent: a.fullest, height: 4)
                Text(Fmt.percent(a.fullest)).font(.system(size: 10).monospacedDigit()).frame(width: 30, alignment: .trailing)
            }
        }
    }
}
