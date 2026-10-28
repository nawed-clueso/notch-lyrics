import AppKit
import SwiftUI
import WebKit
import os.log

private let vizLogger = Logger(subsystem: "com.notchlyrics.app", category: "visualizer")

// MARK: - Bundle-backed scheme handler

/// WKWebView can't load ES modules over `file://` — a file URL has an opaque
/// origin, so the module fetch for `./three.module.min.js` is rejected by CORS
/// before it ever reaches disk. Serving the same files over a private scheme
/// gives the page a real origin and modules resolve normally, with no network
/// access and no local HTTP server.
private final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "notchviz"
    static let host = "scene"

    /// Tasks WebKit has not stopped yet. Responding to a stopped task raises
    /// an ObjC exception, so every reply is gated on membership here.
    private var live = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        live.insert(id)

        guard let root = Bundle.appResources.url(forResource: "web", withExtension: nil) else {
            fail(task, id, "web resource directory missing from bundle")
            return
        }

        // Strip the leading slash and reject anything that tries to climb out
        // of the web directory.
        let relative = task.request.url?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let name = relative.isEmpty ? "visualizer.html" : relative
        guard !name.contains("..") else {
            fail(task, id, "rejected traversal path: \(name)")
            return
        }

        let file = root.appendingPathComponent(name).standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path),
              let data = try? Data(contentsOf: file) else {
            fail(task, id, "no such asset: \(name)")
            return
        }

        let response = HTTPURLResponse(
            url: task.request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": Self.mimeType(for: file.pathExtension),
                "Content-Length": String(data.count),
                // Everything is local and immutable for the app's lifetime.
                "Cache-Control": "max-age=31536000, immutable"
            ]
        )!

        guard live.contains(id) else { return }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
        live.remove(id)
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        live.remove(ObjectIdentifier(task))
    }

    private func fail(_ task: WKURLSchemeTask, _ id: ObjectIdentifier, _ reason: String) {
        vizLogger.error("visualizer asset load failed: \(reason, privacy: .public)")
        NSLog("🎨 visualizer asset load failed: \(reason)")
        guard live.contains(id) else { return }
        task.didFailWithError(URLError(.fileDoesNotExist))
        live.remove(id)
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        // Must be a JS type or WebKit refuses the module script outright.
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "html":      "text/html; charset=utf-8"
        case "css":       "text/css; charset=utf-8"
        case "json":      "application/json"
        case "png":       "image/png"
        case "svg":       "image/svg+xml"
        default:          "application/octet-stream"
        }
    }
}

// MARK: - SwiftUI wrapper

/// The live meter: a Three.js waterfall in a WKWebView, fed the peak history
/// from the audio thread. It never takes hit tests, so the SwiftUI controls
/// around it stay fully interactive.
struct ThreeCanvasView: NSViewRepresentable {
    /// Live peak history source. Read on the main thread only.
    let store: LevelStore
    /// Drives the scene's "engine on" styling.
    let active: Bool
    var accent: NSColor = NSColor(SP.accent)
    /// Painted by the page itself — WKWebView's own transparency needs private
    /// KVC on macOS, so the scene supplies its backdrop instead.
    var background: NSColor = NSColor(red: 0.043, green: 0.043, blue: 0.043, alpha: 1)

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PassthroughWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator.schemeHandler,
                                   forURLScheme: BundleSchemeHandler.scheme)
        config.userContentController.add(context.coordinator, name: "notch")
        config.suppressesIncrementalRendering = true

        let web = PassthroughWebView(frame: .zero, configuration: config)
        // No `drawsBackground` KVC: that key is private and an unrecognised-key
        // exception is not catchable from Swift. The page paints `bg` itself.
        web.underPageBackgroundColor = background
        web.allowsMagnification = false
        context.coordinator.web = web
        context.coordinator.store = store

        var comps = URLComponents()
        comps.scheme = BundleSchemeHandler.scheme
        comps.host = BundleSchemeHandler.host
        comps.path = "/visualizer.html"
        comps.queryItems = [
            URLQueryItem(name: "accent", value: accent.hexRGB),
            URLQueryItem(name: "bg", value: background.hexRGB),
            URLQueryItem(name: "reduced", value: Motion.reduced ? "1" : "0")
        ]
        web.load(URLRequest(url: comps.url!))

        context.coordinator.setActive(active)
        return web
    }

    func updateNSView(_ nsView: PassthroughWebView, context: Context) {
        context.coordinator.store = store
        context.coordinator.setActive(active)
    }

    static func dismantleNSView(_ nsView: PassthroughWebView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        fileprivate let schemeHandler = BundleSchemeHandler()
        weak var web: WKWebView?
        var store: LevelStore?

        private var timer: Timer?
        private var ready = false
        private var active = false
        /// Suppresses redundant round-trips on every SwiftUI diff.
        private var pushedActive: Bool?

        func setActive(_ on: Bool) {
            active = on
            guard ready, pushedActive != on else { return }
            pushedActive = on
            eval("__nl.setActive(\(on));")
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let kind = body["kind"] as? String else { return }
            switch kind {
            case "ready":
                ready = true
                pushedActive = nil
                setActive(active)
                startPumping()
            case "error":
                let text = body["message"] as? String ?? "unknown"
                vizLogger.error("visualizer script error: \(text, privacy: .public)")
                NSLog("🎨 visualizer script error: \(text)")
            default:
                break
            }
        }

        /// 30 Hz matches how fast LevelStore actually gains new samples; the
        /// scene interpolates between pushes at display rate.
        private func startPumping() {
            timer?.invalidate()
            let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pump() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }

        private func pump() {
            guard let web, let store else { return }
            // Skip work entirely while the window is hidden, minimised or
            // fully covered — this app sits open all day.
            let visible = web.window?.isVisible == true
                && web.window?.occlusionState.contains(.visible) == true
            guard visible else { return }

            let samples = store.snapshot()
            var json = "["
            json.reserveCapacity(samples.count * 6 + 2)
            for (i, v) in samples.enumerated() {
                if i > 0 { json += "," }
                json += String(format: "%.3f", v)
            }
            json += "]"
            web.evaluateJavaScript("__nl.push(\(json));", completionHandler: nil)
        }

        private func eval(_ js: String) {
            web?.evaluateJavaScript(js, completionHandler: nil)
        }

        func teardown() {
            timer?.invalidate()
            timer = nil
            web?.configuration.userContentController.removeScriptMessageHandler(forName: "notch")
            web?.stopLoading()
            web = nil
        }
    }
}

/// WKWebView that never participates in hit testing or scrolling, so clicks and
/// wheel events reach the SwiftUI content around it. The meter is a readout, not
/// a control — it takes no input at all.
final class PassthroughWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

// MARK: - Colour helper

extension NSColor {
    /// Six-digit RGB hex without the leading `#`, for passing into the page.
    var hexRGB: String {
        guard let c = usingColorSpace(.sRGB) else { return "1ed760" }
        return String(format: "%02x%02x%02x",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}
