import AppKit
import SwiftUI
import WebKit

/// One window's page, plus the menu commands that act on it.
@MainActor
final class WebController: NSObject, ObservableObject {
    let webView: WKWebView
    private let schemeHandler = SchemeHandler()
    private var titleObserver: NSKeyValueObservation?
    private static let zoomKey = "pageZoom"
    static let titlebarHeight = 28

    override init() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: SchemeHandler.scheme)
        config.websiteDataStore = .default()  // keeps the page's remembered translation
        webView = AppWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(WeakMessageHandler(self), name: "app")
        // the page runs up under the window's title bar; its header leaves room for the window buttons
        config.userContentController.addUserScript(WKUserScript(
            source: "document.documentElement.style.setProperty('--titlebar', '\(Self.titlebarHeight)px')",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.setValue(false, forKey: "drawsBackground")  // no white flash before the page paints
        let zoom = UserDefaults.standard.double(forKey: Self.zoomKey)
        webView.pageZoom = zoom > 0 ? zoom : 1
        titleObserver = webView.observe(\.title) { view, _ in
            MainActor.assumeIsolated { view.window?.title = view.title ?? "Bible Lookup" }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(configChanged), name: .configChanged, object: nil)
        webView.load(URLRequest(url: SchemeHandler.home))
        #if DEBUG
        DebugSnapshots.runIfRequested(webView)
        #endif
    }

    @objc private func configChanged() {
        webView.reload()
    }

    // MARK: menu commands

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func goHome() { webView.load(URLRequest(url: SchemeHandler.home)) }

    func focusSearch() {
        webView.window?.makeFirstResponder(webView)
        webView.evaluateJavaScript("(() => { const q = document.getElementById('q'); q.focus(); q.select(); })()")
    }

    /// Follow the page's ← / → chapter link, if it has one.
    func chapter(next: Bool) {
        let arrow = next ? "→" : "←"
        webView.evaluateJavaScript("[...document.querySelectorAll('.chapnav a')].find((a) => a.textContent.includes('\(arrow)'))?.click()")
    }

    func zoom(_ step: Double?) {
        let z = step.map { min(max(webView.pageZoom + $0, 0.6), 2.5) } ?? 1
        webView.pageZoom = z
        UserDefaults.standard.set(z, forKey: Self.zoomKey)
    }

    func printPage() {
        guard let window = webView.window else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.topMargin = 36
        info.bottomMargin = 36
        info.leftMargin = 36
        info.rightMargin = 36
        let op = webView.printOperation(with: info)
        op.view?.frame = webView.bounds
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        if message.body as? String == "settings" { SettingsOpener.show() }
        if let d = message.body as? [String: Any], d["type"] as? String == "bar" {
            (webView as? AppWebView)?.dragArea.update(
                bottom: (d["bottom"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0,
                holes: (d["holes"] as? [[NSNumber]] ?? []).map { $0.map { CGFloat($0.doubleValue) } },
                zoom: webView.pageZoom, titlebar: CGFloat(Self.titlebarHeight))
        }
    }
}

// MARK: - links

extension WebController: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, url.scheme != SchemeHandler.scheme, url.scheme != "about" else {
            return decisionHandler(.allow)
        }
        decisionHandler(.cancel)
        openOutside(url)
    }

    // target="_blank" links (BibleGateway) open in the default browser
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { openOutside(url) }
        return nil
    }

    private func openOutside(_ url: URL) {
        if NSWorkspace.shared.urlForApplication(toOpen: url) == nil {
            let alert = NSAlert()
            if url.scheme == "logosres" {
                alert.messageText = "Logos isn’t installed on this Mac"
                alert.informativeText = "“Open in Logos” links open the passage in Logos Bible Software."
            } else {
                alert.messageText = "No app on this Mac can open this link"
                alert.informativeText = url.absoluteString
            }
            if let w = webView.window { alert.beginSheetModal(for: w) } else { alert.runModal() }
            return
        }
        NSWorkspace.shared.open(url)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

/// WKUserContentController keeps its handlers alive; this keeps it from keeping the window alive.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WebController?

    init(_ target: WebController) { self.target = target }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { target?.receive(message) }
    }
}

/// The page fills the whole window, title bar included (the window buttons float over its header).
final class AppWebView: WKWebView {
    let dragArea = WindowDragArea()

    override func layout() {
        super.layout()
        if dragArea.superview == nil { addSubview(dragArea) }
        dragArea.layoutInSuperview()
    }

    static let brand = NSColor(name: "brand") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x3B / 255, green: 0x36 / 255, blue: 0x34 / 255, alpha: 1)
            : NSColor(srgbRed: 0x5E / 255, green: 0x56 / 255, blue: 0x53 / 255, alpha: 1)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = window else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Self.brand  // shows only before the page first paints
        window.titlebarSeparatorStyle = .none
        window.makeFirstResponder(self)  // typing goes straight to the search box
    }
}

struct BrowserView: NSViewRepresentable {
    let controller: WebController

    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
