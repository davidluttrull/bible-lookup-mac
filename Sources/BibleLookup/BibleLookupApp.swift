import SwiftUI

@main
struct BibleLookupApp: App {
    init() {
        _ = AppModel.shared  // start loading the bundled Bibles right away
    }

    var body: some Scene {
        WindowGroup {
            WindowContent()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 820)
        .commands {
            AppCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

private struct WindowContent: View {
    @StateObject private var controller = WebController()

    var body: some View {
        BrowserView(controller: controller)
            .ignoresSafeArea()  // run up under the title bar
            .frame(minWidth: 480, minHeight: 360)
            .background(Color(nsColor: AppWebView.brand))
            .focusedSceneValue(\.webController, controller)
            .modifier(RegisterSettingsOpener())
    }
}

/// Lets the page's "Open Settings" button open the Settings window (macOS 14 needs the
/// SwiftUI openSettings action; macOS 13 uses the menu action).
private struct RegisterSettingsOpener: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content.modifier(Sonoma())
        } else {
            content
        }
    }

    @available(macOS 14, *)
    private struct Sonoma: ViewModifier {
        @Environment(\.openSettings) private var openSettings

        func body(content: Content) -> some View {
            content.onAppear { SettingsOpener.open = { openSettings() } }
        }
    }
}

private struct WebControllerKey: FocusedValueKey {
    typealias Value = WebController
}

extension FocusedValues {
    var webController: WebController? {
        get { self[WebControllerKey.self] }
        set { self[WebControllerKey.self] = newValue }
    }
}

private struct AppCommands: Commands {
    @FocusedValue(\.webController) private var page

    var body: some Commands {
        CommandGroup(replacing: .printItem) {
            Button("Print…") { page?.printPage() }
                .keyboardShortcut("p")
                .disabled(page == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("Actual Size") { page?.zoom(nil) }
                .keyboardShortcut("0")
            Button("Zoom In") { page?.zoom(0.1) }
                .keyboardShortcut("+")
            Button("Zoom Out") { page?.zoom(-0.1) }
                .keyboardShortcut("-")
            Divider()
            Button("Reload") { page?.reload() }
                .keyboardShortcut("r")
            Divider()
        }
        CommandMenu("Go") {
            Button("Look Up a Passage") { page?.focusSearch() }
                .keyboardShortcut("l")
            Button("Home") { page?.goHome() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Divider()
            Button("Back") { page?.goBack() }
                .keyboardShortcut("[")
            Button("Forward") { page?.goForward() }
                .keyboardShortcut("]")
            Divider()
            Button("Previous Chapter") { page?.chapter(next: false) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Next Chapter") { page?.chapter(next: true) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
        }
        CommandGroup(replacing: .help) {
            Link("Get a Free ESV API Key", destination: URL(string: "https://api.esv.org/account/create-application/")!)
            Link("Get an NLT API Key", destination: URL(string: "https://api.nlt.to/")!)
            Link("Sign Up for API.Bible (NIV, CSB, NASB)", destination: URL(string: "https://api.bible")!)
        }
    }
}
