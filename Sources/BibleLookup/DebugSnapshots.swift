#if DEBUG
import AppKit
import BibleLookupCore
import WebKit

/// Debug builds only: BL_SNAPSHOTS="/?q=...|name.png;..." loads each page, saves a
/// picture of it, prints any JavaScript errors, then quits. Used to check the app end to end.
/// CGWindowListCreateImage is hidden from new SDKs; look it up at run time (debug only).
private func captureWindow(_ window: NSWindow) -> Data? {
    typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
    let fn = unsafeBitCast(sym, to: Fn.self)
    // .null rect, optionIncludingWindow (8), boundsIgnoreFraming (1)
    guard let cg = fn(.null, 8, UInt32(window.windowNumber), 1)?.takeRetainedValue(), cg.width > 1 else { return nil }
    return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
}

@MainActor
enum DebugSnapshots {
    static func runIfRequested(_ web: WKWebView) {
        guard let spec = ProcessInfo.processInfo.environment["BL_SNAPSHOTS"] else { return }
        if ProcessInfo.processInfo.environment["BL_APPEARANCE"] == "dark" {
            web.appearance = NSAppearance(named: .darkAqua)
        }
        let jobs = spec.split(separator: ";").map { $0.split(separator: "|").map(String.init) }
        let errors = """
            window.__errors = [];
            window.addEventListener('error', (e) => window.__errors.push(e.message));
            window.addEventListener('unhandledrejection', (e) => window.__errors.push(String(e.reason)));
            """
        web.configuration.userContentController.addUserScript(
            WKUserScript(source: errors, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            // BL_TEST_ESV_KEY: save a key the way Settings does, use it, then remove it again
            let testKey = ProcessInfo.processInfo.environment["BL_TEST_ESV_KEY"]
            if let key = testKey {
                print("KEYCHAIN write=\(SettingsStore.write(.esv, key)) readBack=\(SettingsStore.read(.esv) == key)")
                AppModel.shared.apply(SettingsStore.loadConfig())
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            defer {
                if testKey != nil {
                    print("KEYCHAIN removed=\(SettingsStore.write(.esv, "")) empty=\(SettingsStore.read(.esv).isEmpty)")
                }
            }
            if let key = ProcessInfo.processInfo.environment["BL_TEST_APIBIBLE_KEY"] {
                do {
                    let (found, total) = try await findAPIBibles(key: key)
                    print("APIBIBLE total=\(total) found=\(found.keys.sorted()) \(found.values.map(\.name).sorted())")
                } catch {
                    print("APIBIBLE error=\(error)")
                }
            }
            for job in jobs where job.count == 2 {
                web.load(URLRequest(url: URL(string: "biblelookup://app" + job[0])!))
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                let errs = (try? await web.evaluateJavaScript("JSON.stringify(window.__errors || [])")) as? String ?? "?"
                let text = (try? await web.evaluateJavaScript("document.getElementById('main').innerText.slice(0, 160)")) as? String ?? ""
                if let js = ProcessInfo.processInfo.environment["BL_EVAL"] {
                    let r = try? await web.callAsyncJavaScript("return await (" + js + ")", contentWorld: .page)
                    print("EVAL \(r.map { "\($0)" } ?? "nil")")
                    if let aw = web as? AppWebView {
                        let d = aw.dragArea
                        @MainActor func probe(_ x: CGFloat, _ y: CGFloat) -> String {
                            let p = web.isFlipped ? NSPoint(x: x, y: y) : NSPoint(x: x, y: web.bounds.height - y)
                            return d.hitTest(p) === d ? "drag" : "page"
                        }
                        print("DRAG frame=\(d.frame) flipped=\(web.isFlipped) top-middle=\(probe(450, 10)) brand=\(probe(80, 60)) search=\(probe(450, 60)) bar-right-gap=\(probe(890, 60)) text=\(probe(450, 300)) scrollbar-colW=\(probe(893, 60))")
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                print("PAGE \(job[0]) errors=\(errs) text=\(text.replacingOccurrences(of: "\n", with: " ⏎ "))")
                // the real on-screen window (what the person sees), when macOS allows it
                if let window = web.window, let png = captureWindow(window) {
                    let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("win-" + job[1])
                    try? png.write(to: out)
                    print("SAVED \(out.path)")
                }
                if let image = try? await web.takeSnapshot(configuration: nil),
                   let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(job[1])  // inside the sandbox container
                    try? png.write(to: out)
                    print("SAVED \(out.path)")
                }
            }
            fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { fflush(stdout); NSApp.terminate(nil) }
        }
    }
}
#endif
