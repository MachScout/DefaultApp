import AppKit
import Combine
import Foundation
import DefaultAppCore

protocol HandlerServicing: Sendable {
    func catalog(forceRefresh: Bool) async throws -> CatalogSnapshot
    func refreshedApplicationCatalog(at url: URL) async throws -> CatalogSnapshot?
    func refreshedContentTypeCatalog(_ identifier: String) async throws -> CatalogSnapshot?
    func applications(
        capableOf association: Association,
        backend: Backend,
        role: HandlerRole
    ) async throws -> [ApplicationRecord]
    func defaultApplication(
        for association: Association,
        backend: Backend,
        role: HandlerRole
    ) async throws -> ApplicationRecord?
    func setDefaultApplication(
        _ application: ApplicationReference,
        for association: Association,
        backend: Backend,
        role: HandlerRole
    ) async throws
}

extension HandlerServicing {
    func refreshedApplicationCatalog(at url: URL) async throws -> CatalogSnapshot? { nil }
    func refreshedContentTypeCatalog(_ identifier: String) async throws -> CatalogSnapshot? { nil }
}

extension HandlerService: HandlerServicing {
    func refreshedApplicationCatalog(at url: URL) async throws -> CatalogSnapshot? { try await refreshApplication(at: url) }
    func refreshedContentTypeCatalog(_ identifier: String) async throws -> CatalogSnapshot? { try await refreshContentType(identifier) }
}

@MainActor
final class AppStore: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable, Sendable {
        case general
        case urlSchemes
        case contentTypes
        case applications
        case diagnostics

        var id: Self { self }

