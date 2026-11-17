import SwiftUI
import AppKit

// MARK: - One window (one-window spec, phase 2, Nov 17)
//
// Replaces the Requests | Overview switch with one window laid
// out like T3 Code's own app: a sidebar (Inbox above every project, threads nested under each), the selected thread or
// request in the middle (answer and changed files first, commands folded under Steps, a header naming project, account,
// model and why it went there), a composer pinned at the bottom, a diff panel on the right on demand, and an accounts
// bar along the bottom. ⌘K opens a palette. Everything reads the Hub; nothing here polls.
// The app shows a Dock icon only while this window is open.

enum OneSelection: Hashable {
    case run(UUID)
    case thread(String)
}

/// A row in the sidebar: one request (its Plan, Build and Review threads together) or one thread T3 started.
enum OneItem: Identifiable {
    case run(OrchRun)
    case thread(BoardRow)
    var id: String { switch self { case .run(let r): return "run:" + r.id.uuidString; case .thread(let t): return "t:" + t.id } }
    var selection: OneSelection { switch self { case .run(let r): return .run(r.id); case .thread(let t): return .thread(t.id) } }
    var updated: Date {
        switch self { case .run(let r): return r.ended ?? r.started; case .thread(let t): return t.updated ?? .distantPast }
    }
}

@MainActor
final class OneModel: ObservableObject {
    static let shared = OneModel()
    /// Picking a request or thread also points the composer at its project, so a follow-up goes to the same place.
    @Published var selection: OneSelection? {
        didSet {
            guard selection != oldValue, let sel = selection else { return }
            var folder: String?
            switch sel {
            case .run(let id): folder = OrchEngine.shared.runs.first { $0.id == id }.map { $0.repoRoot ?? $0.folder }
            case .thread(let tid):
                if let pid = T3Board.shared.rows.first(where: { $0.id == tid })?.projectId {
                    folder = Hub.shared.projects.first { $0.t3Id == pid }?.path
                }
            }
            if let folder, !folder.isEmpty, folder != composerFolder { composerFolder = folder }
        }
    }
    @Published var diffOpen = false
    @Published var palette = false
    @Published var search = ""
    @Published var older: [(id: String, project: String, snippet: String)] = []
    @Published var searching = false
    @Published var collapsed: Set<String> = []
    @Published var composerFolder: String = UserDefaults.standard.string(forKey: "orch.folder") ?? "" {
        didSet { UserDefaults.standard.set(composerFolder, forKey: "orch.folder") }
    }
    @Published var directTarget: String = UserDefaults.standard.string(forKey: "orch.target") ?? "" {
        didSet { UserDefaults.standard.set(directTarget, forKey: "orch.target") }
    }
    @Published var modeRaw: String = UserDefaults.standard.string(forKey: "orch.mode") ?? OrchMode.auto.rawValue {
        didSet { UserDefaults.standard.set(modeRaw, forKey: "orch.mode") }
    }

    /// The run a T3 thread belongs to (one of its steps), if AI Orchestrator started it.
    func run(for threadId: String) -> OrchRun? {
        OrchEngine.shared.runs.first { r in r.steps.contains { $0.threadId == threadId } }
    }

    /// Board rows grouped into sidebar items: a run's step threads become one request row.
    func items(_ rows: [BoardRow], runs: [OrchRun]) -> [OneItem] {
        var out: [OneItem] = []
        var seenRuns = Set<UUID>()
        for r in rows {
            if let run = run(for: r.id) {
                if seenRuns.insert(run.id).inserted { out.append(.run(run)) }
            } else { out.append(.thread(r)) }
        }
        for run in runs where !seenRuns.contains(run.id) { out.append(.run(run)) }
        return out
    }

    func searchOlder() {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { older = []; return }
        searching = true
        Task {
            defer { searching = false }
            let v = try? await T3Client.shared.call("orchestration.searchThreads", ["query": String(q.prefix(200)), "limit": 20]) as? [String: Any]
            let projects = Dictionary(Hub.shared.projects.compactMap { p in p.t3Id.map { ($0, p.name) } }, uniquingKeysWith: { a, _ in a })
            older = (v?["matches"] as? [[String: Any]] ?? []).compactMap { m in
                guard let id = m["threadId"] as? String else { return nil }
                return (id, projects[m["projectId"] as? String ?? ""] ?? "", m["snippet"] as? String ?? "")
            }
        }
    }
}

enum OneWindow {
    private static var window: NSWindow?
    /// Closes the window (same as its close button: the Dock icon goes away with it).
    static func close() { window?.performClose(nil) }
    private static var closeObserver: NSObjectProtocol?

