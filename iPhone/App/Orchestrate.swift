import SwiftUI
import LocalAuthentication
import UserNotifications
import WidgetKit

// MARK: - Model
//
// The Mac's board (OrchClient in Shared/Orch.swift), shared by the Inbox and Projects tabs. Edit requests, approvals and
// merges ask Face ID (or the passcode) here first; the Mac doesn't ask again.

enum OrchRoute: Hashable {
    case thread(String)            // a T3 thread id or a run id; /orch/thread takes either
    case project(OrchView.Project)
}

@MainActor
final class OrchModel: ObservableObject {
    static let shared = OrchModel()
    @Published var view: OrchView?
    @Published var error: String?
    @Published var sending = false
    @Published var reach = Reach.now
    @Published var inboxPath: [OrchRoute] = []
    @Published var projectsPath: [OrchRoute] = []
    @Published var details: [String: OrchDetail] = [:]
    /// Thread screens on screen; while any is, the board refreshes every 5 s.
    @Published var threadsOpen = 0

    var board: [OrchView.Thread] { view?.state.board ?? [] }
    var targets: [OrchView.Target] { view?.state.targets ?? [] }
    var projects: [OrchView.Project] {
        if let p = view?.state.projects, !p.isEmpty { return p }
        return (view?.state.folders ?? []).map { OrchView.Project(id: $0.path, name: $0.name, path: $0.path, t3: nil, edit: $0.edit, allowed: true) }
    }

    func refresh() async {
        defer { reach = Reach.now }
        #if targetEnvironment(simulator)
        // Screen checks only: a saved /orch reply (`phone-feed orch-json`) instead of the network.
        if let path = ProcessInfo.processInfo.environment["ORCH_FIXTURE"], let data = FileManager.default.contents(atPath: path) {
            do { view = try JSONDecoder().decode(OrchView.self, from: data); error = nil; Shared.lastReached = Date() }
            catch { self.error = "\(error)" }
            return
        }
        #endif
        do {
            let v = try await OrchClient.fetch()
            let before = Shared.boardCounts
            view = v; error = nil
            Notifier.check(v, notify: false)
            if before.needsYou != Shared.boardCounts.needsYou || before.running != Shared.boardCounts.running {
                WidgetCenter.shared.reloadTimelines(ofKind: "InboxWidget")
            }
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    func loadDetail(_ id: String) async {
        #if targetEnvironment(simulator)
        if let dir = ProcessInfo.processInfo.environment["ORCH_DETAIL_DIR"],
           let data = FileManager.default.contents(atPath: dir + "/" + id + ".json"), let d = try? JSONDecoder().decode(OrchDetail.self, from: data) {
            details[id] = d; return
        }
        #endif
        if let d = try? await OrchClient.detail(id) { details[id] = d }
    }

    func send(request: String, folder: String, mode: String, scope: String, target: String?, model: String?, ask: Bool) async -> Bool {
        if scope == "edit" {
            guard await Self.confirmOwner("Allow an Edit request on your Mac") else { return false }
        }
        sending = true
        defer { sending = false }
        var body: [String: Any] = ["id": UUID().uuidString, "kind": "run", "request": request, "folder": folder, "mode": mode, "scope": scope]
        if mode == "direct", let target { body["target"] = target }
        if mode == "direct", let model, !model.isEmpty { body["model"] = model }
        if ask { body["ask"] = true }
        return await post(body)
    }

    /// An action on one T3 thread: approve (Face ID first), decline, reply, stop or reassign.
    func act(_ t: OrchView.Thread, _ action: String, text: String = "") async -> Bool {
        if action == "approve" {
            guard await Self.confirmOwner("Approve what \(t.account) is waiting on") else { return false }
        }
        return await post(["id": UUID().uuidString, "kind": "board", "thread": t.id, "action": action, "text": text])
    }

    /// Stop, merge (Face ID first) or discard one run.
    func runAction(_ r: OrchView.Run, _ kind: String) async -> Bool {
        if kind == "merge" {
            guard await Self.confirmOwner("Merge \(r.branch ?? "this branch") on your Mac") else { return false }
        }
        return await post(["id": UUID().uuidString, "kind": kind, "runId": r.id])
    }

    private func post(_ body: [String: Any]) async -> Bool {
        do { try await OrchClient.post(body); error = nil }
        catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; return false }
        try? await Task.sleep(for: .seconds(1.5))   // the Mac picks requests up as soon as the file lands
        await refresh()
        return true
    }

    static func confirmOwner(_ reason: String) async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return false }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    /// Opens one thread from a notification or a widget.
    func open(_ id: String) {
        inboxPath = [.thread(id)]
    }
}

