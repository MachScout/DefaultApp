import AppKit
import SwiftUI
import DefaultAppCore

@main
@MainActor
struct DefaultApp: App {
    @NSApplicationDelegateAdaptor(ApplicationLifecycleCoordinator.self)
    private var lifecycle

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) { EmptyView() }
                DefaultAppCommands(store: lifecycle.appStore,
                                   showIncoming: { lifecycle.showRequests() })
            }
    }
}

@MainActor
private struct DefaultAppCommands: Commands {
    @ObservedObject var store: AppStore
    let showIncoming: () -> Void

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About DefaultApp") {
                NSApplication.shared.orderFrontStandardAboutPanel(options: [
                    .credits: NSAttributedString(
                        string: "Inspect and manage default applications for URL schemes and content types."
                    ),
                ])
            }
        }
        CommandGroup(replacing: .toolbar) {
            Button("General") { store.selectTab(.general) }
                .keyboardShortcut("1", modifiers: .command)
            Button("URL Schemes") { store.selectTab(.urlSchemes) }
                .keyboardShortcut("2", modifiers: .command)
            Button("Content Types") { store.selectTab(.contentTypes) }
                .keyboardShortcut("3", modifiers: .command)
            Button("Applications") { store.selectTab(.applications) }
                .keyboardShortcut("4", modifiers: .command)
            if store.showsDiagnostics {
                Button("Diagnostics") { store.selectTab(.diagnostics) }
                    .keyboardShortcut("5", modifiers: .command)
            }
            Divider()
            Picker("Handler Backend", selection: Binding(
                get: { store.backend },
                set: { backend in Task { await store.selectBackend(backend) } }
            )) {
                Text("Modern").tag(Backend.modern)
                Text("Legacy").tag(Backend.legacy)
            }
            Toggle("Show Diagnostics", isOn: $store.showsDiagnostics)
            Divider()
            Menu("Content Type Filters") {
                Toggle("Show all identifiers", isOn: $store.showAllContentTypes)
                Toggle("Hide rows without extensions",
                       isOn: $store.contentTypeFilters.hideWithoutExtensions)
                Toggle("Hide rows without a default application",
                       isOn: $store.contentTypeFilters.hideWithoutDefaultApplication)
            }
            Menu("Application Filters") {
                Toggle("Hide system components and helpers", isOn: $store.applicationFilters.hideAuxiliary)
                Toggle("Hide temporary and development builds", isOn: $store.applicationFilters.hideDevelopment)
                Toggle("Hide apps without schemes or content types",
                       isOn: $store.applicationFilters.hideWithoutAssociations)
            }
        }
        CommandMenu("Catalog") {
            Button("Incoming Items…", action: showIncoming)
            Divider()
            Button("Refresh") { Task { await store.refresh() } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(store.isLoading || (store.pendingMutation != nil || store.isCreatingAssociation))
        }
    }
}
