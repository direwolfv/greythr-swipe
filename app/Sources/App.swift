// greytHR menu bar app — a control panel for the launchd + Playwright automation.
// It owns credentials (Keychain), the two times (config.json) and the on/off switch
// (launchd). It is NOT the engine: quit it and the automation keeps running.

import SwiftUI
import AppKit
import Combine
import UserNotifications

// ---------- where things live ----------
// The worker ships inside the bundle; settings and logs live in Application Support, so
// an app installed read-only (Homebrew, /Applications) still works.
let info = Bundle.main.infoDictionary ?? [:]
let scriptURL = Bundle.main.resourceURL?.appendingPathComponent("run.sh")
    ?? URL(fileURLWithPath: "run.sh")

/// Path to the launcher to bake into the LaunchAgent. Bundle URLs come back with symlinks resolved, so a
/// Homebrew install would resolve /Applications/greytHR.app -> opt/greythr ->
/// Cellar/greythr/<version> and pin the plist to a version that `brew upgrade` deletes.
/// When /Applications/greytHR.app is this same bundle, use that stable path instead.
let workerPath: String = {
    let linked = "/Applications/greytHR.app"
    let resolved = URL(fileURLWithPath: linked).resolvingSymlinksInPath().path
    if resolved == Bundle.main.bundleURL.resolvingSymlinksInPath().path {
        return linked + "/Contents/Resources/run.sh"
    }
    return scriptURL.path
}()

let dataDir: URL = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("greytHR")
    try? FileManager.default.createDirectory(at: base.appendingPathComponent("logs"),
                                             withIntermediateDirectories: true)
    return base
}()

let configURL = dataDir.appendingPathComponent("config.json")
let stateURL = dataDir.appendingPathComponent("logs/state.json")
let logURL = dataDir.appendingPathComponent("logs/checkout.log")
let launchdLabel = "com.direwolfv.greythr-swipe"
let launchAgentURL = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/LaunchAgents/\(launchdLabel).plist")

// ---------- tiny shell helper ----------
@discardableResult
func sh(_ tool: String, _ args: [String], env: [String: String] = [:]) -> (out: String, ok: Bool) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    if !env.isEmpty { p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new } }
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return ("", false) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (out, p.terminationStatus == 0)
}

// The worker already reads these with /usr/bin/security, so writing them the same way
// keeps the default ACL that lets the background launchd run read them without a prompt.
func keychainGet(_ service: String) -> String {
    let r = sh("/usr/bin/security", ["find-generic-password", "-s", service, "-w"])
    return r.ok ? r.out : ""
}

func keychainSet(_ service: String, _ value: String) -> Bool {
    // ponytail: the secret rides on argv, so it is briefly visible to `ps`. Same as the
    // setup.sh it replaces; switch to SecItemAdd if that ever matters.
    sh("/usr/bin/security",
       ["add-generic-password", "-a", NSUserName(), "-s", service, "-w", value, "-U"]).ok
}

// ---------- config.json ----------
struct Config: Codable, Equatable {
    var baseUrl = ""
    var checkInAt = "09:00"
    var checkOutAt = "19:00"
    var checkInEnabled = true
    var checkOutEnabled = true
    var weekdaysOnly = true
    var headless = true
    var browserPath: String?
    var nodePath: String?      // empty = auto-detect, see run.sh
    var geoLat: Double?
    var geoLon: Double?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseUrl = try c.decodeIfPresent(String.self, forKey: .baseUrl) ?? baseUrl
        checkInAt = try c.decodeIfPresent(String.self, forKey: .checkInAt) ?? checkInAt
        checkOutAt = try c.decodeIfPresent(String.self, forKey: .checkOutAt) ?? checkOutAt
        checkInEnabled = try c.decodeIfPresent(Bool.self, forKey: .checkInEnabled) ?? checkInEnabled
        checkOutEnabled = try c.decodeIfPresent(Bool.self, forKey: .checkOutEnabled) ?? checkOutEnabled
        weekdaysOnly = try c.decodeIfPresent(Bool.self, forKey: .weekdaysOnly) ?? weekdaysOnly
        headless = try c.decodeIfPresent(Bool.self, forKey: .headless) ?? headless
        browserPath = try c.decodeIfPresent(String.self, forKey: .browserPath)
        nodePath = try c.decodeIfPresent(String.self, forKey: .nodePath)
        geoLat = try c.decodeIfPresent(Double.self, forKey: .geoLat)
        geoLon = try c.decodeIfPresent(Double.self, forKey: .geoLon)
    }
}