        var title: String {
            switch self {
            case .general: "General"
            case .urlSchemes: "URL Schemes"
            case .contentTypes: "Content Types"
            case .applications: "Applications"
            case .diagnostics: "Diagnostics"
            }
        }
    }

    struct PresentedError: Identifiable, Equatable, Sendable {
        let message: String

        var id: String { message }

        fileprivate init(_ error: any Error) {
            message = error.localizedDescription
        }
    }

    /// The lookup result is independent of the visibility of a dismissible error banner.
    enum HandlerLookupState: Equatable, Sendable {
        case unresolved
        case loading
        case loaded(applications: [ApplicationRecord], defaultApplication: ApplicationRecord?)
        case failed(String)
    }

    enum CreationResult: Equatable {
        case created(Association)
        case duplicate(Association)
        case failed(String)
        case savedWithIssue(Association, String)
    }

    enum CustomRegistrationState: Equatable {
        case saved
        case registering
        case registered
        case failed(String)
    }

    enum GeneralDefaultState: Equatable, Sendable {
        case loading
        case loaded(
            applications: [ApplicationRecord],
            selectedApplication: ApplicationRecord?,
            hasMixedSelection: Bool
        )
        case failed(String)
    }

    @Published private(set) var snapshot: CatalogSnapshot?
    @Published var selectedTab: Tab = .general
    @Published var selectedAssociationID: String? {
        didSet { if selectedAssociationID != oldValue { showCachedHandlers() } }
    }
    @Published var selectedApplicationID: String?
    @Published var backend: Backend = .modern
    @Published var role: HandlerRole = .all
    @Published var closesIncomingWindowAfterHandling = true
    @Published var searchText = ""
    @Published var showsDiagnostics = true {
        didSet {
            if !showsDiagnostics, selectedTab == .diagnostics { selectTab(.general) }
        }
    }
    @Published var showAllContentTypes = false {
        didSet {
            associationIndexes[.contentType] = nil
            associationRowsCache = nil
        }
    }
    @Published var contentTypeFilters = ContentTypeFilters() {
        didSet {
            associationRowsCache = nil
        }
    }
    @Published var associationSort = AssociationSort() {
        didSet {
            associationRowsCache = nil
        }
    }
    @Published var applicationFilters = ApplicationFilters() {
        didSet {
            applicationRowsCache = nil
        }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var pendingMutation: ApplicationRecord.ID?
    @Published var presentedError: PresentedError?

    @Published private(set) var handlerLookupState: HandlerLookupState = .unresolved
    @Published private(set) var defaultHandlers: [Association: DefaultHandlerState] = [:] {
        didSet {
            associationRowsCache = nil
            applicationRowsCache = nil
        }
    }
    @Published private(set) var isResolvingDefaults = false
    @Published private(set) var refreshDuration: TimeInterval?
    @Published private(set) var catalogRevision: UInt = 0
    @Published private(set) var customAssociations: [CustomAssociation] = []
    @Published private(set) var customRegistrationStates: [Association: CustomRegistrationState] = [:]
    @Published private(set) var isCreatingAssociation = false
    @Published private(set) var browserDefaultState: GeneralDefaultState = .loading
    @Published private(set) var emailDefaultState: GeneralDefaultState = .loading

    private let customAssociationStore: any CustomAssociationPersisting
    private let customTypeRegistrar: any CustomTypeRegistering
    private let userDefaults: UserDefaults?
    private var customAssociationsLoaded = false
    private var customLoadTask: Task<[CustomAssociation], Error>?
    private var systemSnapshot: CatalogSnapshot?

    private let service: any HandlerServicing
    private let applicationReferenceResolver: any ApplicationReferenceResolving
    private var activeLoadCount = 0
    private var catalogRequestGeneration: UInt = 0
    private var handlerRequestGeneration: UInt = 0
    private var defaultsRequestGeneration: UInt = 0
    private var tabSelectionRequestGeneration: UInt = 0
    private var rowSelectionGeneration: UInt = 0
    private var pendingRowSelectionTask: Task<Void, Never>?
    private var pendingTabSelectionTask: Task<Void, Never>?
    private var preferenceCancellables: Set<AnyCancellable> = []
    private var tabSearches: [Tab: String] = [:]
    private struct LookupKey: Hashable {
        let association: Association
        let backend: Backend
        let role: HandlerRole
    }
    private struct CachedDefault {
        let state: DefaultHandlerState
        let checkedAt: Date
    }
    private var handlerCache: [LookupKey: HandlerLookupState] = [:]
    private var defaultCache: [LookupKey: CachedDefault] = [:]
    private var lookupVersions: [LookupKey: UInt] = [:]
    private var applicationRequestGeneration: UInt = 0
    private var contentTypeRequestGeneration: UInt = 0
    private var generalDefaultsRequestGeneration: UInt = 0
    private var associationRowsCache: (tab: Tab, search: String, rows: [AssociationRow])?
    private var associationIndexes: [Association.Kind: AssociationListIndex] = [:]
    private var applicationRowsCache: (search: String, filters: ApplicationFilters, rows: [ApplicationRecord])?
    private var applicationsByID: [String: ApplicationRecord] = [:]
    private var contentTypesByID: [String: ContentTypeRecord] = [:]


    struct ListQuery: Hashable {
        let tab: Tab
        let backend: Backend
        let role: HandlerRole
        let catalogRevision: UInt
        let applicationID: String?
        let showAllContentTypes: Bool
        let contentTypeFilters: ContentTypeFilters
    }

    var listQuery: ListQuery {
        ListQuery(tab: selectedTab, backend: backend, role: effectiveRole, catalogRevision: catalogRevision,
                  applicationID: selectedTab == .applications ? selectedApplicationID : nil,
                  showAllContentTypes: showAllContentTypes, contentTypeFilters: contentTypeFilters)
    }

    var associationRows: [AssociationRow] {
        guard let snapshot else { return [] }
        if let cached = associationRowsCache, cached.tab == selectedTab, cached.search == searchText { return cached.rows }
        let kind: Association.Kind
        switch selectedTab {
        case .urlSchemes: kind = .urlScheme
        case .contentTypes: kind = .contentType
        case .general, .applications, .diagnostics: return []
        }
        if associationIndexes[kind] == nil { associationIndexes[kind] = AssociationListIndex(snapshot: snapshot, kind: kind, includeNonFileTypes: showAllContentTypes) }
        let filters = kind == .contentType ? contentTypeFilters : ContentTypeFilters()
        let rows = associationIndexes[kind]?.rows(defaults: defaultHandlers, search: searchText,
                                                  filters: filters, sort: associationSort) ?? []
        associationRowsCache = (selectedTab, searchText, rows)
        return rows
    }

    var handlerApplications: [ApplicationRecord] {
        guard case .loaded(let applications, _) = handlerLookupState else { return [] }
        return applications
    }

    var defaultApplication: ApplicationRecord? {
        guard case .loaded(_, let application) = handlerLookupState else { return nil }
        return application
    }

    var applicationRows: [ApplicationRecord] {
        guard let snapshot else { return [] }
        if let cached = applicationRowsCache, cached.search == searchText, cached.filters == applicationFilters { return cached.rows }
        var filters = applicationFilters
        filters.hideWithoutAssociations = false
        let knownDefaults = Set(defaultHandlers.values.compactMap { $0.application?.id })
        let rows = ApplicationProjection.records(from: snapshot, search: searchText, filters: filters).filter {
            !applicationFilters.hideWithoutAssociations || !ApplicationVisibility(record: $0).hasNoAssociations || knownDefaults.contains($0.id)
        }
        applicationRowsCache = (searchText, applicationFilters, rows)
        return rows
    }

    var selectedApplication: ApplicationRecord? {
        selectedApplicationID.flatMap { applicationsByID[$0] }
    }

    var selectedContentType: ContentTypeRecord? {
        guard selectedTab == .contentTypes else { return nil }
        return selectedAssociationID.flatMap { contentTypesByID[$0] }
    }

    var showsRoles: Bool {
        selectedTab == .contentTypes && backend == .legacy
    }

    var visibleTabs: [Tab] {
        Tab.allCases.filter { showsDiagnostics || $0 != .diagnostics }
    }

    private var effectiveRole: HandlerRole { showsRoles ? role : .all }

    init(
        service: any HandlerServicing = HandlerService(),
        applicationReferenceResolver: any ApplicationReferenceResolving = BundleApplicationReferenceResolver(),
        customAssociationStore: any CustomAssociationPersisting = CustomAssociationFileStore(),
        customTypeRegistrar: any CustomTypeRegistering = CustomTypeRegistrar(),
        userDefaults: UserDefaults? = nil
    ) {
        self.service = service
        self.applicationReferenceResolver = applicationReferenceResolver
        self.customAssociationStore = customAssociationStore
        self.customTypeRegistrar = customTypeRegistrar
        self.userDefaults = userDefaults
        if let userDefaults {
            backend = userDefaults.string(forKey: PreferenceKey.backend)
                .flatMap(Backend.init(rawValue:)) ?? .modern
            showsDiagnostics = userDefaults.object(forKey: PreferenceKey.showsDiagnostics) as? Bool ?? true
            closesIncomingWindowAfterHandling =
                userDefaults.object(forKey: PreferenceKey.closesIncomingWindowAfterHandling) as? Bool ?? true
            showAllContentTypes = userDefaults.bool(forKey: PreferenceKey.showAllContentTypes)
            contentTypeFilters = ContentTypeFilters(
                hideWithoutExtensions: userDefaults.bool(forKey: PreferenceKey.hideContentTypesWithoutExtensions),
                hideWithoutDefaultApplication: userDefaults.bool(forKey: PreferenceKey.hideContentTypesWithoutDefaultApplication),
                onlyDynamic: userDefaults.bool(forKey: PreferenceKey.onlyDynamicContentTypes)
            )
            applicationFilters = ApplicationFilters(
                hideAuxiliary: userDefaults.bool(forKey: PreferenceKey.hideAuxiliaryApplications),
                hideDevelopment: userDefaults.bool(forKey: PreferenceKey.hideDevelopmentApplications),
                hideWithoutAssociations: userDefaults.bool(forKey: PreferenceKey.hideApplicationsWithoutAssociations)
            )
            associationSort = AssociationSort(
                column: AssociationSortColumn(rawValue: userDefaults.string(forKey: PreferenceKey.associationSortColumn) ?? "")
                    ?? .identifier,
                ascending: userDefaults.object(forKey: PreferenceKey.associationSortAscending) as? Bool ?? true
            )
        }
        observeDisplayPreferences()
    }

    @discardableResult
    func load(forceRefresh: Bool = false) async -> Bool {
        guard !isCreatingAssociation else { return false }
        catalogRequestGeneration &+= 1
        let requestGeneration = catalogRequestGeneration
        beginLoading()
        presentedError = nil
        let started = Date()
        defer { endLoading() }

        let customLoadError = await loadCustomAssociations()
        do {
            let refreshedSnapshot = try await service.catalog(forceRefresh: forceRefresh)
            guard catalogRequestGeneration == requestGeneration else { return false }
            publishSnapshot(refreshedSnapshot)
            refreshDuration = Date().timeIntervalSince(started)
            if forceRefresh {
                // Preserve visible values while marking every cached query stale.
                for key in defaultCache.keys {
                    defaultCache[key] = defaultCache[key].map { CachedDefault(state: $0.state, checkedAt: .distantPast) }
                }
                defaultsRequestGeneration &+= 1
                for key in lookupVersions.keys { lookupVersions[key, default: 0] &+= 1 }
                catalogRevision &+= 1
            }
            if let snapshot { reconcileSelections(with: snapshot) }
            if forceRefresh { await refreshCustomRegistrationStates() }
            if let customLoadError { presentedError = PresentedError(customLoadError) }
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard catalogRequestGeneration == requestGeneration else { return false }
            presentedError = PresentedError(error)
            return false
        }
    }

    func selectBackend(_ newBackend: Backend) async {
        guard pendingMutation == nil, !isCreatingAssociation, newBackend != backend else { return }
        backend = newBackend
        if !showsRoles {
            role = .all
        }
        invalidateDefaults()
        await loadHandlers()
    }

    func selectRole(_ newRole: HandlerRole) async {
        guard pendingMutation == nil, !isCreatingAssociation else { return }
        let previousRole = effectiveRole
        role = showsRoles ? newRole : .all
        guard effectiveRole != previousRole else { return }
        invalidateDefaults()
        await loadHandlers()
    }

    func selectTab(_ tab: Tab) {
        guard !isCreatingAssociation, showsDiagnostics || tab != .diagnostics else { return }
        invalidatePendingTabSelection()
        applyTabSelection(tab)
    }

    func requestTabSelection(_ tab: Tab) {
        invalidatePendingTabSelection()
        guard pendingMutation == nil, !isCreatingAssociation, tab != selectedTab,
              showsDiagnostics || tab != .diagnostics else { return }
        let requestGeneration = tabSelectionRequestGeneration
        pendingTabSelectionTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  !Task.isCancelled,
                  self.tabSelectionRequestGeneration == requestGeneration else {
                return
            }
            self.pendingTabSelectionTask = nil
            self.applyTabSelection(tab)
        }
    }

    /// Native List/Table may write their binding during layout or teardown.
    /// Defer all row-selection publications and reject callbacks from an old pane.
    func requestRowSelection(_ id: String?, in tab: Tab) {
        guard pendingMutation == nil, !isCreatingAssociation, selectedTab == tab, tab != .diagnostics else { return }
        invalidatePendingRowSelection()
        let current = tab == .applications ? selectedApplicationID : selectedAssociationID
        guard current != id else { return }
        let generation = rowSelectionGeneration
        pendingRowSelectionTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled, self.rowSelectionGeneration == generation,
                  self.selectedTab == tab, self.pendingMutation == nil, !self.isCreatingAssociation else { return }
            self.pendingRowSelectionTask = nil
            if tab == .applications {
                if self.selectedApplicationID != id { self.selectedApplicationID = id }
            } else if self.selectedAssociationID != id { self.selectedAssociationID = id }
        }
    }

    private func invalidatePendingRowSelection() {
        rowSelectionGeneration &+= 1
        pendingRowSelectionTask?.cancel()
        pendingRowSelectionTask = nil
    }

    private func applyTabSelection(_ tab: Tab, duringCreation: Bool = false) {
        guard pendingMutation == nil, (!isCreatingAssociation || duringCreation), tab != selectedTab,
              showsDiagnostics || tab != .diagnostics else { return }
        invalidatePendingRowSelection()
        tabSearches[selectedTab] = searchText
        selectedTab = tab
        searchText = tabSearches[tab] ?? ""
        selectedAssociationID = nil
        if !showsRoles { role = .all }
        handlerRequestGeneration &+= 1
        handlerLookupState = .unresolved
        presentedError = nil
        invalidateDefaults()
    }

    private func invalidatePendingTabSelection() {
        tabSelectionRequestGeneration &+= 1
        pendingTabSelectionTask?.cancel()
        pendingTabSelectionTask = nil
    }

    private enum PreferenceKey {
        static let backend = "display.backend"
        static let showsDiagnostics = "display.showsDiagnostics"
        static let closesIncomingWindowAfterHandling = "incomingItems.closeAfterHandling"
        static let showAllContentTypes = "contentTypes.showAllIdentifiers"
        static let hideContentTypesWithoutExtensions = "contentTypes.hideWithoutExtensions"
        static let hideContentTypesWithoutDefaultApplication = "contentTypes.hideWithoutDefaultApplication"
        static let onlyDynamicContentTypes = "contentTypes.onlyDynamic"
        static let hideAuxiliaryApplications = "applications.hideAuxiliary"
        static let hideDevelopmentApplications = "applications.hideDevelopment"
        static let hideApplicationsWithoutAssociations = "applications.hideWithoutAssociations"
        static let associationSortColumn = "associations.sortColumn"
        static let associationSortAscending = "associations.sortAscending"
    }

    private func observeDisplayPreferences() {
        $backend.dropFirst().sink { [weak self] value in
            self?.userDefaults?.set(value.rawValue, forKey: PreferenceKey.backend)
        }
            .store(in: &preferenceCancellables)
        $showsDiagnostics.dropFirst().sink { [weak self] value in
            self?.userDefaults?.set(value, forKey: PreferenceKey.showsDiagnostics)
        }
            .store(in: &preferenceCancellables)
        $closesIncomingWindowAfterHandling.dropFirst().sink { [weak self] value in
            self?.userDefaults?.set(value, forKey: PreferenceKey.closesIncomingWindowAfterHandling)
        }
            .store(in: &preferenceCancellables)
        $showAllContentTypes.dropFirst().sink { [weak self] value in
            self?.userDefaults?.set(value, forKey: PreferenceKey.showAllContentTypes)
        }
            .store(in: &preferenceCancellables)
        $contentTypeFilters.dropFirst().sink { [weak self] value in
            self?.userDefaults?.set(value.hideWithoutExtensions,
                                    forKey: PreferenceKey.hideContentTypesWithoutExtensions)
            self?.userDefaults?.set(value.hideWithoutDefaultApplication,
                                    forKey: PreferenceKey.hideContentTypesWithoutDefaultApplication)
            self?.userDefaults?.set(value.onlyDynamic, forKey: PreferenceKey.onlyDynamicContentTypes)
        }
            .store(in: &preferenceCancellables)
        $associationSort.dropFirst().sink { [weak self] value in
            self?.userDefaults?.set(value.column.rawValue, forKey: PreferenceKey.associationSortColumn)
            self?.userDefaults?.set(value.ascending, forKey: PreferenceKey.associationSortAscending)
        }
            .store(in: &preferenceCancellables)
        $applicationFilters.dropFirst().sink { [weak self] value in
            self?.userDefaults?.set(value.hideAuxiliary, forKey: PreferenceKey.hideAuxiliaryApplications)
            self?.userDefaults?.set(value.hideDevelopment, forKey: PreferenceKey.hideDevelopmentApplications)
            self?.userDefaults?.set(value.hideWithoutAssociations,
                                    forKey: PreferenceKey.hideApplicationsWithoutAssociations)
        }
            .store(in: &preferenceCancellables)
    }

    func navigate(to association: Association) {
        guard pendingMutation == nil, !isCreatingAssociation else { return }
        navigateToAssociation(association)
    }

    private func navigateToAssociation(_ association: Association) {
        invalidatePendingRowSelection()
        invalidatePendingTabSelection()
        applyTabSelection(association.kind == .urlScheme ? .urlSchemes : .contentTypes, duringCreation: true)
        if association.kind == .contentType, contentTypesByID[association.identifier]?.isFileType == false {
            showAllContentTypes = true
        }
        searchText = ""
        selectedAssociationID = association.identifier
    }

    func refresh() async {
        guard pendingMutation == nil, !isCreatingAssociation else { return }
        guard await load(forceRefresh: true) else { return }
        await loadHandlers()
    }

    func loadGeneralDefaults() async {
        generalDefaultsRequestGeneration &+= 1
        let generation = generalDefaultsRequestGeneration
        browserDefaultState = .loading
        emailDefaultState = .loading

        do {
            let http = try Association.urlScheme("http")
            let https = try Association.urlScheme("https")
            let mailto = try Association.urlScheme("mailto")
            let service = service
            async let httpApplications = service.applications(capableOf: http, backend: .modern, role: .all)
            async let httpsApplications = service.applications(capableOf: https, backend: .modern, role: .all)
            async let httpDefault = service.defaultApplication(for: http, backend: .modern, role: .all)
            async let httpsDefault = service.defaultApplication(for: https, backend: .modern, role: .all)
            async let emailApplications = service.applications(capableOf: mailto, backend: .modern, role: .all)
            async let emailDefault = service.defaultApplication(for: mailto, backend: .modern, role: .all)
            let values = try await (
                httpApplications, httpsApplications, httpDefault,
                httpsDefault, emailApplications, emailDefault
            )
            guard !Task.isCancelled, generalDefaultsRequestGeneration == generation else { return }

            let httpsIDs = Set(values.1.map(\.id))
            let browserApplications = sortedUniqueApplications(
                values.0.filter { httpsIDs.contains($0.id) } + [values.2, values.3].compactMap { $0 }
            )
            let browserSelection = values.2?.id == values.3?.id ? values.2 ?? values.3 : nil
            browserDefaultState = .loaded(
                applications: browserApplications,
                selectedApplication: browserSelection,
                hasMixedSelection: values.2?.id != values.3?.id
            )
            emailDefaultState = .loaded(
                applications: sortedUniqueApplications(values.4 + [values.5].compactMap { $0 }),
                selectedApplication: values.5,
                hasMixedSelection: false
            )
        } catch is CancellationError {
            return
        } catch {
            guard generalDefaultsRequestGeneration == generation else { return }
            let message = error.localizedDescription
            browserDefaultState = .failed(message)
            emailDefaultState = .failed(message)
        }
    }

    func selectDefaultBrowser(_ application: ApplicationRecord) async {
        do {
            try await changeGeneralDefault(
                to: application,
                associations: [Association.urlScheme("http"), Association.urlScheme("https")]
            )
        } catch is CancellationError {
            return
        } catch {
            presentedError = PresentedError(error)
        }
        await loadGeneralDefaults()
    }

    func selectDefaultEmail(_ application: ApplicationRecord) async {
        do {
            try await changeGeneralDefault(
                to: application,
                associations: [Association.urlScheme("mailto")]
            )
        } catch is CancellationError {
            return
        } catch {
            presentedError = PresentedError(error)
        }
        await loadGeneralDefaults()
    }

    private func changeGeneralDefault(
        to application: ApplicationRecord,
        associations: [Association]
    ) async throws {
        guard pendingMutation == nil, !isCreatingAssociation else { return }
        generalDefaultsRequestGeneration &+= 1
        pendingMutation = application.id
        presentedError = nil
        defer { pendingMutation = nil }
        for association in associations {
            try await service.setDefaultApplication(
                application.reference,
                for: association,
                backend: .modern,
                role: .all
            )
            invalidateAssociation(association)
        }
    }

    private func sortedUniqueApplications(_ applications: [ApplicationRecord]) -> [ApplicationRecord] {
        Dictionary(applications.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            .values
            .sorted {
                let comparison = $0.displayName.localizedStandardCompare($1.displayName)
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            }
    }

    /// Four outstanding reads keep the main actor responsive without flooding LaunchServices.
    /// Results stay in the cache until the complete preload can update the table once.
    /// Each result has a key version so a late list lookup cannot undo a detail refresh or mutation.
    func loadAssociationDefaults() async {
        defaultsRequestGeneration &+= 1
        let generation = defaultsRequestGeneration
        let query = listQuery
        restoreCachedDefaults()
        let associations = selectedTab == .applications
            ? selectedApplicationAssociations : associationsWithoutSearch
        let requests = associations.compactMap { association -> (LookupKey, UInt)? in
            let key = LookupKey(association: association, backend: query.backend, role: query.role)
            if selectedTab != .applications, let cached = defaultCache[key], Date().timeIntervalSince(cached.checkedAt) < 60 { return nil }
            if lookupVersions[key] == nil { lookupVersions[key] = 0 }
            return (key, lookupVersions[key, default: 0])
        }
        guard !requests.isEmpty else { isResolvingDefaults = false; return }
        isResolvingDefaults = true
        defer { if defaultsRequestGeneration == generation { isResolvingDefaults = false } }
        let service = service
        await withTaskGroup(of: (LookupKey, UInt, DefaultHandlerState?).self) { group in
            var next = 0
            func enqueue() {
                let (key, version) = requests[next]
                next += 1
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let application = try await service.defaultApplication(for: key.association, backend: key.backend, role: key.role)
                        return (key, version, application.map(DefaultHandlerState.application) ?? DefaultHandlerState.none)
                    } catch is CancellationError { return (key, version, nil) }
                    catch { return (key, version, .failed(error.localizedDescription)) }
                }
            }
            for _ in 0..<min(4, requests.count) { enqueue() }
            var staged: [LookupKey: (version: UInt, state: DefaultHandlerState)] = [:]
            for await (key, version, state) in group {
                guard !Task.isCancelled, defaultsRequestGeneration == generation, listQuery == query else {
                    group.cancelAll()
                    return
                }
                if let state { staged[key] = (version, state) }
                if next < requests.count { enqueue() }
            }
            guard !Task.isCancelled, defaultsRequestGeneration == generation, listQuery == query else { return }
            var completed: [LookupKey: UInt] = [:]
            for (key, result) in staged where lookupVersions[key, default: 0] == result.version {
                cacheDefault(result.state, for: key)
                completed[key] = result.version
            }
            publishDefaultBatch(completed)
        }
    }

    /// Reverse lookup of already resolved defaults; never asks LaunchServices.
    func additionalDefaultAssociations(for application: ApplicationRecord) -> [Association] {
        let declared = Set(declaredAssociations(for: application))
        return defaultHandlers.compactMap { association, state in
            state.application?.id == application.id && !declared.contains(association) ? association : nil
        }.sorted {
            $0.kind == $1.kind ? $0.identifier < $1.identifier : $0.kind.rawValue < $1.kind.rawValue
        }
    }

    func additionalDefaultAssociations(
        for application: ApplicationRecord,
        kind: Association.Kind
    ) -> [Association] {
        additionalDefaultAssociations(for: application).filter { $0.kind == kind }
    }

    var selectedApplicationAssociations: [Association] {
        guard let application = selectedApplication else { return [] }
        return Array(Set(declaredAssociations(for: application) + additionalDefaultAssociations(for: application)))
            .sorted { $0.kind == $1.kind ? $0.identifier < $1.identifier : $0.kind.rawValue < $1.kind.rawValue }
    }

    private func declaredAssociations(for application: ApplicationRecord) -> [Association] {
        let schemes = application.urlSchemes.compactMap { try? Association.urlScheme($0.scheme) }
        let types = (ApplicationProjection(record: application).handledTypes.map(\.identifier)
            + application.exportedTypeDeclarations.map(\.identifier)
            + application.importedTypeDeclarations.map(\.identifier))
            .compactMap { try? Association.contentType($0) }
        return Array(Set(schemes + types)).sorted { $0.identifier < $1.identifier }
    }

    private var associationsWithoutSearch: [Association] {
        guard let snapshot else { return [] }
        switch selectedTab {
        case .urlSchemes: return snapshot.urlSchemes.compactMap { try? .urlScheme($0.identifier) }
        case .contentTypes: return snapshot.contentTypes.filter { showAllContentTypes || $0.isFileType != false }.compactMap { try? .contentType($0.identifier) }
        case .general, .applications, .diagnostics: return []
        }
    }

    private func invalidateDefaults() {
        defaultsRequestGeneration &+= 1
        isResolvingDefaults = false
        restoreCachedDefaults()
    }

    private func restoreCachedDefaults() {
        let values = Dictionary(uniqueKeysWithValues: defaultCache.compactMap { key, value in
            key.backend == backend && key.role == effectiveRole ? (key.association, value.state) : nil
        })
        if defaultHandlers != values { defaultHandlers = values }
    }

    private func cacheDefault(_ state: DefaultHandlerState, for key: LookupKey) {
        // Failed queries remain visible but are retried on the next visit.
        let checkedAt: Date
        if case .failed = state { checkedAt = .distantPast } else { checkedAt = Date() }
        defaultCache[key] = CachedDefault(state: state, checkedAt: checkedAt)
    }

    private func publishDefaults(_ values: [Association: DefaultHandlerState]) {
        let changed = values.filter { defaultHandlers[$0.key] != $0.value }
        if !changed.isEmpty { defaultHandlers.merge(changed) { _, new in new } }
    }

    private func publishDefaultBatch(_ versions: [LookupKey: UInt]) {
        var values: [Association: DefaultHandlerState] = [:]
        for (key, version) in versions where lookupVersions[key, default: 0] == version {
            values[key.association] = defaultCache[key]?.state
        }
        publishDefaults(values)
    }

    private func showCachedHandlers() {
        handlerRequestGeneration &+= 1
        let state = selectedAssociation.flatMap { handlerCache[LookupKey(association: $0, backend: backend, role: effectiveRole)] } ?? .unresolved
        if handlerLookupState != state { handlerLookupState = state }
    }

    private func publishSnapshot(_ value: CatalogSnapshot) {
        systemSnapshot = value
        let value = mergingCustomAssociations(into: value)
        guard snapshot != value else { return }
        associationRowsCache = nil
        associationIndexes.removeAll()
        applicationRowsCache = nil
        applicationsByID = Dictionary(uniqueKeysWithValues: value.applications.map { ($0.id, $0) })
        contentTypesByID = Dictionary(uniqueKeysWithValues: value.contentTypes.map { ($0.id, $0) })
        snapshot = value
        refreshCachedApplicationMetadata()
        catalogRevision &+= 1
    }

    private func refreshCachedApplicationMetadata() {
        func refreshed(_ state: HandlerLookupState) -> HandlerLookupState {
            guard case .loaded(let applications, let defaultApplication) = state else { return state }
            return .loaded(applications: applications.map { applicationsByID[$0.id] ?? $0 },
                           defaultApplication: defaultApplication.map { applicationsByID[$0.id] ?? $0 })
        }
        for (key, cached) in defaultCache {
            guard let old = cached.state.application, let updated = applicationsByID[old.id], old != updated else { continue }
            defaultCache[key] = CachedDefault(state: .application(updated), checkedAt: cached.checkedAt)
        }
        for (key, state) in handlerCache {
            let updated = refreshed(state)
            if updated != state { handlerCache[key] = updated }
        }
        let state = refreshed(handlerLookupState)
        if state != handlerLookupState { handlerLookupState = state }
        restoreCachedDefaults()
    }

    var applicationDetailID: String? { selectedTab == .applications ? selectedApplicationID : nil }

    func refreshSelectedApplication() async {
        applicationRequestGeneration &+= 1
        let generation = applicationRequestGeneration
        let catalogGeneration = catalogRequestGeneration
        guard let application = selectedApplication, selectedTab == .applications else { return }
        do {
            let updated = try await service.refreshedApplicationCatalog(at: application.url)
            guard !Task.isCancelled, generation == applicationRequestGeneration,
                  catalogGeneration == catalogRequestGeneration,
                  applicationDetailID == application.id else { return }
            if let updated { publishSnapshot(updated) }
        } catch is CancellationError { return }
        catch {
            guard !Task.isCancelled, generation == applicationRequestGeneration,
                  catalogGeneration == catalogRequestGeneration, applicationDetailID == application.id else { return }
            presentedError = PresentedError(error)
        }
    }

    var contentTypeDetailID: String? { selectedTab == .contentTypes ? selectedAssociationID : nil }

    /// Declaration metadata can be available even when the selected backend cannot resolve handlers.
    func refreshSelectedContentType() async {
        contentTypeRequestGeneration &+= 1
        let generation = contentTypeRequestGeneration
        let catalogGeneration = catalogRequestGeneration
        guard let identifier = contentTypeDetailID else { return }
        do {
            let updated = try await service.refreshedContentTypeCatalog(identifier)
            guard !Task.isCancelled, generation == contentTypeRequestGeneration,
                  catalogGeneration == catalogRequestGeneration, contentTypeDetailID == identifier else { return }
            if let updated { publishSnapshot(updated) }
        } catch is CancellationError { return }
        catch {
            guard !Task.isCancelled, generation == contentTypeRequestGeneration,
                  catalogGeneration == catalogRequestGeneration, contentTypeDetailID == identifier else { return }
            presentedError = PresentedError(error)
        }
    }

    func loadHandlers() async {
        handlerRequestGeneration &+= 1
        let requestGeneration = handlerRequestGeneration

        presentedError = nil
        guard let association = selectedAssociation else {
            if handlerLookupState != .unresolved { handlerLookupState = .unresolved }
            return
        }
        let key = LookupKey(association: association, backend: backend, role: effectiveRole)
        let cachedState = handlerCache[key]
        let initialState = cachedState ?? .loading
        if handlerLookupState != initialState { handlerLookupState = initialState }
        lookupVersions[key, default: 0] &+= 1
        let version = lookupVersions[key, default: 0]

        let requestedBackend = backend
        let requestedRole = effectiveRole
        let requestedAssociationID = selectedAssociationID
        let requestedTab = selectedTab
        beginLoading()
        defer { endLoading() }

        do {
            let applications = try await service.applications(
                capableOf: association,
                backend: requestedBackend,
                role: requestedRole
            )
            let defaultApplication = try await service.defaultApplication(
                for: association,
                backend: requestedBackend,
                role: requestedRole
            )
            guard ownsHandlerRequest(
                requestGeneration,
                backend: requestedBackend,
                role: requestedRole,
                associationID: requestedAssociationID,
                tab: requestedTab
            ) else {
                return
            }
            guard lookupVersions[key] == version else { return }
            lookupVersions[key, default: 0] &+= 1
            let state = HandlerLookupState.loaded(applications: applications, defaultApplication: defaultApplication)
            handlerCache[key] = state
            if handlerLookupState != state { handlerLookupState = state }
            let defaultState = defaultApplication.map(DefaultHandlerState.application) ?? DefaultHandlerState.none
            cacheDefault(defaultState, for: key)
            publishDefaults([association: defaultState])
        } catch is CancellationError {
            return
        } catch {
            guard ownsHandlerRequest(
                requestGeneration,
                backend: requestedBackend,
                role: requestedRole,
                associationID: requestedAssociationID,
                tab: requestedTab
            ) else {
                return
            }

            if handlerCache[key] == nil { handlerLookupState = .failed(error.localizedDescription) }
            presentedError = PresentedError(error)
        }
    }

    func setDefaultApplication(at url: URL) async {
        let reference = applicationReferenceResolver.reference(forApplicationAt: url)
        await setDefault(reference)
    }

    func setDefault(_ application: ApplicationReference) async {
        guard let association = selectedAssociation else { return }
        await setDefault(application, for: association)
    }

    func setDefault(_ application: ApplicationReference, for association: Association) async {
        guard !isCreatingAssociation else { return }
        _ = await assignDefault(application, for: association)
    }

    private func assignDefault(_ application: ApplicationReference, for association: Association,
                               using overrideBackend: Backend? = nil) async -> Bool {
        guard pendingMutation == nil else { return false }
        let requestedBackend = overrideBackend ?? backend
        let requestedRole: HandlerRole = overrideBackend == nil && selectedTab != .applications ? effectiveRole : .all
        pendingMutation = application.id
        // Supersede reads already in flight for this association in every backend/role.
        invalidateAssociation(association)
        presentedError = nil
        defer { pendingMutation = nil }

        do {
            try await service.setDefaultApplication(
                application,
                for: association,
                backend: requestedBackend,
                role: requestedRole
            )
            if selectedAssociation == association {
                await loadHandlers()
            } else {
                let observed = try await service.defaultApplication(for: association, backend: requestedBackend, role: requestedRole)
                let key = LookupKey(association: association, backend: requestedBackend, role: requestedRole)
                let state = observed.map(DefaultHandlerState.application) ?? DefaultHandlerState.none
                cacheDefault(state, for: key)
                if backend == requestedBackend && effectiveRole == requestedRole { publishDefaults([association: state]) }
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            presentedError = PresentedError(error)
            return false
        }
    }

    private func invalidateAssociation(_ association: Association) {
        for key in Set(lookupVersions.keys).union(defaultCache.keys).union(handlerCache.keys) where key.association == association {
            lookupVersions[key, default: 0] &+= 1
            // Keep stale values for presentation, but force all affected contexts to revalidate.
            if let cached = defaultCache[key] { defaultCache[key] = CachedDefault(state: cached.state, checkedAt: .distantPast) }
        }
        handlerRequestGeneration &+= 1
    }

    var selectedAssociation: Association? {
        guard let selectedAssociationID else { return nil }
        switch selectedTab {
        case .urlSchemes:
            return try? Association.urlScheme(selectedAssociationID)
        case .contentTypes:
            return try? Association.contentType(selectedAssociationID)
        case .general, .applications, .diagnostics:
            return nil
        }
    }

    private func beginLoading() {
        activeLoadCount += 1
        if !isLoading { isLoading = true }
    }

    private func endLoading() {
        activeLoadCount -= 1
        let loading = activeLoadCount > 0
        if isLoading != loading { isLoading = loading }
    }

    private func ownsHandlerRequest(
        _ requestGeneration: UInt,
        backend: Backend,
        role: HandlerRole,
        associationID: String?,
        tab: Tab
    ) -> Bool {
        !Task.isCancelled && handlerRequestGeneration == requestGeneration
            && self.backend == backend
            && effectiveRole == role
            && selectedAssociationID == associationID
            && selectedTab == tab
    }

    private func reconcileSelections(with snapshot: CatalogSnapshot) {
        let validAssociationIDs: Set<String>
        switch selectedTab {
        case .urlSchemes:
            validAssociationIDs = Set(snapshot.urlSchemes.map(\.id))
        case .contentTypes:
            validAssociationIDs = Set(snapshot.contentTypes.map(\.id))
        case .general, .applications, .diagnostics:
            validAssociationIDs = []
        }

        if let selectedAssociationID, !validAssociationIDs.contains(selectedAssociationID) {
            self.selectedAssociationID = nil
            handlerLookupState = .unresolved
        }

        if let selectedApplicationID,
           !snapshot.applications.contains(where: { $0.id == selectedApplicationID }) {
            self.selectedApplicationID = nil
        }
    }
}

