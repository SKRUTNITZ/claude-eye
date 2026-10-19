// Claude Eye — a floating chat overlay for Claude Code on macOS.
// Turn on the 👁️ to attach screenshots of your screens to each message.

import AppKit
import AVFoundation
import Carbon.HIToolbox
import NaturalLanguage
import Speech
import SwiftUI
import UserNotifications

// MARK: - Helpers

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let support = home.appendingPathComponent("Library/Application Support/ClaudeEye")
    static let screenshots = support.appendingPathComponent("screenshots")
    static let history = support.appendingPathComponent("history.json")
    static let logFile = home.appendingPathComponent("Library/Logs/ClaudeEye.log")
    static let defaultWorkspace = home.appendingPathComponent("Claude Eye Workspace")
}

/// `--demo` fills the window with an example chat (for README screenshots) and saves nothing.
let demoMode = CommandLine.arguments.contains("--demo")

func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: Paths.logFile) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: Paths.logFile)
    }
}

/// Finds the `claude` command. GUI apps don't get the shell's PATH, so check the usual
/// install locations first, then ask a login shell.
func locateClaude() -> URL? {
    let fm = FileManager.default
    let candidates = [
        ".local/bin/claude", ".claude/local/claude", ".npm-global/bin/claude", ".bun/bin/claude",
    ].map { Paths.home.appendingPathComponent($0).path } + ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    if let found = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
        return URL(fileURLWithPath: found)
    }
    let shell = Process()
    shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
    shell.arguments = ["-lic", "command -v claude"]
    let out = Pipe()
    shell.standardOutput = out
    shell.standardError = FileHandle.nullDevice
    guard (try? shell.run()) != nil else { return nil }
    shell.waitUntilExit()
    let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
    return fm.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
}

/// Deletes screenshots older than a day; they can contain private information.
func cleanOldScreenshots() {
    let fm = FileManager.default
    let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
    let files = (try? fm.contentsOfDirectory(at: Paths.screenshots, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    for file in files {
        let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if date < cutoff { try? fm.removeItem(at: file) }
    }
}

func openScreenRecordingSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
        NSWorkspace.shared.open(url)
    }
}

/// The biggest visible window of the TradingView desktop app, if it's running.
/// `screencapture -l` can grab it even when other windows cover it.
func tradingViewWindowID() -> CGWindowID? {
    for options in [CGWindowListOption.optionOnScreenOnly, .optionAll] {
        let list = CGWindowListCopyWindowInfo([options, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = list.filter {
            ($0[kCGWindowOwnerName as String] as? String)?.localizedCaseInsensitiveContains("TradingView") == true
                && ($0[kCGWindowLayer as String] as? Int) == 0
        }
        func area(_ w: [String: Any]) -> CGFloat {
            let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            return (b["Width"] ?? 0) * (b["Height"] ?? 0)
        }
        if let best = windows.max(by: { area($0) < area($1) }), area(best) > 400 * 300,
           let id = best[kCGWindowNumber as String] as? Int {
            return CGWindowID(id)
        }
    }
    return nil
}

/// Markdown → plain text for reading aloud and notifications.
func plainText(_ markdown: String) -> String {
    var s = markdown.replacingOccurrences(of: "```[\\s\\S]*?```", with: " (code) ", options: .regularExpression)
    s = s.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)
    s = s.replacingOccurrences(of: "[*_`#>]", with: "", options: .regularExpression)
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Notifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    var onClick: (() -> Void)?

    func setup() {
        guard !demoMode else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if !granted { log("notifications not allowed \(error.map { "\($0)" } ?? "")") }
        }
    }

    func post(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(plainText(body).prefix(200))
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        DispatchQueue.main.async { self.onClick?() }
        done()
    }
}

// MARK: - Voice

/// Speech-to-text with Apple's recognizer. Calls `onText` with the live transcript.
final class Dictation {
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private(set) var listening = false
    var onText: ((String) -> Void)?
    var onError: ((String) -> Void)?

    func start(_ started: @escaping () -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    self.onError?("Voice input needs Speech Recognition permission: System Settings → Privacy & Security → Speech Recognition → Claude Eye.")
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        guard granted else {
                            self.onError?("Voice input needs Microphone permission: System Settings → Privacy & Security → Microphone → Claude Eye.")
                            return
                        }
                        if self.begin() { started() }
                    }
                }
            }
        }
    }

    private func begin() -> Bool {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            onError?("Speech recognition isn't available right now.")
            return false
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            onError?("No microphone found.")
            return false
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            onError?("Couldn't start the microphone: \(error.localizedDescription)")
            return false
        }
        self.request = request
        listening = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let text = result?.bestTranscription.formattedString {
                DispatchQueue.main.async { self?.onText?(text) }
            }
            if error != nil || result?.isFinal == true {
                DispatchQueue.main.async { self?.stop() }
            }
        }
        return true
    }

    func stop() {
        guard listening else { return }
        listening = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        task = nil
    }
}

/// Reads replies aloud in the language they're written in.
final class Speaker {
    private let synth = AVSpeechSynthesizer()

    func speak(_ markdown: String) {
        stop()
        let text = plainText(markdown)
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let lang = recognizer.dominantLanguage?.rawValue {
            let code = lang == "nb" || lang == "nn" ? "no" : lang
            utterance.voice = AVSpeechSynthesisVoice.speechVoices().first { $0.language.hasPrefix(code) || ($0.language.hasPrefix("nb") && code == "no") }
        }
        synth.speak(utterance)
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }
}

// MARK: - Model

struct ChatMessage: Identifiable, Codable {
    enum Role: String, Codable { case user, claude, system }
    var id = UUID()
    let role: Role
    var text: String
    var screenshots: [URL] = []
    var footer: String? = nil
}

/// A saved conversation. `sessionID` lets Claude Code resume it; sessions belong to a folder.
struct Chat: Identifiable, Codable {
    var id = UUID()
    var title = "New chat"
    var updated = Date()
    var folder: String
    var sessionID: String?
    var messages: [ChatMessage] = []

    var hasContent: Bool { messages.contains { $0.role == .user } }
}

enum History {
    static let limit = 50

    static func load() -> [Chat] {
        guard let data = try? Data(contentsOf: Paths.history) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Chat].self, from: data)) ?? []
    }

    static func save(_ chats: [Chat]) {
        guard !demoMode else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let kept = Array(chats.filter(\.hasContent).sorted { $0.updated > $1.updated }.prefix(limit))
        do { try encoder.encode(kept).write(to: Paths.history, options: .atomic) } catch { log("history save failed: \(error)") }
    }
}