struct DayState: Codable {
    var lastCheckinDate: String?
    var lastCheckoutDate: String?
}

func todayString() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: Date())
}

// "09:00" <-> Date, for DatePicker.
func date(fromHHMM s: String) -> Date {
    let parts = s.split(separator: ":").compactMap { Int($0) }
    var c = DateComponents()
    c.year = 2000; c.month = 1; c.day = 1
    c.hour = parts.first ?? 9
    c.minute = parts.count > 1 ? parts[1] : 0
    return Calendar.current.date(from: c) ?? Date()
}

// Appearance is a preference of the app, not of the automation, so it stays out of
// config.json (which the node worker reads) and lives in UserDefaults.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil            // nil = follow the system setting
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    static var current: Appearance {
        Appearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system
    }

    func apply() {
        UserDefaults.standard.set(rawValue, forKey: "appearance")
        NSApp.appearance = nsAppearance
    }
}

func hhmm(from d: Date) -> String {
    let c = Calendar.current.dateComponents([.hour, .minute], from: d)
    return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
}

// Chromium-based browsers Playwright can drive, if they're installed.
struct BrowserChoice: Hashable, Identifiable {
    let name: String
    let path: String?          // nil = Playwright's own bundled Chromium
    var id: String { path ?? "builtin" }

    static let known = [
        ("Brave", "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"),
        ("Chrome", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
        ("Edge", "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"),
    ]

    static var installed: [BrowserChoice] {
        [BrowserChoice(name: "Automatic", path: nil)] + known.compactMap { name, path in
            FileManager.default.isExecutableFile(atPath: path)
                ? BrowserChoice(name: name, path: path) : nil
        }
    }
}

// ---------- model ----------
final class Model: ObservableObject {
    static let shared = Model()

    @Published var config = Config()
    @Published var username = ""
    @Published var password = ""
    @Published var state = DayState()
    @Published var automationOn = false
    @Published var busy = false
    @Published var message = ""
    @Published var appearance = Appearance.current
    @Published var showLog = false
    @Published var tab = 0          // 0 = Schedule, 1 = Runtime, 2 = Account

    // What is currently on disk / in the Keychain. The published values above are what the
    // controls edit, so the difference between the two is "there is something to save".
    @Published var savedConfig = Config()
    @Published var savedUsername = ""
    @Published var savedPassword = ""

    init() { reload() }

    var configDirty: Bool { config != savedConfig }
    var credentialsDirty: Bool { username != savedUsername || password != savedPassword }
    var accountDirty: Bool { configDirty || credentialsDirty }

    var credentialsSet: Bool { !username.isEmpty && !password.isEmpty }
    var configured: Bool { credentialsSet && !config.baseUrl.isEmpty }
    var checkedInToday: Bool { state.lastCheckinDate == todayString() }
    var checkedOutToday: Bool { state.lastCheckoutDate == todayString() }

    /// Refresh from disk. Anything the user is part-way through editing is left alone —
    /// this runs on window open, on the menu tick and after every test run, and silently
    /// swallowing a half-typed password would be worse than showing a stale one.
    func reload() {
        if !configDirty,
           let d = try? Data(contentsOf: configURL),
           let c = try? JSONDecoder().decode(Config.self, from: d) { config = c; savedConfig = c }
        if let d = try? Data(contentsOf: stateURL),
           let s = try? JSONDecoder().decode(DayState.self, from: d) { state = s }
        if !credentialsDirty {
            username = keychainGet("greythr-username"); savedUsername = username
            password = keychainGet("greythr-password"); savedPassword = password
        }
        automationOn = sh("/bin/launchctl",
                          ["print", "gui/\(getuid())/\(launchdLabel)"]).ok
    }