extension AppStore {
    var canCreateAssociation: Bool {
        snapshot != nil && customAssociationsLoaded && !isLoading && !isCreatingAssociation && pendingMutation == nil
    }

    var customAssociationIDs: Set<Association> { Set(customAssociations.map(\.association)) }

    var selectedCustomAssociation: CustomAssociation? {
        customAssociations.first { $0.association == selectedAssociation }
    }

    func existingAssociation(for draft: NewAssociationDraft) -> Association? {
        guard let association = draft.parsedAssociation else { return nil }
        switch association.kind {
        case .urlScheme:
            return snapshot?.urlSchemes.contains { $0.identifier == association.identifier } == true ? association : nil
        case .contentType:
            return snapshot?.contentTypes.contains { $0.identifier == association.identifier } == true ? association : nil
        }
    }

    func createAssociation(_ draft: NewAssociationDraft, application: ApplicationReference?) async -> CreationResult {
        guard canCreateAssociation else { return .failed("Wait for the catalog or the current operation to finish, then try again.") }
        if let existing = existingAssociation(for: draft) { return .duplicate(existing) }
        let record: CustomAssociation
        do { record = try draft.validatedRecord() }
        catch { return .failed(error.localizedDescription) }
        if record.creation == .dynamic && application == nil {
            return .failed("Choose an application to create a handler preference for this dynamic type.")
        }

        isCreatingAssociation = true
        defer { isCreatingAssociation = false }
        do {
            // Persist before publishing or changing LaunchServices. A failed write has no system side effects.
            let records = (customAssociations + [record]).sorted { $0.association.identifier < $1.association.identifier }
            try await customAssociationStore.save(records)
            customAssociations = records
            customRegistrationStates[record.association] = .saved
            publishSnapshot(systemSnapshot ?? CatalogSnapshot())
            navigateToAssociation(record.association)
            role = .all
            return await finishCreating(record, application: application)
        } catch {
            return .failed("Could not save the association: \(error.localizedDescription)")
        }
    }

