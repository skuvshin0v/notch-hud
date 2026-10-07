// Notch HUD: a floating macOS widget that mirrors running Claude Code sessions.
//
// Reads ~/.claude/notch-hud/sessions/*.json (written by the notch-hud mod),
// answers questions and permission asks through ~/.claude/notch-hud/answers,
// sends follow-up prompts through ~/.claude/notch-hud/inbox, stops a turn through
// ~/.claude/notch-hud/stop, and publishes its
// own heartbeat and the frontmost app in ~/.claude/notch-hud/presence.json.

import AppKit
import Combine
import SwiftUI

// MARK: - Model

struct TaskItem: Codable, Hashable {
    var id: String
    var subject: String
    var status: String
}

struct QuestionOption: Codable, Hashable {
    var label: String
    var description: String?
}

struct Question: Codable, Hashable {
    var question: String
    var header: String?
    var multiSelect: Bool?
    var options: [QuestionOption]?
}

struct Pending: Codable, Hashable {
    var id: String
    var kind: String // "question" | "permission"
    var questions: [Question]?
    var tool: String?
    var summary: String?
    var detail: String?
    var canAlways: Bool?
}

struct SessionInfo: Codable, Identifiable, Hashable {
    var id: String
    var cwd: String
    var project: String
    var host: String
    var hostName: String
    var pid: Int?
    var title: String
    var status: String
    var turnStartedAt: Double?
    var activity: String
    var tool: String?
    var tasks: [TaskItem]
    var lastText: String
    /// Absent from a session an older mod writes.
    var lastPrompt: String?
    /// "you" or "agent": who the last prompt came from (absent from older mods: the person).
    var lastPromptFrom: String?
    /// The last few exchanges, newest last (absent from older mods).
    var history: [Exchange]?
    /// The session's subagents still going (absent from older mods).
    var agents: [AgentCard]?
    var pending: Pending?
    var turns: Int
    var updatedAt: Double
}

struct Exchange: Codable, Hashable {
    var from: String
    var prompt: String
    var answer: String
}

struct AgentCard: Codable, Hashable, Identifiable {
    var id: String
    var description: String
    var type: String
    var status: String
    var activity: String
}

enum Paths {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/notch-hud", isDirectory: true)
    static let sessions = root.appendingPathComponent("sessions", isDirectory: true)
    static let answers = root.appendingPathComponent("answers", isDirectory: true)
    static let inbox = root.appendingPathComponent("inbox", isDirectory: true)
    static let stop = root.appendingPathComponent("stop", isDirectory: true)
    static let presence = root.appendingPathComponent("presence.json")
    static let limits = root.appendingPathComponent("limits.json")
}

/// The island's language: English unless the person picked Russian in its settings.
/// A prompt typed in the island reaches Claude Code wrapped in the engine's framing for plugin
/// prompts; the person wrote only what is inside. (The mod strips it too; older mods do not.)
func unframe(_ text: String) -> String {
    text.replacingOccurrences(of: #"^\s*The [\w-]+ plugin sent a message:\s*"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\s*This is how Claude Code surfaces a prompt[\s\S]*$"#, with: "", options: .regularExpression)
}

/// The few phrases the mod itself writes (in English), shown in the island's language.
func modText(_ text: String) -> String {
    guard isRussian else { return text }
    let phrases = [("Thinking…", "Думает…"), ("Compacting context…", "Сжимаю контекст…"),
                   ("**Context compacted.**", "**Контекст сжат.**"),
                   ("**Error:**", "**Ошибка:**"), ("the turn ended with an API error.", "ход прервался из-за ошибки API."),
                   ("API error:", "Ошибка API:"),
                   ("**Refused:**", "**Отказ:**"), ("the model declined to answer.", "модель отказалась отвечать.")]
    return phrases.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
}

var isRussian: Bool { UserDefaults.standard.string(forKey: "language") == "ru" }

/// A string of the island in the language picked.
func tr(_ en: String, _ ru: String) -> String { isRussian ? ru : en }

// Bundle ids of the apps a session can live in, beside the session's own host.
let claudeDesktopIDs: Set<String> = ["com.anthropic.claudefordesktop", "com.anthropic.claude"]

func parentPid(_ pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let ppid = info.kp_eproc.e_ppid
    return ppid > 1 ? ppid : nil
}

/// The GUI app a process runs under (Terminal, iTerm, Ghostty, Claude, an IDE...), by walking its parents.
func appBundleId(forPid pid: Int) -> String? {
    var current: pid_t? = pid_t(pid)
    var hops = 0
    while let p = current, hops < 40 {
        if let app = NSRunningApplication(processIdentifier: p),
           app.activationPolicy == .regular, let id = app.bundleIdentifier {
            return id
        }
        current = parentPid(p)
        hops += 1
    }
    return nil
}

/// The terminal device a process writes to ("/dev/ttys003"), or nil when it has none.
func ttyPath(forPid pid: Int) -> String? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid_t(pid)]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let dev = info.kp_eproc.e_tdev
    guard dev != -1, let name = devname(dev, S_IFCHR) else { return nil }
    return "/dev/" + String(cString: name)
}

/// AppleScript that brings forward the tab (or split) whose tty is `item 1 of argv`, per terminal
/// app; it returns "ok" when it found one.
let focusTTYScripts: [String: String] = [
    "com.apple.Terminal": """
        on run argv
          tell application id "com.apple.Terminal"
            repeat with w in windows
              repeat with t in tabs of w
                if tty of t is item 1 of argv then
                  set miniaturized of w to false
                  set selected of t to true
                  set index of w to 1
                  activate
                  return "ok"
                end if
              end repeat
            end repeat
          end tell
          return "none"
        end run
        """,
    "com.googlecode.iterm2": """
        on run argv
          tell application id "com.googlecode.iterm2"
            repeat with w in windows
              repeat with t in tabs of w
                repeat with s in sessions of t
                  if tty of s is item 1 of argv then
                    select w
                    tell t to select
                    tell s to select
                    activate
                    return "ok"
                  end if
                end repeat
              end repeat
            end repeat
          end tell
          return "none"
        end run
        """,
]

/// Editors that bring forward the window already holding a folder when asked to open it.
let folderWindowApps: Set<String> = [
    "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
]

struct HiddenSession: Equatable {
    /// The turn count when hidden: a change means a turn ran, even one too short to catch working.
    var turns: Int
    /// The session has worked since it was hidden, so its next stop is the end of a turn.
    var sawWork: Bool
}

/// One of the account's rate-limit windows, as the mod last measured it.
struct RateLimit: Codable, Equatable {
    var kind: String
    var percentUsed: Double
    var resetsAt: String?

    var resetDate: Date? {
        guard let resetsAt else { return nil }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: resetsAt) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: resetsAt)
    }
}

struct LimitsFile: Codable {
    var updatedAt: Double
    var limits: [RateLimit]
}

final class Store: ObservableObject {
    @Published var sessions: [SessionInfo] = []
    @Published var frontmost: String = ""
    @Published var now = Date()

    @AppStorage("alwaysShow") var alwaysShow = true
    @AppStorage("routeAlways") var routeAlways = true
    @AppStorage("askSound") var askSound = "hud-chime"
    @AppStorage("doneSound") var doneSound = "hud-duo"
    @AppStorage("language") var language = "en"
    /// The open island shows the settings instead of the sessions.
    @Published var showSettings = false
    /// Set by the app: opens a table in a window of its own.
    var openTable: (_ header: [String], _ rows: [[String]]) -> Void = { _, _ in }
    /// Set by the app: whether the island holds the keyboard (the person is typing in it).
    var islandIsKey: () -> Bool = { false }
    /// Set by the app: gives the island the keyboard, leaving the app beneath it active.
    var focusIsland: () -> Void = {}

    @Published var islandExpanded = false {
        // Opening the island is seeing what had finished: those marks go when it closes again.
        // A chat that finishes while it is open keeps its mark: the person was reading another.
        didSet {
            if !oldValue && islandExpanded { unseenAtOpen = unseen }
            if oldValue && !islandExpanded { unseen.subtract(unseenAtOpen) }
        }
    }
    private var unseenAtOpen = Set<String>()
    /// Sessions that finished since the person last opened the island.
    @Published var unseen = Set<String>()
    @Published var limits: [RateLimit] = []
    /// What the person has typed in each chat's reply box, kept apart from the card: a card that
    /// closes or redraws (a turn starts, an agent's message arrives) never takes the draft with it.
    @Published var drafts: [String: String] = [:]
    /// The session opened in detail in the island's list; one at a time.
    @Published var selected: String?
    @Published var islandHovered = false
    /// The capsule's frame inside the island window (top-left origin): the only part that takes the mouse.
    var islandRect: CGRect = .zero
    /// Sessions that just finished, flashed in the island until the time given.
    @Published var flashes: [String: Date] = [:]
    /// Sessions the person hid from the island; each comes back on an ask or when its next turn ends.
    @Published var hidden: [String: HiddenSession] = [:]

    private var timer: Timer?
    private var seenPending = Set<String>()
    private var seenDone = Set<String>()
    private var hostCache: [Int: String] = [:]
    /// Each session's state as last read (status, ask, turn), and when it last changed, in ms.
    private var lastState: [String: String] = [:]
    private var eventAt: [String: Double] = [:]
    /// What the widget did before the mod caught up: a prompt sent (by session) and asks
    /// answered (by ask id), each until the mod's file confirms it or 5 s pass.
    private var sentAt: [String: Date] = [:]
    private var answeredAt: [String: Date] = [:]
    private var stoppedAt: [String: Date] = [:]
    private let decoder = JSONDecoder()

