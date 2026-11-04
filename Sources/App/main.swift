import AppKit

// The host app only exists to carry the Quick Look extension and declare file
// types. Opening it shows a small status window.

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "ModelThumbs"
        w.center()

        let title = NSTextField(labelWithString: "ModelThumbs is installed")
        title.font = .systemFont(ofSize: 18, weight: .semibold)

        let body = NSTextField(wrappingLabelWithString: """
        Finder now shows previews for 3D printing, CAD and scan files: 3MF, STEP, OBJ, PLY, \
        glTF, Collada, VRML, 3DS, E57/LAS/PCD point clouds, G-code and resin prints, plus the \
        embedded previews of Fusion, SolidWorks, Inventor, Rhino, SketchUp, FreeCAD, Blender, \
        Cura and LightBurn files.

        If icons don't update, click "Refresh thumbnails". If they still don't appear, make sure \
        ModelThumbs is enabled under System Settings → General → Login Items & Extensions → Quick Look.

        You can quit this app — it doesn't need to stay open.
        """)
        body.font = .systemFont(ofSize: 13)
        body.textColor = .secondaryLabelColor

        let refresh = NSButton(title: "Refresh thumbnails", target: self, action: #selector(refreshThumbnails))
        refresh.bezelStyle = .rounded
        let settings = NSButton(title: "Open Extension Settings", target: self, action: #selector(openSettings))
        settings.bezelStyle = .rounded
        let quit = NSButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .rounded
        quit.keyEquivalent = "\r"

        let buttons = NSStackView(views: [refresh, settings, NSView(), quit])
        buttons.orientation = .horizontal
        buttons.distribution = .fill
        let stack = NSStackView(views: [title, body, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 22, bottom: 22, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            body.widthAnchor.constraint(equalToConstant: 416),
            buttons.widthAnchor.constraint(equalTo: body.widthAnchor),
        ])
        w.contentView = content
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func refreshThumbnails() {
        for args in [["-r"], ["-r", "cache"]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Finder"]
        try? p.run()
    }

    @objc func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
            NSWorkspace.shared.open(url)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