    func retryCustomAssociation(_ association: Association, application: ApplicationReference?) async -> CreationResult {
        guard !isCreatingAssociation, pendingMutation == nil,
              let record = customAssociations.first(where: { $0.association == association }) else {
            return .failed("This association is unavailable or another change is in progress.")
        }
        isCreatingAssociation = true
        defer { isCreatingAssociation = false }
        navigateToAssociation(association)
        role = .all
        return await finishCreating(record, application: application)
    }

    private func finishCreating(_ record: CustomAssociation, application: ApplicationReference?) async -> CreationResult {
        let association = record.association
        if association.kind == .contentType, record.creation == .declared,
           customRegistrationStates[association] != .registered {
            customRegistrationStates[association] = .registering
            do {
                try await customTypeRegistrar.register(record)
                customRegistrationStates[association] = .registered
                invalidateAssociation(association)
                // A negative pre-registration lookup must not remain fresh for another minute.
                await loadHandlers()
            } catch {
                customRegistrationStates[association] = .failed(error.localizedDescription)
                return .savedWithIssue(association, "Saved in DefaultApp, but macOS registration was not confirmed. \(error.localizedDescription)")
            }
        }
        if let application {
            guard await assignDefault(application, for: association,
                                      using: record.creation == .dynamic ? .legacy : nil) else {
                return .savedWithIssue(association, "Saved, but the default application was not confirmed. \(presentedError?.message ?? "Try again or choose another application.")")
            }
        }
        return .created(association)
    }

