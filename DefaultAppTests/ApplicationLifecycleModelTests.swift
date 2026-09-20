import XCTest
@testable import DefaultApp

final class ApplicationLifecycleModelTests: XCTestCase {
    func testNormalLaunchPromotesAndShowsMainWindow() {
        var model = ApplicationLifecycleModel()
        XCTAssertEqual(model.finishedLaunching(), [.promoteToRegular, .showMainWindow])
        XCTAssertEqual(model.mode, .regular)
    }

    func testColdIncomingLaunchShowsOnlyIncomingWindow() {
        var model = ApplicationLifecycleModel()
        XCTAssertEqual(model.receivedIncomingItems(), [.showIncomingWindow])
        XCTAssertEqual(model.finishedLaunching(), [])
        XCTAssertEqual(model.mode, .incomingOnly)
    }

    func testIncomingEventAfterNormalLaunchKeepsRegularMode() {
        var model = ApplicationLifecycleModel()
        _ = model.finishedLaunching()
        XCTAssertEqual(model.receivedIncomingItems(), [.showIncomingWindow])
        XCTAssertEqual(model.mode, .regular)
    }

    func testRegularEmptyQueueRespectsClosePreference() {
        var closing = ApplicationLifecycleModel()
        _ = closing.finishedLaunching()
        XCTAssertEqual(closing.queueBecameEmpty(closeWhenHandled: true), [.closeIncomingWindow])

        var retaining = ApplicationLifecycleModel()
        _ = retaining.finishedLaunching()
        XCTAssertEqual(retaining.queueBecameEmpty(closeWhenHandled: false), [])
    }

    func testIncomingOnlyEmptyQueueAlwaysTerminates() {
        var model = ApplicationLifecycleModel()
        _ = model.receivedIncomingItems()
        _ = model.finishedLaunching()
        XCTAssertEqual(model.queueBecameEmpty(closeWhenHandled: false), [.terminate])
    }

    func testTerminationWithoutWorkIsImmediate() {
        var model = ApplicationLifecycleModel()
        XCTAssertEqual(model.requestedTermination(hasPendingItems: false), [.terminate])
    }

    func testTerminationWithWorkPromptsOnlyOnce() {
        var model = ApplicationLifecycleModel()
        XCTAssertEqual(model.requestedTermination(hasPendingItems: true), [.presentTerminationConfirmation])
        XCTAssertEqual(model.requestedTermination(hasPendingItems: true), [])
    }

    func testKeepProcessingCancelsPromptAndShowsQueue() {
        var model = ApplicationLifecycleModel()
        _ = model.requestedTermination(hasPendingItems: true)
        XCTAssertEqual(model.keptProcessing(), [.cancelTermination, .showIncomingWindow])
    }

    func testConfirmedQuitDiscardsAndTerminatesWhenIdle() {
        var model = ApplicationLifecycleModel()
        _ = model.requestedTermination(hasPendingItems: true)
        XCTAssertEqual(model.confirmedSkipAndQuit(isOpening: false), [.discardAllItems, .approveTermination])
    }

    func testConfirmedQuitWaitsForInFlightOpen() {
        var model = ApplicationLifecycleModel()
        _ = model.requestedTermination(hasPendingItems: true)
        XCTAssertEqual(model.confirmedSkipAndQuit(isOpening: true), [.discardWaitingItems, .cancelTermination])
        XCTAssertEqual(model.openingFinished(), [.discardAllItems, .terminate])
    }

    func testKeepProcessingAfterSecondQuitCancelsDeferredTermination() {
        var model = ApplicationLifecycleModel()
        _ = model.finishedLaunching()
        XCTAssertEqual(model.requestedTermination(hasPendingItems: true), [.presentTerminationConfirmation])
        XCTAssertEqual(model.confirmedSkipAndQuit(isOpening: true), [.discardWaitingItems, .cancelTermination])

        XCTAssertEqual(model.requestedTermination(hasPendingItems: true), [.presentTerminationConfirmation])
        XCTAssertEqual(model.keptProcessing(), [.cancelTermination, .showIncomingWindow])

        XCTAssertEqual(model.openingFinished(), [])
    }
}
