// SpareRoom: a menu bar storage meter for macOS with a native glass panel.
// Shows free space and how much more can be freed, turns red when space runs low,
// and cleans with the bundled cleanup.sh (which only removes things that rebuild themselves).
import AppKit
import SwiftUI

let logPath = ("~/Library/Logs/SpareRoom.log" as NSString).expandingTildeInPath
let script = Bundle.main.path(forResource: "cleanup", ofType: "sh") ?? ""
let GB: Int64 = 1_000_000_000

func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .decimal) }

struct Category { let key, name, icon, help: String; var needsCode = false }
let categories: [Category] = [
    .init(key: "caches", name: "App caches", icon: "square.stack.3d.up.fill",
          help: "Temporary files apps keep to open faster. Only ones unused for a week. Apps rebuild them."),
    .init(key: "logs", name: "Old logs", icon: "doc.text.fill",
          help: "Diagnostic records older than a week. Nothing you made."),
    .init(key: "devcaches", name: "Download caches", icon: "shippingbox.fill",
          help: "Copies of tools downloaded by npm, Homebrew and pnpm. Downloaded again when needed."),
    .init(key: "xcode", name: "Xcode builds", icon: "hammer.fill",
          help: "Build files Xcode makes. Rebuilt the next time you build an app."),
    .init(key: "simulators", name: "iPhone simulators", icon: "iphone",
          help: "Apps and data inside test iPhones. The simulators stay and start fresh."),
    .init(key: "worktrees", name: "Old project copies", icon: "folder.fill.badge.minus",
          help: "Extra copies of projects (git worktrees). Only copies with all work committed and pushed, nothing running inside, and no Claude Code chat using them in 4 hours.",
          needsCode: true),
    .init(key: "webbuild", name: "Website builds", icon: "globe",
          help: "Built copies of websites (.next). Rebuilt on the next build. Skipped while a project is running."),
    .init(key: "deps", name: "Packages in idle projects", icon: "cube.box.fill",
          help: "Installed packages (node_modules) in project copies untouched for a week. Reinstalled when you work on them again."),
    .init(key: "mole", name: "Mole deep clean", icon: "wand.and.stars",
          help: "Mole's full cache sweep. May ask to access other apps' data."),
]

@MainActor final class Model: ObservableObject {
    @AppStorage("warnGB") var warnGB = 30
    @AppStorage("autoClean") var autoClean = false
    @AppStorage("projectDir") var projectDir = ""   // folder with the user's git projects; empty = off
    var hidePanel: () -> Void = {}
    @AppStorage("useMole") var useMole = false
    @AppStorage("skipped") var skippedRaw = ""          // categories the user turned off
    @AppStorage("lastAuto") var lastAuto = 0.0
    @AppStorage("samples") var samplesRaw = ""          // "time:free;..." for the trend

    @Published var free: Int64 = 0
    @Published var total: Int64 = 1
    @Published var sizes: [String: Int64] = Model.loadSizes()
    @Published var progress = 0.0          // 0...1 while checking
    @Published var checking = ""            // category being checked
    @AppStorage("sizes") var sizesRaw = ""  // last results, so the panel opens with numbers
    @Published var scannedAt: Date?
    @Published var scanning = false
    @Published var cleaning = false
    @Published var step = ""
    @Published var stepKey = ""             // category being cleaned
    @Published var cleanedKeys: Set<String> = []
    @Published var cleanTotal = 0
    @Published var finished = false
    var justFinished = false
    @Published var freedFrom = ""           // "From old logs and download caches"                // menu bar shows "Freed X" for 30 s         // shows the "Freed X" banner until the next clean
    @Published var result = ""
    @Published var showSettings = false
    var onChange: () -> Void = {}
    private var scanProcess: Process?

