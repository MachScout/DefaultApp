struct ApplicationLifecycleModel {
    enum Mode: Equatable { case launching, regular, incomingOnly }

    enum Action: Equatable {
        case promoteToRegular
        case showMainWindow
        case showIncomingWindow
        case closeIncomingWindow
        case presentTerminationConfirmation
        case discardWaitingItems
        case discardAllItems
        case cancelTermination
        case approveTermination
        case terminate
    }

    private(set) var mode: Mode = .launching
    private(set) var isTerminationPromptVisible = false
    private var receivedIncomingDuringLaunch = false
    private var waitsForOpenBeforeTermination = false

    mutating func receivedIncomingItems() -> [Action] {
        if mode == .launching { receivedIncomingDuringLaunch = true }
        return [.showIncomingWindow]
    }

    mutating func finishedLaunching() -> [Action] {
        if receivedIncomingDuringLaunch {
            mode = .incomingOnly
            return []
        }
        mode = .regular
        return [.promoteToRegular, .showMainWindow]
    }

    mutating func queueBecameEmpty(closeWhenHandled: Bool) -> [Action] {
        switch mode {
        case .incomingOnly: return [.terminate]
        case .regular: return closeWhenHandled ? [.closeIncomingWindow] : []
        case .launching: return []
        }
    }

    mutating func requestedTermination(hasPendingItems: Bool) -> [Action] {
        guard hasPendingItems else { return [.terminate] }
        guard !isTerminationPromptVisible else { return [] }
        isTerminationPromptVisible = true
        return [.presentTerminationConfirmation]
    }

    mutating func confirmedSkipAndQuit(isOpening: Bool) -> [Action] {
        isTerminationPromptVisible = false
        if isOpening {
            waitsForOpenBeforeTermination = true
            return [.discardWaitingItems, .cancelTermination]
        }
        return [.discardAllItems, .approveTermination]
    }

    mutating func keptProcessing() -> [Action] {
        isTerminationPromptVisible = false
        waitsForOpenBeforeTermination = false
        return [.cancelTermination, .showIncomingWindow]
    }

    mutating func openingFinished() -> [Action] {
        guard waitsForOpenBeforeTermination else { return [] }
        waitsForOpenBeforeTermination = false
        return [.discardAllItems, .terminate]
    }
}
