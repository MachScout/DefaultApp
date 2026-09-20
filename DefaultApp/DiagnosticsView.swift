import AppKit
import SwiftUI
import DefaultAppCore

struct DiagnosticsView: View {
    let projection: DiagnosticsProjection
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Diagnostics").font(.title2)
                    Spacer()
                    Button(action: copy) {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .help("Copy the diagnostic report to the clipboard")
                }
                GroupBox("System and Catalog") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(projection.rows) { row in
                            HStack(alignment: .top) {
                                Text(row.label).foregroundStyle(.secondary)
                                Spacer(minLength: 24)
                                Text(row.value).textSelection(.enabled).multilineTextAlignment(.trailing)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(12)
                }
                GroupBox("Private Symbols") {
                    VStack(alignment: .leading, spacing: 8) {
                        if projection.symbols.isEmpty {
                            Text("Load the catalog to see its reported symbols.").foregroundStyle(.secondary)
                        }
                        ForEach(projection.symbols, id: \.self) { symbol in
                            Text(symbol).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                GroupBox("Warnings") {
                    Text(projection.warnings.isEmpty ? "None reported" : projection.warnings.joined(separator: "\n\n"))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
            .padding(24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setString(projection.text, forType: .string)
    }
}
