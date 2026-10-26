import AppKit
import Foundation

struct Monitor {
    let id: String
    let type: String
    let resolution: String
    let enabled: Bool
    let isInternal: Bool
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
            return Monitor(id: id, type: type, resolution: field("Resolution") ?? "Unknown resolution", enabled: enabled == "true", isInternal: internalDisplay)
        }
    }

    private func reload() {
        let result = execute(["list"])
        lastError = result.1 == 0 ? nil : result.0
        detected = result.1 == 0 ? parse(result.0) : []
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
        let quit = NSMenuItem(title: "Quit Display Menu", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func refreshClicked() { reload() }
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
        let result = execute(["id:\(id) enabled:\(monitor.enabled ? "false" : "true")"])
        busy = false
        if result.1 != 0 {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Unable to change display"
            alert.informativeText = result.0.isEmpty ? "displayplacer exited with status \(result.1)" : result.0
            alert.runModal()
        }
        reload()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = DisplayMenu()
app.delegate = delegate
app.run()