    var needsAccess: Bool {
        projectDir.isEmpty && FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.gitconfig")
    }
    var low: Bool { free < Int64(warnGB) * GB }
    var visible: [Category] { categories.filter { (sizes[$0.key] ?? 0) > 0 } }
    func isOn(_ k: String) -> Bool { !skippedRaw.split(separator: ",").contains(Substring(k)) }
    func toggle(_ k: String) {
        var s = Set(skippedRaw.split(separator: ",").map(String.init))
        if s.contains(k) { s.remove(k) } else { s.insert(k) }
        skippedRaw = s.sorted().joined(separator: ","); objectWillChange.send(); onChange()
    }
    var selected: [Category] { visible.filter { isOn($0.key) } }
    var selectedBytes: Int64 { selected.reduce(0) { $0 + (sizes[$1.key] ?? 0) } }

    /// Bytes per day the disk is filling, from samples over the last 2 days (nil if too little data).
    var fillRate: Double? {
        let now = Date().timeIntervalSince1970
        let pts = samplesRaw.split(separator: ";").compactMap { p -> (Double, Double)? in
            let f = p.split(separator: ":"); guard f.count == 2, let t = Double(f[0]), let v = Double(f[1]) else { return nil }
            return (t, v)
        }.filter { now - $0.0 < 2 * 86400 }
        guard let first = pts.first, now - first.0 > 6 * 3600 else { return nil }
        return (first.1 - Double(free)) / (now - first.0) * 86400
    }
    var trend: String {
        guard let r = fillRate, r > Double(GB) else { return "Steady" }
        let days = Double(free) / r
        return "Filling about \(fmt(Int64(r))) a day" + (days < 30 ? ", full in about \(max(1, Int(days))) days" : "")
    }

    func refreshFree() {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
        free = Int64(v?.volumeAvailableCapacity ?? 0); total = Int64(v?.volumeTotalCapacity ?? 1)
        let now = Date().timeIntervalSince1970
        var s = samplesRaw.split(separator: ";").map(String.init)
        let lastT = s.last.flatMap { Double($0.split(separator: ":")[0]) } ?? 0
        if now - lastT > 1800 {   // one sample every 30 min, keep a week
            s.append("\(Int(now)):\(free)"); samplesRaw = s.suffix(336).joined(separator: ";")
        }
        onChange()
        if low && autoClean && !cleaning && now - lastAuto > 6 * 3600 {
            lastAuto = now; clean(auto: true)
        }
    }

    /// Lets the user pick their projects folder. Picking it in the standard dialog is what grants access.
    func chooseProjectFolder() {
        hidePanel()
        NSApp.activate()
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        p.message = "Choose the folder that holds your coding projects"
        p.prompt = "Use This Folder"
        p.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        if p.runModal() == .OK, let url = p.url {
            projectDir = url.path; scannedAt = nil; scan()
        }
    }