    static func show(folder: String? = nil, thread: String? = nil) {
        MainActor.assumeIsolated {
            let m = OneModel.shared
            if let folder { OrchEngine.shared.allow(folder); m.composerFolder = folder }
            if let thread {
                if let run = m.run(for: thread) { m.selection = .run(run.id) } else { m.selection = .thread(thread) }
            }
        }
        OrchEngine.shared.refreshTargets()
        // A Dock icon (and ⌘Tab) only while this window is open.
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        if let w = window { AppWindows.present(w); return }
        let hc = NSHostingController(rootView: OneRoot().burnWindow())
        let w = NSWindow(contentViewController: hc)
        AppWindows.configure(w, title: "AI Orchestrator", autosave: "AIOrchestratorOneWindow", size: NSSize(width: 1280, height: 800), min: NSSize(width: 980, height: 600))
        window = w
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            NSApp.setActivationPolicy(.accessory)
        }
        AppWindows.present(w)
    }

    static var isOpen: Bool { window?.isVisible == true }
}

struct OneRoot: View {
    @ObservedObject private var model = OneModel.shared
    @ObservedObject private var board = T3Board.shared
    @ObservedObject private var engine = OrchEngine.shared
    @ObservedObject private var hub = Hub.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                OneSidebar().frame(width: 280)
                Divider().opacity(0.4)
                VStack(spacing: 0) {
                    OneMiddle().frame(maxWidth: .infinity, maxHeight: .infinity)
                    OneComposer()
                }
                .frame(maxWidth: .infinity)
                if model.diffOpen {
                    Divider().opacity(0.4)
                    OneDiffPanel().frame(width: 460)
                }
            }
            .frame(maxHeight: .infinity)
            AccountsBar()
        }
        .padding(.top, 28)
        .overlay { if model.palette { Palette() } }
        .background {
            // ⌘K inside the window opens the palette.
            Button("") { model.palette.toggle() }.keyboardShortcut("k", modifiers: .command).opacity(0)
        }
    }
}

// MARK: Sidebar

private struct OneSidebar: View {
    @ObservedObject private var model = OneModel.shared
    @ObservedObject private var board = T3Board.shared
    @ObservedObject private var engine = OrchEngine.shared
    @ObservedObject private var hub = Hub.shared

    private func matches(_ i: OneItem) -> Bool {
        let q = model.search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        switch i {
        case .run(let r): return r.request.lowercased().contains(q)
        case .thread(let t): return t.title.lowercased().contains(q) || t.project.lowercased().contains(q)
        }
    }

    var body: some View {
        let inbox: [(String, [OneItem])] = [
            ("Needs you", model.items(board.rows.filter { $0.group == .needsYou }, runs: [])),
            ("Running", model.items(board.rows.filter { $0.group == .running }, runs: engine.runs.filter { $0.status == .running && $0.steps.allSatisfy { $0.threadId == nil } })),
            ("Waiting for room", engine.queue.map { OneItem.run($0) }),
            ("Failed", model.items(board.rows.filter { $0.group == .failed }, runs: [])),
        ]
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
                TextField("Search threads", text: $model.search).textFieldStyle(.plain).font(.system(size: 12))
                    .onSubmit { model.searchOlder() }
                if model.searching { ProgressView().controlSize(.mini) }
            }
            .padding(6).background(RoundedRectangle(cornerRadius: 7).fill(Theme.platter))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Inbox").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
                    ForEach(inbox, id: \.0) { title, items in
                        let shown = items.filter(matches)
                        group(title, count: shown.count, key: "inbox:" + title) {
                            ForEach(shown) { SideRow(item: $0) }
                        }
                    }
                    Text("Projects").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 10)
                    ForEach(hub.projects) { p in
                        let items = projectItems(p).filter(matches)
                        if model.search.isEmpty || !items.isEmpty {
                            group(p.name, count: items.count, key: "p:" + p.id, startCollapsed: items.isEmpty) {
                                ForEach(items.prefix(12)) { SideRow(item: $0) }
                                if items.isEmpty { Text("No threads in the last 14 days").font(Theme.caption).foregroundStyle(.secondary).padding(.leading, 18) }
                            }
                            .contextMenu {
                                Button("New request here") { model.composerFolder = p.path; engine.allow(p.path) }
                                Menu("Pin to account") {
                                    ForEach(engine.targets) { t in
                                        Button((Router.pin(p.path) == t.id ? "✓ " : "") + t.label) { Router.setPin(p.path, t.id) }
                                    }
                                    if Router.pin(p.path) != nil { Divider(); Button("Unpin") { Router.setPin(p.path, nil) } }
                                }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.path)]) }
                            }
                        }
                    }
                    if !model.older.isEmpty {
                        Text("Older matches in T3").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 10)
                        ForEach(model.older, id: \.id) { o in
                            Button { model.selection = .thread(o.id) } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(o.snippet).font(.system(size: 11.5)).lineLimit(2)
                                    Text(o.project).font(Theme.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(5).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } else if !model.search.isEmpty {
                        Button("Search older threads in T3 (Return)") { model.searchOlder() }
                            .buttonStyle(.plain).font(Theme.caption).foregroundStyle(.secondary).padding(.top, 8)
                    }
                }
            }
        }
        .padding(10)
    }

    private func projectItems(_ p: HubProject) -> [OneItem] {
        let rows = p.t3Id.map { id in board.rows.filter { $0.projectId == id } } ?? []
        let real = p.id
        let runs = engine.runs.filter { r in
            let f = URL(fileURLWithPath: r.repoRoot ?? r.folder).resolvingSymlinksInPath().path
            return (f == real || r.folder == p.path) && r.started > Date().addingTimeInterval(-T3Board.days * 86_400)
        }
        return model.items(rows, runs: runs).sorted { $0.updated > $1.updated }
    }

    @ViewBuilder private func group<C: View>(_ title: String, count: Int, key: String, startCollapsed: Bool = false, @ViewBuilder content: () -> C) -> some View {
        let isCollapsed = model.collapsed.contains(key) != startCollapsed
        Button {
            if model.collapsed.contains(key) { model.collapsed.remove(key) } else { model.collapsed.insert(key) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).frame(width: 10)
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
                if count > 0 { Text("\(count)").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 3).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if !isCollapsed { content() }
    }
}

