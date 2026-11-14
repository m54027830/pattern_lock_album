import Foundation
import Observation

nonisolated enum PurchaseOffer: String, Identifiable, Sendable {
    case standard, special

    var id: String { rawValue }

    var productID: String {
        self == .standard ? PurchaseConfiguration.productID : PurchaseConfiguration.specialProductID
    }
}

/// One persisted window per local calendar day, shared by every purchase entry point.
@MainActor @Observable final class SpecialOfferStore {
    static let duration: TimeInterval = 10 * 60
    private static let storageKey = "proSpecialOfferWindow.v1"

    private struct Window: Codable {
        let startedAt: Date
        var expiresAt: Date
        var dismissed: Bool
    }

    @ObservationIgnored private let defaults: UserDefaults
    private var window: Window?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey) {
            window = try? JSONDecoder().decode(Window.self, from: data)
        }
    }

    // Avoid Swift 6.2's synthesized isolated-deinit crash on iOS 26.2.
    deinit {}

    func remainingSeconds(at now: Date = .now) -> Int {
        guard let window, now >= window.startedAt else { return 0 }
        return max(0, Int(ceil(min(Self.duration, window.expiresAt.timeIntervalSince(now)))))
    }

    func showsBanner(at now: Date = .now) -> Bool {
        window?.dismissed == true && remainingSeconds(at: now) > 0
    }

    @discardableResult
    func begin(at now: Date = .now, calendar: Calendar = .current) -> Bool {
        if remainingSeconds(at: now) > 0 { return true }
        if let window {
            // A backwards clock or another visit on the same day cannot issue a new window.
            guard calendar.startOfDay(for: now) > calendar.startOfDay(for: window.startedAt) else { return false }
        }
        window = Window(startedAt: now, expiresAt: now.addingTimeInterval(Self.duration), dismissed: false)
        persist()
        return true
    }

    func dismiss() {
        window?.dismissed = true
        persist()
    }

    func end(at now: Date = .now) {
        guard var window else { return }
        window.expiresAt = min(window.expiresAt, now)
        window.dismissed = false
        self.window = window
        persist()
    }

    private func persist() {
        guard let window, let data = try? JSONEncoder().encode(window) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    static func countdown(_ seconds: Int) -> String {
        String(format: "%02d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
    }
}

@MainActor @Observable final class PurchaseFlow {
    var offer: PurchaseOffer?
    private var pendingOffer: PurchaseOffer?

    init(offer: PurchaseOffer? = .standard) { self.offer = offer }

    deinit {}

    func present(_ offer: PurchaseOffer) {
        pendingOffer = nil
        self.offer = offer
    }

    func close(purchases: PurchaseStore) {
        guard let offer, !purchases.busy, purchases.status != .checking else { return }
        pendingOffer = !purchases.isUnlimited && offer == .standard ? .special : nil
        if !purchases.isUnlimited, offer == .special { purchases.specialOffers.dismiss() }
        self.offer = nil
    }

    func showRegularOffer() {
        pendingOffer = .standard
        offer = nil
    }

    func cancel() {
        pendingOffer = nil
        offer = nil
    }

    /// Called only by the sheet's onDismiss, after its dismissal animation ends.
    /// True completes the entire sequence (and lets onboarding open the vault).
    func presentationDidDismiss(purchases: PurchaseStore, now: Date = .now, calendar: Calendar = .current) -> Bool {
        let next = pendingOffer
        pendingOffer = nil
        guard !purchases.isUnlimited, let next else { return true }
        if next == .special, !purchases.beginSpecialOffer(at: now, calendar: calendar) { return true }
        purchases.clearFeedback()
        offer = next
        return false
    }
}