// MARK: - Notifications (local only, from background refresh, so they can be late)

enum Notifier {
    static let refreshTask = "local.ai-orchestrator.phone.refresh"

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Compares the board with the groups seen last time; threads that moved to Needs you, Failed or Done get a notification.
    static func check(_ v: OrchView, notify: Bool) {
        let before = Shared.boardGroups
        var now: [String: String] = [:]
        for t in v.state.board ?? [] {
            now[t.id] = t.group
            guard notify, !before.isEmpty, before[t.id] != t.group, ["needsYou", "failed", "done"].contains(t.group) else { continue }
            let c = UNMutableNotificationContent()
            c.title = ["needsYou": "Needs you", "failed": "Failed", "done": "Done"][t.group]! + ": " + t.title
            c.body = [t.project, t.account, (t.why ?? "").isEmpty ? t.status : t.why!].joined(separator: " · ")
            c.sound = t.group == "needsYou" ? .default : nil
            c.userInfo = ["thread": t.id]
            c.threadIdentifier = t.id
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: t.id + "." + t.group, content: c, trigger: nil))
        }
        Shared.boardGroups = now
    }

    static func schedule() {
        let r = BGAppRefreshTaskRequestFactory.make(refreshTask, after: 15 * 60)
        BGAppRefreshTaskRequestFactory.submit(r)
    }

    /// The background refresh: board (for notifications and the Inbox widgets) and usage (for the usage widget).
    static func runInBackground() async {
        schedule()
        if let v = try? await OrchClient.fetch(timeout: 10) { check(v, notify: true) }
        _ = try? await FeedClient.fetch(timeout: 10)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

import BackgroundTasks
enum BGAppRefreshTaskRequestFactory {
    static func make(_ id: String, after: TimeInterval) -> BGAppRefreshTaskRequest {
        let r = BGAppRefreshTaskRequest(identifier: id)
        r.earliestBeginDate = Date().addingTimeInterval(after)
        return r
    }
    static func submit(_ r: BGAppRefreshTaskRequest) { try? BGTaskScheduler.shared.submit(r) }
}

/// Notification taps open that thread.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ app: UIApplication, didFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
        guard let id = r.notification.request.content.userInfo["thread"] as? String else { return }
        await MainActor.run {
            UserDefaults.standard.set("inbox", forKey: "startTab")
            NotificationCenter.default.post(name: .openThread, object: id)
        }
    }
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .list] }
}

extension Notification.Name { static let openThread = Notification.Name("openThread") }

// MARK: - Inbox tab

struct OrchInboxView: View {
    @EnvironmentObject var orch: OrchModel
    @State private var composing = false

