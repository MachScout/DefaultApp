import AppKit
import SwiftUI

struct IncomingOpenView: View {
    @ObservedObject var store: IncomingOpenStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Open with…").font(.title2)
                Spacer()
                Text("\(store.remainingCount) more in queue").foregroundStyle(.secondary)
            }
            if let request = store.current {
                Text(request.url.isFileURL ? "FILE" : "URL").font(.caption).foregroundStyle(.secondary)
                Text(request.displayValue)
                    .id(request.id)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .help(request.displayValue)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button(request.url.isFileURL ? "Copy Path" : "Copy Link", action: store.copyCurrent)
                    if request.url.isFileURL {
                        Button("Show in Finder", action: store.revealCurrent)
                    }
                }
                if store.isLoading {
                    ProgressView("Finding applications…")
                }
                List(store.handlers, selection: $store.selectedHandlerID) { application in
                    ApplicationIdentityView(application: application)
                        .padding(.vertical, 4)
                        .tag(application.id)
                }
                .accessibilityLabel("Applications that can open this item")
                .overlay {
                    if !store.isLoading && store.handlers.isEmpty {
                        Text("No other registered handlers. You can copy the item or show it in Finder.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                    }
                }
                if let error = store.errorMessage {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack {
                    Button("Refresh Handlers") { Task { await store.loadHandlers() } }
                        .disabled(store.isLoading || store.isOpening)
                    Spacer()
                    Button("Skip", action: store.skip).disabled(store.isOpening)
                    Button("Open") {
                        if let application = store.handlers.first(where: { $0.id == store.selectedHandlerID }) {
                            Task { await store.open(using: application) }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.selectedHandlerID == nil || store.isLoading || store.isOpening)
                    if store.isOpening { ProgressView().controlSize(.small) }
                }
            } else {
                Text("All incoming items have been handled.").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(24)
        .frame(minWidth: 640, minHeight: 420)
        .task(id: store.current?.id) { await store.loadHandlers() }
    }
}
