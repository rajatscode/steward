//
//  ChatViewModelEmptyStateTests.swift
//  StewardTests
//
//  Regression for "send 'walk me through it' → chat refreshes back to
//  the original greeting". Root cause: `send(_)` sets `hasAnyHistory =
//  true` to dismiss the empty state, then `refreshHistoryFlags()` runs
//  after the turn and re-reads `COUNT(*) FROM events WHERE actor='user'`.
//  Branch B turns produce zero tool calls and zero user-actor events,
//  so `hasAnyHistory` flips back to false and the empty-state greeting
//  + chips overwrite the in-memory transcript. The user's input bubble
//  + the coordinator's reply both vanish from view.
//
//  Fix: `shouldShowEmptyState` also gates on `messages.isEmpty`, so the
//  in-memory transcript holds the empty state at bay even when no
//  events landed in the DB. This file pins that behavior.
//

import XCTest
@testable import Steward

final class ChatViewModelEmptyStateTests: XCTestCase {

    @MainActor
    func test_shouldShowEmptyState_isTrueOnFreshViewModel() {
        let vm = ChatViewModel()
        XCTAssertTrue(vm.shouldShowEmptyState)
    }

    @MainActor
    func test_shouldShowEmptyState_isFalseAfterMessageAppended_evenWithoutHistoryFlag() {
        let vm = ChatViewModel()
        // Drive a known-public path that appends a message WITHOUT also
        // setting hasAnyHistory to true: a malformed notification tap.
        vm.acceptNotificationTap(.malformed(reason: "decode_failed"))

        XCTAssertEqual(vm.messages.count, 1, "precondition: malformed tap should produce a systemNote")
        XCTAssertFalse(vm.hasAnyHistory, "precondition: malformed taps don't set hasAnyHistory")
        XCTAssertFalse(vm.hasAnyDomains, "precondition: no domains seeded")
        XCTAssertFalse(
            vm.shouldShowEmptyState,
            "the in-memory transcript must hold the empty state at bay; otherwise the user's bubbles vanish when refreshHistoryFlags() zeros hasAnyHistory"
        )
    }

    @MainActor
    func test_shouldShowEmptyState_isFalseAfterRoutedTap_whichAlsoSetsHistoryFlag() {
        let vm = ChatViewModel()
        let context = NotificationActionContext(
            kind: .windDown,
            domain: "health",
            instrumentID: nil,
            commitmentID: nil,
            suggestedPrompt: "test"
        )
        vm.acceptNotificationTap(.routed(context))
        XCTAssertEqual(vm.messages.count, 1)
        XCTAssertTrue(vm.hasAnyHistory)
        XCTAssertFalse(vm.shouldShowEmptyState)
    }
}
