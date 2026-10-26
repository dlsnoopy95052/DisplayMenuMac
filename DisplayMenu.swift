import AppKit
import Foundation

struct Monitor {
    let id: String
    let type: String
    let resolution: String
    let enabled: Bool
    let isInternal: Bool
    var hertz: String? = nil
    var colorDepth: String? = nil
    var scaling: String? = nil
    var origin: String? = nil
    var rotation: String? = nil

    /// True only for a real "WIDTHxHEIGHT" resolution; rejects 0x0 and anything malformed.
    var hasValidResolution: Bool {
        let parts = resolution.split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return false }
        return w > 0 && h > 0
    }

    /// displayplacer argument that restores this (currently enabled) display, or nil if the state is unusable.
    var restoreArgument: String? {
        guard enabled, hasValidResolution, let hz = hertz, Int(hz).map({ $0 > 0 }) == true else { return nil }
        var parts = ["id:\(id)", "res:\(resolution)", "hz:\(hz)"]
        if let depth = colorDepth, Int(depth) != nil { parts.append("color_depth:\(depth)") }
        parts.append("enabled:true")
        if let scaling = scaling, scaling == "on" || scaling == "off" { parts.append("scaling:\(scaling)") }
        if let origin = origin, origin.hasPrefix("(") { parts.append("origin:\(origin)") }
        if let rotation = rotation, Int(rotation) != nil { parts.append("degree:\(rotation)") }
        return parts.joined(separator: " ")
    }

    var title: String {
        let kind = isInternal ? "Built-in" : "External"
        return "\(kind) · \(type) · \(resolution) · \(enabled ? "ON" : "OFF")"
    }
}