    init() {
        for dir in [Paths.sessions, Paths.answers, Paths.inbox] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in self?.tick() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.tick() }
    }

    /// The app a session lives in: resolved from its pid, else what the mod reported.
    func host(of s: SessionInfo) -> String {
        if let pid = s.pid, pid > 0 {
            if let cached = hostCache[pid] { return cached }
            if let id = appBundleId(forPid: pid) { hostCache[pid] = id; return id }
        }
        return s.host
    }

    var hosts: Set<String> { Set(sessions.map { host(of: $0) }.filter { !$0.isEmpty }).union(claudeDesktopIDs) }

    /// The person is in an app a session lives in.
    var isInClaude: Bool { hosts.contains(frontmost) }

    var hasPending: Bool { sessions.contains { $0.pending != nil } }

    /// The sessions the island shows: all but the ones hidden.
    var visible: [SessionInfo] { sessions.filter { hidden[$0.id] == nil } }

    func hide(_ s: SessionInfo) {
        hidden[s.id] = HiddenSession(turns: s.turns, sawWork: s.status == "working")
        if selected == s.id { selected = nil }
        if visible.isEmpty { islandExpanded = false }
    }

    func unhide(_ id: String) { hidden[id] = nil }

    func unhideAll() { hidden = [:] }

    /// When something last happened in a chat the island shows (a turn started or ended, an ask came).
    var lastChange: Date {
        Date(timeIntervalSince1970: (visible.compactMap { eventAt[$0.id] }.max() ?? 0) / 1000)
    }

    /// The folder's name; when several sessions share a folder, the start of each one's first prompt too.
    func displayName(_ s: SessionInfo) -> String {
        let twins = sessions.filter { $0.project == s.project }
        guard twins.count > 1 else { return s.project }
        let title = s.title.trimmingCharacters(in: .whitespaces)
        if title.isEmpty {
            let n = (twins.firstIndex { $0.id == s.id } ?? 0) + 1
            return "\(s.project) #\(n)"
        }
        return "\(s.project) · \(title.count > 22 ? String(title.prefix(21)) + "…" : title)"
    }

    /// Whether the island is on screen.
    var shouldShow: Bool {
        if showSettings && islandExpanded { return true }
        // Hidden chats keep it on screen too: its settings are the way to show them again.
        guard !visible.isEmpty || !hidden.isEmpty else { return false }
        if alwaysShow { return true }
        if sessions.contains(where: { $0.pending != nil }) && !isInClaude { return true }
        return !isInClaude
    }

    func tick() {
        now = Date()
        frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if frontmost == Bundle.main.bundleIdentifier { frontmost = "" }
        loadSessions()
        loadLimits()
        writePresence()
        let live = flashes.filter { $0.value > now }
        if live.count != flashes.count { flashes = live }

    }

    private func loadLimits() {
        guard let data = try? Data(contentsOf: Paths.limits),
              let file = try? decoder.decode(LimitsFile.self, from: data) else { return }
        if file.limits != limits { limits = file.limits }
        // Crossing 80% and then 95% of the session window is announced once each, for a moment;
        // the level stays as a small mark until the window resets.
        let level = limitLevel
        if level > announcedLimitLevel { limitFlashUntil = Date().addingTimeInterval(3) }
        if level != announcedLimitLevel { announcedLimitLevel = level }
    }

    /// The session (five-hour) window's use: 0 below 80%, then 80 or 95.
    var limitLevel: Int {
        guard let used = limits.first(where: { $0.kind == "five_hour" })?.percentUsed else { return 0 }
        return used >= 95 ? 95 : used >= 80 ? 80 : 0
    }
    var sessionLimitPercent: Int { Int((limits.first { $0.kind == "five_hour" }?.percentUsed ?? 0).rounded()) }
    @Published var announcedLimitLevel = 0
    @Published var limitFlashUntil: Date = .distantPast
    var isAnnouncingLimit: Bool { limitFlashUntil > now }

    private func writePresence() {
        let body: [String: Any] = [
            "updatedAt": Date().timeIntervalSince1970 * 1000,
            "frontmost": frontmost,
            "routeAlways": routeAlways,
            "away": sessions.filter { host(of: $0) != frontmost }.map(\.id),
            "pid": ProcessInfo.processInfo.processIdentifier,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: body) {
            try? data.write(to: Paths.presence, options: .atomic)
        }
    }

    private func loadSessions() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Paths.sessions, includingPropertiesForKeys: nil)) ?? []
        let nowMs = Date().timeIntervalSince1970 * 1000
        var next: [SessionInfo] = []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let s = try? decoder.decode(SessionInfo.self, from: data) else { continue }
            let age = nowMs - s.updatedAt
            if age > 3_600_000 { try? fm.removeItem(at: url); continue } // long dead
            if age > 20_000 { continue } // no heartbeat: the session is gone
            // Never ran a turn: a pre-started spare process (`claude bg-spare`) or a chat not
            // yet used. Older mods publish these; the card comes with the first prompt.
            if s.status == "idle" && s.turns == 0 && s.pending == nil { continue }
            next.append(s)
        }
        // Newest event on top, as in a messenger: a chat moves only when something happens in it
        // (a turn starts or ends, an ask comes), never on a heartbeat or a tool change. A chat
        // first seen (the widget just started) counts from the start of its last turn.
        let seenAt = Date().timeIntervalSince1970 * 1000
        for s in next {
            let signature = "\(s.status)|\(s.pending?.id ?? "")|\(s.turns)"
            if let seen = lastState[s.id] {
                if seen != signature { eventAt[s.id] = seenAt }
            } else {
                eventAt[s.id] = s.turnStartedAt ?? 0
            }
            lastState[s.id] = signature
        }
        next.sort { a, b in
            let ea = eventAt[a.id] ?? 0, eb = eventAt[b.id] ?? 0
            return ea != eb ? ea > eb : a.id < b.id
        }
        // Hold the widget's own optimistic state until the mod's next write agrees, so a stale
        // read never brings back an ask already answered or a finished card already replied to.
        let cutoff = Date().addingTimeInterval(-5)
        sentAt = sentAt.filter { $0.value > cutoff }
        answeredAt = answeredAt.filter { $0.value > cutoff }
        stoppedAt = stoppedAt.filter { $0.value > cutoff }
        for i in next.indices {
            if stoppedAt[next[i].id] != nil {
                if next[i].status != "working" && next[i].status != "waiting" { stoppedAt[next[i].id] = nil }
                else {
                    next[i].status = "aborted"
                    next[i].pending = nil
                }
            }
            if let p = next[i].pending, answeredAt[p.id] != nil {
                next[i].pending = nil
                next[i].status = "working"
            }
            if sentAt[next[i].id] != nil {
                if next[i].status == "working" { sentAt[next[i].id] = nil } // the mod took it
                else {
                    next[i].status = "working"
                    next[i].activity = tr("Sent…", "Отправлено…")
                }
            }
        }
        notify(next)
        if next != sessions { sessions = next }
        updateHidden()
    }

    /// Brings hidden sessions back when they need the person, and forgets the ones gone.
    private func updateHidden() {
        guard !hidden.isEmpty else { return }
        var next = hidden.filter { id, _ in sessions.contains { $0.id == id } }
        for s in sessions {
            guard var h = next[s.id] else { continue }
            if s.status == "working" || s.turns != h.turns { h.sawWork = true }
            if s.pending != nil || (h.sawWork && s.status != "working") {
                next[s.id] = nil
            } else {
                next[s.id] = h
            }
        }
        if next != hidden { hidden = next }
    }

    private func notify(_ next: [SessionInfo]) {
        for s in next {
            if let p = s.pending, !seenPending.contains(p.id) {
                seenPending.insert(p.id)
                if !isInClaude { Sounds.play(askSound) }
                // The bell rings in the compact island; the ask opens when the person taps it.
                if !islandExpanded { selected = s.id }
            }
            let doneKey = "\(s.id)#\(s.turns)"
            if s.status == "done", !seenDone.contains(doneKey) {
                let wasKnown = sessions.contains { $0.id == s.id && $0.status != "done" }
                seenDone.insert(doneKey)
                if wasKnown {
                    if !isInClaude { Sounds.play(doneSound) }
                    // Announce it in the island for a moment, then keep a mark until it is seen.
                    flashes[s.id] = Date().addingTimeInterval(3)
                    unseen.insert(s.id)
                }
            }
            if s.status != "done" { unseen.remove(s.id) } // a new turn: nothing left to see
        }
    }

    // MARK: actions

    private func writeJSON(_ object: Any, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        // Write beside, then move: the mod must never read half a file.
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        try? data.write(to: tmp)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.moveItem(at: tmp, to: url)
    }

    func answer(_ session: SessionInfo, pending: Pending, payload: [String: Any]) {
        let url = Paths.answers.appendingPathComponent(session.id, isDirectory: true)
            .appendingPathComponent("\(pending.id).json")
        writeJSON(payload, to: url)
        answeredAt[pending.id] = Date()
        // Optimistic: hide the ask until the mod's next write confirms.
        if let i = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[i].pending = nil
            sessions[i].status = "working"
        }
        // Straight on to the next decision waiting, if any (in the list's order).
        if let nextAsk = sessions.first(where: { $0.pending != nil }) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selected = nextAsk.id }
        }
    }

    func sendPrompt(_ session: SessionInfo, text: String) {
        let url = Paths.inbox.appendingPathComponent("\(session.id).json")
        writeJSON(["text": text], to: url)
        sentAt[session.id] = Date()
        if let i = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[i].status = "working"
            sessions[i].activity = tr("Sent…", "Отправлено…")
        }
    }

    /// Ends the session's running turn, as Esc in the terminal does.
    func stop(_ session: SessionInfo) {
        try? FileManager.default.createDirectory(at: Paths.stop, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: Paths.stop.appendingPathComponent(session.id).path, contents: nil)
        stoppedAt[session.id] = Date()
        if let i = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[i].status = "aborted"
            sessions[i].pending = nil
        }
    }

    /// Brings forward the session itself: its tab in Terminal or iTerm2, its folder's window in
    /// an editor, else just the app it lives in.
    func open(_ session: SessionInfo) {
        let resolved = host(of: session)
        let id = resolved.isEmpty ? "com.apple.Terminal" : resolved
        let activate = {
            NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.activate()
        }
        if let script = focusTTYScripts[id], let pid = session.pid, let tty = ttyPath(forPid: pid) {
            // osascript, off the main thread: the first use waits on the Automation consent dialog.
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", script, tty]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                let found = (try? p.run()) != nil && {
                    p.waitUntilExit()
                    let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    return p.terminationStatus == 0 && text.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
                }()
                if !found { DispatchQueue.main.async { _ = activate() } }
            }
        } else if folderWindowApps.contains(id), !session.cwd.isEmpty,
                  let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([URL(fileURLWithPath: session.cwd, isDirectory: true)],
                                    withApplicationAt: app, configuration: config)
        } else {
            _ = activate()
        }
    }
}

