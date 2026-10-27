import AppKit
import Foundation
import IOKit
import IOKit.i2c
import IOKit.graphics
import ApplicationServices

/// True only for a real "WIDTHxHEIGHT" resolution; rejects 0x0 and anything malformed.
func isValidResolution(_ resolution: String) -> Bool {
    let parts = resolution.split(separator: "x")
    guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return false }
    return w > 0 && h > 0
}

struct Mode {
    let resolution: String
    let hertz: String?
    let colorDepth: String?
    let scaling: String?
    let isCurrent: Bool

    var label: String {
        var text = resolution
        if let hz = hertz, Int(hz) != nil { text += " @ \(hz)Hz" }
        if scaling == "on" { text += "  HiDPI" }
        return text
    }
    var pixels: Int {
        resolution.split(separator: "x").compactMap { Int($0) }.reduce(1, *)
    }
    func sameAs(_ other: Mode) -> Bool {
        resolution == other.resolution && hertz == other.hertz && colorDepth == other.colorDepth && scaling == other.scaling
    }
    /// displayplacer argument that switches this display to this mode, or nil if the mode is unusable.
    func argument(for monitor: Monitor) -> String? {
        guard isValidResolution(resolution) else { return nil }
        var parts = ["id:\(monitor.id)", "res:\(resolution)"]
        if let hz = hertz, let value = Int(hz), value > 0 { parts.append("hz:\(hz)") }
        if let depth = colorDepth, Int(depth) != nil { parts.append("color_depth:\(depth)") }
        parts.append("enabled:true")
        if let scaling = scaling, scaling == "on" || scaling == "off" { parts.append("scaling:\(scaling)") }
        if let rotation = monitor.rotation, Int(rotation) != nil { parts.append("degree:\(rotation)") }
        return parts.joined(separator: " ")
    }
}

final class ModeChoice {
    let id: String
    let mode: Mode
    init(id: String, mode: Mode) { self.id = id; self.mode = mode }
}

/// Brightness: DDC/CI over I2C for external displays, DisplayServices (private, loaded dynamically) for the built-in one.
/// Every call fails soft: when a display or API does not answer, the caller simply gets nil/false and hides the slider.
enum BrightnessControl {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let queue = DispatchQueue(label: "com.local.displaymenu.ddc")
    private static var maxValues: [CGDirectDisplayID: Int] = [:]  // only touched on `queue`