enum Mode: String, CaseIterable {
    case normal, business, trading

    var emoji: String { self == .business ? "🧠" : self == .trading ? "💰" : "" }

    // Extra instructions appended to Claude's system prompt for each mode.
    var prompt: String? {
        switch self {
        case .normal: return nil
        case .business: return """
            You are in 🧠 Business mode. Act as a sharp, practical business coach for a beginner entrepreneur. \
            Focus only on ways to make money: apps, websites, online services, and physical real-world businesses. \
            If a screenshot is shared, look for business opportunities in what it shows. \
            For each idea give: what it is, who pays, how it makes money, rough startup cost, the first 3 steps, and the main risks. \
            Be honest about difficulty and realistic income, no hype. Explain in very simple words. Keep replies short and skimmable.
            """
        case .trading: return """
            You are in 💰 Trading mode. The user shares screenshots of TradingView charts. Read the chart carefully: \
            symbol, timeframe, current price, trend, key support and resistance, and every visible indicator. \
            They use the Market Cipher B (MCB) indicator: read its wave trend (the blue waves and whether they are overbought or oversold), \
            the green and red dots (buy/sell signals), the money flow area (green or red), the RSI/stoch lines and VWAP, \
            and look for bullish or bearish divergences between price and the waves or money flow. \
            If there are several screenshots (one per display), use the one that shows the chart.
            Reply in this format:
            **Chart:** symbol, timeframe, price
            **Bias:** Bullish / Bearish / Neutral, with confidence (low/medium/high)
            **Indicators:** what each one shows, in simple words
            **Divergences:** any you see, or "none"
            **Signal:** Wait / Possible long entry / Possible short entry / Consider exit, and the exact trigger to watch for
            **Levels:** possible upside targets, downside risk, and where the idea is wrong (stop idea)
            **Watch for:** 1-3 things
            Only describe what you can actually see. If something is too small, cut off or unreadable, say so and suggest zooming in. \
            Never invent numbers. If no chart is on screen, say so. If TradingView data tools are available, you may use them to confirm prices. \
            For automatic re-checks, keep it short: Chart, Bias, Signal, Levels, and what changed since last time. \
            End with one short line: this is analysis, not financial advice, and to manage risk.
            """
        }
    }

    // Read-only TradingView connector tools; nothing that creates or changes alerts or watchlists.
    var allowedTools: [String] {
        guard self == .trading else { return [] }
        return ["get-ohlcv", "get-symbol-data", "get-technicals-rating", "search-symbols", "get-news"]
            .map { "mcp__claude_ai_TradingView__mcp-tv-\($0)" }
    }
}

/// The Bias and Signal lines of a trading reply, reduced to keywords so changes can be detected.
struct ChartRead: Equatable {
    var bias: String
    var signal: String

    init?(_ reply: String) {
        func field(_ name: String) -> String? {
            reply.components(separatedBy: "\n").first { $0.localizedCaseInsensitiveContains("\(name):") }?.lowercased()
        }
        func earliest(_ line: String?, _ words: [(String, String)]) -> String? {
            guard let line else { return nil }
            return words.compactMap { key, label in line.range(of: key).map { ($0.lowerBound, label) } }
                .min { $0.0 < $1.0 }?.1
        }
        guard let signal = earliest(field("Signal"), [("wait", "Wait"), ("long", "Possible long"), ("short", "Possible short"), ("exit", "Consider exit")])
        else { return nil }
        self.signal = signal
        bias = earliest(field("Bias"), [("bullish", "Bullish"), ("bearish", "Bearish"), ("neutral", "Neutral")]) ?? "?"
    }

    var summary: String { "\(signal) (\(bias))" }
}

enum WatchInterval: Int, CaseIterable {
    case off = 0, five = 5, fifteen = 15
    var label: String { self == .off ? "Auto-watch off" : "Every \(rawValue) min" }
}