    var body: some View {
        NavigationStack(path: $orch.inboxPath) {
            GlassList {
                if let e = orch.error { Section { Text(e).font(.footnote).foregroundStyle(Theme.alert) } }
                let groups: [(String, String)] = [("needsYou", "Needs you"), ("running", "Running")]
                ForEach(groups, id: \.0) { key, title in section(title, orch.board.filter { $0.group == key }) }
                let waiting = (orch.view?.runs ?? []).filter { $0.status == "waiting" }
                if !waiting.isEmpty {
                    Section("Waiting for room") { ForEach(waiting) { r in NavigationLink(value: OrchRoute.thread(r.id)) { RunRowPhone(run: r) } } }
                }
                section("Failed", orch.board.filter { $0.group == "failed" })
                // Runs that failed before any thread started (e.g. a folder that isn't allowed).
                let early = (orch.view?.runs ?? []).filter { $0.status == "failed" && $0.steps.allSatisfy { $0.threadId == nil } }.prefix(5)
                if !early.isEmpty {
                    Section("Failed before starting") { ForEach(Array(early)) { r in NavigationLink(value: OrchRoute.thread(r.id)) { RunRowPhone(run: r) } } }
                }
                section("Done", Array(orch.board.filter { $0.group == "done" }.prefix(12)))
                if orch.view == nil {
                    Section { Text(orch.error == nil ? "Connecting to your Mac…" : "The Inbox shows once the Mac answers.").foregroundStyle(.secondary) }
                } else if orch.board.isEmpty && waiting.isEmpty {
                    Section { Text("No threads on the Mac yet. Tap + to send a request.").foregroundStyle(.secondary) }
                }
                if let l = orch.view?.state.link, l != "live" {
                    Section { Text("The Mac's link to T3 Code: \(l)").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Inbox")
            .appChrome()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { composing = true } label: { Image(systemName: "plus") }.accessibilityLabel("New request")
                }
            }
            .refreshable { await orch.refresh() }
            .orchDestinations()
            .sheet(isPresented: $composing) { NewRequestSheet() }
        }
    }

    @ViewBuilder private func section(_ title: String, _ rows: [OrchView.Thread]) -> some View {
        if !rows.isEmpty {
            Section(title) { ForEach(rows) { t in NavigationLink(value: OrchRoute.thread(t.id)) { ThreadRowPhone(thread: t) } } }
        }
    }
}

extension View {
    func orchDestinations() -> some View {
        navigationDestination(for: OrchRoute.self) { r in
            switch r {
            case .thread(let id): ThreadScreen(id: id)
            case .project(let p): ProjectThreads(project: p)
            }
        }
    }
}

struct ThreadRowPhone: View {
    let thread: OrchView.Thread
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if thread.group == "running" { ProgressView().controlSize(.mini) }
                else { Circle().fill(groupColor(thread.group)).frame(width: 7, height: 7) }
                Text(thread.title).font(.subheadline.weight(.medium)).lineLimit(2)
            }
            Text([thread.project, thread.account, (thread.why ?? "").isEmpty ? thread.status : thread.why!].joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if let r = thread.reason, !r.isEmpty { Text(r).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
        }
    }
}

func groupColor(_ g: String) -> Color {
    switch g {
    case "failed": return Theme.alert
    case "done": return Theme.ok
    case "needsYou": return Theme.warn
    default: return Theme.neutral
    }
}

private func stateColor(_ s: String) -> Color {
    switch s {
    case "done": return Theme.ok
    case "failed": return Theme.alert
    case "stopped", "skipped", "waiting": return Theme.warn
    default: return .secondary
    }
}

struct RunRowPhone: View {
    let run: OrchView.Run
    /// What it's waiting for, or why the router sent its main step where it did.
    private var reasonLine: String? {
        if ["waiting", "failed"].contains(run.status), let m = run.message, !m.isEmpty { return m }
        let main = run.steps.first { $0.name == "Build" || $0.name == "Run" } ?? run.steps.first
        return main?.reason.flatMap { $0.isEmpty ? nil : $0 }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if run.status == "running" { ProgressView().controlSize(.mini) } else { Circle().fill(stateColor(run.status)).frame(width: 7, height: 7) }
                Text(run.title).font(.subheadline.weight(.medium)).lineLimit(2)
            }
            Text("\(URL(fileURLWithPath: run.folder).lastPathComponent) · \(run.status.capitalized)\(run.merged == true ? " · merged" : "")\(run.source == "phone" ? " · from iPhone" : "")")
                .font(.caption).foregroundStyle(.secondary)
            if let r = reasonLine { Text(r).font(.caption2).foregroundStyle(.tertiary).lineLimit(2) }
        }
    }
}

// MARK: - Thread screen: the answer and changed files first, steps folded

struct ThreadScreen: View {
    let id: String
    @EnvironmentObject var orch: OrchModel
    @State private var reply = ""
    @State private var busy: String?
    @FocusState private var typing: Bool

    private var detail: OrchDetail? { orch.details[id] }
    private var thread: OrchView.Thread? { orch.board.first { $0.id == id } ?? detail?.thread }
    private var run: OrchView.Run? {
        let rid = thread?.runId ?? id
        return detail?.run ?? orch.view?.runs.first { $0.id.uppercased() == rid.uppercased() }
    }