    private static let displayServices: (get: GetFn, set: SetFn)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let g = dlsym(handle, "DisplayServicesGetBrightness"),
              let s = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return (unsafeBitCast(g, to: GetFn.self), unsafeBitCast(s, to: SetFn.self))
    }()

    /// displayplacer's persistent screen id is the CoreGraphics display UUID.
    static func displayID(forPersistentID id: String) -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { display in
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
                  let text = CFUUIDCreateString(nil, uuid) as String? else { return false }
            return text.uppercased() == id.uppercased()
        }
    }

    /// Brightness 0...1, or nil when the display does not support it.
    static func get(displayID: CGDirectDisplayID, isInternal: Bool) -> Float? {
        if isInternal {
            var value: Float = 0
            guard let api = displayServices, api.get(displayID, &value) == 0 else { return nil }
            return value
        }
        return queue.sync {
            guard let reply = ddc(displayID, send: vcpRequest([0x51, 0x82, 0x01, 0x10]), replyLength: 11),
                  reply[2] == 0x02, reply[3] == 0x00, reply[4] == 0x10 else { return nil }
            let maximum = Int(reply[6]) << 8 | Int(reply[7])
            let current = Int(reply[8]) << 8 | Int(reply[9])
            guard maximum > 0 else { return nil }
            maxValues[displayID] = maximum
            return Float(min(current, maximum)) / Float(maximum)
        }
    }

    @discardableResult
    static func set(displayID: CGDirectDisplayID, isInternal: Bool, level: Float) -> Bool {
        let level = min(max(level, 0), 1)
        if isInternal {
            guard let api = displayServices else { return false }
            return api.set(displayID, level) == 0
        }
        return queue.sync {
            let value = Int((level * Float(maxValues[displayID] ?? 100)).rounded())
            let message = vcpRequest([0x51, 0x84, 0x03, 0x10, UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
            return ddc(displayID, send: message, replyLength: 0) != nil
        }
    }

    /// Appends the DDC/CI checksum (XOR of the 0x6E destination address and every payload byte).
    private static func vcpRequest(_ payload: [UInt8]) -> [UInt8] {
        payload + [payload.reduce(0x6E, ^)]
    }

    /// Finds the IOFramebuffer driving this display by matching vendor / product / serial against its EDID.
    private static func framebuffer(for displayID: CGDirectDisplayID) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOFramebuffer"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let edid = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "IODisplayEDID" as CFString, nil,
                                                          IOOptionBits(kIORegistryIterateRecursively)) as? Data, edid.count >= 16 {
                let b = [UInt8](edid)
                let vendor = UInt32(b[8]) << 8 | UInt32(b[9])
                let product = UInt32(b[11]) << 8 | UInt32(b[10])
                let serial = UInt32(b[15]) << 24 | UInt32(b[14]) << 16 | UInt32(b[13]) << 8 | UInt32(b[12])
                if vendor == CGDisplayVendorNumber(displayID), product == CGDisplayModelNumber(displayID),
                   serial == CGDisplaySerialNumber(displayID) { return service }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return nil
    }

    /// One DDC/CI transaction. Returns the reply bytes (empty array when no reply is expected), or nil on failure.
    private static func ddc(_ displayID: CGDirectDisplayID, send: [UInt8], replyLength: Int) -> [UInt8]? {
        guard let fb = framebuffer(for: displayID) else { return nil }
        defer { IOObjectRelease(fb) }
        var buses: IOItemCount = 0
        guard IOFBGetI2CInterfaceCount(fb, &buses) == KERN_SUCCESS else { return nil }
        for bus in 0..<buses {
            var interface: io_service_t = 0
            guard IOFBCopyI2CInterfaceForBus(fb, IOOptionBits(bus), &interface) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(interface) }
            var connection: IOI2CConnectRef?
            guard IOI2CInterfaceOpen(interface, 0, &connection) == KERN_SUCCESS, let conn = connection else { continue }
            defer { IOI2CInterfaceClose(conn, 0) }

            var out = send
            let sendCount = UInt32(send.count)
            var reply = [UInt8](repeating: 0, count: max(replyLength, 1))
            var ok = false
            out.withUnsafeMutableBufferPointer { sendPtr in
                reply.withUnsafeMutableBufferPointer { replyPtr in
                    var request = IOI2CRequest()
                    request.commFlags = 0
                    request.sendAddress = 0x6E
                    request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                    request.sendBuffer = vm_address_t(bitPattern: sendPtr.baseAddress)
                    request.sendBytes = sendCount
                    request.minReplyDelay = 30_000_000
                    if replyLength > 0 {
                        request.replyAddress = 0x6F
                        request.replySubAddress = 0x51
                        request.replyTransactionType = IOOptionBits(kIOI2CDDCciReplyTransactionType)
                        request.replyBuffer = vm_address_t(bitPattern: replyPtr.baseAddress)
                        request.replyBytes = UInt32(replyLength)
                    } else {
                        request.replyTransactionType = IOOptionBits(kIOI2CNoTransactionType)
                        request.replyBytes = 0
                    }
                    ok = IOI2CSendRequest(conn, 0, &request) == KERN_SUCCESS && request.result == KERN_SUCCESS
                }
            }
            if ok { return replyLength > 0 ? reply : [] }
        }
        return nil
    }
}

