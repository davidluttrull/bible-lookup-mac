import AppKit
import BibleLookupCore
import Foundation

extension Notification.Name {
    /// Keys or API.Bible translations changed: every window reloads its page.
    static let configChanged = Notification.Name("BibleLookupConfigChanged")
}

/// App-wide state: the Bible service (loaded once, off the main thread) and the saved settings.
final class AppModel: @unchecked Sendable {
    static let shared = AppModel()

    /// Loading the two bundled Bibles takes a moment; requests wait for it.
    let service: Task<BibleService, Error>

    private init() {
        let config = SettingsStore.loadConfig()
        service = Task.detached(priority: .userInitiated) {
            let data = Bundle.main.resourceURL!.appendingPathComponent("Data")
            // passages fetched online, kept between launches (in the app's own sandbox folder)
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            return try BibleService(kjv: Data(contentsOf: data.appendingPathComponent("kjv.json")),
                                    asv: Data(contentsOf: data.appendingPathComponent("asv.json")),
                                    config: config,
                                    cachePath: support?.appendingPathComponent("Bible Lookup/cache.db"))
        }
    }

    /// Settings were saved: pass the new keys to the service, then reload the pages.
    func apply(_ config: Config) {
        Task {
            try? await service.value.update(config)
            await MainActor.run { NotificationCenter.default.post(name: .configChanged, object: nil) }
        }
    }
}

/// Opens the Settings window from code (the page's "Open Settings" button).
@MainActor
enum SettingsOpener {
    static var open: (() -> Void)?

    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let open = open {
            open()
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }
}