// MARK: - Markdown

/// Inline markdown (**bold**, *italic*, `code`, [links](...)); plain text when it does not parse.
func inlineMD(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    var out = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    autolink(&out)
    return out
}

let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

/// Makes bare URLs clickable too (markdown only links `[text](url)` and `<url>`).
func autolink(_ attr: inout AttributedString) {
    guard let detector = linkDetector else { return }
    let plain = String(attr.characters)
    for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
        guard let url = match.url, let r = Range(match.range, in: plain),
              let lo = AttributedString.Index(r.lowerBound, within: attr),
              let hi = AttributedString.Index(r.upperBound, within: attr) else { continue }
        if attr[lo..<hi].runs.contains(where: { $0.link != nil }) { continue }
        attr[lo..<hi].link = url
    }
    for run in attr.runs where run.link != nil {
        attr[run.range].foregroundColor = .hudAccent
        attr[run.range].underlineStyle = .single
    }
}

/// A run of inline markdown, selectable with the mouse. Selectable text on macOS swallows clicks
/// on links, so a run that holds a link stays clickable instead of selectable.
struct MDText: View {
    let attr: AttributedString
    init(_ text: String) { attr = inlineMD(text) }

    var body: some View {
        if attr.runs.contains(where: { $0.link != nil }) {
            Text(attr)
        } else {
            Text(attr).textSelection(.enabled)
        }
    }
}

extension Optional where Wrapped: Collection {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}

/// One exchange: the prompt (the person's as their bubble, an agent's as a quiet foldable line),
/// then the answer, or what Claude is doing while it is still being written.
struct ExchangeView: View {
    let exchange: Exchange
    let isRunning: Bool
    let activity: String
    @State private var showAgentText = false

    var prompt: String { unframe(exchange.prompt).trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if exchange.from == "agent" {
                // Not the person's words: a subagent's report or a task notification.
                Button { withAnimation(.easeOut(duration: 0.15)) { showAgentText.toggle() } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "person.2.fill").font(.system(size: 9))
                        Text(tr("Message from an agent", "Сообщение от агента"))
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(showAgentText ? 90 : 0))
                    }
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                if showAgentText {
                    Text(prompt).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(12).textSelection(.enabled)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                }
            } else if !prompt.isEmpty {
                // What the person asked, as their bubble, above the answer to it.
                Text(prompt)
                    .font(.system(size: 11))
                    .lineLimit(6)
                    .textSelection(.enabled)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.hudAccent.opacity(0.22)))
                    .frame(maxWidth: 300, alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(prompt)
            }
            if isRunning {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(modText(activity.isEmpty ? "Thinking…" : activity))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            } else if !exchange.answer.isEmpty {
                MarkdownView(text: modText(exchange.answer))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The subagents a chat is waiting on, each with what it is doing.
struct AgentList: View {
    let agents: [AgentCard]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr("Agents at work: \(agents.count)", "Работают агенты: \(agents.count)"))
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(agents) { a in
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(a.description.isEmpty ? a.type : a.description)
                        .font(.system(size: 11, weight: .medium)).lineLimit(1)
                    if !a.activity.isEmpty {
                        Text(a.activity).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
    }
}

/// A reply box on the native text view: grows a line at a time up to `maxLines`, then scrolls.
/// Return submits, Shift+Return (or Option+Return) breaks the line.
struct GrowingTextInput: View {
    @Binding var text: String
    var placeholder: String
    var maxLines = 6
    /// Take the keyboard as soon as it appears.
    var autoFocus = false
    var onSubmit: () -> Void
    @State private var height: CGFloat = 18

    var body: some View {
        GrowingTextView(text: $text, height: $height, maxLines: maxLines, autoFocus: autoFocus, onSubmit: onSubmit)
            .frame(height: height)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).font(.system(size: 11)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .allowsHitTesting(false)
                }
            }
    }
}

struct GrowingTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let maxLines: Int
    let autoFocus: Bool
    let onSubmit: () -> Void

    static let font = NSFont.systemFont(ofSize: 11)
    static let inset = NSSize(width: 4, height: 4)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let view = scroll.documentView as! NSTextView
        view.delegate = context.coordinator
        view.font = Self.font
        view.textColor = .labelColor
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.textContainerInset = Self.inset
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.string = text
        DispatchQueue.main.async {
            context.coordinator.measure(view)
            if autoFocus { view.window?.makeFirstResponder(view) }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let view = scroll.documentView as! NSTextView
        if view.string != text {
            view.string = text // cleared after sending
            context.coordinator.measure(view)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingTextView
        init(_ parent: GrowingTextView) { self.parent = parent }

        func textDidChange(_ note: Notification) {
            guard let view = note.object as? NSTextView else { return }
            parent.text = view.string
            measure(view)
        }

        /// Return submits; Shift+Return and Option+Return break the line.
        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    view.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit()
                }
                return true
            }
            return false
        }

        /// As tall as the text, between one line and maxLines; past that the view scrolls.
        func measure(_ view: NSTextView) {
            guard let layout = view.layoutManager, let container = view.textContainer else { return }
            layout.ensureLayout(for: container)
            let line = layout.defaultLineHeight(for: GrowingTextView.font)
            let used = max(layout.usedRect(for: container).height, line)
            let inset = GrowingTextView.inset.height * 2
            let target = min(used, line * CGFloat(parent.maxLines)) + inset
            if abs(parent.height - target) > 0.5 {
                DispatchQueue.main.async { self.parent.height = target }
            }
            view.scrollRangeToVisible(view.selectedRange())
        }
    }
}

/// A code block with a copy button in its corner: what Claude hands over to paste somewhere.
struct CodeBlock: View {
    let text: String
    let size: CGFloat
    @State private var copied = false

    var body: some View {
        Text(text).font(.system(size: size - 1, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .padding(.trailing, 20) // room for the button
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
            .overlay(alignment: .topTrailing) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    withAnimation(.easeOut(duration: 0.15)) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation(.easeOut(duration: 0.2)) { copied = false }
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(copied ? Color.green : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(copied ? tr("Copied", "Скопировано") : tr("Copy", "Скопировать"))
                .padding(3)
            }
    }
}

/// A table as tab-separated text: pastes into Numbers or Sheets as a table.
func tableTSV(_ header: [String], _ rows: [[String]]) -> String {
    ([header] + rows).map { $0.joined(separator: "\t") }.joined(separator: "\n")
}

/// In the island: the header and the first rows, fitted to its width, and a way to open it whole.
struct MarkdownTable: View {
    @EnvironmentObject var store: Store
    let header: [String]
    let rows: [[String]]
    let size: CGFloat
    let previewRows = 3

    var columns: Int { max(header.count, rows.map(\.count).max() ?? 0) }
    func cell(_ row: [String], _ i: Int) -> String { i < row.count ? row[i] : "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { i in
                        Text(inlineMD(cell(header, i))).fontWeight(.semibold)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                ForEach(Array(rows.prefix(previewRows).enumerated()), id: \.offset) { _, row in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(0..<columns, id: \.self) { i in
                            Text(inlineMD(cell(row, i))).lineLimit(1).truncationMode(.tail)
                        }
                    }
                }
            }
            .font(.system(size: size))
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            Button { store.openTable(header, rows) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                    Text(rows.count > previewRows ? tr("Open table · \(rows.count) rows", "Открыть таблицу · \(rows.count) строк")
                         : tr("Open table", "Открыть таблицу"))
                }
                .font(.system(size: size - 1, weight: .medium))
                .foregroundStyle(Color.hudAccent)
            }
            .buttonStyle(.plain)
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        .contentShape(Rectangle())
        .onTapGesture { store.openTable(header, rows) }
    }
}

/// The whole table's grid: wrapping cells up to 280 pt, selectable text.
struct TableGrid: View {
    let header: [String]
    let rows: [[String]]
    static let maxColumn: CGFloat = 280

    var columns: Int { max(header.count, rows.map(\.count).max() ?? 0) }
    func cell(_ row: [String], _ i: Int) -> String { i < row.count ? row[i] : "" }

