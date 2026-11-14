import SwiftUI
import UIKit
import XCTest
@testable import patternlock

@MainActor final class OnboardingRecoveryTests: XCTestCase {
    private let pattern = [0, 1, 2, 7, 12]
    private let customPhrase = "acorn amber anchor apple apron arrow atlas autumn bamboo beach"

    private func recoverySetup() -> OnboardingStore {
        let setup = OnboardingStore()
        setup.startSetup(); setup.chooseGrid()
        setup.submit(pattern); setup.submit(pattern)
        XCTAssertEqual(setup.step, .recovery)
        return setup
    }

    func testRecoveryRequiresCopyOrCompletedShare() {
        for copy in [false, true] {
            let setup = recoverySetup()
            XCTAssertTrue(setup.canSavePhrase)
            XCTAssertFalse(setup.canContinueRecovery)
            setup.confirmRecovery()
            XCTAssertEqual(setup.step, .recovery)
            XCTAssertNotNil(setup.error)
            setup.recordPhraseShare(completed: false, phraseID: setup.phraseID)
            XCTAssertFalse(setup.canContinueRecovery, "Cancelling the share sheet must not count as saving")
            if copy { setup.markPhraseCopied() }
            else { setup.recordPhraseShare(completed: true, phraseID: setup.phraseID) }
            XCTAssertTrue(setup.canContinueRecovery)
            XCTAssertNil(setup.error)
            setup.confirmRecovery()
            XCTAssertEqual(setup.step, .verifyRecovery)
        }
    }

    func testRecreatingPatternGeneratesNewPhraseAndResetsBothSaveActions() {
        let setup = recoverySetup()
        let oldPhrase = setup.phrase, oldID = setup.phraseID
        setup.markPhraseCopied()
        setup.recordPhraseShare(completed: true, phraseID: oldID)
        setup.back()
        XCTAssertEqual(setup.step, .pattern)
        XCTAssertTrue(setup.phrase.isEmpty)
        XCTAssertFalse(setup.copiedPhrase)
        XCTAssertFalse(setup.sharedPhrase)
        setup.submit(pattern); setup.submit(pattern)
        XCTAssertEqual(setup.step, .recovery)
        XCTAssertNotEqual(setup.phrase, oldPhrase)
        XCTAssertFalse(setup.copiedPhrase)
        XCTAssertFalse(setup.sharedPhrase)
        setup.recordPhraseShare(completed: true, phraseID: oldID)
        XCTAssertFalse(setup.canContinueRecovery, "A delayed share result belongs to the old phrase")
        setup.confirmRecovery()
        XCTAssertEqual(setup.step, .recovery)
        setup.markPhraseCopied(); setup.confirmRecovery()
        XCTAssertEqual(setup.step, .verifyRecovery)
    }

    func testCustomPhraseEditsAndModeChangesRequireSavingAgain() {
        let setup = recoverySetup()
        setup.markPhraseCopied()
        let generatedID = setup.phraseID
        setup.useCustomPhrase = true
        setup.customPhrase = "too short"
        XCTAssertFalse(setup.canSavePhrase)
        setup.markPhraseCopied()
        setup.recordPhraseShare(completed: true, phraseID: setup.phraseID)
        XCTAssertFalse(setup.copiedPhrase)
        XCTAssertFalse(setup.sharedPhrase)
        setup.customPhrase = customPhrase
        setup.recordPhraseShare(completed: true, phraseID: generatedID)
        XCTAssertFalse(setup.canContinueRecovery)
        setup.markPhraseCopied()
        XCTAssertTrue(setup.canContinueRecovery)
        let customID = setup.phraseID
        setup.customPhrase += " beacon"
        XCTAssertFalse(setup.canContinueRecovery)
        XCTAssertFalse(setup.copiedPhrase)
        setup.recordPhraseShare(completed: true, phraseID: customID)
        XCTAssertFalse(setup.canContinueRecovery)
        setup.recordPhraseShare(completed: true, phraseID: setup.phraseID)
        XCTAssertTrue(setup.canContinueRecovery)
        setup.useCustomPhrase = false
        XCTAssertFalse(setup.canContinueRecovery)
        XCTAssertFalse(setup.sharedPhrase)
    }

    func testMismatchAndEmptyConfirmationExplainHowToReturnToSamePhrase() async {
        for confirmation in ["", "a different phrase"] {
            let setup = recoverySetup()
            let phrase = setup.phrase
            setup.markPhraseCopied(); setup.confirmRecovery()
            setup.confirmation = confirmation
            // The button can be pressed even before the saved-phrase toggle.
            await setup.finish { _, _, _, _ in XCTFail("A mismatch must never create a vault") }
            XCTAssertEqual(setup.step, .verifyRecovery)
            XCTAssertTrue(setup.recoveryConfirmationMismatch)
            XCTAssertNotNil(setup.error)
            XCTAssertFalse(setup.busy)
            setup.back()
            XCTAssertEqual(setup.step, .recovery)
            XCTAssertEqual(setup.phrase, phrase, "Showing the phrase again must not replace it")
            XCTAssertTrue(setup.copiedPhrase)
            XCTAssertTrue(setup.confirmation.isEmpty)
            XCTAssertFalse(setup.savedPhrase)
            XCTAssertFalse(setup.recoveryConfirmationMismatch)
            XCTAssertNil(setup.error)
            setup.confirmRecovery()
            setup.confirmation = phrase; setup.savedPhrase = true
            var saves = 0
            await setup.finish { _, _, _, saved in
                XCTAssertEqual(saved, phrase)
                saves += 1
            }
            XCTAssertEqual(saves, 1)
            XCTAssertTrue(setup.phrase.isEmpty)
            XCTAssertFalse(setup.copiedPhrase)
            XCTAssertFalse(setup.canFinish)
        }
    }

