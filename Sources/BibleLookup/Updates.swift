import Combine
import Sparkle
import SwiftUI

/// Automatic updates through Sparkle. The update list (appcast) and each new version
/// are published to the GitHub releases by scripts/release.sh; see SUFeedURL in Info.plist.
@MainActor
final class Updates: ObservableObject {
    static let shared = Updates()

    private let controller: SPUStandardUpdaterController
    @Published private(set) var canCheck = false

    private init() {
        #if DEBUG
        let start = false  // test builds would otherwise offer to "update" to the real release
        #else
        let start = true
        #endif
        controller = SPUStandardUpdaterController(startingUpdater: start, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }

    var updater: SPUUpdater { controller.updater }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// Bible Lookup > Check for Updates…
struct CheckForUpdatesButton: View {
    @ObservedObject var updates = Updates.shared

    var body: some View {
        Button("Check for Updates…") { updates.checkForUpdates() }
            .disabled(!updates.canCheck)
    }
}

/// The Updates section of Settings.
struct UpdateSettings: View {
    @ObservedObject private var updates = Updates.shared
    @State private var checks = Updates.shared.updater.automaticallyChecksForUpdates
    @State private var installs = Updates.shared.updater.automaticallyDownloadsUpdates

    var body: some View {
        Toggle("Check for updates automatically", isOn: $checks)
            .onChange(of: checks) { updates.updater.automaticallyChecksForUpdates = $0 }
        Toggle("Download and install updates automatically", isOn: $installs)
            .onChange(of: installs) { updates.updater.automaticallyDownloadsUpdates = $0 }
            .disabled(!checks)
        HStack {
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Check Now") { updates.checkForUpdates() }
                .disabled(!updates.canCheck)
        }
    }
}
