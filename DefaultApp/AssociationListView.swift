import SwiftUI
import DefaultAppCore

struct AssociationListView: View {
    let rows: [AssociationRow]
    @Binding var selection: String?
    let search: String
    let isLoading: Bool
    var showsExtensions = false
    var customAssociations: Set<Association> = []
    @Binding var sort: AssociationSort

    private var tableSelection: Binding<Association?> {
        Binding(get: { rows.first { $0.identifier == selection }?.id },
                set: { selection = $0?.identifier })
    }

    private var tableSortOrder: Binding<[KeyPathComparator<AssociationRow>]> {
        Binding(
            get: { [sort.comparator] },
            set: { newValue in
                guard let comparator = newValue.first,
                      let newSort = AssociationSort(comparator: comparator) else { return }
                sort = newSort
            }
        )
    }

    var body: some View {
        // Conditional TableColumn builders require macOS 14.4; keep both tables on macOS 12.
        Group {
            if showsExtensions {
                Table(rows, selection: tableSelection, sortOrder: tableSortOrder) {
                    TableColumn("Identifier", value: \.identifier) { row in
                        identifierCell(row)
                    }
                    .width(min: 130, ideal: 170)
                    TableColumn("Extensions", value: \.filenameExtensionsSortValue) { row in
                        Text(row.filenameExtensions.isEmpty ? "—" : row.filenameExtensions.joined(separator: ", "))
                            .lineLimit(1).help(row.filenameExtensions.joined(separator: ", "))
                    }
                    .width(min: 70, ideal: 100)
                    TableColumn("Default Application", value: \.defaultApplicationSortValue) { row in
                        DefaultApplicationCell(state: row.defaultHandler)
                    }
                    .width(min: 190, ideal: 250)
                }
            } else {
                Table(rows, selection: tableSelection, sortOrder: tableSortOrder) {
                    TableColumn("Identifier", value: \.identifier) { row in
                        identifierCell(row)
                    }
                    TableColumn("Default Application", value: \.defaultApplicationSortValue) { row in
                        DefaultApplicationCell(state: row.defaultHandler)
                    }
                    .width(min: 190, ideal: 250)
                }
            }
        }
        .accessibilityLabel("Associations")
        .overlay {
            if rows.isEmpty && !isLoading {
                EmptyStateView(title: search.isEmpty ? "No associations" : "No results",
                               message: search.isEmpty ? "Refresh to reload the catalog."
                                : showsExtensions ? "Try an identifier, extension, or default application name."
                                : "Try a different identifier or application name.",
                               symbol: "magnifyingglass")
                    .allowsHitTesting(false)
            }
        }
    }

    private func identifierCell(_ row: AssociationRow) -> some View {
        HStack(spacing: 6) {
            Text(row.identifier).lineLimit(1).help(row.identifier)
            if customAssociations.contains(row.association) {
                Text("Custom").font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private extension AssociationSort {
    var comparator: KeyPathComparator<AssociationRow> {
        let order: SortOrder = ascending ? .forward : .reverse
        switch column {
        case .identifier:
            return KeyPathComparator(\AssociationRow.identifier, order: order)
        case .filenameExtensions:
            return KeyPathComparator(\AssociationRow.filenameExtensionsSortValue, order: order)
        case .defaultApplication:
            return KeyPathComparator(\AssociationRow.defaultApplicationSortValue, order: order)
        }
    }

    init?(comparator: KeyPathComparator<AssociationRow>) {
        let column: AssociationSortColumn
        switch comparator.keyPath {
        case \AssociationRow.identifier:
            column = .identifier
        case \AssociationRow.filenameExtensionsSortValue:
            column = .filenameExtensions
        case \AssociationRow.defaultApplicationSortValue:
            column = .defaultApplication
        default:
            return nil
        }
        self.init(column: column, ascending: comparator.order == .forward)
    }
}

private struct DefaultApplicationCell: View {
    let state: DefaultHandlerState

    var body: some View {
        if let application = state.application {
            HStack(spacing: 6) {
                AppIconView(url: application.url, size: 18)
                Text(application.displayName).lineLimit(1)
            }
            .help(application.displayName)
            .accessibilityElement(children: .combine)
        } else {
            Text(state.label).lineLimit(1).help(state.errorMessage ?? state.label)
        }
    }
}