final class DisplayMenu: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let executable = "/opt/local/bin/displayplacer"
    private var detected: [Monitor] = []
    private var lastError: String?
    private var busy = false
    private let savedKey = "savedDisplayConfigs"
    private var savedConfigs: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: savedKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: savedKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = status.button {
            button.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Display Menu")
            button.title = button.image == nil ? "Displays" : ""
            button.toolTip = "Display Menu — manage external monitors"
        }
        menu.delegate = self
        status.menu = menu
        reload()
    }

    func menuWillOpen(_ menu: NSMenu) { reload() }

    private func execute(_ args: [String]) -> (String, Int32) {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return ("displayplacer not found at \(executable). Install it with: sudo port install displayplacer", 127)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
        } catch {
            return (error.localizedDescription, 1)
        }
    }

    private func parse(_ raw: String) -> [Monitor] {
        // Only the summary before each list of modes is relevant.
        let blocks = raw.components(separatedBy: "Persistent screen id: ").dropFirst()
        return blocks.compactMap { block in
            let summary = String(block.components(separatedBy: "Resolutions for rotation").first ?? "")
            let lines = summary.components(separatedBy: .newlines)
            guard let id = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty else { return nil }
            func field(_ name: String) -> String? {
                lines.first(where: { $0.hasPrefix(name + ": ") })?
                    .dropFirst(name.count + 2).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let type = field("Type"), let enabled = field("Enabled") else { return nil }
            let internalDisplay = type.lowercased().contains("built in") || type.lowercased().contains("built-in") || type.lowercased().contains("internal")
            func firstToken(_ name: String) -> String? {
                field(name)?.split(separator: " ").first.map(String.init)
            }
            return Monitor(id: id, type: type, resolution: field("Resolution") ?? "Unknown resolution", enabled: enabled == "true", isInternal: internalDisplay,
                           hertz: firstToken("Hertz"), colorDepth: firstToken("Color Depth"), scaling: firstToken("Scaling"),
                           origin: firstToken("Origin"), rotation: firstToken("Rotation"))
        }
    }

    /// Keep the last known valid configuration of every enabled external display.
    private func remember(_ monitors: [Monitor]) {
        var configs = savedConfigs
        for monitor in monitors where !monitor.isInternal {
            if let argument = monitor.restoreArgument { configs[monitor.id] = argument }
        }
        savedConfigs = configs
    }

    private func showError(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

    private func reload() {
        let result = execute(["list"])
        lastError = result.1 == 0 ? nil : result.0
        detected = result.1 == 0 ? parse(result.0) : []
        remember(detected)
        menu.removeAllItems()
        let header = NSMenuItem(title: "Detected displays (\(detected.count))", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if detected.isEmpty {
            let message = NSMenuItem(title: "No displays found", action: nil, keyEquivalent: "")
            message.isEnabled = false
            menu.addItem(message)
        }

        for monitor in detected {
            let item = NSMenuItem(title: "", action: monitor.isInternal ? nil : #selector(toggle(_:)), keyEquivalent: "")
            let prefix = monitor.isInternal ? "🔒 " : "🖥 "
            let text = prefix + monitor.title
            let attrs: [NSAttributedString.Key: Any] = monitor.isInternal
                ? [:]
                : [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
            item.attributedTitle = NSAttributedString(string: text, attributes: attrs)
            item.isEnabled = !monitor.isInternal && !busy
            item.toolTip = monitor.isInternal ? "Built-in display is protected from changes" : "Click to turn \(monitor.enabled ? "OFF" : "ON")"
            item.representedObject = monitor.id
            item.target = self
            item.state = monitor.enabled ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "Refresh detected displays", action: #selector(refreshClicked), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        if let error = lastError, !error.isEmpty {
            let truncated = String(error.prefix(180)).replacingOccurrences(of: "\n", with: " ")
            let errorItem = NSMenuItem(title: "Error: \(truncated)", action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        }
        let about = NSMenuItem(title: "About Display Menu", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let quit = NSMenuItem(title: "Quit Display Menu", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func refreshClicked() { reload() }
    @objc private func showAbout() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let built = info?["BuildTime"] as? String ?? "unknown"
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Display Menu"
        if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns") {
            alert.icon = NSImage(contentsOfFile: path)
        }
        alert.informativeText = "Version \(version)\nBuilt: \(built)"
        alert.runModal()
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    @objc private func toggle(_ item: NSMenuItem) {
        guard !busy, let id = item.representedObject as? String,
              let monitor = detected.first(where: { $0.id == id }), !monitor.isInternal else { return }
        if monitor.enabled {
            let alert = NSAlert()
            alert.messageText = "Disable external monitor?"
            alert.informativeText = "\(monitor.type) will be removed from the desktop. Some monitors may require unplugging and reconnecting the cable to turn back on."
            alert.addButton(withTitle: "Disable")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return }
        }
        busy = true
        defer { busy = false; reload() }

        // Re-read the real state so we never act on a stale menu.
        let listing = execute(["list"])
        guard listing.1 == 0 else { showError("Unable to read displays", listing.0); return }
        let current = parse(listing.0)
        remember(current)
        guard let fresh = current.first(where: { $0.id == id }), !fresh.isInternal else {
            showError("Display not found", "The display is no longer detected. Refresh and try again.")
            return
        }
        let wantEnabled = !monitor.enabled  // state requested from the menu the user clicked
        if fresh.enabled == wantEnabled { return }  // already in the requested state: run nothing

        let argument: String
        if wantEnabled {
            guard let saved = savedConfigs[id], saved.contains("res:"), !saved.contains("res:0x0") else {
                showError("Cannot turn display on",
                          "No valid saved configuration for this display. Reconnect the cable, or enable it once from System Settings so its settings can be saved.")
                return
            }
            argument = saved
        } else {
            guard fresh.restoreArgument != nil || savedConfigs[id] != nil else {
                showError("Cannot turn display off", "Its current configuration is not valid, so it could not be saved for restoring. Aborting to keep it recoverable.")
                return
            }
            argument = "id:\(id) enabled:false"
        }
        let result = execute([argument])
        if result.1 != 0 {
            showError("Unable to change display", result.0.isEmpty ? "displayplacer exited with status \(result.1)" : result.0)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = DisplayMenu()
app.delegate = delegate
app.run()
