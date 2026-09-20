import SwiftUI
import DefaultAppCore

struct GeneralSettingsView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Default applications")
                        .font(.largeTitle.weight(.semibold))
                    Text("Choose the applications macOS uses for web links and email links.")
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 0) {
                    DefaultApplicationPickerRow(
                        title: "Default web browser",
                        systemImage: "safari",
                        state: store.browserDefaultState,
                        isDisabled: store.pendingMutation != nil,
                        retry: { await store.loadGeneralDefaults() },
                        select: { await store.selectDefaultBrowser($0) }
                    )
                    Divider().padding(.leading, 52)
                    DefaultApplicationPickerRow(
                        title: "Default email application",
                        systemImage: "envelope",
                        state: store.emailDefaultState,
                        isDisabled: store.pendingMutation != nil,
                        retry: { await store.loadGeneralDefaults() },
                        select: { await store.selectDefaultEmail($0) }
                    )
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Incoming Items")
                        .font(.headline)
                    Toggle("Close the window after the queue is handled",
                           isOn: $store.closesIncomingWindowAfterHandling)
                    Text("When DefaultApp is launched by a file or URL, it always quits after the incoming queue is handled.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 44)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct DefaultApplicationPickerRow: View {
    let title: String
    let systemImage: String
    let state: AppStore.GeneralDefaultState
    let isDisabled: Bool
    let retry: () async -> Void
    let select: (ApplicationRecord) async -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 19))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            Text(title)
            Spacer(minLength: 24)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var control: some View {
        switch state {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
            .frame(width: 230, alignment: .trailing)
        case .failed:
            Button("Try Again") { Task { await retry() } }
        case .loaded(let applications, let selectedApplication, let hasMixedSelection):
            if applications.isEmpty {
                Text("No compatible applications")
                    .foregroundStyle(.secondary)
                    .frame(width: 230, alignment: .trailing)
            } else {
                Menu {
                    ForEach(applications) { application in
                        Button {
                            Task { await select(application) }
                        } label: {
                            if application.id == selectedApplication?.id {
                                Label(application.displayName, systemImage: "checkmark")
                            } else {
                                Text(application.displayName)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 7) {
                        if let selectedApplication {
                            AppIconView(url: selectedApplication.url, size: 16)
                        }
                        Text(selectionTitle(
                            selectedApplication: selectedApplication,
                            hasMixedSelection: hasMixedSelection
                        ))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        Spacer(minLength: 8)
                    }
                    .frame(width: 200, alignment: .leading)
                }
                .menuStyle(.borderedButton)
                .frame(width: 230)
                .disabled(isDisabled)
                .accessibilityLabel(title)
            }
        }
    }

    private func selectionTitle(
        selectedApplication: ApplicationRecord?,
        hasMixedSelection: Bool
    ) -> String {
        if hasMixedSelection { return "Mixed defaults" }
        return selectedApplication?.displayName ?? "No default application"
    }
}