    /// Each column as wide as its longest cell, up to maxColumn. Set explicitly: inside a view that
    /// scrolls both ways a cell gets no width offered, measures as one line, then wraps over the next row.
    var widths: [CGFloat] {
        let body = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 12)]
        let bold = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]
        return (0..<columns).map { i in
            let texts = [(cell(header, i), bold)] + rows.map { (cell($0, i), body) }
            let widest = texts.map { text, attrs in
                (String(inlineMD(text).characters) as NSString).size(withAttributes: attrs).width
            }.max() ?? 0
            return min(ceil(widest) + 2, Self.maxColumn)
        }
    }

    var body: some View {
        let widths = self.widths
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
            GridRow(alignment: .top) {
                ForEach(0..<columns, id: \.self) { i in
                    Text(inlineMD(cell(header, i))).fontWeight(.semibold)
                        .frame(width: widths[i], alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow(alignment: .top) {
                    ForEach(0..<columns, id: \.self) { i in
                        Text(inlineMD(cell(row, i)))
                            .frame(width: widths[i], alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .font(.system(size: 12))
        .textSelection(.enabled)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 16)
    }
}

/// The whole table, in its own window dressed like the island: black, a header with copy and close.
struct TableWindowView: View {
    let header: [String]
    let rows: [[String]]
    let onClose: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("✳︎").font(.system(size: 13, weight: .bold)).foregroundStyle(Color.hudAccent)
                Text(tr("Table", "Таблица")).font(.system(size: 12, weight: .semibold))
                Text(tr("\(rows.count) rows", "\(rows.count) строк")).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tableTSV(header, rows), forType: .string)
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { copied = false } }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(copied ? Color.green : .secondary)
                }
                .buttonStyle(.plain)
                .help(tr("Copy as a table (pastes into Numbers and Google Sheets)", "Скопировать как таблицу (вставляется в Numbers и Google Sheets)"))
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(tr("Close (Esc)", "Закрыть (Esc)"))
            }
            .font(.system(size: 12))
            .padding(.horizontal, 16)
            .frame(height: 38)
            ScrollView([.horizontal, .vertical]) {
                TableGrid(header: header, rows: rows)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        .environment(\.openURL, OpenURLAction { url in
            NSWorkspace.shared.open(url)
            return .handled
        })
    }
}

/// Block-level markdown as Claude writes it: headings, lists, quotes, code fences, rules.
struct MarkdownView: View {
    let text: String
    var size: CGFloat = 11

    enum Block: Hashable {
        case heading(Int, String)
        case bullet(String, Int)
        case numbered(String, String, Int)
        case quote(String)
        case code(String)
        case rule
        case paragraph(String)
        case table(header: [String], rows: [[String]])
    }

    static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("|") && t.contains("-") && t.allSatisfy { "|-: ".contains($0) }
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]? = nil
        var table: [[String]] = []
        func flushTable() {
            guard !table.isEmpty else { return }
            blocks.append(.table(header: table[0], rows: Array(table.dropFirst())))
            table = []
        }
        func flush() {
            flushTable()
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { blocks.append(.code(c.joined(separator: "\n"))); code = nil }
                else { flush(); code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }
            if line.hasPrefix("|") {
                if paragraph.isEmpty == false { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
                if !isTableSeparator(line) { table.append(cells(line)) }
                continue
            }
            flushTable()
            let indent = (raw.prefix { $0 == " " }.count) / 2
            if line.isEmpty { flush(); continue }
            if let m = line.range(of: #"^#{1,6} "#, options: .regularExpression) {
                flush(); blocks.append(.heading(line.distance(from: m.lowerBound, to: m.upperBound) - 1, String(line[m.upperBound...])))
            } else if line == "---" || line == "***" || line == "___" {
                flush(); blocks.append(.rule)
            } else if let m = line.range(of: #"^[-*+] "#, options: .regularExpression) {
                flush(); blocks.append(.bullet(String(line[m.upperBound...]), indent))
            } else if let m = line.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                flush()
                let marker = String(line[m]).trimmingCharacters(in: .whitespaces)
                blocks.append(.numbered(marker, String(line[m.upperBound...]), indent))
            } else if line.hasPrefix(">") {
                flush(); blocks.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(line)
            }
        }
        if let c = code { blocks.append(.code(c.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case let .heading(level, t):
                    MDText(t).font(.system(size: size + (level <= 2 ? 2 : 1), weight: .semibold))
                        .padding(.top, 2)
                case let .bullet(t, indent):
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("•").foregroundStyle(.secondary)
                        MDText(t)
                    }
                    .padding(.leading, CGFloat(indent) * 12)
                case let .numbered(marker, t, indent):
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(marker).foregroundStyle(.secondary).monospacedDigit()
                        MDText(t)
                    }
                    .padding(.leading, CGFloat(indent) * 12)
                case let .quote(t):
                    MDText(t).foregroundStyle(.secondary)
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 2) }
                case let .code(t):
                    CodeBlock(text: t, size: size)
                case .rule:
                    Divider()
                case let .paragraph(t):
                    MDText(t)
                case let .table(header, rows):
                    MarkdownTable(header: header, rows: rows, size: size)
                }
            }
        }
        .font(.system(size: size))
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Views

struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A scroll view as tall as its content up to `maxHeight` (a bare ScrollView fits to zero in the panel).
struct CappedScroll<Content: View>: View {
    let maxHeight: CGFloat
    var fromBottom = false
    @ViewBuilder let content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            content.background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
        }
        // Native feel: no rubber-band and no scrolling at all when the text fits; when it does
        // not, an ordinary scroll with the system's overlay scroller.
        .scrollBounceBehavior(.basedOnSize)
        .scrollDisabled(height <= maxHeight)
        .scrollIndicators(.automatic)
        .defaultScrollAnchor(fromBottom ? .bottom : .top)
        .onPreferenceChange(HeightKey.self) { height = $0 }
        .frame(height: min(max(height, 1), maxHeight))
    }
}

extension Color {
    static let hudAccent = Color(red: 0.85, green: 0.47, blue: 0.34) // Claude orange
}

func statusColor(_ s: SessionInfo) -> Color {
    if s.pending != nil { return .yellow }
    switch s.status {
    case "working": return .hudAccent
    case "done": return .green
    case "error": return .red
    case "aborted": return .gray
    default: return .secondary
    }
}

func statusText(_ s: SessionInfo, now: Date) -> String {
    if let p = s.pending { return p.kind == "question" ? tr("needs an answer", "ждёт ответа") : tr("needs permission", "нужно разрешение") }
    switch s.status {
    case "working":
        if let start = s.turnStartedAt {
            let sec = Int(now.timeIntervalSince1970 - start / 1000)
            return sec < 60 ? tr("working · \(sec)s", "работает · \(sec)с")
                : tr("working · \(sec / 60)m \(sec % 60)s", "работает · \(sec / 60)м \(sec % 60)с")
        }
        return tr("working", "работает")
    case "done": return tr("done", "готово")
    case "error": return tr("error", "ошибка")
    case "aborted": return tr("stopped", "прервано")
    default: return tr("idle", "ожидает")
    }
}

struct PulseDot: View {
    var color: Color
    var animating: Bool
    @State private var on = false
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .opacity(animating ? (on ? 1 : 0.35) : 1)
            .onAppear {
                guard animating else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever()) { on = true }
            }
    }
}

struct QuestionView: View {
    @EnvironmentObject var store: Store
    let session: SessionInfo
    let pending: Pending
    @State private var picks: [Int: Set<String>] = [:]
    @State private var other: [Int: String] = [:]

    var questions: [Question] { pending.questions ?? [] }

    func value(_ i: Int) -> String? {
        let typed = (other[i] ?? "").trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty { return typed }
        let set = picks[i] ?? []
        guard !set.isEmpty else { return nil }
        let order = (questions[i].options ?? []).map(\.label).filter(set.contains)
        return order.joined(separator: ", ")
    }

    var complete: Bool { questions.indices.allSatisfy { value($0) != nil } }