    static var moleInstalled: Bool {
        ["/opt/homebrew/bin/mo", "/usr/local/bin/mo"].contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func scanIfStale() { if scannedAt.map({ Date().timeIntervalSince($0) > 600 }) ?? true { scan() } }

    static func loadSizes() -> [String: Int64] {
        var d: [String: Int64] = [:]
        for p in (UserDefaults.standard.string(forKey: "sizes") ?? "").split(separator: ",") {
            let f = p.split(separator: "="); if f.count == 2, let v = Int64(f[1]) { d[String(f[0])] = v }
        }
        return d
    }

    func scan() {
        guard !scanning, !cleaning else { return }
        scanning = true; progress = 0; checking = ""
        var found: [String: Int64] = [:], total = 1.0, done = 0.0
        scanProcess = run(env: ["DRY": "1"], line: { [self] l in
            let p = l.split(separator: " ")
            guard p.count >= 2 else { return }
            switch p[0] {
            case "@total": total = Double(p[1]) ?? 1
            case "@check":
                progress = done / total; done += 1
                checking = categories.first { $0.key == p[1] }?.name ?? ""
            case "@est" where p.count == 3:
                if let kb = Int64(p[2]) { found[String(p[1])] = kb * 1024; sizes[String(p[1])] = kb * 1024 }  // show as it arrives
            default: break
            }
        }) { [self] in
            if scanning {
                sizes = found; scannedAt = Date()
                sizesRaw = found.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            }
            scanning = false; progress = 1; checking = ""; scanProcess = nil; onChange()
        }
    }

    func clean(auto: Bool = false) {
        guard !cleaning else { return }
        scanProcess?.terminate(); scanning = false
        let keys = auto ? categories.map(\.key).filter(isOn) : selected.map(\.key)
        guard !keys.isEmpty else { return }
        let before = free
        cleaning = true; finished = false; step = "Starting"; stepKey = ""; result = ""
        cleanedKeys = []; cleanTotal = keys.count; onChange()
        _ = run(env: ["CATS": keys.joined(separator: ",")], line: { [self] l in
            let p = l.split(separator: " "); guard p.count == 2 else { return }
            let key = String(p[1])
            switch p[0] {
            case "@total": cleanTotal = Int(key) ?? cleanTotal
            case "@step": stepKey = key; step = categories.first { $0.key == key }?.name ?? key; onChange()
            case "@done": cleanedKeys.insert(key); onChange()
            default: break
            }
        }) { [self] in
            cleaning = false; step = ""; stepKey = ""; refreshFree()
            result = (auto ? "Cleaned automatically. " : "") + "Freed \(fmt(max(0, free - before)))"
            let names = categories.filter { cleanedKeys.contains($0.key) }.map { $0.name.lowercased() }
            freedFrom = names.isEmpty ? "" : "From " + ListFormatter.localizedString(byJoining: names)
            for k in cleanedKeys { sizes[k] = 0 }   // already freed; the re-check below fills in what is left
            finished = true; justFinished = true; onChange()
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.justFinished = false; self?.onChange() }
            scannedAt = nil; scan()
        }
    }

    /// Runs the script; output goes to the log and, line by line, to `line` on the main actor.
    private func run(env: [String: String], line: @escaping (String) -> Void, done: @escaping () -> Void) -> Process? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script]
        var e = ProcessInfo.processInfo.environment
        e["PROJECT_DIR"] = projectDir; e["MOLE"] = useMole ? "1" : "0"
        p.environment = e.merging(env) { $1 }
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let log = FileHandle(forWritingAtPath: logPath)
        let buf = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData; guard !d.isEmpty else { return }
            log?.write(d)
            let lines = buf.feed(d)
            DispatchQueue.main.async { lines.forEach(line) }
        }
        p.terminationHandler = { _ in
            pipe.fileHandleForReading.readabilityHandler = nil; try? log?.close()
            DispatchQueue.main.async { done() }
        }
        do { try p.run(); return p } catch { done(); return nil }
    }
}

final class LineBuffer: @unchecked Sendable {   // used only from the pipe's serial handler
    private var s = ""
    func feed(_ d: Data) -> [String] {
        s += String(decoding: d, as: UTF8.self)
        var out: [String] = []
        while let r = s.firstIndex(of: "\n") { out.append(String(s[..<r])); s = String(s[s.index(after: r)...]) }
        return out
    }
}

// MARK: - UI (native menu-bar extra look: one glass sheet, rows like the Wi-Fi menu)