/// Custom ON/OFF switch. NSSwitch renders grey inside menus (menu windows are never key), so draw it ourselves.
final class ToggleSwitch: NSControl {
    var isOn = false { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.5 } }
    override var intrinsicContentSize: NSSize { NSSize(width: 40, height: 24) }

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds.insetBy(dx: 1, dy: 1)
        (isOn ? NSColor.systemBlue : NSColor.tertiaryLabelColor).setFill()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
        let d = track.height - 4
        let x = isOn ? track.maxX - d - 2 : track.minX + 2
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: track.minY + 2, width: d, height: d)).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isOn.toggle()
        sendAction(action, to: target)
    }
}

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
    var modes: [Mode] = []
    /// Product name reported by the display itself (e.g. "LG HDR 4K"); nil when unknown.
    var productName: String? = nil

    var displayName: String { isInternal ? "Built-in Display" : (productName ?? type) }

    var hasValidResolution: Bool { isValidResolution(resolution) }

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
        return "\(kind) · \(displayName) · \(resolution) · \(enabled ? "ON" : "OFF")"
    }
}

final class DisplayMenu: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    // MacPorts first (original target), then Homebrew on Intel and Apple Silicon.
    private static let executableCandidates = ["/opt/local/bin/displayplacer", "/usr/local/bin/displayplacer", "/opt/homebrew/bin/displayplacer"]
    private let executable = DisplayMenu.executableCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        ?? DisplayMenu.executableCandidates[0]
    private var detected: [Monitor] = []
    private var lastError: String?
    private var busy = false
    private let agentURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.local.displaymenu.plist")
    private var brightnessTargets: [String: (displayID: CGDirectDisplayID, isInternal: Bool)] = [:]
    private var pendingLevels: [String: Float] = [:]
    private let pendingLock = NSLock()
    private let savedKey = "savedDisplayConfigs"
    private let namesKey = "savedDisplayNames"
    /// Product names remembered per display, so a switched-off display keeps its name.
    private var savedNames: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: namesKey) }
    }
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

    func menuWillOpen(_ menu: NSMenu) { if !busy { reload() } }

    /// Runs a displayplacer change off the main thread (macOS can take seconds to reconfigure a display),
    /// then reports errors and refreshes the menu.
    private func applyAsync(_ argument: String, failureTitle: String) {
        busy = true
        status.button?.appearsDisabled = true
        status.button?.toolTip = "Display Menu — applying change…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let result = self.execute([argument])
            DispatchQueue.main.async {
                self.busy = false
                self.status.button?.appearsDisabled = false
                self.status.button?.toolTip = "Display Menu — manage external monitors"
                if result.1 != 0 {
                    self.showError(failureTitle, result.0.isEmpty ? "displayplacer exited with status \(result.1)" : result.0)
                }
                self.reload()
            }
        }
    }

    private func execute(_ args: [String]) -> (String, Int32) {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return ("displayplacer not found. Install it with: sudo port install displayplacer (MacPorts) or brew tap jakehilborn/jakehilborn && brew install displayplacer (Homebrew)", 127)
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

    private func parseModes(_ block: String) -> [Mode] {
        // Only the first "Resolutions for rotation" section (the current rotation).
        let sections = block.components(separatedBy: "Resolutions for rotation")
        guard sections.count > 1 else { return [] }
        var modes: [Mode] = []
        for line in sections[1].components(separatedBy: .newlines) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("mode "), let colon = text.firstIndex(of: ":") else { continue }
            var fields: [String: String] = [:]
            for token in text[text.index(after: colon)...].split(separator: " ") {
                let pair = token.split(separator: ":", maxSplits: 1)
                if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
            }
            guard let res = fields["res"], isValidResolution(res) else { continue }
            modes.append(Mode(resolution: res, hertz: fields["hz"], colorDepth: fields["color_depth"],
                              scaling: fields["scaling"], isCurrent: text.contains("<-- current mode")))
        }
        return modes
    }

    /// Menu-sized list: 8-bit modes only, best refresh rate per resolution, plus the current mode.
    private func choices(for monitor: Monitor) -> [Mode] {
        var best: [String: Mode] = [:]
        for mode in monitor.modes where mode.colorDepth == "8" || mode.isCurrent {
            let key = mode.resolution + "|" + (mode.scaling ?? "")
            let hz = Int(mode.hertz ?? "") ?? 0
            if let old = best[key], (Int(old.hertz ?? "") ?? 0) >= hz { continue }
            best[key] = mode
        }
        var result = Array(best.values)
        if let current = monitor.modes.first(where: { $0.isCurrent }), !result.contains(where: { $0.sameAs(current) }) {
            result.append(current)
        }
        return result.sorted { ($0.pixels, $0.hertz ?? "") > ($1.pixels, $1.hertz ?? "") }
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
                           origin: firstToken("Origin"), rotation: firstToken("Rotation"), modes: parseModes(block))
        }
    }

    /// Fill in each external display's product name from NSScreen, falling back to the last name seen.
    private func resolveNames() {
        var names = savedNames
        for index in detected.indices where !detected[index].isInternal {
            let id = detected[index].id
            if let displayID = BrightnessControl.displayID(forPersistentID: id),
               let screen = NSScreen.screens.first(where: {
                   ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }),
               !screen.localizedName.isEmpty {
                names[id] = screen.localizedName
            }
            detected[index].productName = names[id]
        }
        savedNames = names
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
        resolveNames()
        remember(detected)
        menu.removeAllItems()
        brightnessTargets.removeAll()
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
            let item = NSMenuItem()
            item.view = rowView(for: monitor)
            menu.addItem(item)
            if monitor.enabled, let displayID = BrightnessControl.displayID(forPersistentID: monitor.id),
               let level = BrightnessControl.get(displayID: displayID, isInternal: monitor.isInternal) {
                brightnessTargets[monitor.id] = (displayID, monitor.isInternal)
                let sliderItem = NSMenuItem()
                sliderItem.view = brightnessRow(for: monitor, level: level)
                menu.addItem(sliderItem)
            }
            if monitor.enabled, let current = monitor.modes.first(where: { $0.isCurrent }) {
                let options = choices(for: monitor)
                if options.count > 1 {
                    let parent = NSMenuItem(title: "Resolution: \(current.label)", action: nil, keyEquivalent: "")
                    parent.indentationLevel = 2
                    let submenu = NSMenu()
                    for mode in options {
                        let entry = NSMenuItem(title: mode.label, action: #selector(modeClicked(_:)), keyEquivalent: "")
                        entry.target = self
                        entry.representedObject = ModeChoice(id: monitor.id, mode: mode)
                        entry.state = mode.isCurrent ? .on : .off
                        submenu.addItem(entry)
                    }
                    parent.submenu = submenu
                    menu.addItem(parent)
                }
            }
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
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = FileManager.default.fileExists(atPath: agentURL.path) ? .on : .off
        menu.addItem(login)
        let about = NSMenuItem(title: "About Display Menu", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let quit = NSMenuItem(title: "Quit Display Menu", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// One menu row: display icon, name, and an ON/OFF switch (no switch for the protected built-in display).
    private func rowView(for monitor: Monitor) -> NSView {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 34))
        let symbol = monitor.isInternal ? "laptopcomputer" : "display"
        let icon = NSImageView(frame: NSRect(x: 14, y: 7, width: 20, height: 20))
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = .labelColor
        row.addSubview(icon)

        let name = monitor.displayName
        let label = NSTextField(labelWithString: monitor.enabled ? name : "\(name)  ·  Off")
        label.font = monitor.isInternal ? .systemFont(ofSize: 13) : .boldSystemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 42, y: 8, width: 210, height: 18)
        row.addSubview(label)

        if monitor.isInternal {
            label.textColor = .secondaryLabelColor
            row.toolTip = "Built-in display is protected from changes"
        } else {
            let toggle = ToggleSwitch(frame: NSRect(x: 262, y: 5, width: 40, height: 24))
            toggle.isOn = monitor.enabled
            toggle.identifier = NSUserInterfaceItemIdentifier(monitor.id)
            toggle.target = self
            toggle.action = #selector(switchClicked(_:))
            toggle.isEnabled = !busy
            row.addSubview(toggle)
            row.toolTip = "Switch \(monitor.enabled ? "OFF" : "ON")"
        }
        return row
    }

    private func brightnessRow(for monitor: Monitor, level: Float) -> NSView {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
        let icon = NSImageView(frame: NSRect(x: 14, y: 4, width: 20, height: 20))
        icon.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Brightness")
        icon.contentTintColor = .secondaryLabelColor
        row.addSubview(icon)

        let slider = NSSlider(value: Double(level * 100), minValue: 5, maxValue: 100, target: self, action: #selector(brightnessChanged(_:)))
        slider.identifier = NSUserInterfaceItemIdentifier(monitor.id)
        slider.frame = NSRect(x: 42, y: 4, width: 210, height: 20)
        row.addSubview(slider)

        let label = NSTextField(labelWithString: "\(Int((level * 100).rounded()))%")
        label.tag = 1
        label.alignment = .right
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 256, y: 5, width: 46, height: 18)
        row.addSubview(label)
        return row
    }

    /// Updates the label immediately and sends only the newest value (latest wins) so dragging stays smooth.
    @objc private func brightnessChanged(_ sender: NSSlider) {
        guard let id = sender.identifier?.rawValue, let target = brightnessTargets[id] else { return }
        (sender.superview?.viewWithTag(1) as? NSTextField)?.stringValue = "\(Int(sender.doubleValue.rounded()))%"
        pendingLock.lock()
        pendingLevels[id] = Float(sender.doubleValue / 100)
        pendingLock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.pendingLock.lock()
            let level = self.pendingLevels.removeValue(forKey: id)
            self.pendingLock.unlock()
            if let level = level { BrightnessControl.set(displayID: target.displayID, isInternal: target.isInternal, level: level) }
        }
    }

    @objc private func switchClicked(_ sender: NSControl) {
        guard let id = sender.identifier?.rawValue else { return }
        menu.cancelTracking()  // close the menu before alerts / reload rebuild it
        DispatchQueue.main.async { self.toggle(id: id) }
    }

    @objc private func modeClicked(_ item: NSMenuItem) {
        guard !busy, let choice = item.representedObject as? ModeChoice else { return }
        busy = true
        var handedOff = false
        defer { if !handedOff { busy = false; reload() } }

        let listing = execute(["list"])
        guard listing.1 == 0 else { showError("Unable to read displays", listing.0); return }
        let current = parse(listing.0)
        remember(current)
        guard let fresh = current.first(where: { $0.id == choice.id }), fresh.enabled else {
            showError("Display not available", "The display is off or no longer detected. Refresh and try again.")
            return
        }
        if let active = fresh.modes.first(where: { $0.isCurrent }), active.sameAs(choice.mode) { return }  // already active
        guard let argument = choice.mode.argument(for: fresh) else {
            showError("Invalid resolution", "That mode has no valid resolution, so no command was sent.")
            return
        }
        handedOff = true
        applyAsync(argument, failureTitle: "Unable to change resolution")
    }

    @objc private func refreshClicked() { reload() }
    /// Launch at login = presence of the per-user LaunchAgent (the same one install.sh creates).
    @objc private func toggleLaunchAtLogin() {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: agentURL.path) {
                try fm.removeItem(at: agentURL)
            } else {
                guard let executable = Bundle.main.executablePath else { throw CocoaError(.fileNoSuchFile) }
                let plist: [String: Any] = ["Label": "com.local.displaymenu", "ProgramArguments": [executable],
                                            "RunAtLoad": true, "ProcessType": "Interactive"]
                try fm.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: agentURL)
            }
        } catch {
            showError("Unable to change Launch at Login", error.localizedDescription)
        }
        reload()
    }

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

    private func toggle(id: String) {
        guard !busy,
              let monitor = detected.first(where: { $0.id == id }), !monitor.isInternal else { return }
        if monitor.enabled {
            let alert = NSAlert()
            alert.messageText = "Disable external monitor?"
            alert.informativeText = "\(monitor.displayName) will be removed from the desktop. Some monitors may require unplugging and reconnecting the cable to turn back on."
            alert.addButton(withTitle: "Disable")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return }
        }
        busy = true
        var handedOff = false  // true once applyAsync owns busy/reload
        defer { if !handedOff { busy = false; reload() } }

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
        handedOff = true
        applyAsync(argument, failureTitle: "Unable to change display")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = DisplayMenu()
app.delegate = delegate
app.run()
