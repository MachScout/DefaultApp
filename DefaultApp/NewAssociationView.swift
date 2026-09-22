import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DefaultAppCore

struct NewAssociationView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: NewAssociationDraft
    @State private var appChoice = "later"
    @State private var otherApplication: ApplicationReference?
    @State private var showsAdvanced = false
    @State private var operationError: String?
    @State private var savedAssociation: Association?
    @FocusState private var identifierFocused: Bool

    init(store: AppStore, kind: Association.Kind) {
        self.store = store
        _draft = State(initialValue: NewAssociationDraft(kind: kind))
    }

    private var isURLScheme: Bool { draft.kind == .urlScheme }
    private var isDynamic: Bool { !isURLScheme && draft.contentTypeCreation == .dynamic }
    private var duplicate: Association? { savedAssociation == nil ? store.existingAssociation(for: draft) : nil }
    private var validationError: CustomAssociationValidationError? {
        do { _ = try draft.validatedRecord(); return nil }
        catch { return error as? CustomAssociationValidationError }
    }
    private var selectedApplication: ApplicationReference? {
        switch appChoice {
        case "defaultapp": return ApplicationReference(url: Bundle.main.bundleURL, bundleIdentifier: Bundle.main.bundleIdentifier)
        case "other": return otherApplication
        default: return nil
        }
    }
    private var primaryTitle: String {
        if savedAssociation != nil { return "Retry" }
        return selectedApplication == nil ? "Create" : "Create & Set Default"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(isURLScheme ? "New URL Scheme" : "New Content Type").font(.title2).fontWeight(.semibold)
                Text(isURLScheme ? "Choose how links with this scheme open." : isDynamic
                     ? "Associate an undeclared filename extension without adding an Info.plist type declaration."
                     : "Define a file format and register it with macOS.")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 16) {
                if !isURLScheme {
                    Picker("Type creation", selection: $draft.contentTypeCreation) {
                        Text("Declare a type").tag(ContentTypeCreation.declared)
                        Text("Use a dynamic type").tag(ContentTypeCreation.dynamic)
                    }
                    .pickerStyle(.segmented)
                }
                if !isDynamic {
                    field(isURLScheme ? "Scheme" : "Identifier (UTI)", text: $draft.identifier,
                          placeholder: isURLScheme ? "myproject" : "com.example.myproject", errorField: .identifier)
                        .focused($identifierFocused)
                }
                if let duplicate {
                    HStack(alignment: .top) {
                        Label("This identifier already exists.", systemImage: "info.circle")
                        Spacer()
                        Button("Open Existing") {
                            store.navigate(to: duplicate)
                            dismiss()
                        }
                    }
                    .font(.callout)
                } else if isURLScheme {
                    Text("Example: \(draft.parsedAssociation?.identifier ?? "myproject")://open")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if isDynamic {
                    field("Filename extension", text: $draft.filenameExtensions,
                          placeholder: "myproj", errorField: .filenameExtensions)
                    Text("macOS generates \(draft.parsedAssociation?.identifier ?? "a dyn.* identifier") from this extension. Choose an application to save its default handler.")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                } else if !isURLScheme {
                    field("Name", text: $draft.name, placeholder: "Project Document", errorField: .name)
                    field("Filename extensions", text: $draft.filenameExtensions,
                          placeholder: "myproj, project", errorField: .filenameExtensions)
                    Text("Separate multiple extensions with commas.").font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                        VStack(alignment: .leading, spacing: 14) {
                            Picker("Conforms to", selection: $draft.conformsTo) {
                                Text("Data (public.data)").tag("public.data")
                                Text("Text (public.text)").tag("public.text")
                                Text("Package (com.apple.package)").tag("com.apple.package")
                            }
                            field("MIME type · Optional", text: $draft.mimeType,
                                  placeholder: "application/x-myproject", errorField: .mimeType)
                        }
                        .padding(.top, 12)
                    }
                }
            }
            .disabled(store.isCreatingAssociation || savedAssociation != nil)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Open with", selection: $appChoice) {
                        Text("Choose later").tag("later")
                        Text("DefaultApp — ask each time").tag("defaultapp")
                        if let otherApplication {
                            Text(otherApplication.url.deletingPathExtension().lastPathComponent).tag("other")
                        }
                    }
                    Button("Other Application…", action: chooseApplication)
                }
                if let otherApplication, appChoice == "other" {
                    Text(otherApplication.url.path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
                if isDynamic && selectedApplication == nil {
                    Text("A dynamic type needs a default application to create a Launch Services preference.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if isURLScheme && selectedApplication == nil {
                    Text("Saved in DefaultApp. Choose an application to enable opening links.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(store.isCreatingAssociation)

            if let operationError {
                Label(operationError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.isCreatingAssociation {
                HStack(alignment: .top, spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(store.pendingMutation != nil
                         ? "Setting default… Complete any macOS confirmation dialog."
                         : "Saving and registering the association…")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button(savedAssociation == nil ? "Cancel" : "Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(store.isCreatingAssociation)
                Button(primaryTitle) { Task { await create() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.isCreatingAssociation || duplicate != nil || validationError != nil
                              || (isDynamic && selectedApplication == nil)
                              || (savedAssociation == nil && !store.canCreateAssociation))
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled(store.isCreatingAssociation)
        .task { identifierFocused = true }
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String,
                       errorField: CustomAssociationValidationError.Field) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).fontWeight(.medium)
            TextField(placeholder, text: text)
                .accessibilityLabel(title)
            if duplicate == nil, let error = validationError, error.field == errorField, !text.wrappedValue.isEmpty {
                Text(error.message).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func create() async {
        operationError = nil
        let result: AppStore.CreationResult
        if let savedAssociation {
            result = await store.retryCustomAssociation(savedAssociation, application: selectedApplication)
        } else {
            result = await store.createAssociation(draft, application: selectedApplication)
        }
        switch result {
        case .created: dismiss()
        case .duplicate: break // The inline duplicate action uses the refreshed catalog.
        case .failed(let message): operationError = message
        case .savedWithIssue(let association, let message):
            savedAssociation = association
            operationError = message
        }
    }

    @MainActor private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose Application"
        panel.message = "The default changes only when you confirm the creation form."
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        otherApplication = ApplicationReference(url: url, bundleIdentifier: Bundle(url: url)?.bundleIdentifier)
        appChoice = "other"
    }
}