final class ChatModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input = ""
    @Published var eyeOn = false
    @Published var mode: Mode = .normal
    @Published var busy = false
    @Published var activity = ""
    @Published var folder: URL
    @Published var pinned = true { didSet { panel?.level = pinned ? .floating : .normal } }
    @Published var pendingSnips: [URL] = []
    @Published var listening = false
    @Published var speakReplies = UserDefaults.standard.bool(forKey: "speakReplies") {
        didSet { UserDefaults.standard.set(speakReplies, forKey: "speakReplies"); if !speakReplies { speaker.stop() } }
    }
    @Published var watch: WatchInterval = .off { didSet { restartWatch() } }
    @Published var nextCheck: Date?
    @Published private(set) var chats: [Chat] = []
    @Published var globeOn = false
    let global = GlobalChat()

    weak var panel: NSPanel?
    private var currentChatID = UUID()
    private var sessionID: String?
    private var process: Process?
    private var generation = 0 // bumped on new chat/stop so late output from an old run is ignored
    private var replyID: UUID?
    private var startedAt = Date()
    private var deniedNoticeShown = false
    private var autoCheck = false
    private var lastRead: ChartRead?
    private var watchTimer: Timer?
    private var dictationPrefix = ""
    private let dictation = Dictation()
    private let speaker = Speaker()

    init() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.screenshots, withIntermediateDirectories: true)
        if let saved = UserDefaults.standard.string(forKey: "folder"), fm.fileExists(atPath: saved) {
            folder = URL(fileURLWithPath: saved)
        } else {
            try? fm.createDirectory(at: Paths.defaultWorkspace, withIntermediateDirectories: true)
            folder = Paths.defaultWorkspace
        }

        dictation.onText = { [weak self] text in
            guard let self else { return }
            self.input = self.dictationPrefix + text
        }
        dictation.onError = { [weak self] message in
            self?.listening = false
            self?.say("🎙 \(message)")
        }

        if demoMode { loadDemo(); return }

        chats = History.load()
        if let last = chats.max(by: { $0.updated < $1.updated }), last.hasContent {
            open(last, note: "Welcome back! This is your last chat. 🕘 has older ones, ✏️ starts a new one.")
        } else {
            say("Hi! Turn on 👁️ to let Claude see your screen, then type or 🎙 talk. ⌃⌥Space shows or hides this window.")
        }
    }

    // MARK: Chats & history

    func newChat(note: String = "Started a fresh chat.") {
        stop(silently: true)
        saveCurrent()
        currentChatID = UUID()
        sessionID = nil
        lastRead = nil
        messages = []
        say(note)
    }

    func switchTo(_ chat: Chat) {
        guard chat.id != currentChatID else { return }
        stop(silently: true)
        saveCurrent()
        open(chat, note: "Continuing “\(chat.title)”.")
    }

    private func open(_ chat: Chat, note: String) {
        currentChatID = chat.id
        sessionID = chat.sessionID
        messages = chat.messages
        lastRead = nil
        if FileManager.default.fileExists(atPath: chat.folder), chat.folder != folder.path {
            folder = URL(fileURLWithPath: chat.folder)
            UserDefaults.standard.set(chat.folder, forKey: "folder")
        } else if !FileManager.default.fileExists(atPath: chat.folder) {
            sessionID = nil // the session lived in a folder that's gone, so start fresh
        }
        say(note)
    }

    func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Delete all saved chats?"
        alert.informativeText = "This removes Claude Eye's chat history. It can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        chats = []
        History.save([])
        newChat(note: "History cleared.")
    }

    /// Writes the current conversation into `chats` and to disk.
    func saveCurrent() {
        guard !demoMode, messages.contains(where: { $0.role == .user }) else { return }
        let title = messages.first { $0.role == .user }.map { String($0.text.prefix(48)) } ?? "New chat"
        let chat = Chat(id: currentChatID, title: title, updated: Date(), folder: folder.path,
                        sessionID: sessionID, messages: messages)
        if let i = chats.firstIndex(where: { $0.id == currentChatID }) { chats[i] = chat } else { chats.append(chat) }
        History.save(chats)
    }

    var recentChats: [Chat] {
        Array(chats.filter(\.hasContent).sorted { $0.updated > $1.updated }.prefix(15))
    }

    // MARK: Screen, modes & folder

    func toggleEye() {
        if eyeOn { eyeOn = false } else { turnEyeOn() }
    }

    @discardableResult
    private func turnEyeOn() -> Bool {
        eyeOn = true
        return hasScreenPermission()
    }

    private func hasScreenPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        CGRequestScreenCaptureAccess()
        say("Claude Eye needs Screen Recording permission. In System Settings → Privacy & Security → Screen & System Audio Recording, turn on Claude Eye, then quit (⌘Q) and reopen it. If it's already on, switch it off and on again.")
        openScreenRecordingSettings()
        return false
    }

    func toggleMode(_ m: Mode) {
        mode = (mode == m) ? .normal : m
        if mode != .trading { watch = .off }
        switch mode {
        case .normal:
            say("Normal mode.")
        case .business:
            say("🧠 Business mode: ask for money-making ideas, or show your screen for ideas about what's on it.")
        case .trading:
            say("💰 Trading mode: reading your chart… Use ⏱ to re-check it automatically.")
            analyzeChart()
        }
    }

    /// 🌍 switches the window to the anonymous chat with everyone who has it on.
    func toggleGlobe() {
        globeOn.toggle()
        if globeOn { global.start() } else { global.stop() }
    }

    /// Snaps the screen and asks for a fresh chart read (💰 mode and the 🔄 button).
    func analyzeChart() {
        guard turnEyeOn() else { return }
        send("Analyze the chart I'm showing right now.")
    }

    func chooseFolder() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.canCreateDirectories = true
        picker.prompt = "Use this folder"
        picker.message = "Pick the project folder Claude should work in. Claude can create and edit files here."
        picker.directoryURL = folder
        NSApp.activate(ignoringOtherApps: true)
        guard picker.runModal() == .OK, let url = picker.url else { return }
        folder = url
        UserDefaults.standard.set(url.path, forKey: "folder")
        newChat(note: "Now working in 📁 \(url.lastPathComponent). Started a fresh chat.")
    }

    // MARK: Auto-watch

    private func restartWatch() {
        watchTimer?.invalidate()
        watchTimer = nil
        nextCheck = nil
        guard watch != .off else { return }
        let seconds = TimeInterval(watch.rawValue * 60)
        nextCheck = Date().addingTimeInterval(seconds)
        guard !demoMode else { return }
        watchTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.nextCheck = Date().addingTimeInterval(seconds)
            guard !self.busy, self.mode == .trading else { return }
            self.autoCheck = true
            self.eyeOn = true
            self.send("⏱ Auto-check: read the chart again and tell me what changed.")
        }
        say("⏱ Auto-watch on: I'll re-read the chart every \(watch.rawValue) minutes and notify you when the signal changes. Keep the chart open.")
    }

    /// After a trading reply, compares Bias/Signal with the previous read and alerts on change.
    private func checkSignal(_ reply: String) {
        guard mode == .trading, let read = ChartRead(reply) else { return }
        if let last = lastRead, last != read {
            say("🔔 Signal changed: \(last.summary) → \(read.summary)")
            Notifier.shared.post("💰 Signal changed", "\(last.summary) → \(read.summary)")
        }
        lastRead = read
    }

    // MARK: Snip

    /// Lets the user drag a box on screen; the picture is attached to the next message.
    func snip() {
        guard hasScreenPermission() else { return }
        let url = Paths.screenshots.appendingPathComponent("snip-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).png")
        panel?.alphaValue = 0
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-i", "-x", url.path] // interactive: drag a box, Space for a window, Esc to cancel
            do { try p.run(); p.waitUntilExit() } catch { log("snip failed: \(error)") }
            DispatchQueue.main.async {
                self.panel?.alphaValue = 1
                if FileManager.default.fileExists(atPath: url.path) { self.pendingSnips.append(url) }
            }
        }
    }

    func removeSnip(_ url: URL) {
        pendingSnips.removeAll { $0 == url }
    }

    // MARK: Voice

    func toggleListening() {
        if listening {
            dictation.stop()
            listening = false
            send() // click to talk, click again to send
        } else {
            speaker.stop()
            dictationPrefix = input.isEmpty ? "" : input + " "
            dictation.start { [weak self] in self?.listening = true }
        }
    }

    func speak(_ text: String) { speaker.speak(text) }

    // MARK: Sending

    func stop(silently: Bool = false) {
        speaker.stop()
        guard let p = process else { return }
        generation += 1
        p.terminate()
        process = nil
        finishTurn()
        if !silently { say("⏹ Stopped.") }
    }

    func send() {
        if listening { dictation.stop(); listening = false }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if globeOn {
            guard !text.isEmpty else { return }
            input = ""
            global.send(text) { [weak self] note in
                guard let self, let note else { return }
                self.global.notice = note
                if self.input.isEmpty { self.input = text } // give the text back so it isn't lost
            }
            return
        }
        guard !text.isEmpty || !pendingSnips.isEmpty, !busy else { return }
        input = ""
        send(text.isEmpty ? "What do you see here?" : text)
    }

    private func send(_ text: String) {
        guard !busy else { return }
        speaker.stop()
        let snips = pendingSnips
        pendingSnips = []
        let fullScreen = snips.isEmpty && eyeOn // a snip replaces the full-screen capture
        if fullScreen && !hasScreenPermission() { autoCheck = false; return }
        busy = true
        activity = fullScreen ? "Taking a screenshot…" : "Thinking…"
        if fullScreen {
            captureScreens { shots in
                self.messages.append(ChatMessage(role: .user, text: text, screenshots: shots))
                self.ask(text, screenshots: shots)
            }
        } else {
            messages.append(ChatMessage(role: .user, text: text, screenshots: snips))
            ask(text, screenshots: snips)
        }
    }

    // MARK: Screenshots

    /// Captures the TradingView window in trading mode, otherwise every display (one file each).
    private func captureScreens(_ done: @escaping ([URL]) -> Void) {
        let stamp = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6))"
        var args = ["-x"]
        var urls: [URL]
        if mode == .trading, let window = tradingViewWindowID() {
            urls = [Paths.screenshots.appendingPathComponent("tradingview-\(stamp).png")]
            args += ["-o", "-l", String(window)]
        } else {
            urls = (1...max(NSScreen.screens.count, 1)).map {
                Paths.screenshots.appendingPathComponent("screen-\(stamp)-\($0).png")
            }
        }
        args += urls.map(\.path)
        // Invisible rather than ordered out, so the window keeps its place.
        panel?.alphaValue = 0
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = args
            do { try p.run(); p.waitUntilExit() } catch { log("screencapture failed: \(error)") }
            let saved = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            DispatchQueue.main.async {
                self.panel?.alphaValue = 1
                if saved.isEmpty { self.say("⚠️ Couldn't take a screenshot, sending without one.") }
                done(saved)
            }
        }
    }

    // MARK: Claude

    private func ask(_ text: String, screenshots: [URL]) {
        guard let claude = locateClaude() else {
            say("Couldn't find Claude Code. Install it from https://claude.com/claude-code, run `claude` once in Terminal to log in, then try again.")
            finishTurn()
            return
        }

        var prompt = text
        if !screenshots.isEmpty {
            let list = screenshots.map(\.path).joined(separator: "\n")
            let what = screenshots.count == 1 ? "a screenshot" : "\(screenshots.count) screenshots"
            prompt = "[I'm sharing \(what) of my screen right now — open with the Read tool to see what I see:\n\(list)]\n\n" + text
        }

        var args = ["-p", prompt,
                    "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--permission-mode", "acceptEdits",
                    "--add-dir", Paths.screenshots.path]
        if let id = sessionID { args += ["--resume", id] }
        if let extra = mode.prompt { args += ["--append-system-prompt", extra] }
        if !mode.allowedTools.isEmpty { args += ["--allowedTools"] + mode.allowedTools }

        let p = Process()
        p.executableURL = claude
        p.arguments = args
        p.currentDirectoryURL = folder
        // Drop variables that would make Claude think it's nested inside another session.
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDECODE") && !$0.key.hasPrefix("CLAUDE_CODE_") }
        env["PATH"] = [claude.deletingLastPathComponent().path, "\(Paths.home.path)/.local/bin",
                       "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        process = p
        replyID = nil
        startedAt = Date()
        deniedNoticeShown = false
        let gen = generation

        do { try p.run() } catch {
            say("Couldn't start Claude: \(error.localizedDescription)")
            log("launch failed: \(error)")
            finishTurn()
            return
        }
        log("run mode=\(mode.rawValue) shots=\(screenshots.count) auto=\(autoCheck) resume=\(sessionID ?? "new")")

        var stderrText = ""
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            stderrText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            group.leave()
        }
        DispatchQueue.global().async {
            let handle = out.fileHandleForReading
            var buffer = Data()
            var gotResult = false
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<nl]
                    buffer.removeSubrange(buffer.startIndex...nl)
                    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    if obj["type"] as? String == "result" { gotResult = true }
                    DispatchQueue.main.async { if gen == self.generation { self.handle(event: obj) } }
                }
            }
            p.waitUntilExit()
            group.wait()
            let status = p.terminationStatus
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                if !gotResult {
                    let detail = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                    log("exit \(status) without result: \(detail)")
                    self.say(detail.isEmpty ? "Claude stopped unexpectedly (code \(status))." : "⚠️ \(detail)")
                }
                self.process = nil
                self.finishTurn()
            }
        }
    }

    /// Handles one line of `claude --output-format stream-json`.
    private func handle(event: [String: Any]) {
        switch event["type"] as? String {
        case "system":
            if event["subtype"] as? String == "init", let id = event["session_id"] as? String { sessionID = id }
            if event["subtype"] as? String == "permission_denied" && !deniedNoticeShown {
                deniedNoticeShown = true
                say("ℹ️ Claude wanted to do something the overlay doesn't allow (like running a command). For that, use `claude` in Terminal.")
            }
        case "stream_event":
            guard let ev = event["event"] as? [String: Any] else { return }
            switch ev["type"] as? String {
            case "content_block_start":
                let block = ev["content_block"] as? [String: Any]
                switch block?["type"] as? String {
                case "tool_use":
                    activity = describe(tool: block?["name"] as? String ?? "")
                    separateReply()
                case "text": activity = "Writing…"
                case "thinking": activity = "Thinking…"
                default: break
                }
            case "content_block_delta":
                if let delta = ev["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String {
                    appendReply(text)
                }
            default: break
            }
        case "result":
            if let id = event["session_id"] as? String { sessionID = id }
            let seconds = Int(Date().timeIntervalSince(startedAt).rounded())
            if event["is_error"] as? Bool == true {
                let detail = (event["result"] as? String) ?? (event["errors"] as? [String])?.joined(separator: "\n") ?? "Something went wrong."
                say("⚠️ \(detail)")
            } else if replyID == nil, let text = event["result"] as? String, !text.isEmpty {
                appendReply(text)
            }
            if let id = replyID, let i = messages.firstIndex(where: { $0.id == id }) {
                messages[i].footer = "\(seconds)s"
            }
        default: break
        }
    }

    private func appendReply(_ text: String) {
        if let id = replyID, let i = messages.firstIndex(where: { $0.id == id }) {
            messages[i].text += text
        } else {
            let msg = ChatMessage(role: .claude, text: text)
            replyID = msg.id
            messages.append(msg)
        }
    }

    /// Keeps text written before and after a tool call as separate paragraphs.
    private func separateReply() {
        guard let id = replyID, let i = messages.firstIndex(where: { $0.id == id }),
              !messages[i].text.hasSuffix("\n\n") else { return }
        messages[i].text += "\n\n"
    }

    private func describe(tool: String) -> String {
        switch tool {
        case "Read": return "Looking at your screen…"
        case "Write", "Edit", "MultiEdit", "NotebookEdit": return "Writing code…"
        case "Glob", "Grep", "LS": return "Searching your files…"
        case "WebSearch", "WebFetch": return "Searching the web…"
        case "Bash": return "Trying to run a command…"
        case _ where tool.contains("TradingView"): return "Checking TradingView data…"
        default: return "Working…"
        }
    }

    private func finishTurn() {
        busy = false
        activity = ""
        let wasAuto = autoCheck
        autoCheck = false
        guard let id = replyID, let i = messages.firstIndex(where: { $0.id == id }) else {
            saveCurrent()
            return
        }
        replyID = nil
        messages[i].text = messages[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = messages[i].text
        saveCurrent()
        checkSignal(reply)

        let visible = NSApp.isActive && panel?.isVisible == true
        if !visible && !wasAuto { Notifier.shared.post("Claude Eye", reply) } // auto-checks only notify on change
        if speakReplies && !wasAuto { speaker.speak(reply) }
    }

    private func say(_ text: String) {
        messages.append(ChatMessage(role: .system, text: text))
    }

    // MARK: Demo

    private func loadDemo() {
        mode = .trading
        eyeOn = true
        watch = .off
        folder = Paths.home.appendingPathComponent("my-website")
        let shot = Paths.support.appendingPathComponent("demo-chart.png")
        messages = [
            ChatMessage(role: .system, text: "💰 Trading mode: reading your chart… Use ⏱ to re-check it automatically."),
            ChatMessage(role: .user, text: "Analyze the chart I'm showing right now.",
                        screenshots: FileManager.default.fileExists(atPath: shot.path) ? [shot] : []),
            ChatMessage(role: .claude, text: """
                **Chart:** BTCUSD, 4h, about 67,400
                **Bias:** Bullish, medium confidence
                **Indicators:**
                - MCB waves are curling up from oversold, with a fresh green dot
                - Money flow just turned green
                **Divergences:** Bullish: price made a lower low, the waves made a higher low
                **Signal:** Wait for the 4h candle to close above 67,800 before a possible long entry
                **Levels:** upside 69,200 / 70,500 · downside 65,900 · idea is wrong below 65,500
                This is analysis, not financial advice. Manage your risk.
                """, footer: "14s"),
            ChatMessage(role: .system, text: "⏱ Auto-watch on: I'll re-read the chart every 15 minutes and notify you when the signal changes."),
            ChatMessage(role: .system, text: "🔔 Signal changed: Wait (Bullish) → Possible long (Bullish)"),
        ]
        watch = .fifteen
    }
}

