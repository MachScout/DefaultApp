import SwiftUI
import DefaultAppCore

struct ApplicationsListView: View {
    @ObservedObject var store: AppStore

    var selectionBinding: Binding<String?> {
        Binding(get: { store.selectedApplicationID },
                set: { store.requestRowSelection($0, in: .applications) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                Toggle("Hide system components and helpers", isOn: $store.applicationFilters.hideAuxiliary)
                Toggle("Hide temporary and development builds", isOn: $store.applicationFilters.hideDevelopment)
                Toggle("Hide apps without schemes or content types", isOn: $store.applicationFilters.hideWithoutAssociations)
            } label: {
                Label("Application Filters", systemImage: "line.3.horizontal.decrease.circle")
            }
            .padding([.top, .horizontal], 12)
            List(store.applicationRows, selection: selectionBinding) { application in
                ApplicationListRow(application: application)
                    .padding(.vertical, 5)
                    .tag(application.id)
            }
            .accessibilityLabel("Registered applications")
            .overlay {
                if store.applicationRows.isEmpty && !store.isLoading {
                    EmptyStateView(title: "No applications found", message: "Try a different search, adjust the filters, or refresh the catalog.")
                        .allowsHitTesting(false)
                }
            }
        }
        .disabled((store.pendingMutation != nil || store.isCreatingAssociation))
    }
}

struct ApplicationSelectionDetailView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        if let application = store.selectedApplication {
            ApplicationDetailView(application: application, store: store)
        } else {
            EmptyStateView(title: "Select an application",
                           message: "Inspect its URL schemes, handled content types, and UTI declarations.",
                           symbol: "app.dashed")
        }
    }
}

private struct ApplicationListRow: View {
    let application: ApplicationRecord

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(url: application.url)
            VStack(alignment: .leading, spacing: 3) {
                Text(application.displayName).font(.headline).lineLimit(1)
                Text(application.bundleIdentifier ?? "No bundle identifier")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ApplicationDetailView: View {
    let application: ApplicationRecord
    @ObservedObject var store: AppStore
    private let projection: ApplicationProjection
    private let extensions: String
    private let mimeTypes: String

    init(application: ApplicationRecord, store: AppStore) {
        self.application = application
        self.store = store
        projection = ApplicationProjection(record: application)
        extensions = Set(application.documentTypeClaims.flatMap(\.filenameExtensions)).sorted().joined(separator: ", ")
        mimeTypes = Set(application.documentTypeClaims.flatMap(\.mimeTypes)).sorted().joined(separator: ", ")
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ApplicationIdentityView(application: application)
                if store.pendingMutation != nil {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Changing default… Complete any macOS confirmation dialog.").font(.callout)
                    }
                }
                if let version = application.shortVersion ?? application.bundleVersion {
                    MetadataRow(label: "Version", value: version)
                }
                GroupBox("URL Schemes") {
                    VStack(alignment: .leading, spacing: 8) {
                        if application.urlSchemes.isEmpty { Text("None declared").foregroundStyle(.secondary) }
                        ForEach(application.urlSchemes) { scheme in
                            ApplicationAssociationRow(identifier: scheme.scheme, kind: .urlScheme, application: application, store: store)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                GroupBox("Handled Content Types") {
                    VStack(alignment: .leading, spacing: 10) {
                        if projection.handledTypes.isEmpty { Text("No UTI claims declared").foregroundStyle(.secondary) }
                        ForEach(projection.handledTypes) { type in
                            ApplicationAssociationRow(identifier: type.identifier, kind: .contentType,
                                                      application: application, store: store,
                                                      detailLabel: type.filenameExtensionLabel)
                        }
                        if !extensions.isEmpty { MetadataRow(label: "Filename extensions", value: extensions) }
                        if !mimeTypes.isEmpty { MetadataRow(label: "MIME types", value: mimeTypes) }
                        let additionalDefaults = store.additionalDefaultAssociations(for: application)
                        if !additionalDefaults.isEmpty {
                            Divider()
                            Text("Default associations beyond this app’s declared types and schemes.")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(additionalDefaults, id: \.self) { association in
                                ApplicationAssociationRow(identifier: association.identifier, kind: association.kind,
                                                          application: application, store: store,
                                                          detailLabel: association.kind == .contentType
                                                              ? "Content type" : "URL scheme")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                DeclarationSection(title: "Exported UTI Declarations", declarations: projection.exportedTypes, application: application, store: store)
                DeclarationSection(title: "Imported UTI Declarations", declarations: projection.importedTypes, application: application, store: store)
                if !application.warnings.isEmpty {
                    MetadataRow(label: "Bundle warnings", value: application.warnings.joined(separator: "\n"))
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DeclarationSection: View {
    let title: String
    let declarations: [ContentTypeDeclaration]
    let application: ApplicationRecord
    @ObservedObject var store: AppStore

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 16) {
                if declarations.isEmpty { Text("None declared").foregroundStyle(.secondary) }
                ForEach(declarations) { declaration in
                    VStack(alignment: .leading, spacing: 8) {
                        ApplicationAssociationRow(identifier: declaration.identifier, kind: .contentType, application: application, store: store)
                        if let description = declaration.typeDescription { Text(description) }
                        if !declaration.conformanceIdentifiers.isEmpty {
                            MetadataRow(label: "Conforms to", value: declaration.conformanceIdentifiers.joined(separator: ", "))
                        }
                        TypeTagsView(tags: declaration.tags)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
}

private struct AssociationLink: View {
    let identifier: String
    let kind: Association.Kind
    let navigate: (Association) -> Void

    var body: some View {
        Button(identifier) {
            let association = kind == .urlScheme
                ? try? Association.urlScheme(identifier)
                : try? Association.contentType(identifier)
            if let association { navigate(association) }
        }
        .buttonStyle(.link)
        .help("Show handlers for \(identifier)")
        .accessibilityHint("Opens the association tab")
    }
}

private struct ApplicationAssociationRow: View {
    let identifier: String
    let kind: Association.Kind
    let application: ApplicationRecord
    @ObservedObject var store: AppStore
    var detailLabel: String?

    private var association: Association? {
        kind == .urlScheme ? try? .urlScheme(identifier) : try? .contentType(identifier)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                AssociationLink(identifier: identifier, kind: kind, navigate: store.navigate)
                if let detailLabel { Text(detailLabel).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            if let association {
                let state = store.defaultHandlers[association] ?? .notLoaded
                if state.application?.id == application.id {
                    Label("Default", systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .fixedSize()
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let status = status(state) {
                            Text(status).foregroundStyle(.secondary)
                                .help(state.errorMessage ?? state.label)
                        }
                        Button("Make Default") {
                            Task { await store.setDefault(application.reference, for: association) }
                        }
                        .buttonStyle(.link)
                        .fixedSize()
                        .disabled((store.pendingMutation != nil || store.isCreatingAssociation))
                        .accessibilityLabel("Make \(application.displayName) default for \(identifier)")
                        .help(kind == .contentType && store.backend == .legacy
                              ? "Set default for all roles" : "Set default for this association")
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func status(_ state: DefaultHandlerState) -> String? {
        switch state {
        case .notLoaded: "Checking…"
        case .application: nil
        case .none: "No default"
        case .failed: "Lookup unavailable"
        }
    }
}