    func submit() {
        var answers: [String: String] = [:]
        for i in questions.indices { answers[questions[i].question] = value(i) ?? "" }
        store.answer(session, pending: pending, payload: ["answers": answers])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(questions.enumerated()), id: \.offset) { i, q in
                VStack(alignment: .leading, spacing: 5) {
                    if let h = q.header, !h.isEmpty {
                        Text(h.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    Text(inlineMD(q.question)).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    ForEach(q.options ?? [], id: \.label) { opt in
                        let chosen = picks[i]?.contains(opt.label) ?? false
                        Button {
                            var set = picks[i] ?? []
                            if q.multiSelect == true {
                                if chosen { set.remove(opt.label) } else { set.insert(opt.label) }
                            } else {
                                set = [opt.label]
                            }
                            picks[i] = set
                            other[i] = ""
                            if questions.count == 1 && q.multiSelect != true { submit() }
                        } label: {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: q.multiSelect == true
                                      ? (chosen ? "checkmark.square.fill" : "square")
                                      : (chosen ? "largecircle.fill.circle" : "circle"))
                                    .foregroundStyle(chosen ? Color.hudAccent : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(opt.label).font(.system(size: 12))
                                    if let d = opt.description, !d.isEmpty {
                                        Text(inlineMD(d)).font(.system(size: 10)).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 5).padding(.horizontal, 7)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(chosen ? Color.hudAccent.opacity(0.15) : Color.primary.opacity(0.05)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    TextField(tr("Other…", "Другое…"), text: Binding(
                        get: { other[i] ?? "" },
                        set: { other[i] = $0; if !$0.isEmpty { picks[i] = [] } }))
                        .textFieldStyle(.roundedBorder).font(.system(size: 11))
                        .onSubmit { if complete { submit() } }
                }
            }
            if questions.count > 1 || questions.contains(where: { $0.multiSelect == true }) {
                HStack {
                    Spacer()
                    Button(tr("Answer", "Ответить"), action: submit).disabled(!complete)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

struct PermissionView: View {
    @EnvironmentObject var store: Store
    let session: SessionInfo
    let pending: Pending
    @State private var showDetail = false
    @State private var reason = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "lock.shield").foregroundStyle(.yellow)
                Text(pending.tool ?? "Tool").font(.system(size: 11, weight: .semibold))
                Text(inlineMD(pending.summary ?? "")).font(.system(size: 11)).lineLimit(2)
            }
            if let d = pending.detail, !d.isEmpty {
                CappedScroll(maxHeight: showDetail ? 220 : 54) {
                    Text(d).font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                .onTapGesture { showDetail.toggle() }
            }
            TextField(tr("Reason to deny (optional)", "Причина отказа (необязательно)"), text: $reason)
                .textFieldStyle(.roundedBorder).font(.system(size: 11))
            HStack(spacing: 6) {
                Button(tr("Deny", "Отклонить")) {
                    store.answer(session, pending: pending, payload: ["decision": "deny", "message": reason])
                }
                Spacer()
                if pending.canAlways == true {
                    Button(tr("Always", "Всегда")) { store.answer(session, pending: pending, payload: ["decision": "always"]) }
                }
                Button(tr("Allow", "Разрешить")) { store.answer(session, pending: pending, payload: ["decision": "allow"]) }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
    }
}

struct SessionCard: View {
    @EnvironmentObject var store: Store
    let session: SessionInfo
    /// The island's row already names the session; its detail leaves the header out.
    var showHeader = true
    /// The chat's last exchanges; an older mod gives only the last prompt and answer.
    var conversation: [Exchange] {
        if let history = session.history, !history.isEmpty { return history }
        let prompt = unframe(session.lastPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || !session.lastText.isEmpty else { return [] }
        return [Exchange(from: session.lastPromptFrom ?? "you", prompt: prompt, answer: session.lastText)]
    }

    var reply: Binding<String> {
        Binding(get: { store.drafts[session.id] ?? "" }, set: { store.drafts[session.id] = $0 })
    }
    @State private var expanded = false

    var doneTasks: Int { session.tasks.filter { $0.status == "completed" }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if showHeader { HStack(spacing: 6) {
                PulseDot(color: statusColor(session), animating: session.status == "working" || session.pending != nil)
                Text(session.project).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(statusText(session, now: store.now)).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if session.status == "working" || session.pending != nil {
                    Button { store.stop(session) } label: { Image(systemName: "stop.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help(tr("Stop (like Esc in the terminal)", "Остановить (как Esc в терминале)"))
                }
                Button { store.open(session) } label: { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(tr("Go to the session in \(session.hostName.isEmpty ? "Terminal" : session.hostName)", "Перейти в сессию в \(session.hostName.isEmpty ? "терминале" : session.hostName)"))
            } }
            if showHeader, !session.title.isEmpty {
                Text(session.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }

            if !session.tasks.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: Double(doneTasks), total: Double(max(session.tasks.count, 1)))
                        .tint(.hudAccent)
                    HStack {
                        Text(tr("\(doneTasks)/\(session.tasks.count) tasks", "\(doneTasks)/\(session.tasks.count) задач")).font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                        Button(expanded ? tr("less", "скрыть") : tr("all", "все")) { expanded.toggle() }
                            .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Color.hudAccent)
                    }
                    ForEach(session.tasks.filter { expanded || $0.status == "in_progress" }, id: \.self) { t in
                        HStack(spacing: 5) {
                            Image(systemName: t.status == "completed" ? "checkmark.circle.fill"
                                  : t.status == "in_progress" ? "circle.dotted" : "circle")
                                .font(.system(size: 10))
                                .foregroundStyle(t.status == "completed" ? .green : t.status == "in_progress" ? Color.hudAccent : .secondary)
                            Text(t.subject).font(.system(size: 11)).lineLimit(1)
                                .strikethrough(t.status == "completed").foregroundStyle(t.status == "completed" ? .secondary : .primary)
                        }
                    }
                }
            }

            if showHeader, session.status == "working", session.pending == nil, !session.activity.isEmpty {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(modText(session.activity)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            if let p = session.pending {
                Group {
                    if p.kind == "question" { QuestionView(session: session, pending: p) }
                    else { PermissionView(session: session, pending: p) }
                }
                .id(p.id)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.yellow.opacity(0.6)))
            } else {
                let isWorking = session.status == "working"
                if !session.agents.isNilOrEmpty {
                    AgentList(agents: session.agents ?? [])
                }
                let exchanges = conversation
                if !exchanges.isEmpty {
                    CappedScroll(maxHeight: 260, fromBottom: true) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(exchanges.enumerated()), id: \.offset) { index, x in
                                ExchangeView(exchange: x, isRunning: isWorking && index == exchanges.count - 1,
                                             activity: session.activity)
                            }
                        }
                    }
                }
                HStack(alignment: .bottom, spacing: 6) {
                    // Return sends; Shift+Return breaks the line (see the keyDown monitor).
                    GrowingTextInput(text: reply,
                                     placeholder: isWorking ? tr("Sends when this turn ends…", "Отправится после текущего хода…")
                                                            : tr("Reply to Claude…", "Ответить Claude…"),
                                     autoFocus: !showHeader, onSubmit: send)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
                        // Opened in the island, the reply takes the keyboard at once, so typing
                        // never lands in the app beneath.
                        .onAppear {
                            guard !showHeader else { return }
                            store.focusIsland()
                        }
                    let empty = reply.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 17))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(empty ? Color.secondary.opacity(0.5) : Color.hudAccent)
                    .animation(.easeOut(duration: 0.15), value: empty)
                    .disabled(empty)
                    .help(tr("Send (⏎)", "Отправить (⏎)"))
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    func send() {
        let text = reply.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.sendPrompt(session, text: text)
        store.drafts[session.id] = nil
    }
}

// MARK: - Island

/// The SF Symbol for what a session is doing right now.
func toolSymbol(_ tool: String?) -> String {
    switch tool ?? "" {
    case "Bash", "BashOutput", "KillShell": return "terminal"
    case "Edit", "Write", "NotebookEdit", "MultiEdit": return "pencil"
    case "Read": return "doc.text"
    case "Grep", "Glob", "ToolSearch": return "magnifyingglass"
    case "WebFetch", "WebSearch": return "globe"
    case "Agent", "Task": return "person.2"
    case "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList": return "checklist"
    case "compact": return "arrow.down.right.and.arrow.up.left" // the mod's own: /compact running
    case "": return "sparkle"
    case let t where t.hasPrefix("mcp__"): return "puzzlepiece.extension"
    default: return "gearshape"
    }
}

/// How far a session's tasks are, as a small ring.
struct ProgressRing: View {
    let fraction: Double
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.2), lineWidth: 2)
            Circle().trim(from: 0, to: max(0.04, fraction))
                .stroke(Color.hudAccent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: fraction)
        }
        .frame(width: 12, height: 12)
    }
}

/// One dot per task: done filled, current pulsing, the rest hollow.
struct StepDots: View {
    let tasks: [TaskItem]
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(tasks, id: \.self) { t in
                Circle()
                    .fill(t.status == "completed" ? Color.hudAccent
                          : t.status == "in_progress" ? Color.hudAccent.opacity(pulse ? 1 : 0.3)
                          : Color.white.opacity(0.22))
                    .frame(width: 5, height: 5)
                    .scaleEffect(t.status == "in_progress" && pulse ? 1.25 : 1)
            }
        }
        .onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever()) { pulse = true } }
    }
}

/// The notch's silhouette: flush with the top edge, flared ears up there, rounded below.
struct NotchShape: Shape {
    var ear: CGFloat = 8
    var radius: CGFloat
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height
        let rb = min(radius, (h - ear) / 2, (w - 2 * ear) / 2)
        p.move(to: CGPoint(x: 0, y: 0))
        p.addQuadCurve(to: CGPoint(x: ear, y: ear), control: CGPoint(x: ear, y: 0))
        p.addLine(to: CGPoint(x: ear, y: h - rb))
        p.addQuadCurve(to: CGPoint(x: ear + rb, y: h), control: CGPoint(x: ear, y: h))
        p.addLine(to: CGPoint(x: w - ear - rb, y: h))
        p.addQuadCurve(to: CGPoint(x: w - ear, y: h - rb), control: CGPoint(x: w - ear, y: h))
        p.addLine(to: CGPoint(x: w - ear, y: ear))
        p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - ear, y: 0))
        p.closeSubpath()
        return p
    }
}

struct NotchMetrics {
    var width: CGFloat
    var height: CGFloat
    var hasNotch: Bool

    static func of(_ screen: NSScreen) -> NotchMetrics {
        if screen.safeAreaInsets.top > 0,
           let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            return NotchMetrics(width: screen.frame.width - l.width - r.width,
                                height: screen.safeAreaInsets.top, hasNotch: true)
        }
        return NotchMetrics(width: 0, height: max(NSStatusBar.system.thickness, 24), hasNotch: false)
    }

    /// The screen with a notch, else the main one.
    static var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }
}

/// Whether the island's detail for a session holds anything its row does not already say.
func hasDetail(_ s: SessionInfo) -> Bool {
    true // every chat opens: at the least its prompt and the reply box
}