private struct SideRow: View {
    let item: OneItem
    @ObservedObject private var model = OneModel.shared

    var body: some View {
        let selected = model.selection == item.selection
        Button { model.selection = item.selection } label: {
            HStack(alignment: .top, spacing: 6) {
                dot.frame(width: 10, height: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
                    Text(subtitle).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let why = reason { Text(why).font(Theme.caption).foregroundStyle(.tertiary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4).padding(.leading, 14).padding(.trailing, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.platterHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var title: String {
        switch item { case .run(let r): return r.title; case .thread(let t): return t.title }
    }

    private var subtitle: String {
        switch item {
        case .run(let r):
            let steps = r.steps.map { s in "\(s.name) \(symbol(s.status))" }.joined(separator: " ")
            return steps.isEmpty ? r.status.title : steps
        case .thread(let t):
            return [t.account, t.why.isEmpty ? t.status : t.why].joined(separator: " · ")
        }
    }

    /// Why it's where it is: the router's reason for the main step, or what it's waiting for.
    private var reason: String? {
        guard case .run(let r) = item else { return nil }
        if r.status == .waiting, !r.message.isEmpty { return r.message }
        let main = r.steps.first { $0.name == "Build" || $0.name == "Run" } ?? r.steps.first
        return main.flatMap { $0.reason.isEmpty ? nil : $0.reason }
    }

    private func symbol(_ s: OrchState) -> String {
        switch s { case .done: return "✓"; case .failed: return "✕"; case .running: return "…"; case .stopped: return "■"; case .skipped: return "–"; case .waiting: return "○" }
    }

    @ViewBuilder private var dot: some View {
        switch item {
        case .run(let r):
            if r.status == .running { ProgressView().controlSize(.mini).scaleEffect(0.7) } else { Circle().fill(r.status.color).frame(width: 6, height: 6) }
        case .thread(let t):
            if t.group == .running { ProgressView().controlSize(.mini).scaleEffect(0.7) } else { Circle().fill(t.group.color).frame(width: 6, height: 6) }
        }
    }
}

// MARK: Middle

private struct OneMiddle: View {
    @ObservedObject private var model = OneModel.shared
    @ObservedObject private var engine = OrchEngine.shared
    @ObservedObject private var board = T3Board.shared

    var body: some View {
        switch model.selection {
        case .run(let id):
            if let r = engine.runs.first(where: { $0.id == id }) ?? engine.queue.first(where: { $0.id == id }) { RunPane(run: r).id(id) } else { empty }
        case .thread(let id):
            ThreadPane(threadId: id).id(id)
        case nil:
            empty
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text("Pick a thread on the left, or write a request below.").font(Theme.body).foregroundStyle(.secondary)
            Text("⌘K jumps to any project or thread.").font(Theme.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One line under a pane's title: project · account · model, then why it was routed there.
private struct PaneHeader: View {
    let title: String
    let facts: [String]
    let reason: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 15, weight: .semibold)).textSelection(.enabled).lineLimit(3)
            Text(facts.filter { !$0.isEmpty }.joined(separator: " · ")).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
            if !reason.isEmpty { Text(reason).font(Theme.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RunPane: View {
    @ObservedObject var run: OrchRun
    @ObservedObject private var engine = OrchEngine.shared
    @ObservedObject private var board = T3Board.shared
    @ObservedObject private var model = OneModel.shared
    @State private var busy = false
    @State private var showSteps = false
    @State private var reply = ""

    private var answer: OrchStep? { run.steps.last { !$0.final.isEmpty } }
    private var failure: PlainError? { run.steps.first { $0.status == .failed && !$0.note.isEmpty }.map { PlainError.explain($0.note) } }
    /// Step threads that are waiting on you right now.
    private var waiting: [BoardRow] { board.rows.filter { r in r.group == .needsYou && run.steps.contains { $0.threadId == r.id } } }
    private var lastThread: BoardRow? { run.steps.reversed().compactMap { s in s.threadId.flatMap { id in board.rows.first { $0.id == id } } }.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let s = run.steps.last { $0.status == .running } ?? run.steps.last { $0.target != nil } ?? run.steps.first
            PaneHeader(title: run.title,
                       facts: [URL(fileURLWithPath: run.repoRoot ?? run.folder).lastPathComponent, run.mode.title, run.scope.title,
                               s?.targetLabel ?? "", s?.model ?? "", run.branch ?? "", run.status.title + (run.merged ? " · merged" : "")],
                       reason: run.steps.compactMap { $0.reason.isEmpty ? nil : "\($0.name): \($0.reason)" }.joined(separator: "  ·  "))
            if let f = failure { Text(f.text).font(Theme.body).foregroundStyle(Theme.alert).textSelection(.enabled) }
            if !run.message.isEmpty { Text(run.message).font(Theme.body).foregroundStyle(.secondary).textSelection(.enabled) }
            ForEach(waiting) { w in NeedsYouCard(row: w) }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let a = answer {
                        Text("Answer · \(a.name) · \(a.targetLabel)").font(Theme.caption).foregroundStyle(.secondary)
                        Text(a.final).font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    } else if run.status == .running {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Working…").font(Theme.body).foregroundStyle(.secondary) }
                    }
                    if !run.changed.isEmpty {
                        Text("Changed files").font(Theme.caption).foregroundStyle(.secondary)
                        Text(run.changed).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.platter))
                    }
                    DisclosureGroup("Steps", isExpanded: $showSteps) {
                        VStack(alignment: .leading, spacing: 10) { ForEach(run.steps) { OneStepView(step: $0) } }.padding(.top, 4)
                    }
                    .font(Theme.caption)
                }
            }
            actions
            if let t = lastThread, run.status != .running || t.group == .needsYou {
                HStack {
                    TextField("Reply to \(t.account)…", text: $reply).textFieldStyle(.roundedBorder).onSubmit(sendReply)
                    Button("Reply", action: sendReply).disabled(reply.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.small)
            }
        }
        .padding(16)
    }

    private func sendReply() {
        guard let t = lastThread else { return }
        let text = reply; reply = ""
        Task { await board.reply(t, text) }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if run.status == .running || run.status == .waiting { Button("Stop") { engine.stop(run) } }
            if run.worktree != nil, run.status != .running, !run.merged {
                Button("Merge into \(URL(fileURLWithPath: run.repoRoot ?? run.folder).lastPathComponent)") {
                    busy = true; Task { await engine.merge(run); busy = false }
                }
                .buttonStyle(.borderedProminent).disabled(busy || run.changed.isEmpty)
                Button("Discard") {
                    let a = NSAlert()
                    a.messageText = "Discard \(run.branch ?? "this branch")?"
                    a.informativeText = "This deletes the run's own branch and worktree. Your checkout isn't touched."
                    a.addButton(withTitle: "Discard"); a.addButton(withTitle: "Cancel")
                    if a.runModal() == .alertFirstButtonReturn { busy = true; Task { await engine.discard(run); busy = false } }
                }
                .disabled(busy)
            }
            if let t = lastThread, t.group == .failed || t.group == .needsYou, let to = board.reassignTarget(t) {
                Button("Reassign → \(to.label)") { Task { await board.reassign(t) } }
            }
            if run.worktree != nil || lastThread != nil { Button(model.diffOpen ? "Hide diff" : "Diff") { model.diffOpen.toggle() } }
            if busy { ProgressView().controlSize(.small) }
            Spacer()
        }
        .controlSize(.small)
    }
}

/// A Needs-you request with Approve (Touch ID) and Decline.
private struct NeedsYouCard: View {
    let row: BoardRow
    @ObservedObject private var board = T3Board.shared
    var body: some View {
        HStack(spacing: 8) {
            Text("\(row.account): \(row.why)").font(Theme.body).lineLimit(2)
            Spacer()
            if row.canApprove {
                Button("Approve") { Task { await board.answer(row, approve: true) } }.buttonStyle(.borderedProminent)
                Button("Decline") { Task { await board.answer(row, approve: false) } }
            }
            if board.busy.contains(row.id) { ProgressView().controlSize(.small) }
            if let n = board.note[row.id] { Text(n).font(Theme.caption).foregroundStyle(.secondary) }
        }
        .controlSize(.small)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.platterHover))
    }
}

private struct OneStepView: View {
    @ObservedObject var step: OrchStep
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if step.status == .running { ProgressView().controlSize(.mini) } else { Circle().fill(step.status.color).frame(width: 6, height: 6) }
                Text(step.name).font(Theme.cardTitle)
                Text("\(step.targetLabel)\(step.model.map { " · " + $0 } ?? "") · \(step.scope.title)").font(Theme.body).foregroundStyle(.secondary)
                Spacer()
                Text(step.status.title).font(Theme.caption).foregroundStyle(step.status.color)
            }
            if !step.reason.isEmpty { Text(step.reason).font(Theme.caption).foregroundStyle(.secondary) }
            if !step.note.isEmpty { Text(step.note).font(Theme.body).foregroundStyle(Theme.warn) }
            if !step.output.isEmpty {
                ScrollView {
                    Text(step.output.suffix(20_000)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 40, maxHeight: 220).padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.platter))
            }
        }
    }
}

