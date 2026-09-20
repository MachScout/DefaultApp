import Combine
import Foundation
import SwiftUI
import XCTest
@testable import DefaultApp
import DefaultAppCore

final class AppStoreTests: XCTestCase, @unchecked Sendable {
    private let safari = ApplicationRecord(
        url: URL(fileURLWithPath: "/Applications/Safari.app"),
        bundleIdentifier: "com.apple.Safari",
        displayName: "Safari"
    )
    private let firefox = ApplicationRecord(
        url: URL(fileURLWithPath: "/Applications/Firefox.app"),
        bundleIdentifier: "org.mozilla.firefox",
        displayName: "Firefox"
    )

    @MainActor
    func testGeneralTabIsSelectedBeforeCatalogLoads() {
        let store = AppStore(
            service: FakeService(snapshot: sampleSnapshot),
            customAssociationStore: MemoryCustomAssociations(),
            customTypeRegistrar: TestTypeRegistrar()
        )

        XCTAssertEqual(store.selectedTab.rawValue, "general")
    }

    @MainActor
    func testDisplayPreferencesPersistAcrossStoreInstances() {
        let suiteName = "AppStoreTests.preferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = FakeService(snapshot: sampleSnapshot)
        let first = AppStore(
            service: service,
            customAssociationStore: MemoryCustomAssociations(),
            customTypeRegistrar: TestTypeRegistrar(),
            userDefaults: defaults
        )

        first.backend = .legacy
        first.showsDiagnostics = false
        first.showAllContentTypes = true
        first.contentTypeFilters.hideWithoutExtensions = true
        first.contentTypeFilters.hideWithoutDefaultApplication = true
        first.applicationFilters.hideAuxiliary = true
        first.applicationFilters.hideDevelopment = true
        first.applicationFilters.hideWithoutAssociations = true
        first.associationSort = .init(column: .defaultApplication, ascending: false)
        XCTAssertTrue(first.closesIncomingWindowAfterHandling)
        first.closesIncomingWindowAfterHandling = false

        let restored = AppStore(
            service: service,
            customAssociationStore: MemoryCustomAssociations(),
            customTypeRegistrar: TestTypeRegistrar(),
            userDefaults: defaults
        )

        XCTAssertEqual(restored.backend, .legacy)
        XCTAssertFalse(restored.showsDiagnostics)
        XCTAssertTrue(restored.showAllContentTypes)
        XCTAssertEqual(restored.contentTypeFilters,
                       .init(hideWithoutExtensions: true,
                             hideWithoutDefaultApplication: true))
        XCTAssertEqual(restored.applicationFilters,
                       .init(hideAuxiliary: true,
                             hideDevelopment: true,
                             hideWithoutAssociations: true))
        XCTAssertEqual(restored.associationSort,
                       .init(column: .defaultApplication, ascending: false))
        XCTAssertFalse(restored.closesIncomingWindowAfterHandling)
    }

    @MainActor
    func testHidingDiagnosticsRemovesItFromNavigationAndLeavesHiddenTab() {
        let suiteName = "AppStoreTests.diagnostics.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppStore(
            service: FakeService(snapshot: sampleSnapshot),
            customAssociationStore: MemoryCustomAssociations(),
            customTypeRegistrar: TestTypeRegistrar(),
            userDefaults: defaults
        )
        store.selectTab(.diagnostics)
        XCTAssertEqual(store.selectedTab, .diagnostics)

        store.showsDiagnostics = false