    var body: some View {
        GlassList {
            header
            answer
            files
            actions
            if let e = orch.error { Section { Text(e).font(.footnote).foregroundStyle(Theme.alert) } }
            steps
        }
        .navigationTitle(thread == nil && run != nil ? "Request" : "Thread")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            orch.threadsOpen += 1
            while !Task.isCancelled {
                await orch.loadDetail(id)
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .onDisappear { orch.threadsOpen = max(orch.threadsOpen - 1, 0) }
    }

    @ViewBuilder private var header: some View {
        Section {
            if let t = thread {
                Text(t.title).font(.headline)
                Text([t.project, t.account, t.status, t.step.map { "\($0) step" } ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if let w = t.why, !w.isEmpty { Text(w).foregroundStyle(t.group == "failed" ? Theme.alert : .primary) }
                if let r = t.reason, !r.isEmpty { Text(r).font(.caption).foregroundStyle(.secondary) }
            } else if let r = run {
                Text(r.title).font(.headline)
                Text([URL(fileURLWithPath: r.folder).lastPathComponent, r.branch, r.status.capitalized].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if let m = r.message, !m.isEmpty { Text(m).font(.callout) }
            } else if detail == nil {
                HStack { ProgressView(); Text("Loading from your Mac…").foregroundStyle(.secondary) }
            } else {
                Text("This thread is no longer on the Mac's board.").foregroundStyle(.secondary)
            }
        }
    }

    /// The thread's latest message, or the last step's output for a run without one.
    @ViewBuilder private var answer: some View {
        let text = (detail?.thread?.latest ?? thread?.latest ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let output = run?.steps.last(where: { !($0.output ?? "").isEmpty })?.output.map { String($0.suffix(1500)) } ?? ""
        if !text.isEmpty {
            Section("Answer") { Text(text).textSelection(.enabled) }
        } else if !output.isEmpty {
            Section("Answer") { Text(output).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
        }
    }

    @ViewBuilder private var files: some View {
        let list = detail?.files ?? []
        if !list.isEmpty {
            Section {
                ForEach(list, id: \.self) { f in
                    HStack {
                        Text(f.path).font(.system(size: 13, design: .monospaced)).lineLimit(1).truncationMode(.head)
                        Spacer()
                        Text("+\(f.added)").foregroundStyle(Theme.ok).monospacedDigit()
                        Text("−\(f.removed)").foregroundStyle(Theme.alert).monospacedDigit()
                    }
                    .font(.caption)
                }
            } header: { Text("Changed files") } footer: {
                Text("\(list.count) file\(list.count == 1 ? "" : "s"), +\(list.reduce(0) { $0 + $1.added }) −\(list.reduce(0) { $0 + $1.removed })"
                     + (run?.merged == true ? ". Merged." : ""))
            }
        }
    }

    @ViewBuilder private var actions: some View {
        let t = thread, r = run
        Section {
            if let t, t.group == "needsYou", t.canApprove == true {
                Button { act("approve") } label: { Label("Approve (Face ID)", systemImage: "faceid") }.bold()
                Button(role: .destructive) { act("decline") } label: { Label("Decline", systemImage: "xmark") }
            }
            if let r, r.canMerge {
                Button { runAct(r, "merge") } label: { Label("Merge \(r.branch ?? "") (Face ID)", systemImage: "arrow.triangle.merge") }.bold()
                Button(role: .destructive) { runAct(r, "discard") } label: { Label("Discard the branch", systemImage: "trash") }
            }
            if let t, t.group == "running" || t.status == "waiting" {
                Button(role: .destructive) { act("stop") } label: { Label("Stop", systemImage: "stop.circle") }
            } else if t == nil, let r, r.running {
                Button(role: .destructive) { runAct(r, "stop") } label: { Label("Stop this request", systemImage: "stop.circle") }
            }
            if let t, t.group != "done", let to = t.reassignTo, !to.isEmpty {
                Button { act("reassign") } label: { Label("Reassign to \(to)", systemImage: "arrow.left.arrow.right") }
            }
            if let t {
                TextField("Reply to \(t.account)…", text: $reply, axis: .vertical).lineLimit(1...5).focused($typing)
                Button { let x = reply; reply = ""; typing = false; act("reply", x) } label: { Label("Send reply", systemImage: "arrowshape.turn.up.left") }
                    .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } footer: {
            if let b = busy { Text("Sending \(b) to your Mac…") }
            else if let t, t.group == "running" { Text("A reply goes in after the turn that's running now.") }
        }
    }

    @ViewBuilder private var steps: some View {
        if let r = run, !r.steps.isEmpty {
            Section("Steps") {
                ForEach(r.steps, id: \.self) { s in
                    DisclosureGroup {
                        if let why = s.reason, !why.isEmpty { Text(why).font(.caption).foregroundStyle(.secondary) }
                        if let n = s.note, !n.isEmpty { Text(n).font(.footnote).foregroundStyle(Theme.warn) }
                        if let o = s.output, !o.isEmpty {
                            Text(String(o.suffix(4000))).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        } else if detail == nil { Text("Loading output…").font(.caption).foregroundStyle(.secondary) }
                    } label: {
                        HStack {
                            Text("\(s.name) · \(s.target ?? "–")\(s.model.map { " · " + $0 } ?? "")").font(.subheadline).lineLimit(1)
                            Spacer()
                            Text(s.status.capitalized).font(.caption).foregroundStyle(stateColor(s.status))
                        }
                    }
                }
            }
        }
    }

    private func act(_ action: String, _ text: String = "") {
        guard let t = thread else { return }
        busy = action
        Task { _ = await orch.act(t, action, text: text); await orch.loadDetail(id); busy = nil }
    }
    private func runAct(_ r: OrchView.Run, _ kind: String) {
        busy = kind
        Task { _ = await orch.runAction(r, kind); try? await Task.sleep(for: .seconds(1.5)); await orch.loadDetail(id); busy = nil }
    }
}

// MARK: - New request

struct NewRequestSheet: View {
    @EnvironmentObject var orch: OrchModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("orch.folder", store: Shared.defaults) private var folder = ""
    @AppStorage("orch.mode", store: Shared.defaults) private var mode = "auto"
    @AppStorage("orch.scope", store: Shared.defaults) private var scope = "read"
    @AppStorage("orch.target", store: Shared.defaults) private var target = ""
    @AppStorage("orch.model", store: Shared.defaults) private var modelName = ""
    @AppStorage("orch.ask", store: Shared.defaults) private var ask = false
    @State private var text = ""
    @FocusState private var typing: Bool

    private var current: OrchView.Project? { orch.projects.first { $0.path == folder } }
    private var editOK: Bool { current?.edit == true }
    private var pickedTarget: OrchView.Target? { orch.targets.first { $0.id == target } ?? orch.targets.first { $0.usable } }
    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && current != nil && !orch.sending && (scope == "read" || editOK)
            && (mode == "auto" || pickedTarget != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What should it do?", text: $text, axis: .vertical).lineLimit(4...12).focused($typing)
                } footer: { Text("Tap the microphone on the keyboard to dictate.") }
                Section {
                    if orch.projects.isEmpty { Text("Connecting to your Mac…").foregroundStyle(.secondary) }
                    else { Picker("Project", selection: $folder) { ForEach(orch.projects) { Text($0.name).tag($0.path) } } }
                    Picker("Route", selection: $mode) { Text("Auto").tag("auto"); Text("Direct").tag("direct") }.pickerStyle(.segmented)
                    if mode == "direct" {
                        Picker("Account", selection: $target) {
                            ForEach(orch.targets, id: \.id) { t in Text("\(t.label) · \(roomText(t))").tag(t.id) }
                        }
                        TextField("Model (blank = the account's default)", text: $modelName)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Picker("Scope", selection: $scope) { Text("Read").tag("read"); Text("Edit").tag("edit") }.pickerStyle(.segmented)
                    Toggle("Ask before acting", isOn: $ask)
                } footer: {
                    if scope == "edit", let p = current, !editOK {
                        Text("Edit isn't allowed in \(p.name) yet. Allow it once on the Mac (send one Edit request there), then send from here.")
                            .foregroundStyle(Theme.alert)
                    } else if scope == "edit" {
                        Text("Edit works on its own branch; you merge or discard it from the thread. Sending asks for Face ID.")
                    }
                }
                Section("Where it goes") { Text(preview).font(.callout) }
            }
            .navigationTitle("New request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(orch.sending ? "Sending…" : "Send") {
                        Task {
                            typing = false
                            let t = mode == "direct" ? pickedTarget?.id : nil
                            if await orch.send(request: text.trimmingCharacters(in: .whitespacesAndNewlines), folder: folder, mode: mode, scope: scope,
                                               target: t, model: modelName.trimmingCharacters(in: .whitespaces), ask: ask) {
                                text = ""; dismiss()
                            }
                        }
                    }
                    .bold().disabled(!canSend)
                }
            }
            .onAppear {
                // Defaults to the last project used.
                if current == nil { folder = orch.projects.first?.path ?? "" }
                typing = true
            }
        }
        .presentationDetents([.large])
    }

    private func roomText(_ t: OrchView.Target) -> String { t.why ?? t.room.map { String(format: "%.0f%% left", $0) } ?? "–" }

    /// From the Mac's router: the reason its build step would get, plus how Auto splits the work.
    private var preview: String {
        if mode == "direct" {
            guard let t = pickedTarget else { return "Pick an account." }
            let m = modelName.trimmingCharacters(in: .whitespaces)
            return "Goes straight to \(t.label)\(m.isEmpty ? "" : " on \(m)") (\(roomText(t)))."
        }
        let p = orch.view?.state.preview
        let reason = p?.pinned?[folder]?[scope] ?? p?.default?[scope]
        guard let reason else { return "Auto: Claude plans, the account with the most room builds, a different one reviews. Update the Mac app to see where it would go." }
        return "Build: \(reason).\nPlan and review go to Claude first; review uses a different account from the build. Accounts near their limit are skipped."
    }
}

// MARK: - Projects tab

struct OrchProjectsView: View {
    @EnvironmentObject var orch: OrchModel
    var feed: Feed
    var body: some View {
        NavigationStack(path: $orch.projectsPath) {
            GlassList {
                Section {
                    if orch.projects.isEmpty { Text(orch.view == nil ? "Connecting to your Mac…" : "No projects on the Mac yet.").foregroundStyle(.secondary) }
                    ForEach(orch.projects) { p in
                        let rows = orch.board.filter { $0.projectId != nil && $0.projectId == p.t3 }
                        NavigationLink(value: OrchRoute.project(p)) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name)
                                    let needs = rows.filter { $0.group == "needsYou" }.count, running = rows.filter { $0.group == "running" }.count
                                    if needs + running > 0 {
                                        Text([needs > 0 ? "\(needs) need you" : nil, running > 0 ? "\(running) running" : nil].compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if !rows.isEmpty { Text("\(rows.count)").foregroundStyle(.secondary).monospacedDigit() }
                            }
                        }
                    }
                } header: { Text("Projects and threads") }
                ProjectTokenSections(feed: feed)
            }
            .navigationTitle("Projects")
            .appChrome()
            .refreshable { await orch.refresh() }
            .orchDestinations()
        }
    }
}

/// One project's threads and requests, newest first.
struct ProjectThreads: View {
    let project: OrchView.Project
    @EnvironmentObject var orch: OrchModel
    var body: some View {
        let rows = orch.board.filter { project.t3 != nil && $0.projectId == project.t3 }
        let runs = (orch.view?.runs ?? []).filter { $0.folder == project.path }
        GlassList {
            Section("Threads") {
                if rows.isEmpty { Text("No threads in the last 14 days.").foregroundStyle(.secondary) }
                ForEach(rows) { t in NavigationLink(value: OrchRoute.thread(t.id)) { ThreadRowPhone(thread: t) } }
            }
            if !runs.isEmpty {
                Section("Requests") { ForEach(runs) { r in NavigationLink(value: OrchRoute.thread(r.id)) { RunRowPhone(run: r) } } }
            }
            Section {
                Text(project.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(project.edit == true ? "Edit is allowed here." : "Read only from the phone until Edit is allowed once on the Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Shared chrome: appearance, the Home/Away dot, settings

struct AppChrome: ViewModifier {
    @EnvironmentObject var orch: OrchModel
    @State private var showSetup = false
    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { AppearanceMenu() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSetup = true } label: {
                        HStack(spacing: 5) {
                            Circle().fill(dot).frame(width: 8, height: 8)
                            Text(orch.reach.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Image(systemName: "gearshape")
                        }
                    }
                    .accessibilityLabel("\(orch.reach.label). Mac connection settings")
                }
            }
            .sheet(isPresented: $showSetup) { NavigationStack { SetupView(first: false) } }
    }
    private var dot: Color {
        switch orch.reach {
        case .home: return Theme.ok
        case .away: return Theme.neutral
        case .unreachable, .notPaired: return Theme.alert
        }
    }
}

extension View { func appChrome() -> some View { modifier(AppChrome()) } }