// MARK: - 🌍 Global chat

/// An anonymous chat room shared by everyone who has Claude Eye with 🌍 turned on.
/// Messages go through the free public relay ntfy.sh, which keeps them for about 12 hours.
struct GlobalMessage: Identifiable, Equatable {
    let id: String
    let name: String
    let text: String
    let time: Date
    let mine: Bool
}

final class GlobalChat: ObservableObject {
    static let topic = "claude-eye-global-chat-v1"
    static let maxLength = 500
    private static let server = URL(string: "https://ntfy.sh/")!
    /// Apps with 🌍 on say "I'm here" on this topic every few minutes; that's how we count who's online.
    private static let presenceTopic = topic + "-online"
    private static let pingEvery: TimeInterval = 4 * 60
    private static let onlineWindow: TimeInterval = 5 * 60

    @Published var messages: [GlobalMessage] = []
    @Published var connected = false
    @Published var notice: String?
    @Published private var seen: [String: Date] = [:] // device tag → last "I'm here"
    @Published var muted: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "globalMuted") ?? []) {
        didSet { UserDefaults.standard.set(Array(muted), forKey: "globalMuted") }
    }
    /// A random nickname like "Anon-4821", kept between launches. Nothing else about you is sent.
    let name: String
    /// A random tag so this Mac can recognise its own messages and be counted once.
    private let device: String

    private var tasks: [Task<Void, Never>] = []
    private var pingTimer: Timer?
    private var lastSent = Date.distantPast
    private var sentIDs: Set<String> = []

    init() {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "globalName") == nil { defaults.set("Anon-\(Int.random(in: 1000...9999))", forKey: "globalName") }
        if defaults.string(forKey: "globalDevice") == nil { defaults.set(UUID().uuidString, forKey: "globalDevice") }
        name = defaults.string(forKey: "globalName")!
        device = defaults.string(forKey: "globalDevice")!
    }

    var visible: [GlobalMessage] { messages.filter { !muted.contains($0.name) } }

    /// People online right now, including you.
    var onlineCount: Int {
        let cutoff = Date().addingTimeInterval(-Self.onlineWindow)
        return seen.filter { $0.key != device && $0.value > cutoff }.count + 1
    }

    var running: Bool { !tasks.isEmpty }

    func start() {
        guard tasks.isEmpty else { return }
        seen[device] = Date()
        tasks = [
            stream(Self.topic, firstSince: "12h") { [weak self] id, time, payload in self?.received(id, time, payload) },
            stream(Self.presenceTopic, firstSince: "\(Int(Self.onlineWindow))s") { [weak self] _, time, payload in
                guard let self, let tag = payload["from"] as? String else { return }
                if payload["bye"] as? Bool == true { self.seen[tag] = nil } else { self.seen[tag] = max(time, self.seen[tag] ?? time) }
            },
        ]
        ping()
        pingTimer = Timer.scheduledTimer(withTimeInterval: Self.pingEvery, repeats: true) { [weak self] _ in
            self?.ping()
            self?.objectWillChange.send() // refresh the count as old pings expire
        }
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
        pingTimer?.invalidate()
        pingTimer = nil
        connected = false
        post(Self.presenceTopic, ["from": device, "bye": true]) { _, _ in }
        seen = [:]
    }

    private func ping() {
        post(Self.presenceTopic, ["from": device]) { _, _ in }
    }

    /// Keeps a live connection to a topic: first older messages, then new ones as they arrive. Reconnects on drops.
    private func stream(_ topic: String, firstSince: String,
                        handle: @escaping (String, Date, [String: Any]) -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            var lastID: String?
            while !Task.isCancelled {
                var url = Self.server.appendingPathComponent("\(topic)/json")
                url.append(queryItems: [URLQueryItem(name: "since", value: lastID ?? firstSince)])
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(from: url)
                    if (response as? HTTPURLResponse)?.statusCode == 200 {
                        if topic == Self.topic { await MainActor.run { self?.connected = true } }
                        for try await line in bytes.lines {
                            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                                  event["event"] as? String == "message", let id = event["id"] as? String,
                                  let body = event["message"] as? String,
                                  let payload = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
                            else { continue }
                            lastID = id
                            let time = Date(timeIntervalSince1970: event["time"] as? TimeInterval ?? Date().timeIntervalSince1970)
                            await MainActor.run { handle(id, time, payload) }
                        }
                    }
                } catch {
                    if !Task.isCancelled { log("global chat \(topic) disconnected: \(error.localizedDescription)") }
                }
                if topic == Self.topic { await MainActor.run { self?.connected = false } }
                try? await Task.sleep(nanoseconds: 3_000_000_000) // wait a bit, then reconnect
            }
        }
    }

    private func received(_ id: String, _ time: Date, _ payload: [String: Any]) {
        guard let name = payload["name"] as? String, let text = payload["text"] as? String,
              !messages.contains(where: { $0.id == id }) else { return }
        let clean = String(text.prefix(Self.maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if let tag = payload["from"] as? String, time > (seen[tag] ?? .distantPast) { seen[tag] = time } // chatting counts as online
        let mine = sentIDs.contains(id) || payload["from"] as? String == device
        messages.append(GlobalMessage(id: id, name: String(name.prefix(20)), text: clean, time: time, mine: mine))
        if messages.count > 300 { messages.removeFirst(messages.count - 300) }
    }

    private func post(_ topic: String, _ payload: [String: Any], done: @escaping (Int, String?) -> Void) {
        var request = URLRequest(url: Self.server.appendingPathComponent(topic))
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let id = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["id"] as? String
            if status != 200 { log("global post \(topic) failed \(status) \(error.map { "\($0)" } ?? "")") }
            DispatchQueue.main.async { done(status, id) }
        }.resume()
    }

    /// Sends a message. Calls `done` with a note for the user if it wasn't sent.
    func send(_ text: String, done: @escaping (String?) -> Void) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return done(nil) }
        guard clean.count <= Self.maxLength else { return done("Too long, keep it under \(Self.maxLength) letters.") }
        guard Date().timeIntervalSince(lastSent) > 3 else { return done("Slow down a little, wait a few seconds.") }
        lastSent = Date()
        notice = nil
        post(Self.topic, ["v": 1, "name": name, "text": clean, "from": device]) { status, id in
            if let id { self.sentIDs.insert(id) }
            if status == 200 { return done(nil) }
            done(status == 429 ? "The chat is busy, try again in a minute." : "Couldn't send. Check your internet.")
        }
    }

    func mute(_ name: String) { muted.insert(name) }
    func unmuteAll() { muted = [] }
}