struct Row<Trailing: View>: View {
    let icon: String; var on = false; var tint: Color = .accentColor
    let title: String; var subtitle: String? = nil
    var action: (() -> Void)? = nil
    @ViewBuilder var trailing: Trailing
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 12, weight: .medium))
                .foregroundStyle(on ? Color.white : Color.primary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(on ? tint : Color.primary.opacity(0.1)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                if let s = subtitle { Text(s).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(hover && action != nil ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { action?() }
    }
}

struct PlainRow: View {   // like "Wi-Fi Settings…" at the bottom of the Wi-Fi menu
    let title: String; let action: () -> Void
    @State private var hover = false
    var body: some View {
        Text(title).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle()).onHover { hover = $0 }.onTapGesture(perform: action)
    }
}

let shadowRoom: CGFloat = 24   // transparent margin so the shadow is not clipped

struct Panel: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            storage
            Divider().padding(.horizontal, 8)
            if m.showSettings { options } else { cleanup }
            Divider().padding(.horizontal, 8)
            PlainRow(title: m.showSettings ? "Done" : "Options…") { m.showSettings.toggle() }
            PlainRow(title: "Storage Settings…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!)
            }
            PlainRow(title: "Quit SpareRoom") { NSApp.terminate(nil) }
        }
        .padding(6)
        .frame(width: 310)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        // The shadow follows the rounded glass; the window's own shadow would be square.
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        .padding(shadowRoom)
    }

    func header(_ t: String, _ trailing: String = "") -> some View {
        HStack {
            Text(t).font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(trailing).font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
        }.padding(.horizontal, 8).padding(.top, 4)
    }

    var storage: some View {
        VStack(alignment: .leading, spacing: 6) {
            header("Storage", "\(fmt(m.free)) free")
            GeometryReader { g in
                let t = Double(max(m.total, 1)), used = Double(m.total - m.free)
                let can = min(Double(m.selectedBytes), used)
                // used (minus what can be freed) | can be freed | empty
                HStack(spacing: 1.5) {
                    Capsule().fill(m.low ? Color.red : Color.primary.opacity(0.55))
                        .frame(width: g.size.width * (used - can) / t)
                    if can > 0 {
                        Capsule().fill(Color.accentColor.opacity(0.75)).frame(width: max(3, g.size.width * can / t))
                    }
                    Capsule().fill(Color.primary.opacity(0.12))
                }
                .animation(.easeOut(duration: 0.4), value: m.free)
                .animation(.easeOut(duration: 0.4), value: m.selectedBytes)
            }.frame(height: 7).padding(.horizontal, 8)
            HStack(spacing: 12) {
                legend(Color.primary.opacity(0.12), "\(fmt(m.free)) empty")
                if m.selectedBytes > 0 { legend(.accentColor, "\(fmt(m.selectedBytes)) can be freed") }
                Spacer()
            }.padding(.horizontal, 8)
            Text(m.low ? "Below \(m.warnGB) GB. Free up some space." : "\(fmt(m.total - m.free)) used of \(fmt(m.total)) · \(m.trend)")
                .font(.system(size: 11)).foregroundStyle(m.low ? .red : .secondary)
                .padding(.horizontal, 8).padding(.bottom, 2)
        }
    }

    func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text(t).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    var cleanup: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Can be freed").font(.system(size: 13, weight: .semibold))
                Spacer()
                if m.scanning {
                    ProgressView(value: m.progress).progressViewStyle(.circular).controlSize(.small)
                        .animation(.easeOut(duration: 0.3), value: m.progress)
                    Text(m.checking.isEmpty ? "Checking…" : "Checking \(m.checking.lowercased())…")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(fmt(m.visible.reduce(0) { $0 + (m.sizes[$1.key] ?? 0) }))
                        .font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
                }
            }.padding(.horizontal, 8).padding(.top, 4)
            ForEach(m.visible, id: \.key) { c in
                let on = m.isOn(c.key)
                Row(icon: c.icon, on: on, title: c.name, subtitle: c.help,
                    action: m.cleaning ? nil : { m.toggle(c.key) }) {
                    if m.cleaning && m.cleanedKeys.contains(c.key) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            .transition(.scale.combined(with: .opacity))
                    } else if m.cleaning && m.stepKey == c.key {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(fmt(m.sizes[c.key] ?? 0)).font(.system(size: 12)).monospacedDigit()
                            .foregroundStyle(on && !m.cleaning ? .primary : .secondary)
                    }
                }
            }
            if m.needsAccess {
                Row(icon: "chevron.left.forwardslash.chevron.right", title: "Coding projects",
                    subtitle: "Old project copies, builds and packages. Choose the folder that holds your projects.") {
                    Button("Choose…") { m.chooseProjectFolder() }
                        .buttonStyle(.glass).controlSize(.small)
                }
            }
            if m.visible.isEmpty && !m.scanning && !m.needsAccess {
                Text("Nothing to clean right now.").font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
            if m.cleaning {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: Double(m.cleanedKeys.count), total: Double(max(m.cleanTotal, 1)))
                        .animation(.easeOut(duration: 0.3), value: m.cleanedKeys.count)
                    Text("Step \(min(m.cleanedKeys.count + 1, max(m.cleanTotal, 1))) of \(max(m.cleanTotal, 1)) · \(m.step)")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }.padding(.horizontal, 8).padding(.top, 6)
            } else if m.finished && !m.result.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.result).font(.system(size: 13, weight: .semibold))
                        if !m.freedFrom.isEmpty {
                            Text(m.freedFrom).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.12)))
                .padding(.horizontal, 8).padding(.top, 6)
                .transition(.opacity)
            }
            if (!m.visible.isEmpty || m.cleaning) && !m.cleaning {
                Button { m.clean() } label: {
                    HStack(spacing: 6) {
                        if m.selected.isEmpty { Text("Select something to clean") }
                        else { Text("Free Up \(fmt(m.selectedBytes))") }
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent).controlSize(.large)
                .tint(m.low ? .red : .accentColor)
                .disabled(m.cleaning || m.selected.isEmpty)
                .padding(.horizontal, 8).padding(.top, 6)
            }
        }
        .padding(.bottom, 4)
    }

    var options: some View {
        VStack(alignment: .leading, spacing: 2) {
            header("Options")
            Row(icon: "exclamationmark.triangle", title: "Warn me below") {
                Picker("", selection: $m.warnGB) {
                    ForEach([10, 20, 30, 50, 100], id: \.self) { Text("\($0) GB").tag($0) }
                }.labelsHidden().fixedSize().controlSize(.small)
            }
            toggleRow("arrow.triangle.2.circlepath", "Clean automatically",
                      "When space runs low, at most every 6 hours.", $m.autoClean)
            Row(icon: "chevron.left.forwardslash.chevron.right", on: !m.projectDir.isEmpty, title: "Coding projects",
                subtitle: m.projectDir.isEmpty ? "Off" : (m.projectDir as NSString).abbreviatingWithTildeInPath) {
                if m.projectDir.isEmpty {
                    Button("Choose…") { m.chooseProjectFolder() }.buttonStyle(.glass).controlSize(.small)
                } else {
                    Button("Turn Off") { m.projectDir = ""; m.scannedAt = nil; m.scan() }.buttonStyle(.glass).controlSize(.small)
                }
            }
            if Model.moleInstalled {
                toggleRow("wand.and.stars", "Mole deep clean", "May ask to access other apps' data.", $m.useMole)
            }
        }
        .padding(.bottom, 4)
        .onChange(of: m.useMole) { m.scannedAt = nil; m.scan() }
        .onChange(of: m.warnGB) { m.refreshFree() }
    }

    func toggleRow(_ icon: String, _ title: String, _ sub: String, _ b: Binding<Bool>) -> some View {
        Row(icon: icon, on: b.wrappedValue, title: title, subtitle: sub) {
            Toggle("", isOn: b).toggleStyle(.switch).labelsHidden().controlSize(.mini)
        }
    }
}