    func testConfirmationRequiresSavedAcknowledgementAndCanRetrySaveFailure() async {
        let setup = recoverySetup()
        setup.useCustomPhrase = true; setup.customPhrase = customPhrase
        setup.recordPhraseShare(completed: true, phraseID: setup.phraseID)
        setup.confirmRecovery()
        setup.confirmation = "  " + customPhrase.uppercased().replacingOccurrences(of: " ", with: "\n  ") + "  "
        await setup.finish { _, _, _, _ in XCTFail("Saving outside Pattern must be acknowledged") }
        XCTAssertNotNil(setup.error)
        XCTAssertFalse(setup.recoveryConfirmationMismatch)
        setup.savedPhrase = true
        XCTAssertTrue(setup.canFinish)
        await setup.finish { _, _, _, _ in throw CocoaError(.fileWriteUnknown) }
        XCTAssertNotNil(setup.error)
        XCTAssertEqual(setup.step, .verifyRecovery)
        XCTAssertEqual(setup.phrase, customPhrase)
        XCTAssertTrue(setup.canFinish)
        XCTAssertFalse(setup.busy)
        var saves = 0
        await setup.finish { _, _, _, saved in
            XCTAssertEqual(saved, self.customPhrase)
            saves += 1
        }
        XCTAssertEqual(saves, 1)
        XCTAssertNil(setup.error)
        XCTAssertFalse(setup.sharedPhrase)
        XCTAssertFalse(setup.useCustomPhrase)
    }

    func testPhraseConfirmationKeepsSetupReadyWhilePurchaseOfferIsPresented() async {
        let setup = recoverySetup()
        setup.markPhraseCopied(); setup.confirmRecovery()
        XCTAssertFalse(setup.confirmRecoveryPhrase())
        setup.confirmation = setup.phrase; setup.savedPhrase = true
        let phrase = setup.phrase
        XCTAssertTrue(setup.confirmRecoveryPhrase())
        XCTAssertEqual(setup.step, .verifyRecovery)
        XCTAssertEqual(setup.phrase, phrase)
        XCTAssertFalse(setup.busy)
        XCTAssertTrue(setup.canFinish)
        var registrations = 0
        await setup.finish { _, _, _, recovery in
            registrations += 1
            XCTAssertEqual(recovery, phrase)
        }
        XCTAssertEqual(registrations, 1)
        XCTAssertTrue(setup.phrase.isEmpty)
    }

    func testShareSheetOnlyRecordsSuccessfulCompletion() async throws {
        let setup = recoverySetup()
        let phraseID = setup.phraseID
        let host = UIHostingController(rootView: OnboardingPhraseShareSheet(phrase: setup.phrase) { completed in
            setup.recordPhraseShare(completed: completed, phraseID: phraseID)
        })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true }
        await layout(window, host: host)
        let activity = try XCTUnwrap(activityController(in: host))
        let completion = try XCTUnwrap(activity.completionWithItemsHandler)
        completion(nil, false, nil, nil)
        await Task.yield()
        XCTAssertFalse(setup.canContinueRecovery)
        completion(nil, true, nil, CocoaError(.fileWriteUnknown))
        await Task.yield()
        XCTAssertFalse(setup.canContinueRecovery)
        completion(nil, true, nil, nil)
        await Task.yield()
        XCTAssertTrue(setup.canContinueRecovery)
    }

    func testRecoveryScreensRenderAcrossPhoneAndTabletSizes() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for size in [CGSize(width: 320, height: 700), CGSize(width: 393, height: 852), CGSize(width: 834, height: 1194)] {
            let setup = recoverySetup()
            let phrase = setup.phrase
            let host = UIHostingController(rootView: OnboardingView(setup: setup) { _, _, _, _ in
                XCTFail("Rendering setup must not create a vault")
            })
            let window = UIWindow(windowScene: scene)
            window.rootViewController = host; window.isHidden = false
            defer { window.isHidden = true }
            window.frame = CGRect(origin: .zero, size: size)
            host.traitOverrides.horizontalSizeClass = size.width < 600 ? .compact : .regular
            for state in ["Unsaved", "SaveOptions", "Copied", "Mismatch", "ShowPhrase"] {
                if state == "Copied" { setup.markPhraseCopied() }
                if state == "Mismatch" {
                    setup.confirmRecovery()
                    await setup.finish { _, _, _, _ in XCTFail("An empty phrase must not create a vault") }
                }
                if state == "ShowPhrase" { setup.back() }
                await layout(window, host: host)
                if state == "SaveOptions", let scroll = scrollView(in: host.view) {
                    let bottom = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                    scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
                    await layout(window, host: host)
                }
                XCTAssertEqual(setup.phrase, phrase)
                XCTAssertEqual(setup.canContinueRecovery, state != "Unsaved" && state != "SaveOptions")
                let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: screenshot)
                attachment.name = "Onboarding-\(state)-\(Int(size.width))"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    private func activityController(in controller: UIViewController) -> UIActivityViewController? {
        if let activity = controller as? UIActivityViewController { return activity }
        return controller.children.lazy.compactMap { self.activityController(in: $0) }.first
    }

    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }

    private func layout<Content: View>(_ window: UIWindow, host: UIHostingController<Content>) async {
        for _ in 0..<4 {
            window.setNeedsLayout(); window.layoutIfNeeded()
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            await Task.yield()
        }
    }
}
