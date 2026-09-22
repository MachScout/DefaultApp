import SwiftUI
import DefaultAppCore

struct RootView: View {
    @ObservedObject var store: AppStore
    @FocusState private var searchFocused: Bool
    @State private var newAssociationTab: AppStore.Tab?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: tabSelectionBinding) {
                ForEach(store.visibleTabs) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled((store.pendingMutation != nil || store.isCreatingAssociation))
            .padding()

            if showsCatalogChrome {
                HStack {
                    Button { searchFocused = true } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("f", modifiers: .command)
                    .accessibilityLabel("Focus search")
                    .help("Search the current tab (⌘F)")
                    TextField(store.selectedTab == .contentTypes ? "Search identifiers, extensions, or loaded apps" : "Search \(store.selectedTab.title)", text: $store.searchText)
                        .textFieldStyle(.roundedBorder)
                        .focused($searchFocused)
                        .accessibilityLabel("Search \(store.selectedTab.title)")
                    if !store.searchText.isEmpty {
                        Button { store.searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                        .help("Clear search")
                    }
                    Button { Task { await store.refresh() } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Refresh catalog and handlers (⌘R)")
                    .disabled(store.isLoading || store.pendingMutation != nil || store.isCreatingAssociation)
                    if store.selectedTab == .urlSchemes || store.selectedTab == .contentTypes {
                        Button { newAssociationTab = store.selectedTab } label: {
                            Label(store.selectedTab == .urlSchemes ? "Add URL Scheme…" : "Add Content Type…", systemImage: "plus")
                        }
                        .disabled(!store.canCreateAssociation)
                        .help("Create a custom association")
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
            }
            if let error = store.presentedError {
                ErrorBanner(message: error.message,
                            retry: {
                                Task {
                                    if store.selectedTab == .general { await store.loadGeneralDefaults() }
                                    else { await store.refresh() }
                                }
                            },
                            dismiss: { store.presentedError = nil })
                    .disabled(store.isLoading || (store.pendingMutation != nil || store.isCreatingAssociation))
            }
            Divider()
            // Give every tab the existing viewport. Split-view and table fitting sizes
            // must not become new size constraints for the WindowGroup during a switch.
            GeometryReader { geometry in
                content
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
            if store.selectedTab != .general {
                Divider()
                HStack {
                    if store.isLoading || store.isResolvingDefaults {
                        ProgressView().controlSize(.small)
                        Text(store.isLoading ? "Loading catalog and handlers…" : "Resolving default applications…")
                    } else {
                        Text(status)
                    }
                    Spacer()
                    Text(store.backend == .modern ? "Modern API" : "Legacy API")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
        }
        .frame(minWidth: 940, idealWidth: 1180, maxWidth: .infinity,
               minHeight: 540, idealHeight: 720, maxHeight: .infinity)
        .task {
            await store.loadGeneralDefaults()
            if store.snapshot == nil { await store.load() }
        }
        .sheet(item: $newAssociationTab) { tab in
            NewAssociationView(store: store, kind: tab == .urlSchemes ? .urlScheme : .contentType)
        }
        .task(id: store.contentTypeDetailID) { await store.refreshSelectedContentType() }
        .task(id: store.applicationDetailID) { await store.refreshSelectedApplication() }
        .task(id: store.listQuery) { await store.loadAssociationDefaults() }
        .task(id: store.selectedAssociation) { await store.loadHandlers() }
    }

    var tabSelectionBinding: Binding<AppStore.Tab> {
        Binding(
            get: { store.selectedTab },
            set: { tab in
                store.requestTabSelection(tab)
            }
        )
    }

    var associationSelectionBinding: Binding<String?> {
        let tab = store.selectedTab
        return Binding(get: { store.selectedAssociationID },
                       set: { store.requestRowSelection($0, in: tab) })
    }

    private var showsCatalogChrome: Bool {
        store.selectedTab == .urlSchemes || store.selectedTab == .contentTypes || store.selectedTab == .applications
    }

    private var content: some View {
        ZStack {
            // One split view for the lifetime of the window preserves the user's
            // divider position across catalog tabs, including visits to General and Diagnostics.
            HSplitView {
                StableSplitPane(minWidth: 420, idealWidth: 500) {
                    if store.selectedTab == .applications {
                        ApplicationsListView(store: store)
                    } else {
                        VStack(spacing: 0) {
                            if store.selectedTab == .contentTypes {
                                HStack {
                                    Menu {
                                        Toggle("Show all identifiers", isOn: $store.showAllContentTypes)
                                        Toggle("Only dynamic types", isOn: $store.contentTypeFilters.onlyDynamic)
                                        Toggle("Hide rows without extensions",
                                               isOn: $store.contentTypeFilters.hideWithoutExtensions)
                                        Toggle("Hide rows without a default application",
                                               isOn: $store.contentTypeFilters.hideWithoutDefaultApplication)
                                    } label: {
                                        Label("Content Type Filters", systemImage: "line.3.horizontal.decrease.circle")
                                    }
                                    .help("Filter identifiers by type metadata and resolved defaults")
                                    Spacer()
                                }
                                .padding(12)
                            }
                            AssociationListView(rows: store.associationRows,
                                                selection: associationSelectionBinding,
                                                search: store.searchText,
                                                isLoading: store.isLoading || store.isResolvingDefaults,
                                                showsExtensions: store.selectedTab == .contentTypes,
                                                customAssociations: store.customAssociationIDs,
                                                sort: $store.associationSort)
                                .disabled((store.pendingMutation != nil || store.isCreatingAssociation))
                        }
                    }
                }
                StableSplitPane(minWidth: 380, idealWidth: 600) {
                    if store.selectedTab == .applications {
                        ApplicationSelectionDetailView(store: store)
                    } else {
                        AssociationDetailView(store: store)
                    }
                }
            }
            .opacity(showsCatalogChrome ? 1 : 0)
            .disabled(!showsCatalogChrome)
            .allowsHitTesting(showsCatalogChrome)
            .accessibilityHidden(!showsCatalogChrome)

            if store.selectedTab == .general {
                GeneralSettingsView(store: store)
            }

            if store.selectedTab == .diagnostics {
                DiagnosticsView(projection: DiagnosticsProjection(
                    snapshot: store.snapshot, backend: store.backend,
                    osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                    refreshDuration: store.refreshDuration
                ))
            }
        }
    }

    private var status: String {
        guard let snapshot = store.snapshot else { return "Catalog not loaded" }
        switch store.selectedTab {
        case .general: return "General settings"
        case .urlSchemes: return "\(store.associationRows.count) of \(snapshot.urlSchemes.count) URL schemes"
        case .contentTypes: return "\(store.associationRows.count) of \(snapshot.contentTypes.count) content types"
        case .applications: return "\(store.applicationRows.count) of \(snapshot.applications.count) applications"
        case .diagnostics: return "\(snapshot.diagnostics.warnings.count) catalog warnings"
        }
    }
}

/// HSplitView must measure the pane, not the changing detail/list inside it.
/// Keeping the fitting size constant preserves a user-positioned divider.
struct StableSplitPane<Content: View>: View {
    let minWidth: CGFloat
    let idealWidth: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { geometry in
            content
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .clipped()
        }
        .frame(minWidth: minWidth, idealWidth: idealWidth, maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String
    var symbol = "info.circle"

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.largeTitle).accessibilityHidden(true)
            Text(title).font(.headline)
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct ErrorBanner: View {
    let message: String
    let retry: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityHidden(true)
            Text(message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry", action: retry)
            Button("Dismiss", action: dismiss)
        }
        .padding()
        .background(Color.orange.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Operation error")
    }
}