/// What a T3 thread shows: latest answer, changed files, commands.
struct ThreadDetail: Equatable {
    var answer = ""
    var files: [String] = []
    var commands: [String] = []
    var model = ""
    var turns = 0
    var worktree: String?
}

private struct ThreadPane: View {
    let threadId: String
    @ObservedObject private var board = T3Board.shared
    @ObservedObject private var hub = Hub.shared
    @ObservedObject private var model = OneModel.shared
    @State private var detail = ThreadDetail()
    @State private var loadError = ""
    @State private var showSteps = false
    @State private var reply = ""

    private var row: BoardRow? { board.rows.first { $0.id == threadId } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let r = row
            PaneHeader(title: r?.title ?? "Thread",
                       facts: [r?.project ?? "", r?.account ?? "", detail.model, r?.branch ?? "", r?.status ?? ""],
                       reason: r.map { "Started in \($0.source)" + ($0.title.hasPrefix("↪") ? " as a reassignment" : "") } ?? "")
            if let r, r.group == .needsYou { NeedsYouCard(row: r) }
            if let p = r?.problem { Text(p.text).font(Theme.body).foregroundStyle(Theme.alert) }
            if !loadError.isEmpty { Text(loadError).font(Theme.caption).foregroundStyle(Theme.warn) }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !detail.answer.isEmpty {
                        Text("Answer").font(Theme.caption).foregroundStyle(.secondary)
                        Text(detail.answer).font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    } else if r?.group == .running {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Working…").font(Theme.body).foregroundStyle(.secondary) }
                    }
                    if !detail.files.isEmpty {
                        Text("Changed files").font(Theme.caption).foregroundStyle(.secondary)
                        Text(detail.files.joined(separator: "\n")).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.platter))
                    }
                    DisclosureGroup("Steps (\(detail.commands.count) commands)", isExpanded: $showSteps) {
                        Text(detail.commands.joined(separator: "\n")).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    .font(Theme.caption)
                }
            }
            if let r {
                HStack(spacing: 8) {
                    if r.group == .running || r.status == "waiting" { Button("Stop") { Task { await board.stop(r) } } }
                    if r.group != .done, let t = board.reassignTarget(r) { Button("Reassign → \(t.label)") { Task { await board.reassign(r) } } }
                    if detail.turns > 0 || detail.worktree != nil { Button(model.diffOpen ? "Hide diff" : "Diff") { model.diffOpen.toggle() } }
                    if board.busy.contains(r.id) { ProgressView().controlSize(.small) }
                    if let n = board.note[r.id] { Text(n).font(Theme.caption).foregroundStyle(.secondary) }
                    Spacer()
                }
                .controlSize(.small)
                HStack {
                    TextField("Reply to \(r.account)…", text: $reply).textFieldStyle(.roundedBorder).onSubmit(send)
                    Button("Reply", action: send).disabled(reply.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.small)
            }
        }
        .padding(16)
        .task { hub.follow(threadId); await load() }
        .onDisappear { hub.unfollow(threadId) }
        .onChange(of: hub.threadTicks[threadId]) { _, _ in Task { await load() } }
    }

    private func send() {
        guard let r = row else { return }
        let t = reply; reply = ""
        Task { await board.reply(r, t) }
    }

    private func load() async {
        do {
            let p = try await T3Client.shared.projection(threadId)
            detail = Self.parse(p)
            loadError = ""
        } catch { loadError = error.localizedDescription }
    }

    static func parse(_ p: [String: Any]) -> ThreadDetail {
        var d = ThreadDetail()
        let thread = p["thread"] as? [String: Any] ?? [:]
        d.model = (thread["modelSelection"] as? [String: Any])?["model"] as? String ?? ""
        d.worktree = thread["worktreePath"] as? String
        let root = d.worktree.map { $0 + "/" } ?? ""
        for m in (p["messages"] as? [[String: Any]] ?? []).reversed() where m["role"] as? String == "assistant" {
            if let t = m["text"] as? String, !t.isEmpty { d.answer = t; break }
        }
        var files: [String] = []
        for item in p["turnItems"] as? [[String: Any]] ?? [] {
            switch item["type"] as? String {
            case "command_execution":
                if let c = item["input"] as? String, item["title"] as? String != "Workspace ready" { d.commands.append("$ " + c.replacingOccurrences(of: root, with: "")) }
            case "file_change":
                for c in item["changes"] as? [[String: Any]] ?? [] { if let path = c["path"] as? String { files.append(path.replacingOccurrences(of: root, with: "")) } }
            default: break
            }
        }
        d.files = files.uniquedList()
        d.turns = (p["checkpoints"] as? [[String: Any]] ?? []).compactMap { ($0["appRunOrdinal"] as? NSNumber)?.intValue }.max() ?? 0
        return d
    }
}