        XCTAssertEqual(store.selectedTab, .general)
        XCTAssertFalse(store.visibleTabs.contains(.diagnostics))
        store.selectTab(.diagnostics)
        XCTAssertEqual(store.selectedTab, .general)
    }

    @MainActor
    func testLaunchDisablesAutomaticWindowTabbing() {
        let previousValue = NSWindow.allowsAutomaticWindowTabbing
        defer { NSWindow.allowsAutomaticWindowTabbing = previousValue }
        NSWindow.allowsAutomaticWindowTabbing = true

        ApplicationLifecycleCoordinator().applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification)
        )

        XCTAssertFalse(NSWindow.allowsAutomaticWindowTabbing)
    }

    func testAppBundleStartsAsUIElement() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoURL = repositoryRoot.appendingPathComponent("DefaultApp/Info.plist")
        let data = try Data(contentsOf: infoURL)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["LSUIElement"] as? Bool, true)
    }

    @MainActor
    func testLifecycleCoordinatorOwnsSharedStores() {
        let suiteName = "LifecycleCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = ApplicationLifecycleCoordinator(userDefaults: defaults)
        XCTAssertTrue(coordinator.appStore.closesIncomingWindowAfterHandling)
        XCTAssertTrue(coordinator.incomingStore.requests.isEmpty)
    }

    @MainActor
    func testTerminationUsesPublishedEmptyQueueBeforeBackingPropertyUpdates() {
        let suiteName = "LifecycleCoordinatorTests.publishedQueue.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let originalWindows = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        defer {
            for window in NSApplication.shared.windows
                where !originalWindows.contains(ObjectIdentifier(window)) {
                if let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
                }
                window.delegate = nil
                window.close()
            }
        }
        let incomingStore = IncomingOpenStore(workspace: FakeOpeningWorkspace())
        let coordinator = ApplicationLifecycleCoordinator(userDefaults: defaults,
                                                          incomingStore: incomingStore)
        incomingStore.enqueue([URL(string: "https://example.com/final")!])
        var terminationReply: NSApplication.TerminateReply?
        let observation = incomingStore.$requests.dropFirst().sink { requests in
            guard requests.isEmpty else { return }
            // @Published delivers from willSet: termination must use the emitted
            // queue, even while a synchronous callback can still read the old item.
            XCTAssertEqual(incomingStore.requests.count, 1)
            terminationReply = coordinator.applicationShouldTerminate(.shared)
        }

        withExtendedLifetime(observation) { incomingStore.skip() }

        XCTAssertEqual(terminationReply, .terminateNow)
        XCTAssertTrue(incomingStore.requests.isEmpty)
    }

    @MainActor
    func testMenuPruningRemovesFileAndAutomaticWindowTabsOnly() {
        let mainMenu = NSMenu()
        mainMenu.addItem(withTitle: "DefaultApp", action: nil, keyEquivalent: "")
        mainMenu.addItem(withTitle: "File", action: nil, keyEquivalent: "")
        let viewItem = mainMenu.addItem(withTitle: "View", action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: "View")
        let tabBar = viewMenu.addItem(withTitle: "Show Tab Bar",
                                      action: NSSelectorFromString("toggleTabBar:"), keyEquivalent: "")
        let overview = viewMenu.addItem(withTitle: "Show All Tabs",
                                        action: NSSelectorFromString("toggleTabOverview:"), keyEquivalent: "")
        viewMenu.addItem(withTitle: "General", action: NSSelectorFromString("menuAction:"), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Enter Full Screen",
                         action: NSSelectorFromString("toggleFullScreen:"), keyEquivalent: "")
        viewItem.submenu = viewMenu

        ApplicationLifecycleCoordinator.pruneMainMenu(mainMenu)

        XCTAssertFalse(mainMenu.items.contains { $0.title == "File" })
        XCTAssertFalse(viewMenu.items.contains(tabBar))
        XCTAssertFalse(viewMenu.items.contains(overview))
        XCTAssertEqual(viewMenu.items.map(\.title), ["General", "Enter Full Screen"])
    }

    @MainActor
    func testGeneralDefaultsLoadEligibleApplicationsAndCurrentSelections() async throws {
        let mail = ApplicationRecord(
            url: URL(fileURLWithPath: "/Applications/Mail.app"),
            bundleIdentifier: "com.apple.mail",
            displayName: "Mail"
        )
        let http = try Association.urlScheme("http")
        let https = try Association.urlScheme("https")
        let mailto = try Association.urlScheme("mailto")
        let service = FakeService(
            snapshot: sampleSnapshot,
            handlerApplicationsByAssociation: [
                http: [safari, firefox],
                https: [firefox, safari],
                mailto: [mail],
            ],
            defaultApplicationsByAssociation: [
                http: firefox,
                https: firefox,
                mailto: mail,
            ]
        )
        let store = makeStore(service: service)

        await store.loadGeneralDefaults()

        XCTAssertEqual(
            store.browserDefaultState,
            .loaded(applications: [firefox, safari], selectedApplication: firefox, hasMixedSelection: false)
        )
        XCTAssertEqual(
            store.emailDefaultState,
            .loaded(applications: [mail], selectedApplication: mail, hasMixedSelection: false)
        )
    }

    @MainActor
    func testSelectingDefaultBrowserUpdatesHTTPAndHTTPS() async throws {
        let http = try Association.urlScheme("http")
        let https = try Association.urlScheme("https")
        let mailto = try Association.urlScheme("mailto")
        let service = FakeService(
            snapshot: sampleSnapshot,
            handlerApplicationsByAssociation: [http: [safari, firefox], https: [safari, firefox]],
            defaultApplicationsByAssociation: [http: firefox, https: firefox, mailto: safari]
        )
        let store = makeStore(service: service)
        await store.loadGeneralDefaults()

        await store.selectDefaultBrowser(safari)

        let recordedHTTP = await service.recordedDefault(for: http)
        let recordedHTTPS = await service.recordedDefault(for: https)
        let recordedMailto = await service.recordedDefault(for: mailto)
        XCTAssertEqual(recordedHTTP, safari)
        XCTAssertEqual(recordedHTTPS, safari)
        XCTAssertEqual(recordedMailto, safari)
        guard case .loaded(_, let selected, let isMixed) = store.browserDefaultState else {
            return XCTFail("Expected a loaded browser setting")
        }
        XCTAssertEqual(selected, safari)
        XCTAssertFalse(isMixed)
    }

    @MainActor
    func testSelectingDefaultEmailUpdatesOnlyMailto() async throws {
        let mail = ApplicationRecord(
            url: URL(fileURLWithPath: "/Applications/Mail.app"),
            bundleIdentifier: "com.apple.mail",
            displayName: "Mail"
        )
        let http = try Association.urlScheme("http")
        let https = try Association.urlScheme("https")
        let mailto = try Association.urlScheme("mailto")
        let service = FakeService(
            snapshot: sampleSnapshot,
            handlerApplicationsByAssociation: [mailto: [mail, safari]],
            defaultApplicationsByAssociation: [http: firefox, https: firefox, mailto: safari]
        )
        let store = makeStore(service: service)
        await store.loadGeneralDefaults()

        await store.selectDefaultEmail(mail)

        let recordedHTTP = await service.recordedDefault(for: http)
        let recordedHTTPS = await service.recordedDefault(for: https)
        let recordedMailto = await service.recordedDefault(for: mailto)
        XCTAssertEqual(recordedHTTP, firefox)
        XCTAssertEqual(recordedHTTPS, firefox)
        XCTAssertEqual(recordedMailto, mail)
        guard case .loaded(_, let selected, _) = store.emailDefaultState else {
            return XCTFail("Expected a loaded email setting")
        }
        XCTAssertEqual(selected, mail)
    }

    @MainActor
    func testCatalogWindowSizeDoesNotDependOnTabOrSelectedContent() async throws {
        let longIdentifier = "com.example." + String(repeating: "long-content-type-", count: 8) + "document"
        let application = ApplicationRecord(
            url: URL(fileURLWithPath: "/Applications/Example.app"),
            bundleIdentifier: "com.example.application", displayName: "Example",
            urlSchemes: [.init(scheme: "example")],
            documentTypeClaims: [.init(contentTypeIdentifiers: [longIdentifier], role: .viewer)])
        let snapshot = CatalogSnapshot(applications: [application],
            urlSchemes: [.init(identifier: "example")],
            contentTypes: [.init(identifier: longIdentifier)])
        let service = FakeService(snapshot: snapshot, handlerApplications: [application], defaultApplication: application)
        let store = makeStore(service: service)
        await store.load()
        let hosting = NSHostingController(rootView: RootView(store: store))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask.insert(.resizable)
        window.setContentSize(CGSize(width: 1180, height: 720))
        defer { window.close() }

        func settleLayout() async {
            for _ in 0..<5 {
                hosting.view.layoutSubtreeIfNeeded()
                window.layoutIfNeeded()
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        await settleLayout()
        let initialIntrinsicSize = hosting.view.intrinsicContentSize
        for size in [CGSize(width: 1180, height: 720), CGSize(width: 1000, height: 600)] {
            window.setContentSize(size)
            await settleLayout()
            for tab in AppStore.Tab.allCases + [.urlSchemes, .applications] {
                store.selectTab(tab)
                await settleLayout()
                XCTAssertEqual(hosting.view.intrinsicContentSize, initialIntrinsicSize, "Intrinsic size for \(tab)")
                XCTAssertEqual(window.contentLayoutRect.width, size.width, accuracy: 1, "\(tab), empty selection")
                XCTAssertEqual(window.contentLayoutRect.height, size.height, accuracy: 1, "\(tab), empty selection")
                switch tab {
                case .general: break
                case .urlSchemes: store.selectedAssociationID = "example"
                case .contentTypes: store.selectedAssociationID = longIdentifier
                case .applications: store.selectedApplicationID = application.id
                case .diagnostics: break
                }
                await store.loadHandlers()
                await settleLayout()
                XCTAssertEqual(hosting.view.intrinsicContentSize, initialIntrinsicSize, "Intrinsic size for \(tab)")
                XCTAssertEqual(window.contentLayoutRect.width, size.width, accuracy: 1, "\(tab), loaded selection")
                XCTAssertEqual(window.contentLayoutRect.height, size.height, accuracy: 1, "\(tab), loaded selection")
            }
        }
    }

    @MainActor
    func testSelectingRowsPreservesSplitPosition() async throws {
        let short = ApplicationRecord(url: safari.url, bundleIdentifier: "test.short", displayName: "Short")
        let long = ApplicationRecord(url: firefox.url, bundleIdentifier: "test.long", displayName: "Long",
            urlSchemes: [.init(scheme: "long-scheme-name")],
            documentTypeClaims: [.init(contentTypeIdentifiers: ["com.example." + String(repeating: "document", count: 12)], role: .viewer)])
        let service = FakeService(snapshot: CatalogSnapshot(applications: [short, long],
            urlSchemes: [.init(identifier: "example")], contentTypes: [.init(identifier: "public.text")]),
            handlerApplications: [long], defaultApplication: long)
        let store = makeStore(service: service)
        await store.load()
        store.selectTab(.applications)
        let hosting = NSHostingController(rootView: RootView(store: store))
        let window = NSWindow(contentViewController: hosting)
        window.isReleasedWhenClosed = false
        window.styleMask.insert(.resizable)
        window.setContentSize(CGSize(width: 1180, height: 720))
        window.orderFront(nil)
        defer { window.close() }

        func settle() async {
            for _ in 0..<5 {
                hosting.view.layoutSubtreeIfNeeded()
                window.layoutIfNeeded()
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        func splitView(in view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView, split.isVertical { return split }
            return view.subviews.lazy.compactMap { splitView(in: $0) }.first
        }
        await settle()
        for tab in [AppStore.Tab.applications, .urlSchemes, .contentTypes, .diagnostics, .applications] {
            store.selectTab(tab)
            await settle()
            let split = try XCTUnwrap(splitView(in: hosting.view))
            if tab == .applications && store.selectedApplicationID == nil {
                split.setPosition(450, ofDividerAt: 0)
                await settle()
            }
            XCTAssertEqual(split.subviews[0].frame.width, 450, accuracy: 1, "Switching to \(tab) moved the divider")
            let initialWidth = try XCTUnwrap(split.subviews.first).frame.width
            if tab == .diagnostics { continue }
            for application in [short, long, short] {
                if tab == .applications { store.selectedApplicationID = application.id }
                else {
                    store.selectedAssociationID = tab == .contentTypes ? "public.text" : "example"
                    await store.loadHandlers()
                }
                await settle()
                let currentSplit = try XCTUnwrap(splitView(in: hosting.view))
                XCTAssertTrue(currentSplit === split, "Selecting a row replaced the split view")
                XCTAssertEqual(currentSplit.subviews[0].frame.width, initialWidth, accuracy: 1,
                               "\(tab): selecting \(application.displayName) moved the divider")
                XCTAssertEqual(window.contentLayoutRect.width, 1180, accuracy: 1)
            }
        }
    }

    @MainActor
    func testTabSelectionBindingDefersStoreMutationUntilAfterSetterReturns() async {
        let service = FakeService(snapshot: sampleSnapshot)
        let store = makeStore(service: service)
        let changed = expectation(description: "Deferred tab selection applied")
        let observation = store.$selectedTab
            .dropFirst()
            .sink { tab in
                if tab == .contentTypes { changed.fulfill() }
            }
        let binding = RootView(store: store).tabSelectionBinding

        binding.wrappedValue = .contentTypes

        XCTAssertEqual(store.selectedTab, .urlSchemes)
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertEqual(store.selectedTab, .contentTypes)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testTabSelectionBindingPublishesOnlyNewestQueuedSelection() async {
        let service = FakeService(snapshot: sampleSnapshot)
        let store = makeStore(service: service)
        let staleSelection = expectation(description: "Older tab selection is discarded")
        staleSelection.isInverted = true
        let newestSelection = expectation(description: "Newest tab selection applied")
        let observation = store.$selectedTab
            .dropFirst()
            .sink { tab in
                if tab == .contentTypes { staleSelection.fulfill() }
                if tab == .applications { newestSelection.fulfill() }
            }
        let binding = RootView(store: store).tabSelectionBinding

        binding.wrappedValue = .contentTypes
        binding.wrappedValue = .applications

        await fulfillment(of: [newestSelection, staleSelection], timeout: 0.2)
        XCTAssertEqual(store.selectedTab, .applications)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testDirectTabSelectionSupersedesQueuedBindingSelection() async {
        let service = FakeService(snapshot: sampleSnapshot)
        let store = makeStore(service: service)
        let staleSelection = expectation(description: "Queued tab selection is discarded")
        staleSelection.isInverted = true
        let directSelection = expectation(description: "Direct tab selection applied")
        let observation = store.$selectedTab
            .dropFirst()
            .sink { tab in
                if tab == .contentTypes { staleSelection.fulfill() }
                if tab == .applications { directSelection.fulfill() }
            }
        let binding = RootView(store: store).tabSelectionBinding

        binding.wrappedValue = .contentTypes
        store.selectTab(.applications)

        await fulfillment(of: [directSelection, staleSelection], timeout: 0.2)
        XCTAssertEqual(store.selectedTab, .applications)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testLoadPublishesSnapshotAndPreservesValidSelections() async {
        let snapshot = sampleSnapshot
        let service = FakeService(snapshot: snapshot)
        let store = makeStore(service: service)
        store.selectedTab = .urlSchemes
        store.selectedAssociationID = "mailto"
        store.selectedApplicationID = safari.id

        await store.load(forceRefresh: true)

        XCTAssertEqual(store.snapshot, snapshot)
        XCTAssertEqual(store.selectedAssociationID, "mailto")
        XCTAssertEqual(store.selectedApplicationID, safari.id)
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.presentedError)
        let calls = await service.recordedCalls()
        XCTAssertEqual(calls, [.catalog(forceRefresh: true)])
    }

    @MainActor
    func testLoadClearsSelectionsMissingFromRefreshedSnapshot() async {
        let service = FakeService(snapshot: sampleSnapshot)
        let store = makeStore(service: service)
        store.selectedTab = .contentTypes
        store.selectedAssociationID = "public.missing"
        store.selectedApplicationID = ApplicationReference(
            url: URL(fileURLWithPath: "/Applications/Missing.app")
        ).id

        await store.load()

        XCTAssertNil(store.selectedAssociationID)
        XCTAssertNil(store.selectedApplicationID)
    }

    @MainActor
    func testLoadModelsInFlightAndFailureStates() async {
        let gate = AsyncGate()
        let service = FakeService(snapshot: sampleSnapshot, catalogGate: gate)
        let store = makeStore(service: service)
        let load = Task { @MainActor in await store.load() }

        await gate.waitUntilEntered()
        XCTAssertTrue(store.isLoading)
        XCTAssertNil(store.snapshot)

        await service.setCatalogError(.catalogUnavailable)
        await gate.release()
        await load.value

        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.snapshot)
        XCTAssertEqual(store.presentedError?.message, "The catalog is unavailable.")
    }

    @MainActor
    func testNewerCatalogLoadSurvivesOlderSuccessfulCompletion() async {
        let staleGate = AsyncGate()
        let newerSnapshot = CatalogSnapshot(applications: [firefox])
        let service = FakeService(
            snapshot: sampleSnapshot,
            catalogPlans: [
                LookupPlan(gate: staleGate, result: .success(sampleSnapshot)),
                LookupPlan(result: .success(newerSnapshot)),
            ]
        )
        let store = makeStore(service: service)
        let staleLoad = Task { @MainActor in await store.load() }
        await staleGate.waitUntilEntered()

        await store.load(forceRefresh: true)
        XCTAssertEqual(store.snapshot, newerSnapshot)

        await staleGate.release()
        await staleLoad.value

        XCTAssertEqual(store.snapshot, newerSnapshot)
        XCTAssertNil(store.presentedError)
    }

    @MainActor
    func testOlderCatalogFailureCannotReplaceNewerSuccess() async {
        let staleGate = AsyncGate()
        let service = FakeService(
            snapshot: sampleSnapshot,
            catalogPlans: [
                LookupPlan(gate: staleGate, result: .failure(.catalogUnavailable)),
                LookupPlan(result: .success(sampleSnapshot)),
            ]
        )
        let store = makeStore(service: service)
        let staleLoad = Task { @MainActor in await store.load() }
        await staleGate.waitUntilEntered()

        await store.load(forceRefresh: true)
        XCTAssertEqual(store.snapshot, sampleSnapshot)
        XCTAssertNil(store.presentedError)

        await staleGate.release()
        await staleLoad.value

        XCTAssertEqual(store.snapshot, sampleSnapshot)
        XCTAssertNil(store.presentedError)
    }

    @MainActor
    func testStaleFailedRefreshDoesNotStartHandlerLookupAfterNewerLoadSucceeds() async {
        let staleGate = AsyncGate()
        let service = FakeService(
            snapshot: sampleSnapshot,
            catalogPlans: [
                LookupPlan(gate: staleGate, result: .failure(.catalogUnavailable)),
                LookupPlan(result: .success(sampleSnapshot)),
            ]
        )
        let store = makeStore(service: service)
        store.selectedTab = .urlSchemes
        store.selectedAssociationID = "mailto"
        let staleRefresh = Task { @MainActor in await store.refresh() }
        await staleGate.waitUntilEntered()

        let newerLoadSucceeded = await store.load(forceRefresh: true)
        XCTAssertTrue(newerLoadSucceeded)

        await staleGate.release()
        await staleRefresh.value

        let calls = await service.recordedCalls()
        XCTAssertEqual(calls, [.catalog(forceRefresh: true), .catalog(forceRefresh: true)])
        XCTAssertNil(store.presentedError)
    }

    @MainActor
    func testBackendChangeClearsUnsupportedRoleAndReloadsHandlers() async throws {
        let association = try Association.urlScheme("mailto")
        let service = FakeService(
            snapshot: sampleSnapshot,
            handlerApplications: [safari, firefox],
            defaultApplication: safari
        )
        let store = makeStore(service: service)
        store.selectedTab = .urlSchemes
        store.selectedAssociationID = "mailto"
        store.backend = .legacy
        store.role = .viewer

        await store.selectBackend(.modern)

        XCTAssertEqual(store.role, .all)
        XCTAssertEqual(store.backend, .modern)
        XCTAssertEqual(store.handlerApplications, [safari, firefox])
        XCTAssertEqual(store.defaultApplication, safari)
        let calls = await service.recordedCalls()
        XCTAssertEqual(
            calls,
            [
                .applications(association, backend: .modern, role: .all),
                .defaultApplication(association, backend: .modern, role: .all),
            ]
        )
    }

    @MainActor
    func testLegacyRoleChangeReloadsHandlersWithSelectedRole() async throws {
        let association = try Association.contentType("public.text")
        let service = FakeService(snapshot: sampleSnapshot, handlerApplications: [firefox])
        let store = makeStore(service: service)
        store.selectedTab = .contentTypes
        store.selectedAssociationID = "public.text"
        store.backend = .legacy

        await store.selectRole(.editor)

        XCTAssertEqual(store.role, .editor)
        XCTAssertEqual(store.handlerApplications, [firefox])
        let calls = await service.recordedCalls()
        XCTAssertEqual(
            calls,
            [
                .applications(association, backend: .legacy, role: .editor),
                .defaultApplication(association, backend: .legacy, role: .editor),
            ]
        )
    }

    @MainActor
    func testHandlerFailurePreservesCachedResultsAndPresentsError() async {
        let service = FakeService(
            snapshot: sampleSnapshot,
            handlerApplications: [safari],
            defaultApplication: safari
        )
        let store = makeStore(service: service)
        store.selectedTab = .urlSchemes
        store.selectedAssociationID = "mailto"
        await store.loadHandlers()
        await service.setLookupError(.handlersUnavailable)

        await store.loadHandlers()

        XCTAssertEqual(store.handlerApplications, [safari])
        XCTAssertEqual(store.defaultApplication, safari)
        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(store.presentedError?.message, "Handlers are unavailable.")
    }

    @MainActor
    func testNewerLookupSurvivesStaleFailureAfterSelectionReturnsToOriginalValue() async {
        let staleGate = AsyncGate()
        let service = FakeService(
            snapshot: sampleSnapshot,
            defaultApplication: firefox,
            applicationPlans: [
                LookupPlan(gate: staleGate, result: .failure(.handlersUnavailable)),
                LookupPlan(result: .success([firefox])),
            ]
        )
        let store = makeStore(service: service)
        store.selectedTab = .urlSchemes
        store.selectedAssociationID = "mailto"
        let staleLoad = Task { @MainActor in await store.loadHandlers() }
        await staleGate.waitUntilEntered()

        store.selectedTab = .contentTypes
        store.selectedAssociationID = "public.text"
        store.selectedTab = .urlSchemes
        store.selectedAssociationID = "mailto"
        await store.loadHandlers()
        XCTAssertEqual(store.handlerApplications, [firefox])
        XCTAssertNil(store.presentedError)

        await staleGate.release()
        await staleLoad.value

        XCTAssertEqual(store.handlerApplications, [firefox])
        XCTAssertEqual(store.defaultApplication, firefox)
        XCTAssertNil(store.presentedError)
    }

    @MainActor
    func testSameSelectionNewerSuccessSupersedesOlderSuccessfulCompletion() async {
        let staleGate = AsyncGate()
        let service = FakeService(
            snapshot: sampleSnapshot,
            applicationPlans: [
                LookupPlan(gate: staleGate, result: .success([safari])),
                LookupPlan(result: .success([firefox])),
            ],
            defaultPlans: [
                LookupPlan(result: .success(firefox)),
                LookupPlan(result: .success(safari)),
            ]
        )
        let store = makeStore(service: service)
        store.selectedTab = .urlSchemes
        store.selectedAssociationID = "mailto"
        let staleLoad = Task { @MainActor in await store.loadHandlers() }
        await staleGate.waitUntilEntered()

        await store.loadHandlers()
        XCTAssertEqual(store.handlerApplications, [firefox])
        XCTAssertEqual(store.defaultApplication, firefox)

        await staleGate.release()
        await staleLoad.value

        XCTAssertEqual(store.handlerApplications, [firefox])
        XCTAssertEqual(store.defaultApplication, firefox)
        XCTAssertNil(store.presentedError)
    }

    @MainActor
    func testLoadingRemainsTrueUntilOverlappingCatalogAndHandlerLoadsFinish() async {
        let catalogGate = AsyncGate()
        let service = FakeService(
            snapshot: sampleSnapshot,
            handlerApplications: [safari],
            defaultApplication: safari,
            catalogGate: catalogGate
        )
        let store = makeStore(service: service)
        store.selectedTab = .urlSchemes
        store.selectedAssociationID = "mailto"
        let catalogLoad = Task { @MainActor in await store.load() }
        await catalogGate.waitUntilEntered()

        await store.loadHandlers()

        XCTAssertTrue(store.isLoading)
        await catalogGate.release()
        await catalogLoad.value
        XCTAssertFalse(store.isLoading)
    }

    @MainActor
    func testSetDefaultModelsPendingMutationAndReloadsHandlers() async throws {
        let association = try Association.urlScheme("mailto")
        let gate = AsyncGate()
        let service = FakeService(
            snapshot: sampleSnapshot,
            handlerApplications: [safari, firefox],
            defaultApplication: firefox,
            mutationGate: gate
        )
        let store = makeStore(service: service)
        store.selectedTab = .urlSchemes
        store.selectedAssociationID = "mailto"
        let mutation = Task { @MainActor in await store.setDefault(firefox.reference) }

        await gate.waitUntilEntered()
        XCTAssertEqual(store.pendingMutation, firefox.id)

        await gate.release()
        await mutation.value

        XCTAssertNil(store.pendingMutation)
        XCTAssertNil(store.presentedError)
        XCTAssertEqual(store.defaultApplication, firefox)
        let calls = await service.recordedCalls()
        XCTAssertEqual(
            calls,
            [
                .setDefault(firefox.reference, association: association, backend: .modern, role: .all),
                .applications(association, backend: .modern, role: .all),
                .defaultApplication(association, backend: .modern, role: .all),
            ]
        )
    }

    @MainActor
    func testSetDefaultFailureClearsPendingMutationAndPresentsError() async throws {
        let association = try Association.contentType("public.text")
        let service = FakeService(snapshot: sampleSnapshot, mutationError: .mutationRejected)
        let store = makeStore(service: service)
        store.selectedTab = .contentTypes
        store.selectedAssociationID = "public.text"
        store.backend = .legacy
        store.role = .viewer

        await store.setDefault(safari.reference)

        XCTAssertNil(store.pendingMutation)
        XCTAssertEqual(store.presentedError?.message, "The mutation was rejected.")
        let calls = await service.recordedCalls()
        XCTAssertEqual(calls, [.setDefault(safari.reference, association: association, backend: .legacy, role: .viewer)])
    }

    @MainActor
    func testSecondMutationCannotClearPendingStateOwnedByFirstMutation() async {
        let firstGate = AsyncGate()
        let service = FakeService(
            snapshot: sampleSnapshot,
            handlerApplications: [safari, firefox],
            defaultApplication: safari,
            mutationPlans: [
                MutationPlan(gate: firstGate),
                MutationPlan(),
            ]
        )
        let store = makeStore(service: service)
        store.selectedTab = .urlSchemes
        store.selectedAssociationID = "mailto"
        let firstMutation = Task { @MainActor in await store.setDefault(safari.reference) }
        await firstGate.waitUntilEntered()
        XCTAssertEqual(store.pendingMutation, safari.id)

        await store.setDefault(firefox.reference)

        XCTAssertEqual(store.pendingMutation, safari.id)
        let callsWhileFirstIsPending = await service.recordedCalls()
        XCTAssertEqual(
            callsWhileFirstIsPending.filter {
                if case .setDefault = $0 { return true }
                return false
            }.count,
            1
        )
        await firstGate.release()
        await firstMutation.value
        XCTAssertNil(store.pendingMutation)
    }

    @MainActor
    func testTabSwitchRestoresItsSearchAndResetsSchemeRole() async {
        let store = makeStore(service: FakeService(snapshot: sampleSnapshot))
        store.searchText = "mail"
        store.selectTab(.contentTypes)
        XCTAssertEqual(store.searchText, "")
        store.searchText = "text"
        store.backend = .legacy
        store.role = .viewer
        store.selectedAssociationID = "public.text"
        store.selectTab(.urlSchemes)
        XCTAssertEqual(store.searchText, "mail")
        XCTAssertEqual(store.role, .all)
        XCTAssertNil(store.selectedAssociationID)
        store.selectTab(.contentTypes)
        XCTAssertEqual(store.searchText, "text")
    }

    @MainActor
    func testAssociationNavigationClearsSearchAndUsesTheCorrectTab() async throws {
        let store = makeStore(service: FakeService(snapshot: sampleSnapshot))
        store.selectTab(.applications)
        store.searchText = "Safari"
        store.navigate(to: try .contentType("public.text"))
        XCTAssertEqual(store.selectedTab, .contentTypes)
        XCTAssertEqual(store.selectedAssociationID, "public.text")
        XCTAssertEqual(store.searchText, "")
    }

    @MainActor
    func testListDefaultsUseSelectedBackendAndRoleAndFeedSearch() async throws {
        let service = FakeService(snapshot: sampleSnapshot, defaultApplication: firefox)
        let store = makeStore(service: service)
        store.selectedTab = .contentTypes
        store.backend = .legacy
        store.role = .editor
        await store.load()
        await store.loadAssociationDefaults()
        store.searchText = "firefox"
        XCTAssertEqual(store.associationRows.map(\.identifier), ["public.text"])
        XCTAssertEqual(store.associationRows.first?.defaultHandler, .application(firefox))
        let calls = await service.recordedCalls()
        XCTAssertTrue(calls.contains(.defaultApplication(try .contentType("public.text"), backend: .legacy, role: .editor)))
    }

    @MainActor
    func testStaleListLookupCannotOverwriteChangedBackend() async {
        let gate = AsyncGate()
        let service = FakeService(snapshot: sampleSnapshot, defaultPlans: [
            LookupPlan(gate: gate, result: .success(safari)),
            LookupPlan(result: .success(firefox)),
        ])
        let store = makeStore(service: service)
        await store.load()
        let stale = Task { await store.loadAssociationDefaults() }
        await gate.waitUntilEntered()
        await store.selectBackend(.legacy)
        await store.loadAssociationDefaults()
        await gate.release()
        await stale.value
        XCTAssertEqual(store.associationRows.first?.defaultHandler, .application(firefox))
        XCTAssertFalse(store.isResolvingDefaults)
    }

    @MainActor
    func testListLookupFailureIsDistinctFromNoDefault() async {
        let service = FakeService(snapshot: sampleSnapshot)
        let store = makeStore(service: service)
        await store.load()
        await service.setLookupError(.handlersUnavailable)
        await store.loadAssociationDefaults()
        XCTAssertEqual(store.associationRows.first?.defaultHandler.errorMessage, "Handlers are unavailable.")
    }

    @MainActor
    func testSchemeRoleIntentUsesAllEvenInLegacyMode() async {
        let store = makeStore(service: FakeService(snapshot: sampleSnapshot))
        store.backend = .legacy
        await store.selectRole(.viewer)
        XCTAssertEqual(store.role, .all)
    }

    @MainActor
    func testDetailLookupPublishesNoDefaultInTableInsteadOfLoading() async {
        let store = makeStore(service: FakeService(snapshot: sampleSnapshot))
        await store.load()
        store.selectedAssociationID = "mailto"
        await store.loadHandlers()
        XCTAssertEqual(store.associationRows.first?.defaultHandler, DefaultHandlerState.none)
    }

    @MainActor
    func testRefreshReloadsSelectedDefaultAndKeepsSelection() async {
        let service = FakeService(snapshot: sampleSnapshot, defaultPlans: [
            LookupPlan(result: .success(safari)),
            LookupPlan(result: .success(firefox)),
        ])
        let store = makeStore(service: service)
        await store.load()
        store.selectedAssociationID = "mailto"
        await store.loadHandlers()
        await store.refresh()
        XCTAssertEqual(store.selectedAssociationID, "mailto")
        XCTAssertEqual(store.defaultApplication, firefox)
        XCTAssertEqual(store.associationRows.first?.defaultHandler, .application(firefox))
    }

    @MainActor
    func testReselectingBackendPreservesResolvedDefaultsAndSearch() async {
        let service = FakeService(snapshot: sampleSnapshot, defaultApplication: firefox)
        let store = makeStore(service: service)
        await store.load()
        await store.loadAssociationDefaults()
        let query = store.listQuery

        await store.selectBackend(.modern)

        store.searchText = "Firefox"
        XCTAssertEqual(store.listQuery, query)
        XCTAssertEqual(store.associationRows.map(\.identifier), ["mailto"])
        XCTAssertEqual(store.associationRows.first?.defaultHandler, .application(firefox))
    }

    @MainActor
    func testReselectingRolePreservesResolvedDefaultsAndSearch() async {
        let service = FakeService(snapshot: sampleSnapshot, defaultApplication: firefox)
        let store = makeStore(service: service)
        store.selectedTab = .contentTypes
        store.backend = .legacy
        store.role = .viewer
        await store.load()
        await store.loadAssociationDefaults()
        let query = store.listQuery

        await store.selectRole(.viewer)

        store.searchText = "Firefox"
        XCTAssertEqual(store.listQuery, query)
        XCTAssertEqual(store.associationRows.map(\.identifier), ["public.text"])
        XCTAssertEqual(store.associationRows.first?.defaultHandler, .application(firefox))
    }

    @MainActor
    func testSelectingSameEffectiveRolePreservesResolvedSchemeDefault() async {
        let service = FakeService(snapshot: sampleSnapshot, defaultApplication: firefox)
        let store = makeStore(service: service)
        await store.load()
        await store.loadAssociationDefaults()

        await store.selectRole(.viewer)

        XCTAssertEqual(store.role, .all)
        XCTAssertEqual(store.associationRows.first?.defaultHandler, .application(firefox))
    }

    @MainActor
    func testReselectingBackendDoesNotCancelInFlightDefaultLookup() async {
        let gate = AsyncGate()
        let service = FakeService(snapshot: sampleSnapshot, defaultPlans: [
            LookupPlan(gate: gate, result: .success(firefox)),
        ])
        let store = makeStore(service: service)
        await store.load()
        let lookup = Task { await store.loadAssociationDefaults() }
        await gate.waitUntilEntered()

        await store.selectBackend(.modern)

        XCTAssertTrue(store.isResolvingDefaults)
        await gate.release()
        await lookup.value
        XCTAssertEqual(store.associationRows.first?.defaultHandler, .application(firefox))
        XCTAssertFalse(store.isResolvingDefaults)
    }

    @MainActor
    func testOtherApplicationURLResolvesBundleIdentifierForLegacySchemeAndRole() async throws {
        let url = URL(fileURLWithPath: "/Applications/Firefox.app")
        let resolver = BundleApplicationReferenceResolver { selectedURL in
            selectedURL.path == "/Applications/Firefox.app" ? "org.mozilla.firefox" : nil
        }
        let selections: [(Association, HandlerRole)] = [
            (try .urlScheme("mailto"), .all),
            (try .contentType("public.text"), .editor),
        ]
        for (association, role) in selections {
            let service = FakeService(snapshot: sampleSnapshot, defaultApplication: firefox)
            let store = makeStore(service: service, applicationReferenceResolver: resolver)
            store.selectedTab = association.kind == .urlScheme ? .urlSchemes : .contentTypes
            store.selectedAssociationID = association.identifier
            store.backend = .legacy
            store.role = role

            await store.setDefaultApplication(at: url)

            XCTAssertNil(store.presentedError)
            XCTAssertEqual(store.defaultApplication, firefox)
            let calls = await service.recordedCalls()
            XCTAssertEqual(calls.first, .setDefault(
                ApplicationReference(url: url, bundleIdentifier: "org.mozilla.firefox"),
                association: association, backend: .legacy, role: role
            ))
        }
    }

    @MainActor
    func testLookupStateDistinguishesUnresolvedLoadingAndConfirmedAbsence() async {
        let gate = AsyncGate()
        let service = FakeService(snapshot: sampleSnapshot, applicationPlans: [
            LookupPlan(gate: gate, result: .success([])),
        ])
        let store = makeStore(service: service)
        store.selectedAssociationID = "mailto"
        XCTAssertEqual(store.handlerLookupState, .unresolved)

        let lookup = Task { await store.loadHandlers() }
        await gate.waitUntilEntered()
        XCTAssertEqual(store.handlerLookupState, .loading)
        await gate.release()
        await lookup.value

        XCTAssertEqual(store.handlerLookupState, .loaded(applications: [], defaultApplication: nil))
        store.selectTab(.contentTypes)
        XCTAssertEqual(store.handlerLookupState, .unresolved)
    }

    @MainActor
    func testDismissingLookupFailurePreservesUnavailableStateUntilSuccessfulRetry() async {
        let service = FakeService(snapshot: sampleSnapshot, handlerApplications: [firefox], defaultPlans: [
            LookupPlan(result: .failure(.handlersUnavailable)),
        ])
        let store = makeStore(service: service)
        store.selectedAssociationID = "mailto"
        await store.loadHandlers()
        XCTAssertEqual(store.handlerLookupState, .failed("Handlers are unavailable."))

        store.presentedError = nil

        XCTAssertEqual(store.handlerLookupState, .failed("Handlers are unavailable."))
        await store.loadHandlers()
        XCTAssertEqual(store.handlerLookupState, .loaded(applications: [firefox], defaultApplication: nil))
    }

    @MainActor
    func testMutationFailureDoesNotReplaceKnownEmptyLookupResult() async {
        let service = FakeService(snapshot: sampleSnapshot, mutationError: .mutationRejected)
        let store = makeStore(service: service)
        store.selectedAssociationID = "mailto"
        await store.loadHandlers()
        XCTAssertEqual(store.handlerLookupState, .loaded(applications: [], defaultApplication: nil))

        await store.setDefault(firefox.reference)

        XCTAssertNotNil(store.presentedError)
        XCTAssertEqual(store.handlerLookupState, .loaded(applications: [], defaultApplication: nil))
        store.presentedError = nil
        XCTAssertEqual(store.handlerLookupState, .loaded(applications: [], defaultApplication: nil))
    }

    @MainActor
    func testApplicationDetailsResolveSchemesHandledAndDeclaredTypesForSelectedBackend() async throws {
        let application = ApplicationRecord(url: safari.url, displayName: "Browser",
            urlSchemes: [.init(scheme: "https")],
            documentTypeClaims: [.init(contentTypeIdentifiers: ["public.text"], role: .viewer)],
            exportedTypeDeclarations: [.init(identifier: "test.document", provenance: .exported)],
            importedTypeDeclarations: [.init(identifier: "public.text", provenance: .imported)])
        let service = FakeService(snapshot: CatalogSnapshot(applications: [application]), defaultApplication: application)
        let store = makeStore(service: service)
        await store.load()
        store.selectTab(.applications)
        store.backend = .legacy
        store.selectedApplicationID = application.id
        await store.loadAssociationDefaults()
        XCTAssertEqual(store.selectedApplicationAssociations.count, 3)
        for association in store.selectedApplicationAssociations {
            XCTAssertEqual(store.defaultHandlers[association], .application(application))
        }
        let calls = await service.recordedCalls()
        XCTAssertTrue(calls.contains(.defaultApplication(try .contentType("public.text"), backend: .legacy, role: .all)))
    }

    @MainActor
    func testSelectingApplicationWithoutAssociationsStopsPreviousLoadingIndicator() async {
        let first = ApplicationRecord(url: safari.url, displayName: "First", urlSchemes: [.init(scheme: "https")])
        let empty = ApplicationRecord(url: firefox.url, displayName: "Empty")
        let gate = AsyncGate()
        let service = FakeService(snapshot: CatalogSnapshot(applications: [first, empty]), defaultPlans: [
            LookupPlan(gate: gate, result: .success(first)),
        ])
        let store = makeStore(service: service)
        await store.load()
        store.selectTab(.applications)
        store.selectedApplicationID = first.id
        let oldLookup = Task { await store.loadAssociationDefaults() }
        await gate.waitUntilEntered()
        store.selectedApplicationID = empty.id
        await store.loadAssociationDefaults()
        XCTAssertFalse(store.isResolvingDefaults)
        await gate.release()
        await oldLookup.value
        XCTAssertFalse(store.isResolvingDefaults)
    }

    @MainActor
    func testStaleApplicationDefaultsCannotOverwriteNewSelection() async throws {
        let first = ApplicationRecord(url: safari.url, displayName: "First", urlSchemes: [.init(scheme: "https")])
        let second = ApplicationRecord(url: firefox.url, displayName: "Second", urlSchemes: [.init(scheme: "https")])
        let gate = AsyncGate()
        let service = FakeService(snapshot: CatalogSnapshot(applications: [first, second]), defaultPlans: [
            LookupPlan(gate: gate, result: .success(first)), LookupPlan(result: .success(second)),
        ])
        let store = makeStore(service: service)
        await store.load()
        store.selectTab(.applications)
        store.selectedApplicationID = first.id
        let oldLookup = Task { await store.loadAssociationDefaults() }
        await gate.waitUntilEntered()
        store.selectedApplicationID = second.id
        await store.loadAssociationDefaults()
        await gate.release()
        await oldLookup.value
        XCTAssertEqual(store.defaultHandlers[try .urlScheme("https")], .application(second))
    }

    @MainActor
    func testApplicationDetailMutationUsesExplicitAssociationWithoutNavigating() async throws {
        let service = FakeService(snapshot: sampleSnapshot, defaultApplication: firefox)
        let store = makeStore(service: service)
        store.selectTab(.applications)
        let association = try Association.urlScheme("mailto")
        await store.setDefault(firefox.reference, for: association)
        XCTAssertEqual(store.selectedTab, .applications)
        XCTAssertEqual(store.defaultHandlers[association], .application(firefox))
        let calls = await service.recordedCalls()
        XCTAssertTrue(calls.contains(.setDefault(firefox.reference, association: association, backend: .modern, role: .all)))
    }

    @MainActor
    func testCachedDetailsRemainVisibleDuringRevalidation() async {
        let gate = AsyncGate()
        let service = FakeService(snapshot: sampleSnapshot, defaultApplication: safari,
            applicationPlans: [LookupPlan(result: .success([safari])),
                               LookupPlan(gate: gate, result: .success([firefox]))])
        let store = makeStore(service: service)
        store.selectedAssociationID = "mailto"
        await store.loadHandlers()
        let refresh = Task { await store.loadHandlers() }
        await gate.waitUntilEntered()
        XCTAssertEqual(store.handlerApplications, [safari])
        await gate.release()
        await refresh.value
        XCTAssertEqual(store.handlerApplications, [firefox])
    }

    @MainActor
    func testTabRoundTripReusesListDefaults() async {
        let service = FakeService(snapshot: sampleSnapshot, defaultApplication: safari)
        let store = makeStore(service: service)
        await store.load()
        await store.loadAssociationDefaults()
        store.selectTab(.contentTypes)
        await store.loadAssociationDefaults()
        store.selectTab(.urlSchemes)
        await store.loadAssociationDefaults()
        let calls = await service.recordedCalls()
        XCTAssertEqual(calls.filter { if case .defaultApplication = $0 { return true }; return false }.count, 2)
        XCTAssertEqual(store.associationRows.first?.defaultHandler, .application(safari))
    }

    @MainActor
    func testMutationPreservesUnrelatedDefaultsAndCatalogRevision() async throws {
        let service = FakeService(snapshot: sampleSnapshot, defaultApplication: safari)
        let store = makeStore(service: service)
        await store.load()
        await store.loadAssociationDefaults()
        let revision = store.catalogRevision
        let mailto = try Association.urlScheme("mailto")
        await store.setDefault(firefox.reference, for: try .urlScheme("https"))
        XCTAssertEqual(store.defaultHandlers[mailto], .application(safari))
        XCTAssertEqual(store.catalogRevision, revision)
        let calls = await service.recordedCalls()
        XCTAssertEqual(calls.filter { if case .catalog = $0 { return true }; return false }.count, 1)
    }

    @MainActor
    func testListStartedDuringDetailRefreshCannotDiscardDetailResult() async {
        let gate = AsyncGate()
        let service = FakeService(snapshot: sampleSnapshot,
            applicationPlans: [LookupPlan(gate: gate, result: .success([firefox]))],
            defaultPlans: [LookupPlan(result: .success(safari)), LookupPlan(result: .success(firefox))])
        let store = makeStore(service: service)
        await store.load()
        store.selectedAssociationID = "mailto"
        let detail = Task { await store.loadHandlers() }
        await gate.waitUntilEntered()
        await store.loadAssociationDefaults()
        await gate.release()
        await detail.value
        XCTAssertEqual(store.handlerApplications, [firefox])
        XCTAssertEqual(store.defaultApplication, firefox)
    }

    @MainActor
    func testMutationSupersedesPendingListRead() async throws {
        let gate = AsyncGate()
        let service = FakeService(snapshot: sampleSnapshot, defaultApplication: firefox,
            defaultPlans: [LookupPlan(gate: gate, result: .success(safari))])
        let store = makeStore(service: service)
        await store.load()
        let list = Task { await store.loadAssociationDefaults() }
        await gate.waitUntilEntered()
        let association = try Association.urlScheme("mailto")
        await store.setDefault(firefox.reference, for: association)
        await gate.release()
        await list.value
        XCTAssertEqual(store.defaultHandlers[association], .application(firefox))
        store.selectTab(.contentTypes)
        store.selectTab(.urlSchemes)
        XCTAssertEqual(store.defaultHandlers[association], .application(firefox))
    }

    @MainActor
    func testApplicationDetailsKeepCachedRecordWhileOnlySelectedBundleRefreshes() async {
        let gate = AsyncGate()
        let changed = ApplicationRecord(url: safari.url, displayName: "Updated Safari")
        let updated = CatalogSnapshot(applications: [changed, firefox])
        let service = FakeService(snapshot: sampleSnapshot,
            metadataPlan: LookupPlan(gate: gate, result: .success(updated)))
        let store = makeStore(service: service)
        await store.load()
        store.selectTab(.applications)
        store.selectedApplicationID = safari.id
        let refresh = Task { await store.refreshSelectedApplication() }
        await gate.waitUntilEntered()
        XCTAssertEqual(store.selectedApplication, safari)
        await gate.release()
        await refresh.value
        XCTAssertEqual(store.selectedApplication, changed)
        let calls = await service.recordedCalls()
        XCTAssertEqual(calls, [.catalog(forceRefresh: false), .refreshApplication(safari.url)])
    }

    @MainActor
    func testUnchangedDetailsDoNotPublishDuplicateLookupState() async {
        let service = FakeService(snapshot: sampleSnapshot, handlerApplications: [safari], defaultApplication: safari)
        let store = makeStore(service: service)
        store.selectedAssociationID = "mailto"
        await store.loadHandlers()
        var publications = 0
        let observation = store.$handlerLookupState.dropFirst().sink { _ in publications += 1 }
        await store.loadHandlers()
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testListCachesConfirmedAbsenceOfDefault() async throws {
        let service = FakeService(snapshot: sampleSnapshot)
        let store = makeStore(service: service)
        await store.load()
        await store.loadAssociationDefaults()
        let association = try Association.urlScheme("mailto")
        XCTAssertEqual(store.defaultHandlers[association], DefaultHandlerState.none)
        await store.loadAssociationDefaults()
        let calls = await service.recordedCalls()
        XCTAssertEqual(calls.filter { if case .defaultApplication = $0 { return true }; return false }.count, 1)
    }

    @MainActor
    func testContentTypeMetadataRefreshesEvenWhenHandlersAreUnavailable() async {
        let changed = ContentTypeRecord(identifier: "public.text", localizedDescription: "Updated description")
        let service = FakeService(snapshot: sampleSnapshot,
            metadataPlan: LookupPlan(result: .success(CatalogSnapshot(contentTypes: [changed]))))
        let store = makeStore(service: service)
        await store.load()
        store.selectTab(.contentTypes)
        store.selectedAssociationID = "public.text"
        await service.setLookupError(.handlersUnavailable)
        await store.loadHandlers()
        await store.refreshSelectedContentType()
        XCTAssertEqual(store.selectedContentType, changed)
        XCTAssertEqual(store.handlerLookupState, .failed("Handlers are unavailable."))
        let calls = await service.recordedCalls()
        XCTAssertTrue(calls.contains(.refreshContentType("public.text")))
    }

    @MainActor
    func testApplicationMetadataRefreshUpdatesCachedDefaultNamesWithoutHandlerQueries() async throws {
        let changed = ApplicationRecord(url: safari.url, bundleIdentifier: safari.bundleIdentifier, displayName: "Renamed Safari")
        let updated = CatalogSnapshot(applications: [changed, firefox], urlSchemes: sampleSnapshot.urlSchemes)
        let service = FakeService(snapshot: sampleSnapshot, defaultApplication: safari,
            metadataPlan: LookupPlan(result: .success(updated)))
        let store = makeStore(service: service)
        await store.load()
        store.selectTab(.urlSchemes)
        await store.loadAssociationDefaults()
        store.selectTab(.applications)
        store.selectedApplicationID = safari.id
        await store.refreshSelectedApplication()
        store.selectTab(.urlSchemes)
        XCTAssertEqual(store.defaultHandlers[try .urlScheme("mailto")], .application(changed))
        let calls = await service.recordedCalls()
        XCTAssertEqual(calls.filter { if case .defaultApplication = $0 { return true }; return false }.count, 1)
    }

    @MainActor
    func testApplicationSelectionBindingDoesNotPublishDuringSetter() async {
        let store = makeStore(service: FakeService(snapshot: sampleSnapshot))
        await store.load()
        store.selectTab(.applications)
        let changed = expectation(description: "Selection applied after view update")
        var publications = 0
        let observation = store.$selectedApplicationID.dropFirst().sink { id in
            publications += 1
            if id == self.safari.id { changed.fulfill() }
        }
        let binding = ApplicationsListView(store: store).selectionBinding
        binding.wrappedValue = nil
        XCTAssertEqual(publications, 0, "Redundant nil must not trigger SwiftUI update loops")
        binding.wrappedValue = safari.id
        XCTAssertNil(store.selectedApplicationID)
        XCTAssertEqual(publications, 0)
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertEqual(store.selectedApplicationID, safari.id)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testRemovedApplicationListCannotWriteSelectionAfterTabChange() async {
        let store = makeStore(service: FakeService(snapshot: sampleSnapshot))
        store.selectTab(.applications)
        let binding = ApplicationsListView(store: store).selectionBinding
        binding.wrappedValue = safari.id
        store.selectTab(.contentTypes)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertNil(store.selectedApplicationID)
    }

    @MainActor
    func testLoadingAllContentTypeDefaultsPublishesOneCompleteSnapshot() async {
        let types = (0..<65).map { ContentTypeRecord(identifier: "test.type-\($0)") }
        let service = FakeService(snapshot: CatalogSnapshot(contentTypes: types))
        let store = makeStore(service: service)
        await store.load()
        store.selectTab(.contentTypes)

        var publishedCounts: [Int] = []
        let observation = store.$defaultHandlers.dropFirst().sink { publishedCounts.append($0.count) }

        await store.loadAssociationDefaults()

        let calls = await service.recordedCalls()
        let lookups = calls.filter { if case .defaultApplication = $0 { return true }; return false }.count
        XCTAssertEqual(lookups, 65)
        XCTAssertEqual(publishedCounts, [65], "A preload must replace table rows only after the complete result is ready")
        XCTAssertFalse(store.isResolvingDefaults)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testCancelledContentTypePreloadCannotExposeItsPartialCache() async {
        let types = (0..<65).map { ContentTypeRecord(identifier: "test.type-\($0)") }
        let gate = AsyncGate()
        let service = FakeService(
            snapshot: CatalogSnapshot(contentTypes: types),
            defaultPlans: [LookupPlan(gate: gate, result: .success(safari))]
        )
        let store = makeStore(service: service)
        await store.load()
        store.selectTab(.contentTypes)
        let preload = Task { await store.loadAssociationDefaults() }
        await gate.waitUntilEntered()

        for _ in 0..<100 {
            let calls = await service.recordedCalls()
            let lookups = calls.filter { if case .defaultApplication = $0 { return true }; return false }.count
            if lookups == types.count { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        store.selectTab(.urlSchemes)
        store.selectTab(.contentTypes)
        XCTAssertTrue(store.defaultHandlers.isEmpty, "A cancelled preload must not make partial results visible")

        await gate.release()
        await preload.value
        XCTAssertTrue(store.defaultHandlers.isEmpty)
    }

    @MainActor
    func testAppShowsCachedDefaultsMissingFromPlistWithoutLookup() async throws {
        let service = FakeService(snapshot: sampleSnapshot, defaultApplication: safari)
        let store = makeStore(service: service)
        await store.load()
        store.selectTab(.contentTypes)
        await store.loadAssociationDefaults()
        store.selectTab(.applications)
        store.selectedApplicationID = safari.id
        let before = await service.recordedCalls()
        XCTAssertEqual(store.additionalDefaultAssociations(for: safari), [try .contentType("public.text")])
        let after = await service.recordedCalls()
        XCTAssertEqual(after, before)
        await store.selectBackend(.legacy)
        XCTAssertTrue(store.additionalDefaultAssociations(for: safari).isEmpty, "Do not mix backend contexts")
    }

    @MainActor
    func testContentTypeTablePreloadsEveryDefaultBeforeScrolling() async throws {
        let types = (0..<1_301).map { ContentTypeRecord(identifier: String(format: "test.type-%04d", $0)) }
        let service = FakeService(snapshot: CatalogSnapshot(contentTypes: types))
        let store = makeStore(service: service)
        await store.load()
        store.selectTab(.contentTypes)
        let hosting = NSHostingController(rootView: RootView(store: store))
        let window = NSWindow(contentViewController: hosting)
        window.isReleasedWhenClosed = false
        window.setContentSize(CGSize(width: 1180, height: 720))
        window.orderFront(nil)
        defer { window.close() }
        for _ in 0..<200 where store.defaultHandlers.count < types.count {
            hosting.view.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let calls = await service.recordedCalls()
        let lookups = calls.filter {
            if case .defaultApplication(let association, _, _) = $0 { return association.kind == .contentType }
            return false
        }.count
        XCTAssertEqual(lookups, types.count)
        XCTAssertEqual(store.defaultHandlers.count, types.count)

        func tableScrollView(in view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView, scrollView.documentView is NSTableView { return scrollView }
            return view.subviews.lazy.compactMap { tableScrollView(in: $0) }.first
        }
        let scrollView = try XCTUnwrap(tableScrollView(in: hosting.view))
        let bottom = NSPoint(x: 0, y: scrollView.documentView?.bounds.maxY ?? 0)
        scrollView.contentView.scroll(to: bottom)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        for _ in 0..<5 {
            hosting.view.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let callsAfterScroll = await service.recordedCalls()
        let lookupsAfterScroll = callsAfterScroll.filter {
            if case .defaultApplication(let association, _, _) = $0 { return association.kind == .contentType }
            return false
        }.count
        XCTAssertEqual(lookupsAfterScroll, lookups, "Scrolling must not trigger additional default lookups")
    }

    @MainActor
    func testContentTypeFilterHidesDevicesButCanRevealAllIdentifiers() async {
        let service = FakeService(snapshot: CatalogSnapshot(contentTypes: [
            .init(identifier: "public.text", isFileType: true),
            .init(identifier: "com.apple.ipad-8-wifi-1", isFileType: false),
            .init(identifier: "com.unknown.md", isFileType: false)]))
        let store = makeStore(service: service)
        await store.load()
        store.selectTab(.contentTypes)
        XCTAssertEqual(store.associationRows.map(\.identifier), ["public.text"])
        store.showAllContentTypes = true
        XCTAssertEqual(store.associationRows.count, 3)
        store.showAllContentTypes = false
        XCTAssertEqual(store.associationRows.map(\.identifier), ["public.text"])
    }

    @MainActor
    func testAdditionalDefaultsAreRevalidatedWhenOpeningApplication() async throws {
        let service = FakeService(snapshot: sampleSnapshot, defaultPlans: [
            LookupPlan(result: .success(safari)), LookupPlan(result: .success(firefox))])
        let store = makeStore(service: service)
        await store.load()
        store.selectTab(.contentTypes)
        await store.loadAssociationDefaults()
        store.selectTab(.applications)
        store.selectedApplicationID = safari.id
        XCTAssertEqual(store.selectedApplicationAssociations, [try .contentType("public.text")])
        await store.loadAssociationDefaults()
        XCTAssertTrue(store.additionalDefaultAssociations(for: safari).isEmpty)
        XCTAssertEqual(store.additionalDefaultAssociations(for: firefox), [try .contentType("public.text")])
    }

    @MainActor
    func testAppsWithCachedDefaultsSurviveHideWithoutAssociationsFilter() async {
        let service = FakeService(snapshot: sampleSnapshot, defaultApplication: safari)
        let store = makeStore(service: service)
        await store.load()
        store.selectTab(.urlSchemes)
        await store.loadAssociationDefaults()
        store.selectTab(.applications)
        store.applicationFilters.hideWithoutAssociations = true
        XCTAssertEqual(store.applicationRows, [safari])
    }

    @MainActor
    func testPreloadedDefaultsEnableColdApplicationNameSearch() async {
        let service = FakeService(snapshot: sampleSnapshot, defaultApplication: safari)
        let store = makeStore(service: service)
        await store.load()
        store.selectTab(.contentTypes)
        store.searchText = "Safari"
        XCTAssertTrue(store.associationRows.isEmpty)
        await store.loadAssociationDefaults()
        XCTAssertEqual(store.associationRows.map(\.identifier), ["public.text"])
    }

    @MainActor
    private func makeStore(service: any HandlerServicing,
                           applicationReferenceResolver: any ApplicationReferenceResolving = BundleApplicationReferenceResolver()) -> AppStore {
        let store = AppStore(service: service, applicationReferenceResolver: applicationReferenceResolver,
                             customAssociationStore: MemoryCustomAssociations(), customTypeRegistrar: TestTypeRegistrar())
        store.selectTab(.urlSchemes)
        return store
    }

    @MainActor
    func testCreatingSchemePersistsAndSelectsWithoutChangingDefaults() async throws {
        let persistence = MemoryCustomAssociations()
        let service = FakeService(snapshot: sampleSnapshot)
        let store = AppStore(service: service, customAssociationStore: persistence, customTypeRegistrar: TestTypeRegistrar())
        await store.load()
        store.searchText = "nothing matches"
        var draft = NewAssociationDraft(kind: .urlScheme)
        draft.identifier = " MyProject: "
        let association = try Association.urlScheme("myproject")

        let result = await store.createAssociation(draft, application: nil)

        XCTAssertEqual(result, .created(association))
        XCTAssertEqual(store.selectedAssociation, association)
        XCTAssertEqual(store.searchText, "")
        XCTAssertTrue(store.associationRows.contains { $0.identifier == "myproject" })
        XCTAssertTrue(store.customAssociationIDs.contains(association))
        let saved = try await persistence.load()
        XCTAssertEqual(saved.map(\.association), [association])
        let calls = await service.recordedCalls()
        XCTAssertFalse(calls.contains { if case .setDefault = $0 { return true }; return false })
    }

    @MainActor
    func testCustomTypeMetadataAndSelectionSurviveRefreshAndRelaunch() async throws {
        let persistence = MemoryCustomAssociations()
        let registrar = TestTypeRegistrar()
        let service = FakeService(snapshot: sampleSnapshot, metadataPlan: .init(result: .success(sampleSnapshot)))
        let store = AppStore(service: service, customAssociationStore: persistence, customTypeRegistrar: registrar)
        await store.load()
        var draft = NewAssociationDraft(kind: .contentType)
        draft.identifier = "com.example.project"
        draft.name = "Project Document"
        draft.filenameExtensions = ".MyProj, myproj, project"
        draft.mimeType = "application/x-project"
        let association = try Association.contentType("com.example.project")
        let result = await store.createAssociation(draft, application: nil)
        XCTAssertEqual(result, .created(association))
        await store.refresh()
        await store.refreshSelectedContentType()
        XCTAssertEqual(store.selectedAssociation, association)
        XCTAssertEqual(store.selectedContentType?.localizedDescription, "Project Document")
        XCTAssertEqual(Set(store.selectedContentType?.tags["public.filename-extension"] ?? []), ["myproj", "project"])
        XCTAssertEqual(store.selectedContentType?.tags["public.mime-type"], ["application/x-project"])
        XCTAssertEqual(store.customRegistrationStates[association], .registered)

        let relaunched = AppStore(service: service, customAssociationStore: persistence, customTypeRegistrar: registrar)
        await relaunched.load()
        relaunched.navigate(to: association)
        XCTAssertEqual(relaunched.associationRows.map(\.identifier).filter { $0 == association.identifier }.count, 1)
        XCTAssertEqual(relaunched.selectedContentType?.supertypes, ["public.data"])
        XCTAssertEqual(relaunched.customRegistrationStates[association], .registered)
    }

    @MainActor
    func testDuplicateCreationDoesNotPersistOrAssignDefault() async throws {
        let persistence = MemoryCustomAssociations()
        let service = FakeService(snapshot: sampleSnapshot)
        let store = AppStore(service: service, customAssociationStore: persistence, customTypeRegistrar: TestTypeRegistrar())
        await store.load()
        var draft = NewAssociationDraft(kind: .urlScheme)
        draft.identifier = " MAILTO: "
        let result = await store.createAssociation(draft, application: firefox.reference)
        XCTAssertEqual(result, .duplicate(try Association.urlScheme("mailto")))
        let saved = try await persistence.load()
        XCTAssertTrue(saved.isEmpty)
        let calls = await service.recordedCalls()
        XCTAssertFalse(calls.contains { if case .setDefault = $0 { return true }; return false })
    }

    @MainActor
    func testFailedCustomSaveDoesNotPublishOrChangeSystemDefaults() async {
        let persistence = MemoryCustomAssociations(saveError: .mutationRejected)
        let service = FakeService(snapshot: sampleSnapshot)
        let store = AppStore(service: service, customAssociationStore: persistence, customTypeRegistrar: TestTypeRegistrar())
        await store.load()
        var draft = NewAssociationDraft(kind: .urlScheme)
        draft.identifier = "unsaved"
        let result = await store.createAssociation(draft, application: firefox.reference)
        guard case .failed = result else { return XCTFail("Expected save failure, got \(result)") }
        XCTAssertFalse(store.associationRows.contains { $0.identifier == "unsaved" })
        XCTAssertTrue(store.customAssociations.isEmpty)
        let calls = await service.recordedCalls()
        XCTAssertFalse(calls.contains { if case .setDefault = $0 { return true }; return false })
    }

    @MainActor
    func testRegistrationFailureRetainsSavedTypeAndCanRetry() async throws {
        let persistence = MemoryCustomAssociations()
        let registrar = TestTypeRegistrar(fails: true)
        let service = FakeService(snapshot: sampleSnapshot)
        let store = AppStore(service: service, customAssociationStore: persistence, customTypeRegistrar: registrar)
        await store.load()
        var draft = NewAssociationDraft(kind: .contentType)
        draft.identifier = "com.example.retry"
        draft.name = "Retry Document"
        draft.filenameExtensions = "retrydoc"
        let association = try Association.contentType(draft.identifier)
        let result = await store.createAssociation(draft, application: firefox.reference)
        guard case .savedWithIssue(let saved, _) = result else { return XCTFail("Expected partial success") }
        XCTAssertEqual(saved, association)
        XCTAssertEqual(store.selectedAssociation, association)
        let calls = await service.recordedCalls()
        XCTAssertFalse(calls.contains { if case .setDefault = $0 { return true }; return false })
        await registrar.setFailure(false)
        let retry = await store.retryCustomAssociation(association, application: nil)
        XCTAssertEqual(retry, .created(association))
        XCTAssertEqual(store.customRegistrationStates[association], .registered)
        let savedRecords = try await persistence.load()
        XCTAssertEqual(savedRecords.count, 1)
    }

    @MainActor
    func testDefaultFailureRetainsCustomSchemeAndRetryUsesAllRoles() async throws {
        let persistence = MemoryCustomAssociations()
        let service = FakeService(snapshot: sampleSnapshot, defaultApplication: firefox,
                                  mutationPlans: [.init(error: .mutationRejected), .init()])
        let store = AppStore(service: service, customAssociationStore: persistence, customTypeRegistrar: TestTypeRegistrar())
        await store.load()
        store.selectTab(.contentTypes)
        await store.selectBackend(.legacy)
        await store.selectRole(.viewer)
        var draft = NewAssociationDraft(kind: .urlScheme)
        draft.identifier = "retry-scheme"
        let association = try Association.urlScheme(draft.identifier)
        let result = await store.createAssociation(draft, application: firefox.reference)
        guard case .savedWithIssue = result else { return XCTFail("Expected partial success") }
        XCTAssertEqual(store.customAssociations.count, 1)
        let retry = await store.retryCustomAssociation(association, application: firefox.reference)
        XCTAssertEqual(retry, .created(association))
        let calls = await service.recordedCalls()
        XCTAssertEqual(calls.filter { $0 == .setDefault(firefox.reference, association: association, backend: .legacy, role: .all) }.count, 2)
        XCTAssertEqual(store.defaultApplication, firefox)
    }

    @MainActor
    func testConcurrentCreationIsRejectedWhileDefaultAssignmentIsPending() async throws {
        let gate = AsyncGate()
        let persistence = MemoryCustomAssociations()
        let service = FakeService(snapshot: sampleSnapshot, defaultApplication: firefox, mutationGate: gate)
        let store = AppStore(service: service, customAssociationStore: persistence, customTypeRegistrar: TestTypeRegistrar())
        await store.load()
        var draft = NewAssociationDraft(kind: .urlScheme)
        draft.identifier = "busy-scheme"
        let first = Task { await store.createAssociation(draft, application: firefox.reference) }
        await gate.waitUntilEntered()
        XCTAssertTrue(store.isCreatingAssociation)
        XCTAssertNotNil(store.pendingMutation)
        var other = NewAssociationDraft(kind: .urlScheme)
        other.identifier = "other-scheme"
        let result = await store.createAssociation(other, application: nil)
        guard case .failed = result else {
            await gate.release()
            _ = await first.value
            return XCTFail("Expected a busy failure")
        }
        await gate.release()
        _ = await first.value
        XCTAssertFalse(store.isCreatingAssociation)
        XCTAssertEqual(store.customAssociations.count, 1)
    }

    @MainActor
    func testRegistrationFreezesNavigationAndOrdinarySetters() async throws {
        let gate = AsyncGate()
        let registrar = TestTypeRegistrar(gate: gate)
        let service = FakeService(snapshot: sampleSnapshot)
        let store = AppStore(service: service, customAssociationStore: MemoryCustomAssociations(), customTypeRegistrar: registrar)
        await store.load()
        var draft = NewAssociationDraft(kind: .contentType)
        draft.identifier = "org.example.in-flight"
        draft.name = "In-flight document"
        draft.filenameExtensions = "inflight"
        let association = try Association.contentType(draft.identifier)
        let creation = Task { await store.createAssociation(draft, application: nil) }
        await gate.waitUntilEntered()
        store.selectTab(.applications)
        await store.selectBackend(.legacy)
        await store.setDefault(firefox.reference, for: association)
        await store.refresh()
        XCTAssertEqual(store.selectedAssociation, association)
        XCTAssertEqual(store.backend, .modern)
        let calls = await service.recordedCalls()
        XCTAssertFalse(calls.contains { if case .setDefault = $0 { return true }; return false })
        XCTAssertEqual(calls.filter { if case .catalog = $0 { return true }; return false }.count, 1)
        await gate.release()
        let result = await creation.value
        XCTAssertEqual(result, .created(association))
    }

    @MainActor
    func testUnreadableCustomFileKeepsSystemCatalogVisibleAndBlocksOverwrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("custom.json")
        let original = Data("not valid json".utf8)
        try original.write(to: file)
        let store = AppStore(service: FakeService(snapshot: sampleSnapshot),
                             customAssociationStore: CustomAssociationFileStore(url: file), customTypeRegistrar: TestTypeRegistrar())
        await store.load()
        XCTAssertEqual(store.snapshot?.urlSchemes.map(\.identifier), ["mailto"])
        XCTAssertNotNil(store.presentedError)
        XCTAssertFalse(store.canCreateAssociation)
        var draft = NewAssociationDraft(kind: .urlScheme)
        draft.identifier = "blocked"
        guard case .failed = await store.createAssociation(draft, application: nil) else { return XCTFail("Expected blocked save") }
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    private var sampleSnapshot: CatalogSnapshot {
        CatalogSnapshot(
            applications: [safari, firefox],
            urlSchemes: [
                URLSchemeRecord(
                    identifier: "mailto",
                    handlerApplications: [safari.reference],
                    declaringApplications: [firefox.reference]
                ),
            ],
            contentTypes: [
                ContentTypeRecord(identifier: "public.text", localizedDescription: "Plain text"),
            ]
        )
    }
}

private actor MemoryCustomAssociations: CustomAssociationPersisting {
    var records: [CustomAssociation] = []
    let saveError: FixtureError?
    init(saveError: FixtureError? = nil) { self.saveError = saveError }
    func load() async throws -> [CustomAssociation] { records }
    func save(_ records: [CustomAssociation]) async throws {
        if let saveError { throw saveError }
        self.records = records
    }
}

private actor TestTypeRegistrar: CustomTypeRegistering {
    var registered: Set<Association> = []
    var fails: Bool
    let gate: AsyncGate?
    init(fails: Bool = false, gate: AsyncGate? = nil) { self.fails = fails; self.gate = gate }
    func register(_ record: CustomAssociation) async throws {
        await gate?.suspend()
        if fails { throw FixtureError.mutationRejected }
        registered.insert(record.association)
    }
    func isRegistered(_ record: CustomAssociation) async -> Bool { registered.contains(record.association) }
    func setFailure(_ value: Bool) { fails = value }
}

private enum FixtureError: Error, LocalizedError, Sendable {
    case catalogUnavailable
    case handlersUnavailable
    case mutationRejected

    var errorDescription: String? {
        switch self {
        case .catalogUnavailable: "The catalog is unavailable."
        case .handlersUnavailable: "Handlers are unavailable."
        case .mutationRejected: "The mutation was rejected."
        }
    }
}

private struct LookupPlan<Value: Sendable>: Sendable {
    let gate: AsyncGate?
    let result: Result<Value, FixtureError>

    init(gate: AsyncGate? = nil, result: Result<Value, FixtureError>) {
        self.gate = gate
        self.result = result
    }
}

private struct MutationPlan: Sendable {
    let gate: AsyncGate?
    let error: FixtureError?

    init(gate: AsyncGate? = nil, error: FixtureError? = nil) {
        self.gate = gate
        self.error = error
    }
}

private actor AsyncGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor FakeService: HandlerServicing {
    enum Call: Equatable, Sendable {
        case catalog(forceRefresh: Bool)
        case refreshApplication(URL)
        case refreshContentType(String)
        case applications(Association, backend: Backend, role: HandlerRole)
        case defaultApplication(Association, backend: Backend, role: HandlerRole)
        case setDefault(ApplicationReference, association: Association, backend: Backend, role: HandlerRole)
    }

    private let snapshot: CatalogSnapshot
    private let handlerApplications: [ApplicationRecord]
    private let defaultApplication: ApplicationRecord?
    private let handlerApplicationsByAssociation: [Association: [ApplicationRecord]]
    private var defaultApplicationsByAssociation: [Association: ApplicationRecord]
    private let catalogGate: AsyncGate?
    private let mutationGate: AsyncGate?
    private var catalogError: FixtureError?
    private var lookupError: FixtureError?
    private let mutationError: FixtureError?
    private var applicationPlans: [LookupPlan<[ApplicationRecord]>]
    private var defaultPlans: [LookupPlan<ApplicationRecord?>]
    private var mutationPlans: [MutationPlan]
    private var catalogPlans: [LookupPlan<CatalogSnapshot>]
    private let metadataPlan: LookupPlan<CatalogSnapshot>?
    private var calls: [Call] = []

    init(
        snapshot: CatalogSnapshot,
        handlerApplications: [ApplicationRecord] = [],
        defaultApplication: ApplicationRecord? = nil,
        handlerApplicationsByAssociation: [Association: [ApplicationRecord]] = [:],
        defaultApplicationsByAssociation: [Association: ApplicationRecord] = [:],
        catalogGate: AsyncGate? = nil,
        mutationGate: AsyncGate? = nil,
        mutationError: FixtureError? = nil,
        applicationPlans: [LookupPlan<[ApplicationRecord]>] = [],
        defaultPlans: [LookupPlan<ApplicationRecord?>] = [],
        mutationPlans: [MutationPlan] = [],
        catalogPlans: [LookupPlan<CatalogSnapshot>] = [],
        metadataPlan: LookupPlan<CatalogSnapshot>? = nil
    ) {
        self.snapshot = snapshot
        self.handlerApplications = handlerApplications
        self.defaultApplication = defaultApplication
        self.handlerApplicationsByAssociation = handlerApplicationsByAssociation
        self.defaultApplicationsByAssociation = defaultApplicationsByAssociation
        self.catalogGate = catalogGate
        self.mutationGate = mutationGate
        self.mutationError = mutationError
        self.applicationPlans = applicationPlans
        self.defaultPlans = defaultPlans
        self.mutationPlans = mutationPlans
        self.catalogPlans = catalogPlans
        self.metadataPlan = metadataPlan
    }

    func catalog(forceRefresh: Bool) async throws -> CatalogSnapshot {
        calls.append(.catalog(forceRefresh: forceRefresh))
        if !catalogPlans.isEmpty {
            let plan = catalogPlans.removeFirst()
            await plan.gate?.suspend()
            return try plan.result.get()
        }
        await catalogGate?.suspend()
        if let catalogError { throw catalogError }
        return snapshot
    }

    func applications(
        capableOf association: Association,
        backend: Backend,
        role: HandlerRole
    ) async throws -> [ApplicationRecord] {
        calls.append(.applications(association, backend: backend, role: role))
        if !applicationPlans.isEmpty {
            let plan = applicationPlans.removeFirst()
            await plan.gate?.suspend()
            return try plan.result.get()
        }
        if let lookupError { throw lookupError }
        if let applications = handlerApplicationsByAssociation[association] { return applications }
        return handlerApplications
    }

    func defaultApplication(
        for association: Association,
        backend: Backend,
        role: HandlerRole
    ) async throws -> ApplicationRecord? {
        calls.append(.defaultApplication(association, backend: backend, role: role))
        if !defaultPlans.isEmpty {
            let plan = defaultPlans.removeFirst()
            await plan.gate?.suspend()
            return try plan.result.get()
        }
        if let lookupError { throw lookupError }
        if let application = defaultApplicationsByAssociation[association] { return application }
        return defaultApplication
    }

    func setDefaultApplication(
        _ application: ApplicationReference,
        for association: Association,
        backend: Backend,
        role: HandlerRole
    ) async throws {
        calls.append(.setDefault(application, association: association, backend: backend, role: role))
        if !mutationPlans.isEmpty {
            let plan = mutationPlans.removeFirst()
            await plan.gate?.suspend()
            if let error = plan.error { throw error }
            defaultApplicationsByAssociation[association] = applicationRecord(for: application)
            return
        }
        await mutationGate?.suspend()
        if let mutationError { throw mutationError }
        defaultApplicationsByAssociation[association] = applicationRecord(for: application)
    }

    func refreshedApplicationCatalog(at url: URL) async throws -> CatalogSnapshot? {
        guard let metadataPlan else { return nil }
        calls.append(.refreshApplication(url))
        await metadataPlan.gate?.suspend()
        return try metadataPlan.result.get()
    }

    func refreshedContentTypeCatalog(_ identifier: String) async throws -> CatalogSnapshot? {
        guard let metadataPlan else { return nil }
        calls.append(.refreshContentType(identifier))
        await metadataPlan.gate?.suspend()
        return try metadataPlan.result.get()
    }

    func setCatalogError(_ error: FixtureError?) {
        catalogError = error
    }

    func setLookupError(_ error: FixtureError?) {
        lookupError = error
    }

    func recordedCalls() -> [Call] {
        calls
    }

    func recordedDefault(for association: Association) -> ApplicationRecord? {
        defaultApplicationsByAssociation[association]
    }

    private func applicationRecord(for reference: ApplicationReference) -> ApplicationRecord {
        let known = handlerApplicationsByAssociation.values.flatMap { $0 } + handlerApplications
        return known.first(where: { $0.id == reference.id }) ?? ApplicationRecord(
            url: reference.url,
            bundleIdentifier: reference.bundleIdentifier,
            displayName: reference.url.deletingPathExtension().lastPathComponent
        )
    }
}

@MainActor
final class IncomingOpenTests: XCTestCase {
    func testQueuePreservesDuplicatesAndArrivalOrderAndExcludesSelf() async throws {
        let workspace = FakeOpeningWorkspace()
        let own = ApplicationRecord(url: URL(fileURLWithPath: "/Applications/DefaultApp.app"),
                                    bundleIdentifier: "test.atlas", displayName: "Atlas")
        let otherCopy = ApplicationRecord(url: URL(fileURLWithPath: "/tmp/DefaultApp.app"),
                                          bundleIdentifier: "test.atlas", displayName: "Atlas Copy")
        let target = ApplicationRecord(url: URL(fileURLWithPath: "/Applications/Browser.app"), displayName: "Browser")
        workspace.candidates = [own, otherCopy, target]
        let store = IncomingOpenStore(workspace: workspace, ownApplication: own.reference)
        let first = try XCTUnwrap(URL(string: "https://example.com/one"))
        let second = URL(fileURLWithPath: "/tmp/two.txt")
        store.enqueue([first, first, second])
        await store.loadHandlers()
        XCTAssertEqual(store.current?.url, first)
        XCTAssertEqual(store.remainingCount, 2)
        XCTAssertEqual(store.handlers, [target])
        let originalID = store.current?.id
        await store.open(using: target)
        XCTAssertEqual(workspace.opened, [first])
        XCTAssertEqual(store.current?.url, first)
        XCTAssertNotEqual(store.current?.id, originalID)
        store.skip()
        XCTAssertEqual(store.current?.url, second)
        XCTAssertEqual(store.remainingCount, 0)
        store.skip()
        XCTAssertNil(store.current)
    }

    func testOpenFailureRetainsCurrentAndQueueForRetry() async throws {
        let workspace = FakeOpeningWorkspace()
        let app = ApplicationRecord(url: URL(fileURLWithPath: "/Applications/Browser.app"), displayName: "Browser")
        workspace.candidates = [app]
        workspace.shouldFail = true
        let store = IncomingOpenStore(workspace: workspace)
        let url = try XCTUnwrap(URL(string: "https://example.com"))
        store.enqueue([url, url])
        await store.loadHandlers()
        let id = store.current?.id
        await store.open(using: app)
        XCTAssertEqual(store.current?.id, id)
        XCTAssertEqual(store.remainingCount, 1)
        XCTAssertNotNil(store.errorMessage)
        workspace.shouldFail = false
        await store.open(using: app)
        XCTAssertNotEqual(store.current?.id, id)
        XCTAssertNil(store.errorMessage)
    }

    func testEventsArrivingWhileOpeningWaitAndDuplicateOpenIsIgnored() async throws {
        let workspace = FakeOpeningWorkspace()
        let target = ApplicationRecord(url: URL(fileURLWithPath: "/Applications/Browser.app"), displayName: "Browser")
        workspace.candidates = [target]
        let gate = AsyncGate()
        workspace.openGate = gate
        let store = IncomingOpenStore(workspace: workspace)
        let first = try XCTUnwrap(URL(string: "https://example.com/one"))
        let second = try XCTUnwrap(URL(string: "https://example.com/two"))
        store.enqueue([first])
        await store.loadHandlers()
        let opening = Task { await store.open(using: target) }
        await gate.waitUntilEntered()
        store.enqueue([second])
        store.skip()
        await store.open(using: target)
        XCTAssertEqual(store.current?.url, first)
        XCTAssertEqual(store.remainingCount, 1)
        await gate.release()
        await opening.value
        XCTAssertEqual(workspace.opened, [first])
        XCTAssertEqual(store.current?.url, second)
        XCTAssertFalse(store.isOpening)
    }

    func testLateHandlerLookupCannotReplaceNextEvent() async throws {
        let workspace = FakeOpeningWorkspace()
        let gate = AsyncGate()
        workspace.gate = gate
        let store = IncomingOpenStore(workspace: workspace)
        store.enqueue([try XCTUnwrap(URL(string: "https://example.com/one")),
                       try XCTUnwrap(URL(string: "https://example.com/two"))])
        let lookup = Task { await store.loadHandlers() }
        await gate.waitUntilEntered()
        store.skip()
        await gate.release()
        await lookup.value
        XCTAssertTrue(store.handlers.isEmpty)
        XCTAssertEqual(store.current?.url.lastPathComponent, "two")
    }

    func testDiscardAllItemsClearsQueueAndPresentationState() async throws {
        let workspace = FakeOpeningWorkspace()
        let app = ApplicationRecord(url: URL(fileURLWithPath: "/Applications/Browser.app"), displayName: "Browser")
        workspace.candidates = [app]
        let gate = AsyncGate()
        workspace.gate = gate
        let store = IncomingOpenStore(workspace: workspace)
        store.enqueue([try XCTUnwrap(URL(string: "https://example.com/one")),
                       try XCTUnwrap(URL(string: "https://example.com/two"))])
        let lookup = Task { await store.loadHandlers() }
        await gate.waitUntilEntered()

        store.discardAllItems()
        await gate.release()
        await lookup.value

        XCTAssertTrue(store.requests.isEmpty)
        XCTAssertTrue(store.handlers.isEmpty)
        XCTAssertNil(store.selectedHandlerID)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isLoading)
    }

    func testDiscardWaitingItemsKeepsOnlyInFlightCurrentItem() async throws {
        let workspace = FakeOpeningWorkspace()
        let app = ApplicationRecord(url: URL(fileURLWithPath: "/Applications/Browser.app"), displayName: "Browser")
        workspace.candidates = [app]
        let gate = AsyncGate()
        workspace.openGate = gate
        let store = IncomingOpenStore(workspace: workspace)
        let first = try XCTUnwrap(URL(string: "https://example.com/one"))
        store.enqueue([first, try XCTUnwrap(URL(string: "https://example.com/two"))])
        await store.loadHandlers()
        let opening = Task { await store.open(using: app) }
        await gate.waitUntilEntered()

        store.discardWaitingItems()

        XCTAssertEqual(store.requests.map(\.url), [first])
        XCTAssertTrue(store.isOpening)
        await gate.release()
        await opening.value
        XCTAssertTrue(store.requests.isEmpty)
    }
}

@MainActor
private final class FakeOpeningWorkspace: IncomingOpening {
    var candidates: [ApplicationRecord] = []
    var opened: [URL] = []
    var shouldFail = false
    var gate: AsyncGate?
    var openGate: AsyncGate?
    func applications(for url: URL) async throws -> [ApplicationRecord] {
        await gate?.suspend()
        return candidates
    }
    func open(_ url: URL, with application: URL) async throws {
        await openGate?.suspend()
        if shouldFail { throw FixtureError.handlersUnavailable }
        opened.append(url)
    }
}