    private func loadCustomAssociations() async -> (any Error)? {
        guard !customAssociationsLoaded else { return nil }
        if customLoadTask == nil {
            let persistence = customAssociationStore
            customLoadTask = Task { try await persistence.load() }
        }
        guard let task = customLoadTask else { return nil }
        do {
            let records = try await task.value
            guard !customAssociationsLoaded else { return nil }
            customAssociations = records
            customAssociationsLoaded = true
            customLoadTask = nil
            await refreshCustomRegistrationStates()
            return nil
        } catch {
            customLoadTask = nil
            return error
        }
    }

    private func refreshCustomRegistrationStates() async {
        for record in customAssociations where record.creation == .declared {
            let registered = await customTypeRegistrar.isRegistered(record)
            if registered { customRegistrationStates[record.association] = .registered }
            else if case .failed = customRegistrationStates[record.association] { continue }
            else { customRegistrationStates[record.association] = .saved }
        }
    }

    private func mergingCustomAssociations(into snapshot: CatalogSnapshot) -> CatalogSnapshot {
        guard !customAssociations.isEmpty else { return snapshot }
        var schemes = Dictionary(uniqueKeysWithValues: snapshot.urlSchemes.map { ($0.identifier, $0) })
        var types = Dictionary(uniqueKeysWithValues: snapshot.contentTypes.map { ($0.identifier, $0) })
        for record in customAssociations {
            let identifier = record.association.identifier
            switch record.association.kind {
            case .urlScheme:
                if schemes[identifier] == nil { schemes[identifier] = URLSchemeRecord(identifier: identifier) }
            case .contentType:
                if let metadata = record.contentTypeRecord {
                    types[identifier] = ContentTypeRecord(identifier: identifier,
                        localizedDescription: metadata.localizedDescription, tags: metadata.tags,
                        supertypes: metadata.supertypes, declaringApplication: types[identifier]?.declaringApplication,
                        isFileType: true, isDynamic: record.creation == .dynamic)
                }
            }
        }
        return CatalogSnapshot(applications: snapshot.applications,
                               urlSchemes: schemes.values.sorted { $0.identifier.localizedStandardCompare($1.identifier) == .orderedAscending },
                               contentTypes: types.values.sorted { $0.identifier.localizedStandardCompare($1.identifier) == .orderedAscending },
                               diagnostics: snapshot.diagnostics)
    }
}