// MARK: Diff panel

private struct OneDiffPanel: View {
    @ObservedObject private var model = OneModel.shared
    @ObservedObject private var engine = OrchEngine.shared
    @ObservedObject private var hub = Hub.shared
    @State private var text = ""
    @State private var source = ""
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Diff").font(.system(size: 13, weight: .semibold))
                Text(source).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button { model.diffOpen = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).prefix(4000).enumerated()), id: \.offset) { _, l in
                        Text(String(l)).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(l.hasPrefix("+") && !l.hasPrefix("+++") ? Theme.ok : l.hasPrefix("-") && !l.hasPrefix("---") ? Theme.alert : l.hasPrefix("@@") ? Color.secondary : Color.primary)
                            .fixedSize()
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if text.isEmpty && !loading { Text("No changes recorded.").font(Theme.body).foregroundStyle(.secondary) }
        }
        .padding(12)
        .task(id: model.selection) { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        text = ""
        switch model.selection {
        case .run(let id):
            guard let r = engine.runs.first(where: { $0.id == id }) else { return }
            if let wt = r.worktree, let base = r.baseCommit {
                source = "git diff \(String(base.prefix(8)))…\(r.branch ?? "HEAD")"
                text = await OrchEngine.git(["diff", base], in: wt).out
            } else if let t = r.steps.last(where: { $0.threadId != nil })?.threadId {
                await t3Diff(t)
            } else { source = "" }
        case .thread(let id):
            await t3Diff(id)
        case nil: break
        }
    }

    private func t3Diff(_ id: String) async {
        do {
            let p = try await T3Client.shared.projection(id)
            let turns = (p["checkpoints"] as? [[String: Any]] ?? []).compactMap { ($0["appRunOrdinal"] as? NSNumber)?.intValue }.max() ?? 0
            guard turns > 0 else { source = "T3 recorded no checkpoints"; return }
            source = "T3 turn diff, turns 0–\(turns)"
            text = try await T3Client.shared.threadDiff(id, turns: turns)
        } catch { source = error.localizedDescription }
    }
}