/// One line per session in the open island: what it is doing, how far along; a tap opens its detail.
struct SessionRow: View {
    @EnvironmentObject var store: Store
    let session: SessionInfo
    @State private var hovered = false

    var isOpen: Bool { store.selected == session.id }
    var done: Int { session.tasks.filter { $0.status == "completed" }.count }

    /// The state in words, for the glyph's tooltip.
    var line: String {
        if let p = session.pending { return p.kind == "question" ? tr("needs a decision", "ждёт решения") : tr("needs permission", "ждёт разрешения") }
        switch session.status {
        case "working": return session.activity.isEmpty ? tr("working", "работает") : modText(session.activity)
        case "done": return tr("done", "готово")
        case "error": return tr("error", "ошибка")
        case "aborted": return tr("stopped", "прервано")
        default: return tr("idle", "ожидает")
        }
    }

    @ViewBuilder var glyph: some View {
        if session.pending != nil {
            Image(systemName: "bell.fill").foregroundStyle(.yellow)
                .symbolEffect(.bounce, options: .repeating.speed(0.6))
        } else if session.status == "working" {
            Image(systemName: toolSymbol(session.tool)).foregroundStyle(Color.hudAccent)
                .symbolEffect(.pulse, options: .repeating)
                .contentTransition(.symbolEffect(.replace))
        } else if session.status == "done" {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if session.status == "error" {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        } else if session.status == "aborted" {
            Image(systemName: "stop.circle.fill").foregroundStyle(.gray)
        } else {
            Text("✳︎").font(.system(size: 13, weight: .bold)).foregroundStyle(Color.hudAccent.opacity(0.45))
        }
    }

    @ViewBuilder var trailing: some View {
        if session.pending == nil, session.status == "working" {
            if !session.tasks.isEmpty {
                HStack(spacing: 5) {
                    if session.tasks.count <= 8 { StepDots(tasks: session.tasks) }
                    Text("\(done * 100 / session.tasks.count)%")
                }
            } else if let start = session.turnStartedAt {
                let sec = max(0, Int(store.now.timeIntervalSince1970 - start / 1000))
                Text(String(format: "%d:%02d", sec / 60, sec % 60))
            }
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            // The glyph says the state; its words wait in the tooltip.
            glyph.frame(width: 16).help(line)
            if store.unseen.contains(session.id) {
                Circle().fill(Color.green).frame(width: 6, height: 6).help(tr("Finished while you were away", "Закончил, пока ты не смотрел"))
            }
            Text(store.displayName(session)).font(.system(size: 12, weight: .semibold)).lineLimit(1).layoutPriority(1)
            Spacer(minLength: 4)
            // Never squeezed: a long name truncates before the timer wraps.
            trailing.font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
            if hovered && (session.status == "working" || session.pending != nil) {
                Button { store.stop(session) } label: { Image(systemName: "stop.circle") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(tr("Stop (like Esc in the terminal)", "Остановить (как Esc в терминале)"))
            }
            Button { store.open(session) } label: { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(tr("Go to the session in \(session.hostName.isEmpty ? "Terminal" : session.hostName)", "Перейти в сессию в \(session.hostName.isEmpty ? "терминале" : session.hostName)"))
            // An ask can't be hidden: the session would wait on it unseen.
            if hovered && session.pending == nil {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { store.hide(session) }
                } label: { Image(systemName: "eye.slash") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(tr("Hide until it next needs you", "Скрыть из шторки до следующего ответа"))
            }
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .opacity(hasDetail(session) ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(
            session.pending != nil ? Color.yellow.opacity(0.12) : Color.white.opacity(isOpen ? 0.08 : 0.04)))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture {
            store.unseen.remove(session.id) // opened: seen
            guard hasDetail(session) else { return } // nothing to open: the row says it all
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                store.selected = isOpen ? nil : session.id
            }
        }
    }
}

/// Fades, blurs and shrinks toward the notch, as the Dynamic Island's content does: nothing slides.
struct DissolveModifier: ViewModifier {
    let isActive: Bool
    func body(content: Content) -> some View {
        content
            .opacity(isActive ? 0 : 1)
            .blur(radius: isActive ? 8 : 0)
            .scaleEffect(isActive ? 0.9 : 1, anchor: .top)
    }
}

extension AnyTransition {
    static var dissolve: AnyTransition {
        .modifier(active: DissolveModifier(isActive: true), identity: DissolveModifier(isActive: false))
    }
}

/// The sounds the island can ring: its own soft ones (widget/Sounds, in the app's Resources),
/// then the system's, quietest first, each with a word on how it sounds.
enum Sounds {
    static let own: [(name: String, en: String, ru: String)] = [
        ("hud-drop", "drop", "капля"), ("hud-bubble", "bubble", "пузырёк"), ("hud-chime", "soft chime", "мягкий звон"),
        ("hud-duo", "two notes", "две ноты"), ("hud-bell", "low bell", "низкий колокол"),
    ]
    static let all: [(name: String, en: String, ru: String)] = [
        ("Tink", "click", "щелчок"), ("Pop", "bubble", "пузырёк"), ("Purr", "purr", "урчание"),
        ("Bottle", "bottle", "бутылка"), ("Morse", "double beep", "двойной бип"), ("Frog", "croak", "квак"),
        ("Glass", "glass", "стекло"), ("Ping", "ping", "пинг"), ("Hero", "fanfare", "фанфара"),
        ("Submarine", "sonar", "сонар"), ("Blow", "breath", "выдох"), ("Basso", "low", "низкий"),
        ("Funk", "funk", "фанк"), ("Sosumi", "sosumi", "сосуми"),
    ]

    /// An empty name is silence. Restarts the sound when it is already playing.
    static func play(_ name: String) {
        guard !name.isEmpty, let sound = NSSound(named: name) else { return }
        sound.stop()
        sound.play()
    }
}

/// What is left of the account's rate-limit windows, read for the rings and their details.
struct LimitReading {
    let limits: [RateLimit]
    let now: Date

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "HH:mm"
        return f
    }()
    static let dayTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "EE HH:mm"
        return f
    }()

    /// The session window outside, the week inside, anything else after them.
    var ordered: [RateLimit] {
        let rank = ["five_hour": 0, "seven_day": 1]
        return limits.sorted { rank[$0.kind, default: 2] < rank[$1.kind, default: 2] }
    }

    static func title(_ kind: String) -> String {
        switch kind {
        case "five_hour": tr("Session", "Сессия")
        case "seven_day": tr("Week", "Неделя")
        case "spend_limit": tr("Spend", "Расход")
        default: kind
        }
    }

    /// Green while little is spent, through yellow and orange, red as the window runs out.
    static func color(used: Double) -> Color {
        let t = min(1, max(0, used / 100))
        return Color(hue: 0.33 * (1 - t), saturation: 0.85, brightness: 0.95)
    }

    /// A window past its reset starts over: nothing of it is used until the next reading.
    func used(_ l: RateLimit) -> Double {
        if let reset = l.resetDate, reset <= now { return 0 }
        return min(100, max(0, l.percentUsed))
    }

    /// The session window counts down to its reset; the others name the moment.
    func reset(_ l: RateLimit) -> String {
        if l.kind == "five_hour" { return countdown(l) }
        guard let d = l.resetDate, d > now else { return "" }
        let f = Calendar.current.isDate(d, inSameDayAs: now) ? Self.time : Self.dayTime
        f.locale = Locale(identifier: isRussian ? "ru_RU" : "en_US")
        return tr("resets ", "сброс ") + f.string(from: d)
    }

    /// "resets in 4h 25m": hours and minutes left, never seconds (a last minute shows as 1m).
    func countdown(_ l: RateLimit) -> String {
        guard let d = l.resetDate, d > now else { return "" }
        let minutes = max(1, Int((d.timeIntervalSince(now) / 60).rounded(.up)))
        let h = minutes / 60, m = minutes % 60
        let left = h > 0 ? tr("\(h)h \(m)m", "\(h) ч \(m) м") : tr("\(m)m", "\(m) м")
        return tr("resets in ", "сброс через ") + left
    }

    /// The session window, the one the countdown beside the rings speaks for.
    var session: RateLimit? { limits.first { $0.kind == "five_hour" } }

    var summary: String {
        ordered.map { l in
            let r = reset(l)
            return "\(Self.title(l.kind)): " + tr("\(Int(used(l).rounded()))% used", "потрачено \(Int(used(l).rounded()))%") + (r.isEmpty ? "" : ", \(r)")
        }.joined(separator: "\n")
    }
}

/// The limits as Apple Watch activity rings, the session outside and the week inside: each ring
/// fills as its window is spent and turns from green to red on the way.
struct LimitRings: View {
    let reading: LimitReading
    var size: CGFloat = 20
    var line: CGFloat = 3

    var body: some View {
        ZStack {
            ForEach(Array(reading.ordered.prefix(3).enumerated()), id: \.element.kind) { i, l in
                let d = size - CGFloat(i) * (line + 1) * 2
                let color = LimitReading.color(used: reading.used(l))
                Circle().stroke(color.opacity(0.22), lineWidth: line).frame(width: d - line, height: d - line)
                Circle()
                    .trim(from: 0, to: reading.used(l) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: d - line, height: d - line)
                    .animation(.easeInOut(duration: 0.6), value: reading.used(l))
            }
        }
        .frame(width: size, height: size)
    }
}

/// The rings with a line per window: how much is spent and when it comes back.
struct LimitDetails: View {
    let reading: LimitReading

