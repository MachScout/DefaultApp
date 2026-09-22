import SwiftUI
import DefaultAppCore

struct MyHandlersView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("My Handlers")
                        .font(.largeTitle.weight(.semibold))
                    Text("Associations currently handled by DefaultApp and the applications that can be restored.")
                        .foregroundStyle(.secondary)
                }

                incomingItems

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Default handlers")
                            .font(.headline)
                        Spacer()
                        Button("Refresh") { Task { await store.loadOwnedHandlers(forceRefresh: true) } }
                            .disabled(store.isLoadingOwnedHandlers || store.isRestoringOwnedHandlers)
                    }

                    if store.isLoadingOwnedHandlers || store.isCatalogPending {
                        ProgressView("Checking URL schemes and content types…")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if store.snapshot == nil {
                        Text("Catalog could not be loaded. Use Refresh to try again.")
                            .foregroundStyle(.secondary)
                    } else if store.ownedHandlers.isEmpty {
                        Text("DefaultApp is not the default handler for any known association.")
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(store.ownedHandlers) { row in
                                HStack(alignment: .top, spacing: 16) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(row.association.identifier)
                                            .font(.body.monospaced())
                                            .textSelection(.enabled)
                                        Text(row.association.kind == .urlScheme ? "URL scheme" : "Content type")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 3) {
                                        Text(row.previousApplication?.displayName ?? "No other handler available")
                                        if row.isAutomaticallyDetermined {
                                            Text("Automatically determined")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        } else if row.previousApplication != nil {
                                            Text("Previously saved")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        if row.backend == .legacy && row.role != .all {
                                            Text("\(row.role.displayName) · Legacy API")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .padding(12)
                                .accessibilityElement(children: .combine)
                                Divider()
                            }
                        }
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    Button("Restore previous handlers") {
                        Task { await store.restorePreviousHandlers() }
                    }
                    .disabled(store.isLoadingOwnedHandlers || store.isRestoringOwnedHandlers
                              || !store.ownedHandlers.contains { $0.previousApplication != nil })
                    if store.isRestoringOwnedHandlers {
                        ProgressView("Restoring handlers one by one…")
                    }
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 44)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var incomingItems: some View {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
        }
    }
}