// MARK: - Views

struct ChatView: View {
    @ObservedObject var model: ChatModel
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.globeOn {
                GlobalChatView(chat: model.global)
            } else {
                transcript
            }
            Divider()
            if !model.pendingSnips.isEmpty && !model.globeOn { snipTray }
            inputBar
            statusBar
        }
        .frame(minWidth: 440, minHeight: 380)
        .background(.ultraThinMaterial)
        .onAppear { inputFocused = true }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            toggleButton("👁️", on: model.eyeOn, color: .blue, action: model.toggleEye, label: "Screen sharing",
                         help: model.eyeOn ? "Claude sees your screen with each message (⌘E to turn off)" : "Let Claude see your screen (⌘E)")
            toggleButton("✂️", on: !model.pendingSnips.isEmpty, color: .orange, action: model.snip, label: "Snip",
                         help: "Snip: drag a box around part of the screen to show just that (⌘⇧S)")
            toggleButton("🧠", on: model.mode == .business, color: .pink, action: { model.toggleMode(.business) },
                         label: "Business mode", help: "🧠 Business mode: money-making ideas for apps, websites and real-world businesses")
                .disabled(model.busy)
            toggleButton("💰", on: model.mode == .trading, color: .green, action: { model.toggleMode(.trading) },
                         label: "Trading mode", help: "💰 Trading mode: reads your TradingView chart straight away")
                .disabled(model.busy)
            toggleButton("🌍", on: model.globeOn, color: .teal, action: model.toggleGlobe, label: "Global chat",
                         help: model.globeOn ? "🌍 You're in the anonymous chat with everyone online (click to go back to Claude)"
                                             : "🌍 Chat anonymously with everyone who has Claude Eye open")

            if model.mode == .trading && !model.globeOn {
                Button(action: model.analyzeChart) { Image(systemName: "arrow.clockwise") }
                    .disabled(model.busy)
                    .help("Read the chart again (⌘R)")
                    .accessibilityLabel("Read the chart again")
                Menu {
                    Picker("Auto-watch", selection: $model.watch) {
                        ForEach(WatchInterval.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: model.watch == .off ? "timer" : "timer.circle.fill")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(model.watch == .off ? Color.primary : Color.green)
                .help("⏱ Auto-watch: re-read the chart every 5 or 15 minutes and notify when the signal changes")
            }

            Spacer(minLength: 4)

            Menu {
                if model.recentChats.isEmpty {
                    Text("No saved chats yet")
                } else {
                    ForEach(model.recentChats) { chat in
                        Button("\(chat.title) · \(chat.updated.formatted(.relative(presentation: .named)))") { model.switchTo(chat) }
                    }
                    Divider()
                    Button("Clear History…", role: .destructive) { model.clearHistory() }
                }
            } label: { Image(systemName: "clock.arrow.circlepath") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Chat history")
                .disabled(model.busy)

            Button(action: { model.pinned.toggle() }) { Image(systemName: model.pinned ? "pin.fill" : "pin.slash") }
                .buttonStyle(.borderless)
                .help(model.pinned ? "Always on top (click to turn off)" : "Not on top (click to keep on top)")
                .accessibilityLabel(model.pinned ? "Unpin window" : "Pin window on top")

            Button(action: { model.newChat() }) { Image(systemName: "square.and.pencil") }
                .buttonStyle(.borderless)
                .help("New chat (⌘N)")
                .accessibilityLabel("New chat")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func toggleButton(_ emoji: String, on: Bool, color: Color, action: @escaping () -> Void,
                              label: String, help: String) -> some View {
        Button(action: action) {
            Text(emoji).font(.system(size: 18))
                .opacity(on ? 1 : 0.45)
                .frame(width: 30, height: 30)
                .background(Circle().fill(on ? color.opacity(0.35) : Color.clear))
                .overlay(Circle().stroke(on ? color : Color.gray.opacity(0.4), lineWidth: 2))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityValue(on ? "On" : "Off")
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.messages) { Bubble(message: $0, speak: model.speak).id($0.id) }
                    if model.busy {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(model.activity.isEmpty ? "Working…" : model.activity)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(10)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.messages.count) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.messages.last?.text) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.busy) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    // MARK: Input

    private var snipTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.pendingSnips, id: \.self) { url in
                    ZStack(alignment: .topTrailing) {
                        if let img = NSImage(contentsOf: url) {
                            Image(nsImage: img).resizable().scaledToFit().frame(height: 52).cornerRadius(5)
                        }
                        Button(action: { model.removeSnip(url) }) {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                        .accessibilityLabel("Remove snip")
                    }
                }
                Text("✂️ Attached to your next message").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
        }
    }

    private var placeholder: String {
        if model.listening { return "Listening… click 🎙 again to send" }
        if model.globeOn { return "Write to everyone as \(model.global.name)…" }
        switch model.mode {
        case .business: return "Ask for business ideas…"
        case .trading: return "Ask about the chart…"
        case .normal: return model.eyeOn ? "Tell Claude about what you're showing…" : "Message Claude…"
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button(action: model.toggleListening) {
                Image(systemName: model.listening ? "mic.fill" : "mic")
                    .font(.title3)
                    .foregroundStyle(model.listening ? Color.red : Color.secondary)
                    .frame(width: 26, height: 30)
            }
            .buttonStyle(.plain)
            .disabled(model.busy && !model.globeOn)
            .help(model.listening ? "Stop and send" : "🎙 Talk instead of typing (click again to send)")
            .accessibilityLabel(model.listening ? "Stop listening and send" : "Start voice input")

            TextField(placeholder, text: $model.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit(model.send)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(model.listening ? Color.red : Color.clear, lineWidth: 1.5))

            if model.busy && !model.globeOn {
                Button(action: { model.stop() }) { Image(systemName: "stop.circle.fill").font(.title2) }
                    .buttonStyle(.plain).foregroundStyle(.red)
                    .help("Stop (Esc)").accessibilityLabel("Stop")
                    .keyboardShortcut(.cancelAction)
            } else {
                Button(action: model.send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain).foregroundStyle(.blue)
                    .disabled(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (model.pendingSnips.isEmpty || model.globeOn))
                    .help("Send (Return · ⌥Return for a new line)").accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Button(action: model.chooseFolder) {
                Label(model.folder.lastPathComponent, systemImage: "folder").lineLimit(1)
            }
            .buttonStyle(.borderless)
            .help("Project folder Claude works in (⌘O): \(model.folder.path)")

            if let next = model.nextCheck {
                Label { Text("Next check \(next, style: .relative)") } icon: { Image(systemName: "timer") }
                    .foregroundStyle(.green)
            }

            Spacer()

            Button(action: { model.speakReplies.toggle() }) {
                Label(model.speakReplies ? "Read aloud" : "Silent",
                      systemImage: model.speakReplies ? "speaker.wave.2.fill" : "speaker.slash")
            }
            .buttonStyle(.borderless)
            .help(model.speakReplies ? "🔊 Answers are read aloud (click to turn off)" : "🔊 Read answers aloud")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

/// The 🌍 room: a green "online now" bar, the messages, and a short safety note.
struct GlobalChatView: View {
    @ObservedObject var chat: GlobalChat

    var body: some View {
        VStack(spacing: 0) {
            onlineBar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        Text("🌍 Anonymous chat with everyone who has Claude Eye open. You are **\(chat.name)**. Be kind, and never share your name, address, passwords or other private info. Messages disappear after about 12 hours.")
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 4)
                        if chat.visible.isEmpty {
                            Text(chat.connected ? "No messages yet. Say hi! 👋" : "Connecting…")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(chat.visible) { GlobalBubble(message: $0, mute: chat.mute).id($0.id) }
                        if let notice = chat.notice {
                            Text("⚠️ \(notice)").font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(10)
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: chat.visible.count) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: chat.notice) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var onlineBar: some View {
        HStack(spacing: 6) {
            Circle().fill(chat.connected ? Color.green : Color.orange).frame(width: 8, height: 8)
            if chat.connected {
                Text("\(chat.onlineCount) online now").fontWeight(.semibold).foregroundStyle(.green)
            } else {
                Text("Connecting…").foregroundStyle(.orange)
            }
            Spacer()
            if !chat.muted.isEmpty {
                Button("Unmute \(chat.muted.count)") { chat.unmuteAll() }
                    .buttonStyle(.borderless)
                    .help("Show messages from people you muted again")
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.green.opacity(0.08))
        .accessibilityElement(children: .combine)
    }
}

struct GlobalBubble: View {
    let message: GlobalMessage
    let mute: (String) -> Void

    var body: some View {
        VStack(alignment: message.mine ? .trailing : .leading, spacing: 2) {
            Text("\(message.mine ? "You" : message.name) · \(message.time.formatted(date: .omitted, time: .shortened))")
                .font(.caption2).foregroundStyle(.secondary)
            // Shown as plain text on purpose, so strangers can't sneak in clickable links.
            Text(verbatim: message.text)
                .textSelection(.enabled)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(message.mine ? Color.teal.opacity(0.85) : Color.gray.opacity(0.2)))
                .foregroundStyle(message.mine ? Color.white : Color.primary)
        }
        .frame(maxWidth: .infinity, alignment: message.mine ? .trailing : .leading)
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
            }
            if !message.mine {
                Button("Mute \(message.name)") { mute(message.name) }
            }
        }
    }
}

struct Bubble: View {
    let message: ChatMessage
    let speak: (String) -> Void
    @State private var hovering = false

    var body: some View {
        switch message.role {
        case .system:
            Text(inlineMarkdown(message.text))
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
        case .user:
            VStack(alignment: .trailing, spacing: 4) {
                if !message.screenshots.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(message.screenshots, id: \.self) { shot in
                            if let img = NSImage(contentsOf: shot) {
                                Image(nsImage: img).resizable().scaledToFit()
                                    .frame(maxHeight: 80).cornerRadius(6)
                                    .onTapGesture { NSWorkspace.shared.open(shot) }
                                    .help("Screenshot sent to Claude (click to open)")
                            }
                        }
                    }
                }
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.85)))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .claude:
            VStack(alignment: .leading, spacing: 4) {
                MarkdownText(text: message.text)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.2)))
                HStack(spacing: 10) {
                    Group {
                        Button(action: copy) { Label("Copy", systemImage: "doc.on.doc") }
                        Button(action: { speak(message.text) }) { Label("Read aloud", systemImage: "speaker.wave.2") }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .opacity(hovering ? 1 : 0)
                    if let footer = message.footer {
                        Text(footer).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onHover { hovering = $0 }
            .contextMenu {
                Button("Copy", action: copy)
                Button("Read Aloud") { speak(message.text) }
            }
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
    }
}

func inlineMarkdown(_ s: String) -> AttributedString {
    let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
}

/// Small Markdown renderer: headings, bullet and numbered lists, code blocks, inline styles.
struct MarkdownText: View {
    let text: String

    private enum Block: Hashable {
        case heading(String), bullet(String), numbered(String, String), code(String), paragraph(String)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var code: [String]? = nil
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { result.append(.code(c.joined(separator: "\n"))); code = nil } else { code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                result.append(.heading(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                result.append(.bullet(String(line.dropFirst(2))))
            } else if let dot = line.firstIndex(of: "."), !line[..<dot].isEmpty, line[..<dot].allSatisfy(\.isNumber),
                      line[line.index(after: dot)...].hasPrefix(" ") {
                result.append(.numbered(String(line[..<dot]), String(line[line.index(dot, offsetBy: 2)...])))
            } else {
                result.append(.paragraph(line))
            }
        }
        if let c = code { result.append(.code(c.joined(separator: "\n"))) } // still streaming
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let s):
                    Text(inlineMarkdown(s)).font(.headline)
                case .bullet(let s):
                    HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•"); Text(inlineMarkdown(s)) }
                case .numbered(let n, let s):
                    HStack(alignment: .firstTextBaseline, spacing: 6) { Text("\(n).").monospacedDigit(); Text(inlineMarkdown(s)) }
                case .code(let s):
                    Text(s).font(.system(.caption, design: .monospaced))
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25)))
                case .paragraph(let s):
                    Text(inlineMarkdown(s))
                }
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Global hotkey (⌃⌥Space)

