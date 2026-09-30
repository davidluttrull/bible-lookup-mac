import AppKit

/// The page fills the whole window, so the web view would swallow the clicks that should
/// move the window. This invisible view lies over the page's header (at least the title
/// bar strip) and drags the window, except over the parts of the header that are for
/// clicking, which the page reports as holes (the app name and the search box).
final class WindowDragArea: NSView {
    private var holes: [NSRect] = []
    private var height: CGFloat = 28  // the title bar strip, until the page reports its header

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    /// bottom: how far down the header reaches (0 when it's hidden); holes: [x, y, w, h] in page pixels
    func update(bottom: CGFloat, holes: [[CGFloat]], zoom: CGFloat, titlebar: CGFloat) {
        height = max(bottom * zoom, titlebar)
        self.holes = holes.compactMap { h in
            h.count == 4 ? NSRect(x: h[0] * zoom, y: h[1] * zoom, width: h[2] * zoom, height: h[3] * zoom) : nil
        }
        layoutInSuperview()
        window?.invalidateCursorRects(for: self)
    }

    func layoutInSuperview() {
        guard let sv = superview else { return }
        let y = sv.isFlipped ? 0 : sv.bounds.height - height
        frame = NSRect(x: 0, y: y, width: sv.bounds.width, height: height)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        guard bounds.contains(p), !holes.contains(where: { $0.contains(p) }) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard let window = window else { return }
        if event.clickCount == 2 {
            // double-click does what System Settings > Desktop & Dock says for title bars
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.miniaturize(nil)
            case "None": break
            default: window.zoom(nil)
            }
            return
        }
        window.performDrag(with: event)
    }

    // scrolling over the header still scrolls the page
    override func scrollWheel(with event: NSEvent) {
        superview?.scrollWheel(with: event)
    }
}
