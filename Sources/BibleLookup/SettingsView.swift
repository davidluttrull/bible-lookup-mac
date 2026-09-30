import BibleLookupCore
import SwiftUI

struct SettingsView: View {
    @State private var esv = SettingsStore.read(.esv)
    @State private var nlt = SettingsStore.read(.nlt)
    @State private var apiBible = SettingsStore.read(.apiBible)
    @State private var found = SettingsStore.apiBibleIds
    @State private var showKeys = false
    @State private var searching = false
    @State private var status: String?
    @State private var statusIsError = false
    @State private var saved = [SettingsStore.read(.esv), SettingsStore.read(.nlt), SettingsStore.read(.apiBible)]

    private var changed: Bool { [esv, nlt, apiBible] != saved }

    var body: some View {
        Form {
            Section {
                keyField("ESV API key", text: $esv)
                Link("Get a free key at api.esv.org", destination: URL(string: "https://api.esv.org/account/create-application/")!)
            } header: {
                Text("English Standard Version")
            } footer: {
                note("Create a non-commercial application, then paste its key here.")
            }

            Section {
                keyField("NLT API key (optional)", text: $nlt)
                Link("Request a key at api.nlt.to", destination: URL(string: "https://api.nlt.to/")!)
            } header: {
                Text("New Living Translation")
            } footer: {
                note("The NLT works without a key on its shared test key. Your own key is better for regular use.")
            }

            Section {
                keyField("API.Bible key", text: $apiBible)
                ForEach(apiBibleIds, id: \.self) { tid in
                    LabeledContent(tid) {
                        if let b = found[tid] {
                            Label(b.name, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Text("Not connected").foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Button("Find My Translations") { Task { await findTranslations() } }
                        .disabled(apiBible.trimmingCharacters(in: .whitespaces).isEmpty || searching)
                    if searching { ProgressView().controlSize(.small) }
                    Spacer()
                    Link("Sign up at api.bible", destination: URL(string: "https://api.bible")!)
                }
            } header: {
                Text("NIV, CSB and NASB (API.Bible)")
            } footer: {
                note("The free Starter plan includes 3 copyrighted Bibles of your choice. Choose them in your API.Bible dashboard, then click Find My Translations.")
            }

            Section {
                Toggle("Show keys", isOn: $showKeys)
                HStack {
                    if let status = status {
                        Text(status)
                            .foregroundStyle(statusIsError ? Color.red : Color.secondary)
                            .font(.callout)
                    }
                    Spacer()
                    Button("Save") { Task { await save() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!changed || searching)
                }
            } footer: {
                note("Keys are stored in this Mac’s keychain and are sent only to the Bible sites they belong to. KJV and ASV are built in and need no key.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func keyField(_ label: String, text: Binding<String>) -> some View {
        if showKeys {
            TextField(label, text: text).font(.body.monospaced())
        } else {
            SecureField(label, text: text)
        }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary)
    }

    private func save() async {
        let keyChanged = apiBible != saved[2]
        let ok = SettingsStore.write(.esv, esv) && SettingsStore.write(.nlt, nlt) && SettingsStore.write(.apiBible, apiBible)
        guard ok else {
            report("Couldn’t save to the keychain.", error: true)
            return
        }
        saved = [esv, nlt, apiBible]
        if keyChanged {
            if apiBible.trimmingCharacters(in: .whitespaces).isEmpty {
                found = [:]
                SettingsStore.apiBibleIds = [:]
            } else {
                await findTranslations()  // also applies the new settings
                return
            }
        }
        AppModel.shared.apply(SettingsStore.loadConfig())
        report("Saved.")
    }

    /// Ask API.Bible which of NIV, CSB and NASB this key can read (the Python version's --setup).
    private func findTranslations() async {
        searching = true
        defer { searching = false }
        SettingsStore.write(.apiBible, apiBible)
        saved[2] = apiBible
        do {
            let (matches, total) = try await findAPIBibles(key: apiBible.trimmingCharacters(in: .whitespaces))
            found = matches
            SettingsStore.apiBibleIds = matches
            AppModel.shared.apply(SettingsStore.loadConfig())
            let names = apiBibleIds.filter { matches[$0] != nil }
            report(names.isEmpty
                ? "Your key can read \(total) English Bibles, but not NIV, CSB or NASB."
                : "Saved. Connected: \(names.joined(separator: ", ")).")
        } catch {
            report("\(error)", error: true)
        }
    }

    private func report(_ s: String, error: Bool = false) {
        status = s
        statusIsError = error
    }
}