final class HotKey {
    private static var action: (() -> Void)?
    private var ref: EventHotKeyRef?

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        HotKey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4345_5945), id: 1) // "CEYE"
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
    }
}

// MARK: - Window & app

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = ChatModel()
    var panel: FloatingPanel!
    var hotKey: HotKey?

    func applicationDidFinishLaunching(_ note: Notification) {
        log("launch\(demoMode ? " (demo)" : "")")
        cleanOldScreenshots()
        buildMenu()

        let size = NSSize(width: 460, height: 640)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: screen.maxX - size.width - 20, y: screen.maxY - size.height - 20)
        panel = FloatingPanel(contentRect: NSRect(origin: origin, size: size),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        panel.title = "Claude Eye"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if !demoMode { panel.setFrameAutosaveName("ClaudeEyePanel") }
        panel.contentView = NSHostingView(rootView: ChatView(model: model))
        panel.delegate = self
        model.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // `--demo --snapshot <file.png>` saves a picture of the window (for the README).
        if demoMode, let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            let window = String(panel.windowNumber)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-l", window, path]
                try? p.run()
                p.waitUntilExit()
                log("snapshot \(path) status \(p.terminationStatus)")
            }
        }

        hotKey = HotKey(keyCode: kVK_Space, modifiers: controlKey | optionKey) { [weak self] in self?.toggleWindow() }
        Notifier.shared.onClick = { [weak self] in self?.showWindow() }
        Notifier.shared.setup()

        // `open -a "Claude Eye" --args --mode trading` starts in a mode.
        let args = CommandLine.arguments
        if !demoMode, let i = args.firstIndex(of: "--mode"), i + 1 < args.count, let m = Mode(rawValue: args[i + 1]), m != .normal {
            model.toggleMode(m)
        }
        // `--globe` opens straight into the 🌍 chat.
        if !demoMode && args.contains("--globe") { model.toggleGlobe() }
    }

    func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func toggleWindow() {
        if panel.isVisible && NSApp.isActive && panel.isKeyWindow { panel.orderOut(nil) } else { showWindow() }
    }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow()
        return true
    }

    // Hiding the window (hotkey) keeps the app running; the close button quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop(silently: true)
        model.saveCurrent()
        if model.globeOn { model.global.stop() }
    }

    @objc func newChat() { model.newChat() }
    @objc func toggleEye() { model.toggleEye() }
    @objc func snip() { model.snip() }
    @objc func talk() { model.toggleListening() }
    @objc func readChart() { if model.mode != .trading { model.toggleMode(.trading) } else { model.analyzeChart() } }
    @objc func chooseFolder() { model.chooseFolder() }
    @objc func openLog() { NSWorkspace.shared.open(Paths.logFile) }

    private func buildMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Claude Eye", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Claude Eye", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Claude Eye", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addSubmenu(appMenu, to: main)

        // Needed so ⌘C / ⌘V / ⌘A work in the text field.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        addSubmenu(edit, to: main)

        let chat = NSMenu(title: "Chat")
        let items: [(String, Selector, String)] = [
            ("New Chat", #selector(newChat), "n"),
            ("Toggle Screen Sharing", #selector(toggleEye), "e"),
            ("Snip Part of the Screen", #selector(snip), "S"),
            ("Talk", #selector(talk), "d"),
            ("Read Chart", #selector(readChart), "r"),
            ("Choose Project Folder…", #selector(chooseFolder), "o"),
            ("Open Log", #selector(openLog), ""),
        ]
        for (title, action, key) in items {
            chat.addItem(withTitle: title, action: action, keyEquivalent: key).target = self
        }
        addSubmenu(chat, to: main)

        NSApp.mainMenu = main
    }

    private func addSubmenu(_ menu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem()
        item.submenu = menu
        main.addItem(item)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