// MARK: - Panel window that stays under the menu bar icon and closes on outside clicks

final class AnchoredPanel: NSPanel {
    var topRight: NSPoint = .zero   // keeps the panel pinned below the icon as its height changes
    override var canBecomeKey: Bool { true }
    override func setFrame(_ r: NSRect, display: Bool) {
        var f = r; f.origin = NSPoint(x: topRight.x - f.width, y: topRight.y - f.height)
        super.setFrame(f, display: display)
    }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }   // Esc
}

@MainActor final class App: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let model = Model()
    var panel: AnchoredPanel!
    var outsideClick: Any?

    func applicationDidFinishLaunching(_ n: Notification) {
        let host = NSHostingController(rootView: Panel(m: model))
        host.sizingOptions = .preferredContentSize
        host.view.wantsLayer = true; host.view.layer?.backgroundColor = .clear
        panel = AnchoredPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.contentViewController = host
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .statusBar; panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        item.button?.target = self; item.button?.action = #selector(toggle)
        model.onChange = { [weak self] in self?.updateButton() }
        model.hidePanel = { [weak self] in self?.close() }
        model.refreshFree(); model.scan()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.model.refreshFree() }
        }
    }

    func updateButton() {
        guard let b = item.button else { return }
        let low = model.low
        b.image = NSImage(systemSymbolName: low ? "externaldrive.fill.badge.exclamationmark" : "internaldrive",
                          accessibilityDescription: "Storage")
        b.image?.isTemplate = true
        b.contentTintColor = low ? .systemRed : nil
        let main = model.cleaning ? " Cleaning \(min(model.cleanedKeys.count + 1, max(model.cleanTotal, 1)))/\(max(model.cleanTotal, 1))"
            : model.justFinished ? " ✓ \(model.result)" : " \(model.free / GB) GB"
        let title = NSMutableAttributedString(string: main, attributes: low ? [.foregroundColor: NSColor.systemRed] : [:])
        let can = model.selectedBytes / GB
        if !model.cleaning && !model.justFinished && can >= 1 {
            let att = NSTextAttachment(); att.image = badge("+\(can) GB")
            att.bounds = NSRect(x: 0, y: -2.5, width: att.image!.size.width, height: att.image!.size.height)
            title.append(NSAttributedString(string: "  "))
            title.append(NSAttributedString(attachment: att))
        }
        b.attributedTitle = title
        b.toolTip = "\(fmt(model.free)) empty" + (can >= 1 ? ", about \(fmt(model.selectedBytes)) more can be freed" : "")
    }

    /// Small pill with the text cut out. Drawn on demand with the label color, so it follows light and dark menu bars.
    func badge(_ text: String) -> NSImage {
        let font = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
        let ts = (text as NSString).size(withAttributes: [.font: font])
        let size = NSSize(width: ceil(ts.width) + 9, height: 14)
        let img = NSImage(size: size, flipped: false) { r in
            NSColor.labelColor.withAlphaComponent(0.5).setFill()
            NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            (text as NSString).draw(at: NSPoint(x: (r.width - ts.width) / 2, y: (r.height - ts.height) / 2 + 0.5),
                                    withAttributes: [.font: font, .foregroundColor: NSColor.black])
            return true
        }
        return img
    }

    @objc func toggle() { panel.isVisible ? close() : open() }

    func open() {
        guard let b = item.button, let w = b.window, let screen = w.screen else { return }
        model.refreshFree(); model.scanIfStale(); model.showSettings = false
        let icon = w.convertToScreen(b.convert(b.bounds, to: nil))
        let width: CGFloat = 310
        // The window is shadowRoom bigger on every side than the visible glass.
        let right = min(icon.midX + width / 2, screen.visibleFrame.maxX - 6) + shadowRoom
        panel.topRight = NSPoint(x: max(right, screen.visibleFrame.minX + width + 6 + shadowRoom),
                                 y: screen.visibleFrame.maxY - 4 + shadowRoom)
        panel.setFrame(NSRect(origin: .zero, size: panel.contentViewController!.preferredContentSize), display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        // A global listener sees clicks in other apps and the desktop; no permission needed for mouse events.
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.close() }
        }
    }

    func close() {
        if let m = outsideClick { NSEvent.removeMonitor(m); outsideClick = nil }
        let p = panel!
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; p.animator().alphaValue = 0 },
                                             completionHandler: { p.orderOut(nil) })
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { App() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