    var body: some View {
        HStack(spacing: 12) {
            LimitRings(reading: reading, size: 56, line: 7)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(reading.ordered, id: \.kind) { l in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(LimitReading.title(l.kind) + tr(" · used", " · потрачено")).font(.system(size: 10)).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(Int(reading.used(l).rounded()))%")
                                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                                .foregroundStyle(LimitReading.color(used: reading.used(l)))
                            Text(reading.reset(l)).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

/// The island's settings, behind the gear in its header.
struct SettingsView: View {
    @EnvironmentObject var store: Store
    @AppStorage("alwaysShow") var alwaysShow = true // as Store's: one default, or the switch lies
    @AppStorage("routeAlways") var routeAlways = true
    @AppStorage("askSound") var askSound = "hud-chime"
    @AppStorage("doneSound") var doneSound = "hud-duo"
    @AppStorage("language") var language = "en"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            section(tr("Island", "Шторка"))
            toggle(tr("Always show", "Показывать всегда"), $alwaysShow)
            toggle(tr("Always send questions to the widget", "Отправлять вопросы в виджет всегда"), $routeAlways)
            section(tr("Sounds", "Звуки"))
            soundRow(tr("Question or permission", "Вопрос или разрешение"), $askSound)
            soundRow(tr("Session finished", "Сессия закончила"), $doneSound)
            section(tr("Language", "Язык"))
            Picker("", selection: $language) {
                Text("English").tag("en")
                Text("Русский").tag("ru")
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
            if !store.hidden.isEmpty {
                Button(tr("Show hidden chats (\(store.hidden.count))", "Показать скрытые чаты (\(store.hidden.count))")) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { store.unhideAll() }
                }
                .buttonStyle(.plain).foregroundStyle(Color.hudAccent)
            }
            Divider().padding(.top, 2)
            Button(tr("Quit Notch HUD", "Выйти из Notch HUD")) { NSApp.terminate(nil) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        // Showing always changes whether the island is on screen: let the app look again.
        .onChange(of: alwaysShow) { store.objectWillChange.send() }
        // Every view reads the language through tr(): have them all draw again.
        .onChange(of: language) { store.objectWillChange.send() }
    }

    func section(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
    }

    func toggle(_ title: String, _ on: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle("", isOn: on).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
    }

    func soundRow(_ title: String, _ sound: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Spacer()
            Picker("", selection: sound) {
                Text(tr("No sound", "Без звука")).tag("")
                Divider()
                Section(tr("Soft", "Мягкие")) {
                    ForEach(Sounds.own, id: \.name) { s in
                        let hint = tr(s.en, s.ru)
                        Text(hint.prefix(1).uppercased() + hint.dropFirst()).tag(s.name)
                    }
                }
                Section(tr("System", "Системные")) {
                    ForEach(Sounds.all, id: \.name) { Text("\($0.name) · \(tr($0.en, $0.ru))").tag($0.name) }
                }
            }
            .labelsHidden().fixedSize().controlSize(.small)
            // Picking a sound plays it at once.
            .onChange(of: sound.wrappedValue) { _, new in Sounds.play(new) }
            Button { Sounds.play(sound.wrappedValue) } label: { Image(systemName: "play.fill") }
                .buttonStyle(.plain).foregroundStyle(Color.hudAccent)
                .disabled(sound.wrappedValue.isEmpty)
                .help(tr("Play", "Прослушать"))
        }
    }
}

struct IslandView: View {
    @EnvironmentObject var store: Store
    /// The wider wing's own width, as last measured.
    @State private var showHidden = false
    @State private var showLimits = false
    let notch: NotchMetrics
    let ear: CGFloat = 8

    var items: [SessionInfo] { store.visible }
    var hiddenItems: [SessionInfo] { store.sessions.filter { store.hidden[$0.id] != nil } }
    var pendingCount: Int { items.filter { $0.pending != nil }.count }
    var working: [SessionInfo] { items.filter { $0.status == "working" && $0.pending == nil } }
    var spring: Animation { .spring(response: 0.35, dampingFraction: 0.8) }

    /// The session both wings speak for, so the icon and the progress never come from two sessions.
    /// By urgency, then by the list's fixed order: an ask, work, an error, an interrupted turn, the rest.
    var lead: SessionInfo? {
        items.first { $0.pending != nil }
            ?? working.first
            ?? items.first { $0.status == "error" }
            ?? items.first { $0.status == "aborted" }
            ?? items.first { $0.status == "done" }
            ?? items.first
    }

    /// The session that just finished, announced for a moment (an ask still comes first).
    var announcing: SessionInfo? {
        guard pendingCount == 0 else { return nil }
        return items.filter { (store.flashes[$0.id] ?? .distantPast) > store.now }
            .max { (store.flashes[$0.id] ?? .distantPast) < (store.flashes[$1.id] ?? .distantPast) }
    }

    /// Nothing needs the person and nothing has happened for a while: the island rests in a
    /// small still form, and wakes the moment work starts, an ask comes or a chat finishes.
    var quiet: Bool {
        !items.contains { $0.pending != nil || $0.status == "working" }
            && !items.contains { store.unseen.contains($0.id) }
            && announcing == nil
            && store.now.timeIntervalSince(store.lastChange) > 30
    }

    /// Left wing: the lead session's state, and how many sessions share it (when more than one).
    @ViewBuilder var leftWing: some View {
        leftIcon
            // Marks on the icon's corners instead of words: the session limit nearly spent
            // (orange, red from 95%), a chat finished that you have not opened (green).
            .overlay(alignment: .topTrailing) {
                if store.limitLevel > 0 && !store.isAnnouncingLimit {
                    cornerDot(store.limitLevel >= 95 ? .red : .orange)
                        .help(tr("Session limit \(store.sessionLimitPercent)% used", "Лимит сессии израсходован на \(store.sessionLimitPercent)%"))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if hasUnseen && announcing == nil { cornerDot(.green) }
            }
    }

    var hasUnseen: Bool { items.contains { store.unseen.contains($0.id) && $0.id != lead?.id } }

    func cornerDot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 5, height: 5)
            .overlay(Circle().stroke(Color.black, lineWidth: 1))
            .offset(x: 3, y: -1)
    }

    /// The lead session's state, one glyph.
    @ViewBuilder var leftIcon: some View {
        if quiet {
            Text("✳︎").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.hudAccent.opacity(0.4))
        } else if store.isAnnouncingLimit && pendingCount == 0 {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .foregroundStyle(store.limitLevel >= 95 ? Color.red : Color.orange)
                .symbolEffect(.bounce, value: store.announcedLimitLevel)
        } else if announcing != nil {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                .symbolEffect(.bounce, value: announcing?.id)
        } else if let s = lead {
            if s.pending != nil {
                Image(systemName: "bell.fill").foregroundStyle(.yellow)
                    .symbolEffect(.bounce, options: .repeating.speed(0.6))
            } else if s.status == "working" {
                Image(systemName: toolSymbol(s.tool))
                    .foregroundStyle(Color.hudAccent)
                    .symbolEffect(.pulse, options: .repeating)
                    .contentTransition(.symbolEffect(.replace))
            } else if s.status == "error" {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else if s.status == "aborted" {
                Image(systemName: "stop.circle.fill").foregroundStyle(.gray)
            } else if s.status == "done" {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Text("✳︎").font(.system(size: 13, weight: .bold)).foregroundStyle(Color.hudAccent.opacity(0.45))
            }
        }
    }

    /// Right wing: the same lead session's progress or outcome.
    /// The lead session's progress, one glyph: what kind of answer it needs, how far its tasks
    /// are, or that it is thinking. No words, so the island never changes width.
    @ViewBuilder var rightWing: some View {
        if quiet || announcing != nil || (store.isAnnouncingLimit && pendingCount == 0) {
            Circle().fill(.white.opacity(0.22)).frame(width: 4, height: 4)
        } else if let s = lead {
            if let p = s.pending {
                Image(systemName: p.kind == "permission" ? "lock.fill" : "questionmark")
                    .foregroundStyle(.yellow)
            } else if s.status == "working" {
                if !s.tasks.isEmpty {
                    let done = s.tasks.filter { $0.status == "completed" }.count
                    ProgressRing(fraction: Double(done) / Double(s.tasks.count))
                } else {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.white.opacity(0.85))
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                }
            } else {
                Circle().fill(.white.opacity(0.22)).frame(width: 4, height: 4)
            }
        }
    }

    var compact: some View {
        // Fixed wings, one glyph each, so the island keeps one width whatever happens and the gap
        // sits exactly under the notch.
        HStack(spacing: 0) {
            leftWing.frame(width: 22, alignment: .trailing)
            Color.clear.frame(width: max(notch.width, 24) + 8)
            rightWing.frame(width: 22, alignment: .leading)
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 10 + ear)
        .frame(height: notch.height)
        .contentShape(Rectangle())
        .onTapGesture {
            // Open on the ask waiting, or on the only session there is; the cross closes it.
            if let asking = items.first(where: { $0.pending != nil }) {
                store.selected = asking.id
            } else if items.count == 1, let only = items.first, hasDetail(only) {
                store.selected = only.id
            }
            store.showSettings = false
            withAnimation(spring) { store.islandExpanded = true }
        }
    }

    /// The hidden sessions, folded into one line; open, each can be shown again.
    var hiddenList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(spring) { showHidden.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "eye.slash")
                    Text(tr("Hidden: \(hiddenItems.count)", "Скрыто: \(hiddenItems.count)"))
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(showHidden ? 90 : 0))
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showHidden {
                ForEach(hiddenItems) { s in
                    HStack(spacing: 8) {
                        Text(store.displayName(s)).font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Button(tr("Show", "Показать")) {
                            withAnimation(spring) { store.unhide(s.id) }
                        }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.hudAccent)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                }
            }
        }
        .padding(.horizontal, 2)
    }

    var expanded: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("✳︎").font(.system(size: 13, weight: .bold)).foregroundStyle(Color.hudAccent)
                Text(store.showSettings ? tr("Settings", "Настройки")
                     : pendingCount > 0 ? tr("Needs you", "Нужно твоё действие")
                     : working.isEmpty ? tr("Done", "Готово") : tr("Working: \(working.count)", "Работает: \(working.count)"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if !store.limits.isEmpty {
                    let reading = LimitReading(limits: store.limits, now: store.now)
                    Button { withAnimation(spring) { showLimits.toggle() } } label: { LimitRings(reading: reading) }
                        .buttonStyle(.plain)
                        .help(reading.summary)
                        .onDisappear { showLimits = false }
                }
                Button {
                    withAnimation(spring) { store.showSettings.toggle() }
                } label: { Image(systemName: store.showSettings ? "gearshape.fill" : "gearshape") }
                    .buttonStyle(.plain)
                    .foregroundStyle(store.showSettings ? Color.hudAccent : .secondary)
                    .help(tr("Settings", "Настройки"))
                Button {
                    withAnimation(spring) { store.islandExpanded = false }
                } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(tr("Close", "Закрыть"))
            }
            .frame(minHeight: notch.hasNotch ? notch.height - 6 : 20)
            // A tap on the header's empty space closes the island too; its buttons keep their taps.
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(spring) { store.islandExpanded = false } }
            // The rings tapped open: their details, in the island's own palette.
            if showLimits && !store.limits.isEmpty {
                LimitDetails(reading: LimitReading(limits: store.limits, now: store.now)).transition(.opacity)
            }
            if store.showSettings {
                SettingsView().transition(.opacity)
            } else {

                VStack(spacing: 4) {
                    ForEach(items) { s in
                        SessionRow(session: s)
                        // The session tapped open (or opened on the ask when the island opened).
                        if store.selected == s.id && hasDetail(s) {
                            SessionCard(session: s, showHeader: false)
                                .transition(.asymmetric(
                                    insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.08)),
                                    removal: .opacity.animation(.easeIn(duration: 0.1))))
                        }
                    }
                }
            }
            if !hiddenItems.isEmpty { hiddenList }
        }
        .padding(.horizontal, 14 + ear)
        .padding(.top, 4)
        .padding(.bottom, 14)
        .frame(width: 400 + 2 * ear)
    }

    var body: some View {
        VStack(spacing: 0) {
            // One capsule that grows out of the notch and back: the content cross-fades inside
            // it while its shape springs between the two sizes, clipped so nothing spills over.
            ZStack(alignment: .top) {
                if store.islandExpanded {
                    expanded.transition(.asymmetric(
                        insertion: .dissolve.animation(.easeOut(duration: 0.24).delay(0.1)),
                        removal: .dissolve.animation(.easeIn(duration: 0.14))))
                } else {
                    compact.transition(.asymmetric(
                        insertion: .dissolve.animation(.easeOut(duration: 0.18).delay(0.16)),
                        removal: .dissolve.animation(.easeIn(duration: 0.08))))
                }
            }
            .background(NotchShape(ear: ear, radius: store.islandExpanded ? 24 : 12).fill(Color.black))
            .clipShape(NotchShape(ear: ear, radius: store.islandExpanded ? 24 : 12))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { store.islandRect = $0 }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: store.islandExpanded)
        .environment(\.colorScheme, .dark)
        .environment(\.openURL, OpenURLAction { url in
            NSWorkspace.shared.open(url)
            return .handled
        })
        .onHover { store.islandHovered = $0 }
    }
}

