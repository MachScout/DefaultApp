import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DefaultAppCore

struct AssociationDetailView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        if let association = store.selectedAssociation {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(association.kind == .urlScheme ? "URL SCHEME" : "CONTENT TYPE")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(association.identifier).font(.title2).textSelection(.enabled)
                        if let description = store.selectedContentType?.localizedDescription {
                            Text(description).foregroundStyle(.secondary)
                        }
                    }
                    if let custom = store.selectedCustomAssociation {
                        CustomAssociationStatusView(store: store, record: custom)
                    }
                    if let type = store.selectedContentType {
                        ContentTypeMetadataView(record: type)
                    }
                    if store.showsRoles {
                        Picker("Handler role", selection: Binding(
                            get: { store.role },
                            set: { role in Task { await store.selectRole(role) } }
                        )) {
                            Text("All").tag(HandlerRole.all)
                            Text("Viewer").tag(HandlerRole.viewer)
                            Text("Editor").tag(HandlerRole.editor)
                            Text("Shell").tag(HandlerRole.shell)
                        }
                        .pickerStyle(.segmented)
                        .disabled((store.pendingMutation != nil || store.isCreatingAssociation))
                        .help("The Legacy API can assign separate applications for each content type role")
                    }
                    GroupBox("Current Default") {
                        CurrentDefaultView(state: store.handlerLookupState)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    RegisteredHandlersView(
                        state: store.handlerLookupState,
                        disabled: (store.pendingMutation != nil || store.isCreatingAssociation) || store.isLoading,
                        setDefault: { application in Task { await store.setDefault(application) } }
                    )
                    Button("Use DefaultApp as Default") {
                        Task { await store.setDefaultApplication(at: Bundle.main.bundleURL) }
                    }
                    .disabled((store.pendingMutation != nil || store.isCreatingAssociation) || store.isLoading
                        || store.defaultApplication?.id == ApplicationReference(url: Bundle.main.bundleURL).id)
                    .help("Show a handler chooser whenever this association opens in DefaultApp")
                    Button("Other Application…", action: chooseApplication)
                        .disabled((store.pendingMutation != nil || store.isCreatingAssociation) || store.isLoading)
                        .help("Choose an application bundle to use as the default")
                    if store.pendingMutation != nil {
                        HStack(alignment: .top) {
                            ProgressView().controlSize(.small)
                            Text("Changing default… Complete any macOS confirmation dialog. The result will be verified.")
                                .font(.callout)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            EmptyStateView(title: "Select an association",
                           message: "Choose an identifier to inspect its metadata and registered applications.",
                           symbol: "arrow.left.circle")
        }
    }

    @MainActor private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose Default Application"
        panel.message = "Select the application to use for \(store.selectedAssociationID ?? "this association")."
        panel.prompt = "Set Default"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await store.setDefaultApplication(at: url) }
    }
}

private struct CustomAssociationStatusView: View {
    @ObservedObject var store: AppStore
    let record: CustomAssociation

    private var state: AppStore.CustomRegistrationState {
        store.customRegistrationStates[record.association] ?? .saved
    }

    var body: some View {
        GroupBox("Custom association") {
            VStack(alignment: .leading, spacing: 8) {
                if record.association.kind == .urlScheme {
                    Text("Saved in DefaultApp.")
                    if store.defaultApplication == nil {
                        Text("Choose a default application to open links with this scheme.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    switch state {
                    case .registered:
                        Label("Registered with macOS", systemImage: "checkmark.circle")
                    case .registering:
                        ProgressView("Registering with macOS…").controlSize(.small)
                    case .saved:
                        Text("Saved in DefaultApp. macOS registration is not confirmed.")
                        registerButton
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).textSelection(.enabled)
                        registerButton
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var registerButton: some View {
        Button("Register with macOS") {
            Task { await store.retryCustomAssociation(record.association, application: nil) }
        }
        .disabled((store.pendingMutation != nil || store.isCreatingAssociation) || store.isLoading)
    }
}

private struct CurrentDefaultView: View {
    let state: AppStore.HandlerLookupState

    var body: some View {
        switch state {
        case .unresolved:
            Text("Default not loaded").foregroundStyle(.secondary)
        case .loading:
            ProgressView("Loading handler…")
        case .failed(let message):
            Text("Default lookup unavailable").foregroundStyle(.secondary).help(message)
        case .loaded(_, let application):
            if let application {
                ApplicationIdentityView(application: application)
            } else {
                Text("No default application").foregroundStyle(.secondary)
            }
        }
    }
}

private struct RegisteredHandlersView: View {
    let state: AppStore.HandlerLookupState
    let disabled: Bool
    let setDefault: (ApplicationReference) -> Void

    var body: some View {
        GroupBox("Registered Applications") {
            LazyVStack(alignment: .leading, spacing: 14) {
                switch state {
                case .unresolved:
                    Text("Registered applications not loaded.").foregroundStyle(.secondary)
                case .loading:
                    ProgressView("Loading registered applications…")
                case .failed(let message):
                    Text("Registered applications unavailable.").foregroundStyle(.secondary).help(message)
                case .loaded(let applications, let currentDefault):
                    if applications.isEmpty {
                        Text("No registered applications to display.").foregroundStyle(.secondary)
                    }
                    ForEach(applications) { application in
                        HStack(spacing: 12) {
                            ApplicationIdentityView(application: application)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button(application.id == currentDefault?.id ? "Current Default" : "Use as Default") {
                                setDefault(application.reference)
                            }
                            .disabled(disabled || application.id == currentDefault?.id)
                            .accessibilityLabel("Use \(application.displayName) as default")
                            .help(application.url.path)
                        }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ApplicationIdentityView: View {
    let application: ApplicationRecord
    @State private var launchError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                AppIconView(url: application.url)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(application.displayName).font(.headline).lineLimit(1)
                        Button {
                            Task {
                                do {
                                    _ = try await NSWorkspace.shared.openApplication(at: application.url,
                                        configuration: NSWorkspace.OpenConfiguration())
                                } catch { launchError = error.localizedDescription }
                            }
                        } label: { Image(systemName: "play.fill") }
                        .buttonStyle(.borderless)
                        .help("Launch \(application.displayName)")
                        .accessibilityLabel("Launch \(application.displayName)")
                    }
                    Text(application.bundleIdentifier ?? "No bundle identifier")
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            HStack(spacing: 6) {
                Text(application.url.path).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Button { NSWorkspace.shared.activateFileViewerSelecting([application.url]) } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
                .accessibilityLabel("Show \(application.displayName) in Finder")
            }
        }
        .help(application.url.path)
        .accessibilityElement(children: .contain)
        .alert("Could not launch application", isPresented: Binding(
            get: { launchError != nil }, set: { if !$0 { launchError = nil } }
        )) {
            Button("OK") { launchError = nil }
        } message: { Text(launchError ?? "") }
    }
}

private struct ContentTypeMetadataView: View {
    let record: ContentTypeRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !record.supertypes.isEmpty {
                MetadataRow(label: "Conforms to", value: record.supertypes.joined(separator: ", "))
            }
            TypeTagsView(tags: record.tags)
            if let application = record.declaringApplication {
                MetadataRow(label: "Declared by", value: application.bundleIdentifier ?? application.url.lastPathComponent)
            }
        }
    }
}

struct MetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct TypeTagsView: View {
    let tags: [String: [String]]
    private var keys: [String] { tags.keys.sorted() }

    var body: some View {
        ForEach(keys, id: \.self) { key in
            MetadataRow(label: key, value: (tags[key] ?? []).joined(separator: ", "))
        }
    }
}