    func saveConfig() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(config),
              (try? data.write(to: configURL)) != nil else {
            message = "Could not write config.json."
            return
        }
        savedConfig = config
    }

    func saveCredentials() {
        guard credentialsSet else { message = "Enter both a username and a password."; return }
        let ok = keychainSet("greythr-username", username) && keychainSet("greythr-password", password)
        if ok { savedUsername = username; savedPassword = password }
        message = ok ? "Saved." : "Could not write to the Keychain."
    }

    /// Write (or refresh) the LaunchAgent so it points at this copy of the app. Returns
    /// true if the file changed, meaning launchd needs to be told to reload it.
    @discardableResult
    func installLaunchAgent() -> Bool {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(launchdLabel)</string>
          <key>ProgramArguments</key>
          <array>
            <string>/bin/sh</string>
            <string>\(workerPath)</string>
          </array>
          <key>StartInterval</key><integer>300</integer>
          <key>RunAtLoad</key><true/>
          <key>StandardOutPath</key><string>\(dataDir.path)/logs/launchd.out.log</string>
          <key>StandardErrPath</key><string>\(dataDir.path)/logs/launchd.err.log</string>
        </dict>
        </plist>
        """
        let existing = try? String(contentsOf: launchAgentURL, encoding: .utf8)
        guard existing != plist else { return false }
        try? FileManager.default.createDirectory(
            at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? plist.write(to: launchAgentURL, atomically: true, encoding: .utf8)
        return true
    }

    func setAutomation(_ on: Bool) {
        installLaunchAgent()
        let r = on
            ? sh("/bin/launchctl", ["bootstrap", "gui/\(getuid())", launchAgentURL.path])
            : sh("/bin/launchctl", ["bootout", "gui/\(getuid())/\(launchdLabel)"])
        if !r.ok && !r.out.isEmpty { message = r.out }
        automationOn = sh("/bin/launchctl", ["print", "gui/\(getuid())/\(launchdLabel)"]).ok
    }

    /// Run the worker now. `action` is "--in" or "--out".
    func runNow(_ action: String, dryRun: Bool = false) {
        guard !busy else { return }
        busy = true
        message = "Running…"
        var args = [scriptURL.path, action]
        if dryRun { args.append("--dry-run") }
        DispatchQueue.global().async {
            let r = sh("/bin/sh", args)
            DispatchQueue.main.async {
                self.busy = false
                self.message = r.out.split(separator: "\n").last.map(String.init) ?? "Done."
                self.reload()
            }
        }
    }

    /// Which node would actually run, and its version. Asks run.sh so the answer always
    /// matches the real lookup. Tests the field as typed — NODE_BIN outranks config.json —
    /// so there is no need to save first.
    func testNode() {
        guard !busy else { return }
        busy = true
        message = "Checking node…"
        let typed = (config.nodePath ?? "").trimmingCharacters(in: .whitespaces)
        DispatchQueue.global().async {
            let r = sh("/bin/sh", [scriptURL.path, "--print-node"],
                       env: typed.isEmpty ? [:] : ["NODE_BIN": typed])
            DispatchQueue.main.async {
                self.busy = false
                self.message = r.out.isEmpty ? "Could not run node." : r.out
            }
        }
    }

    func recentLog(_ lines: Int = 15) -> String {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return "No log yet." }
        return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }
}

// ---------- menu bar ----------
struct MenuContent: View {
    @ObservedObject var model: Model

    var body: some View {
        if !model.configured {
            Text("⚠︎ Not set up — open Settings")
        } else {
            Text(model.checkedInToday
                 ? "● Checked in today"
                 : model.config.checkInEnabled ? "○ Check in at \(model.config.checkInAt)"
                                               : "○ Check-in off")
            Text(model.checkedOutToday
                 ? "● Checked out today"
                 : model.config.checkOutEnabled ? "○ Check out at \(model.config.checkOutAt)"
                                                : "○ Check-out off")
        }
        if !model.automationOn { Text("⚠︎ Automation is off") }

        Divider()
        Button("Check in now") { model.runNow("--in") }.disabled(model.busy)
        Button("Check out now") { model.runNow("--out") }.disabled(model.busy)
        Divider()
        Picker("Appearance", selection: Binding(
            get: { model.appearance },
            set: { model.appearance = $0; $0.apply() }
        )) {
            ForEach(Appearance.allCases) {
                Label($0.label, systemImage: $0.symbol).tag($0)
            }
        }
        Button("Settings…") { AppDelegate.shared.showSettings() }
        Button("Quit") { NSApp.terminate(nil) }
    }
}

struct LogView: View {
    @ObservedObject var model: Model

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(model.recentLog(200))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
        }
        .frame(minWidth: 400, minHeight: 200)
    }
}

// ---------- settings window ----------
struct AccountTab: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading) {
                GridRow {
                    Text("greytHR URL")
                    TextField("https://yourcompany.greythr.com", text: $model.config.baseUrl)
                }
                GridRow {
                    Text("Username")
                    TextField("employee ID", text: $model.username)
                }
                GridRow {
                    Text("Password")
                    SecureField("password", text: $model.password)
                }
            }
            HStack {
                Spacer()
                Button("Save") { model.saveConfig(); model.saveCredentials() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.accountDirty)
            }
            Text("The URL is your company's greytHR address. Credentials are "
                 + "stored in the macOS Keychain as \"greythr-username\" and "
                 + "\"greythr-password\" — never in a file. The background job reads them "
                 + "with /usr/bin/security, so approve \"Always Allow\" when macOS asks.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(16)
    }
}

struct ScheduleTab: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Check in at", isOn: $model.config.checkInEnabled)
                DatePicker("", selection: Binding(
                    get: { date(fromHHMM: model.config.checkInAt) },
                    set: { model.config.checkInAt = hhmm(from: $0) }
                ), displayedComponents: .hourAndMinute)
                .labelsHidden()
                .disabled(!model.config.checkInEnabled)
            }
            HStack {
                Toggle("Check out at", isOn: $model.config.checkOutEnabled)
                DatePicker("", selection: Binding(
                    get: { date(fromHHMM: model.config.checkOutAt) },
                    set: { model.config.checkOutAt = hhmm(from: $0) }
                ), displayedComponents: .hourAndMinute)
                .labelsHidden()
                .disabled(!model.config.checkOutEnabled)
            }
            Toggle("Weekdays only", isOn: $model.config.weekdaysOnly)
            Toggle("Automation running", isOn: Binding(
                get: { model.automationOn },
                set: { model.setAutomation($0) }
            ))
            Text("Checks every 5 minutes. If the Mac is asleep at the chosen time, "
                 + "it acts on the first check after it wakes. Which browser and which "
                 + "node it drives are on the Runtime tab.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Test check-in") { model.runNow("--in", dryRun: true) }
                Button("Test check-out") { model.runNow("--out", dryRun: true) }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Save") { model.saveConfig(); model.message = "Saved." }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.configDirty)
            }
            Spacer()
        }
        .padding(16)
    }
}

/// Which binaries the worker drives, and how visibly. Separate from Schedule, which is
/// only about *when* it runs.
struct RuntimeTab: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Browser")
                Picker("", selection: $model.config.browserPath) {
                    ForEach(BrowserChoice.installed) { Text($0.name).tag($0.path) }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            Toggle("Headless (never show the browser)", isOn: $model.config.headless)
            Text("Turn off Headless to watch the browser do it — useful when something breaks.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            HStack {
                Text("Node")
                // Blank means run.sh picks one: Homebrew, then the newest nvm, then PATH.
                TextField("auto — Homebrew, then nvm, then PATH", text: Binding(
                    get: { model.config.nodePath ?? "" },
                    set: { model.config.nodePath = $0.isEmpty ? nil : $0 }
                ))
                Button("Test") { model.testNode() }.disabled(model.busy)
            }
            Text("launchd gives the job almost no PATH, so the worker resolves node itself. "
                 + "Leave blank unless the automation must use a different node than your shell — "
                 + "run `which node` in Terminal to find that one. Test shows which node will "
                 + "actually run, and its version.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Save") { model.saveConfig(); model.message = "Saved." }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.configDirty)
            }
            Spacer()
        }
        .padding(16)
    }
}

struct SettingsView: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Appearance")
                Spacer()
                Picker("", selection: Binding(
                    get: { model.appearance },
                    set: { model.appearance = $0; $0.apply() }
                )) {
                    ForEach(Appearance.allCases) {
                        Image(systemName: $0.symbol).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .help("System, light, or dark")
            }

            // Fixed size on purpose: switching tabs must not change the content's fitting
            // size, because resizing this window from a SwiftUI state change crashes AppKit.
            TabView(selection: $model.tab) {
                ScheduleTab(model: model).tabItem { Text("Schedule") }.tag(0)
                RuntimeTab(model: model).tabItem { Text("Runtime") }.tag(1)
                AccountTab(model: model).tabItem { Text("Account") }.tag(2)
            }
            .frame(width: 440, height: 320)

            if !model.message.isEmpty {
                Text(model.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .textSelection(.enabled)
            }

            Button(model.showLog ? "Hide recent activity" : "Show recent activity…") {
                AppDelegate.shared.toggleLog()
            }
        }
        .padding(24)
        .frame(width: 488)
        .onAppear { model.reload() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static var shared: AppDelegate!
    private var window: NSWindow?
    private var logWindow: NSWindow?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        Appearance.current.apply()
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
        if Model.shared.installLaunchAgent() {
            sh("/bin/launchctl", ["bootout", "gui/\(getuid())/\(launchdLabel)"])
            sh("/bin/launchctl", ["bootstrap", "gui/\(getuid())", launchAgentURL.path])
            Model.shared.reload()
        }
        showSettings()
    }

    // The worker posts notifications through us (open -g "greythr://notify?...") instead of
    // osascript, so they are attributed to this app and clicking one opens this window.
    func application(_ app: NSApplication, open urls: [URL]) {
        for url in urls where url.host == "notify" {
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let value = { (name: String) in q.first { $0.name == name }?.value }
            post(title: value("title") ?? "greytHR", body: value("body") ?? "")
        }
        Model.shared.reload()
    }

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // Show banners even when the app is frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    // Clicking a notification opens the window — the whole point of this detour.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        showSettings()
        done()
    }

    // Launching an already-running menu bar app (Finder, `open`, Dock) lands here.
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return true
    }

    /// The activity log lives in its own window. Growing and shrinking the settings window
    /// to fit an inline section meant resizing it from inside SwiftUI's change notification,
    /// which lands in AppKit's layout pass and throws an uncatchable exception.
    func toggleLog() {
        if let w = logWindow, w.isVisible {
            w.close()
            Model.shared.showLog = false
            return
        }
        if logWindow == nil {
            let host = NSHostingView(rootView: LogView(model: Model.shared))
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
                             styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "greytHR — recent activity"
            w.isReleasedWhenClosed = false
            w.contentView = host
            w.center()
            logWindow = w
        }
        Model.shared.reload()
        Model.shared.showLog = true
        logWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSettings() {
        Model.shared.reload()
        Model.shared.tab = Model.shared.configured ? 0 : 2   // unconfigured -> Account
        if window == nil {
            let host = NSHostingView(rootView: SettingsView(model: Model.shared))
            let w = NSWindow(
                contentRect: NSRect(origin: .zero, size: host.fittingSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            w.title = "greytHR"
            w.isReleasedWhenClosed = false        // reopen the same window later
            w.contentView = host
            // Drag-resizable, but no green zoom button and no full-screen space.
            w.collectionBehavior = [.fullScreenNone]
            w.standardWindowButton(.zoomButton)?.isEnabled = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct GreytHRApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = Model.shared
    private let tick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some Scene {
        MenuBarExtra("greytHR", systemImage: "clock.badge.checkmark") {
            MenuContent(model: model)
                .onReceive(tick) { _ in model.reload() }
        }
    }
}