// MARK: Composer

private struct OneComposer: View {
    @ObservedObject private var model = OneModel.shared
    @ObservedObject private var engine = OrchEngine.shared
    @ObservedObject private var hub = Hub.shared
    @AppStorage("orch.scope") private var scopeRaw = OrchScope.read.rawValue
    @AppStorage("orch.model") private var modelName = ""
    @AppStorage("orch.askFirst") private var askFirst = false
    @State private var text = ""
    @FocusState private var focused: Bool

    private var mode: OrchMode { OrchMode(rawValue: model.modeRaw) ?? .auto }
    private var scope: OrchScope { OrchScope(rawValue: scopeRaw) ?? .read }
    private var target: OrchTarget? { engine.targets.first { $0.id == model.directTarget } ?? engine.targets.first }
    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.composerFolder.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Write a request for \(model.composerFolder.isEmpty ? "a project" : URL(fileURLWithPath: model.composerFolder).lastPathComponent)…")
                            .font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 1).padding(.leading, 5).allowsHitTesting(false)
                    }
                    TextEditor(text: $text).font(.system(size: 13)).scrollContentBackground(.hidden).focused($focused)
                }
                .frame(height: 62)
                Button(action: send) { Text("Send").frame(width: 56) }
                    .keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent).disabled(!canSend)
            }
            HStack(spacing: 8) {
                Menu {
                    ForEach(hub.projects) { p in Button(p.name + (engine.folders.contains(p.path) ? "" : "  (allow)")) { engine.allow(p.path); model.composerFolder = p.path } }
                    Divider()
                    Button("Add folder…") { if let f = engine.addFolder() { model.composerFolder = f } }
                } label: { Text("Project: \(model.composerFolder.isEmpty ? "none" : URL(fileURLWithPath: model.composerFolder).lastPathComponent)") }
                .fixedSize()
                Picker("", selection: $model.modeRaw) { ForEach(OrchMode.allCases) { Text($0.title).tag($0.rawValue) } }
                    .pickerStyle(.segmented).fixedSize()
                if mode == .direct {
                    Picker("", selection: $model.directTarget) {
                        ForEach(engine.targets) { t in Text("\(t.label) · \(t.why ?? t.roomText)").tag(t.id) }
                    }
                    .fixedSize()
                    TextField("Model: default", text: $modelName).textFieldStyle(.roundedBorder).frame(width: 120)
                }
                Picker("", selection: $scopeRaw) { ForEach(OrchScope.allCases) { Text($0.title).tag($0.rawValue) } }
                    .pickerStyle(.segmented).fixedSize()
                    .help("Read: looks and answers only. Edit: changes files on a branch of its own; you merge it.")
                Toggle("Ask before acting", isOn: $askFirst).toggleStyle(.checkbox)
                    .help("The agent waits for your Approve (Touch ID) before each command or edit.")
                Text(preview).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(Theme.platter)
    }

    /// Where Auto would send it right now (the same Router every entry point uses).
    private var preview: String {
        if mode == .direct { return target.map { "→ \($0.label)" } ?? "" }
        let b = Router.route(.build, scope: scope, project: model.composerFolder,
                             prefer: OrchEngine.shared.affinity(.build, folder: model.composerFolder, steps: []))
        return b.target.map { "Build → \($0.label)" } ?? b.reason
    }

    private func send() {
        guard canSend else { return }
        let folder = model.composerFolder
        if mode == .direct, let t = target, let why = t.why {
            let a = NSAlert()
            a.messageText = "\(t.label) is \(why)."
            a.informativeText = "Send it there anyway?"
            a.addButton(withTitle: "Send anyway"); a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        if scope == .edit, !OrchEngine.editAllowed.contains(folder) {
            let a = NSAlert()
            a.messageText = "Allow Edit runs in \(URL(fileURLWithPath: folder).lastPathComponent)?"
            a.informativeText = "Each Edit run changes files on a branch of its own (orch/…), in a separate worktree. Your checkout is untouched until you press Merge. Runs never push, deploy or use sudo."
            a.addButton(withTitle: "Allow"); a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
            UserDefaults.standard.set(OrchEngine.editAllowed + [folder], forKey: "orch.editAllowed")
        }
        engine.allow(folder)
        let run = engine.start(request: text.trimmingCharacters(in: .whitespacesAndNewlines), folder: folder, mode: mode, scope: scope,
                               target: mode == .direct ? target : nil, model: mode == .direct ? modelName : nil, askFirst: askFirst)
        model.selection = .run(run.id)
        text = ""
    }
}