// MARK: - Window

final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true } // text fields need the keyboard
    override var canBecomeMain: Bool { false }

    /// The panel never activates the app, so the main menu may not see ⌘-keys: route the
    /// standard edit commands to whatever field holds the keyboard.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let action: Selector?
        switch (mods, key) {
        case (.command, "x"): action = #selector(NSText.cut(_:))
        case (.command, "c"): action = #selector(NSText.copy(_:))
        case (.command, "v"): action = #selector(NSText.paste(_:))
        case (.command, "a"): action = #selector(NSText.selectAll(_:))
        case (.command, "z"): action = Selector(("undo:"))
        case ([.command, .shift], "z"): action = Selector(("redo:"))
        default: action = nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = Store()
    var island: HUDPanel!
    var tableWindow: HUDPanel?
    var islandHosting: NSHostingView<AnyView>!
    var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ note: Notification) {
        // One HUD at a time: the mod may launch it while a copy from /Applications already runs.
        let me = ProcessInfo.processInfo.processIdentifier
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != me }) {
            NSApp.terminate(nil)
            return
        }
        island = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 32),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        island.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2) // over the menu bar
        island.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        island.isOpaque = false
        island.backgroundColor = .clear
        island.hasShadow = false
        island.hidesOnDeactivate = false
        island.becomesKeyOnlyIfNeeded = true
        island.acceptsMouseMovedEvents = true
        island.ignoresMouseEvents = true
        // Track the pointer everywhere so the stage takes clicks only over the capsule.
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.updateMousePassThrough()
        }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.updateMousePassThrough()
            return event
        }
        buildIsland()
        store.islandIsKey = { [weak self] in self?.island.isKeyWindow ?? false }
        store.focusIsland = { [weak self] in self?.island.makeKey() }
        store.openTable = { [weak self] header, rows in self?.showTable(header: header, rows: rows) }
        // A click anywhere outside the island (other apps, the desktop) closes it at once.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard let self, self.store.islandExpanded else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { self.store.islandExpanded = false }
            self.island.resignKey()
        }
        // Esc while typing in it closes it too.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Shift+Return in a multi-line field adds a line instead of submitting.
            if event.keyCode == 36,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift,
               let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                editor.insertNewlineIgnoringFieldEditor(nil)
                return nil
            }
            if event.keyCode == 53, let table = self?.tableWindow, table.isKeyWindow {
                table.close()
                return nil
            }
            guard let self, event.keyCode == 53, self.store.islandExpanded else { return event }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { self.store.islandExpanded = false }
            return nil
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.buildIsland(); self?.sync() }

        installEditMenu()

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in DispatchQueue.main.async { self?.sync() } }
            .store(in: &bag)
        sync()
    }

    func buildIsland() {
        let notch = NotchMetrics.screen.map(NotchMetrics.of) ?? NotchMetrics(width: 0, height: 24, hasNotch: false)
        islandHosting = NSHostingView(rootView: AnyView(IslandView(notch: notch).environmentObject(store)))
        island.contentView = islandHosting
    }

    /// A fixed, transparent stage centred on the notch: the capsule animates inside it, and the
    /// window never resizes (resizing is what made the open and close jump).
    func fitIsland() {
        guard let screen = NotchMetrics.screen else { return }
        let size = NSSize(width: 520, height: (screen.frame.height * 0.8).rounded())
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        if island.frame != frame { island.setFrame(frame, display: true) }
    }

    /// The stage lets the mouse through everywhere but over the capsule itself.
    func updateMousePassThrough() {
        guard island.isVisible else { return }
        let p = NSEvent.mouseLocation
        let local = CGPoint(x: p.x - island.frame.minX, y: island.frame.maxY - p.y)
        let inside = store.islandRect.insetBy(dx: -2, dy: -2).contains(local)
        if island.ignoresMouseEvents == inside { island.ignoresMouseEvents = !inside }
    }

    func sync() {
        let needIsland = store.shouldShow || store.hasPending
        if needIsland {
            fitIsland()
            if !island.isVisible { island.orderFrontRegardless() }
            updateMousePassThrough()
        } else if island.isVisible {
            island.orderOut(nil)
        }
        // Folded (by Esc, the cross or a click away), the island hands the keyboard back.
        if !store.islandExpanded && island.isKeyWindow {
            island.resignKey()
            NSWorkspace.shared.frontmostApplication?.activate()
        }
    }

    /// Opens a table whole in a window just under the notch, sized to the table (up to 80% of the screen).
    func showTable(header: [String], rows: [[String]]) {
        tableWindow?.close()
        // The open island would cover the window's top: fold it away.
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { store.islandExpanded = false }
        let window = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        window.title = tr("Table", "Таблица")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.delegate = self
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        let hosting = NSHostingView(rootView: TableWindowView(header: header, rows: rows) { [weak window] in
            window?.close()
        })
        window.contentView = hosting

        let screen = NotchMetrics.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        // A ScrollView measures to nothing: size the window by the grid alone.
        // The grid's ideal size (fixedSize), not its minimum, plus the header bar and the scroller.
        var fit = NSHostingView(rootView: TableGrid(header: header, rows: rows).fixedSize()).fittingSize
        fit.width += 20
        fit.height += 38 + 8
        let size = NSSize(width: min(max(fit.width, 320), visible.width * 0.8),
                          height: min(max(fit.height, 160), visible.height * 0.8))
        // Under the notch, beside the island when it is open.
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 12)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        tableWindow = window
    }

    /// Closing the table brings back the island open on the chat it came from.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === tableWindow else { return }
        tableWindow = nil
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { store.islandExpanded = true }
    }

    /// Text fields learn ⌘C/⌘V/⌘X/⌘A/⌘Z from the main menu's Edit items. An accessory app shows
    /// no menu bar, but key equivalents still route through this one.
    func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }
}

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
