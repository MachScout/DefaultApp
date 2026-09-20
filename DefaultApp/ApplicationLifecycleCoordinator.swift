import AppKit
import Combine
import SwiftUI

@MainActor
final class ApplicationLifecycleCoordinator: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let appStore: AppStore
    let incomingStore: IncomingOpenStore

    private var model = ApplicationLifecycleModel()
    private var mainWindow: NSWindow?
    private var incomingWindow: NSWindow?
    private var observations: Set<AnyCancellable> = []
    private var lastPendingCount = 0
    private var lastOpeningValue = false
    private var terminationReplyPending = false
    private var isClosingIncomingProgrammatically = false
    private var isDiscardingItems = false

    override convenience init() {
        self.init(userDefaults: .standard)
    }

    init(userDefaults: UserDefaults,
         incomingStore: IncomingOpenStore = IncomingOpenStore()) {
        self.appStore = AppStore(userDefaults: userDefaults)
        self.incomingStore = incomingStore
        super.init()
        observeIncomingState()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        perform(model.finishedLaunching())
        if let mainMenu = NSApplication.shared.mainMenu { Self.pruneMainMenu(mainMenu) }
    }

    static func pruneMainMenu(_ mainMenu: NSMenu) {
        if let fileItem = mainMenu.items.first(where: { $0.title == "File" }) {
            mainMenu.removeItem(fileItem)
        }
        guard let viewMenu = mainMenu.items.first(where: { $0.title == "View" })?.submenu else { return }
        let automaticTabActions = [NSSelectorFromString("toggleTabBar:"),
                                   NSSelectorFromString("toggleTabOverview:")]
        for item in viewMenu.items where item.action.map(automaticTabActions.contains) == true {
            viewMenu.removeItem(item)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        incomingStore.enqueue(urls)
        perform(model.receivedIncomingItems())
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        guard model.mode == .regular else { return false }
        perform([.showMainWindow])
        return true
    }

    func showMainWindow() {
        _ = NSApplication.shared.setActivationPolicy(.regular)
        if mainWindow == nil { mainWindow = makeMainWindow() }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func showRequests() {
        if incomingWindow == nil { incomingWindow = makeIncomingWindow() }
        incomingWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func makeMainWindow() -> NSWindow {
        let controller = NSHostingController(rootView: RootView(store: appStore))
        let window = NSWindow(contentViewController: controller)
        window.title = "DefaultApp"
        window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable])
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1180, height: 720))
        window.setFrameAutosaveName("DefaultApp.MainWindow")
        window.delegate = self
        window.center()
        return window
    }

    private func makeIncomingWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "DefaultApp — Incoming Items"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: IncomingOpenView(store: incomingStore))
        window.delegate = self
        window.center()
        return window
    }

    private func perform(_ actions: [ApplicationLifecycleModel.Action]) {
        for action in actions {
            switch action {
            case .promoteToRegular:
                _ = NSApplication.shared.setActivationPolicy(.regular)
            case .showMainWindow:
                showMainWindow()
            case .showIncomingWindow:
                showRequests()
            case .closeIncomingWindow:
                isClosingIncomingProgrammatically = true
                incomingWindow?.close()
                isClosingIncomingProgrammatically = false
            case .presentTerminationConfirmation:
                presentTerminationConfirmation()
            case .discardWaitingItems:
                isDiscardingItems = true
                incomingStore.discardWaitingItems()
                isDiscardingItems = false
            case .discardAllItems:
                isDiscardingItems = true
                incomingStore.discardAllItems()
                isDiscardingItems = false
            case .cancelTermination:
                replyToPendingTermination(false)
            case .approveTermination:
                replyToPendingTermination(true)
            case .terminate:
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func observeIncomingState() {
        Publishers.CombineLatest(incomingStore.$requests, incomingStore.$isOpening)
            .sink { [weak self] requests, isOpening in
                guard let self else { return }
                let openingFinished = lastOpeningValue && !isOpening
                let queueBecameEmpty = lastPendingCount > 0 && requests.isEmpty
                lastPendingCount = requests.count
                lastOpeningValue = isOpening

                // Explicit lifecycle discards already have a termination action.
                // Keep the observed facts current without issuing it a second time.
                guard !isDiscardingItems else { return }
                if openingFinished {
                    let actions = model.openingFinished()
                    if !actions.isEmpty {
                        perform(actions)
                        return
                    }
                    if requests.isEmpty {
                        perform(model.queueBecameEmpty(
                            closeWhenHandled: appStore.closesIncomingWindowAfterHandling
                        ))
                        return
                    }
                }
                if queueBecameEmpty && !isOpening {
                    perform(model.queueBecameEmpty(
                        closeWhenHandled: appStore.closesIncomingWindowAfterHandling
                    ))
                }
            }
            .store(in: &observations)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === mainWindow {
            NSApplication.shared.terminate(sender)
            return false
        }
        if sender === incomingWindow,
           model.mode == .incomingOnly,
           !isClosingIncomingProgrammatically {
            NSApplication.shared.terminate(sender)
            return false
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // @Published emits before its backing property changes, so use the store's
        // synchronous count while queue callbacks are still observing the old array.
        let actions = model.requestedTermination(hasPendingItems: incomingStore.pendingRequestCount > 0)
        if actions == [.terminate] { return .terminateNow }
        guard !actions.isEmpty else { return .terminateCancel }
        terminationReplyPending = true
        perform(actions)
        return .terminateLater
    }

    private func presentTerminationConfirmation() {
        if mainWindow == nil && incomingWindow == nil { showRequests() }
        guard let window = mainWindow ?? incomingWindow else { return }
        window.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        alert.messageText = "Incoming items are still waiting"
        alert.informativeText = "Skip the remaining items and quit, or keep DefaultApp open to process them."
        alert.addButton(withTitle: "Skip Remaining and Quit")
        alert.addButton(withTitle: "Keep Processing")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                perform(model.confirmedSkipAndQuit(isOpening: incomingStore.isOpening))
            } else {
                perform(model.keptProcessing())
            }
        }
    }

    private func replyToPendingTermination(_ shouldTerminate: Bool) {
        guard terminationReplyPending else { return }
        terminationReplyPending = false
        NSApplication.shared.reply(toApplicationShouldTerminate: shouldTerminate)
    }
}