// MARK: Accounts bar

struct AccountsBar: View {
    @ObservedObject private var engine = OrchEngine.shared
    @ObservedObject private var hub = Hub.shared
    @ObservedObject private var signIn = T3SignIn.shared

    var body: some View {
        let missing = OrchTargets.claudeWithoutCLI(engine.targets)
        let ready = engine.targets.filter(\.usable).count
        HStack(spacing: 14) {
            Text("\(ready) of \(engine.targets.count + missing.count) can take work")
                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(ready == 0 ? Theme.alert : .primary)
            ForEach(engine.targets) { t in
                HStack(spacing: 5) {
                    Circle().fill(t.usable ? Theme.ok : (t.blocked ? Theme.alert : Theme.warn)).frame(width: 6, height: 6)
                    Text(t.label).font(.system(size: 11, weight: .medium))
                    Text(signIn.state[t.t3Instance ?? ""] ?? t.why ?? t.roomText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    if let r = engine.running(on: t), r > 0 { Text("· \(r) running").font(.system(size: 11)).foregroundStyle(.secondary) }
                    if t.kind == .cursor, t.t3Off == "not signed in to T3 Code", let inst = t.t3Instance {
                        Button("Sign in") { signIn.cursor(inst) }.controlSize(.mini)
                            .help("Opens Cursor's sign-in in your browser through T3 Code. Claude can't finish it for you.")
                    }
                    if let sid = t.statusID, t.paysExtra || t.extraCap > 0 { ExtraRuleMenu(statusID: sid) }
                }
            }
            ForEach(missing, id: \.self) { name in
                HStack(spacing: 5) {
                    Circle().fill(Theme.warn).frame(width: 6, height: 6)
                    Text("Claude · \(name)").font(.system(size: 11, weight: .medium))
                    Text(signIn.state["claude:" + name] ?? "not signed in").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Sign in") { signIn.claude(name: name) }.controlSize(.mini)
                }
            }
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(hub.link == .live ? Theme.ok : Theme.warn).frame(width: 6, height: 6)
                Text(hub.link == .live ? engine.t3Status : hub.link.text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .help("Requests run on the local T3 Code service (127.0.0.1:3773) over one live connection. Memory and CPU are measured.")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.platter)
        .task { _ = await engine.refreshT3() }
    }
}

/// The per-account rule for paid extra usage. It starts at Never, and only this menu changes it.
struct ExtraRuleMenu: View {
    let statusID: String
    @ObservedObject private var engine = OrchEngine.shared
    var body: some View {
        let key = "orch.extraCap." + statusID
        let cap = UserDefaults.standard.double(forKey: key)
        Menu(cap > 0 ? String(format: "Paid extra: up to $%.0f", cap) : "Paid extra: never") {
            Button("Never") { UserDefaults.standard.set(0, forKey: key); engine.refreshTargets() }
            ForEach([25.0, 50, 100, 200], id: \.self) { v in
                Button(String(format: "Up to $%.0f this month", v)) { UserDefaults.standard.set(v, forKey: key); engine.refreshTargets() }
            }
        }
        .controlSize(.mini).fixedSize()
    }
}

// MARK: Palette (⌘K)

private struct Palette: View {
    @ObservedObject private var model = OneModel.shared
    @ObservedObject private var hub = Hub.shared
    @ObservedObject private var board = T3Board.shared
    @ObservedObject private var engine = OrchEngine.shared
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    private struct Entry: Identifiable { let id: String; let title: String; let kind: String; let run: () -> Void }

    private var entries: [Entry] {
        var out: [Entry] = []
        for p in hub.projects {
            out.append(Entry(id: "p:" + p.id, title: p.name, kind: "Project") { model.composerFolder = p.path; engine.allow(p.path); model.collapsed.remove("p:" + p.id) })
            out.append(Entry(id: "n:" + p.id, title: "New request in \(p.name)", kind: "Request") { model.composerFolder = p.path; engine.allow(p.path) })
        }
        for r in board.rows { out.append(Entry(id: "t:" + r.id, title: r.title, kind: r.project) { OneWindow.show(thread: r.id) }) }
        for r in engine.runs.prefix(60) { out.append(Entry(id: "r:" + r.id.uuidString, title: r.title, kind: "Request · " + URL(fileURLWithPath: r.folder).lastPathComponent) { model.selection = .run(r.id) }) }
        for t in engine.targets {
            out.append(Entry(id: "a:" + t.id, title: "Send to \(t.label)", kind: "Account · " + (t.why ?? t.roomText)) { model.modeRaw = OrchMode.direct.rawValue; model.directTarget = t.id })
        }
        out.append(Entry(id: "auto", title: "Route automatically (Auto)", kind: "Account") { model.modeRaw = OrchMode.auto.rawValue })
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? Array(out.prefix(30)) : out.filter { $0.title.lowercased().contains(q) || $0.kind.lowercased().contains(q) }.prefix(30).map { $0 }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.25).onTapGesture { model.palette = false }
            VStack(alignment: .leading, spacing: 0) {
                TextField("Jump to a project or thread, start a request, pick an account…", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 15)).padding(12).focused($focused)
                    .onSubmit { pick(entries.indices.contains(index) ? entries[index] : entries.first) }
                    .onKeyPress(.downArrow) { index = min(index + 1, max(0, entries.count - 1)); return .handled }
                    .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                    .onKeyPress(.escape) { model.palette = false; return .handled }
                    .onChange(of: query) { _, _ in index = 0 }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                            Button { pick(e) } label: {
                                HStack {
                                    Text(e.title).font(.system(size: 12.5)).lineLimit(1)
                                    Spacer()
                                    Text(e.kind).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(i == index ? Theme.platterHover : .clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
            .frame(width: 560)
            .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
            .padding(.top, 70)
        }
        .onAppear { focused = true }
    }

    private func pick(_ e: Entry?) {
        guard let e else { return }
        model.palette = false
        e.run()
    }
}

extension Array where Element: Hashable {
    func uniquedList() -> [Element] { var seen = Set<Element>(); return filter { seen.insert($0).inserted } }
}
