import Observation
import UIKit

nonisolated enum AppIcon: String, CaseIterable, Identifiable, Sendable {
    case classic = "Classic", square = "Square", triangles = "Triangles", checker = "Checker"
    case stripes = "Stripes", rings = "Rings", diamonds = "Diamonds", waves = "Waves"
    case hexagons = "Hexagons", mosaic = "Mosaic"
    case calculator = "Calculator", printer = "Printer", wifi = "WiFi", chatbot = "Chatbot"
    case notes = "Notes", weather = "Weather", clock = "Clock", compass = "Compass"

    static let utilityIcons: [AppIcon] = [.calculator, .printer, .wifi, .chatbot, .notes, .weather, .clock, .compass]
    static let patternIcons: [AppIcon] = [.square, .triangles, .checker, .stripes, .rings, .diamonds, .waves, .hexagons, .mosaic]

    var id: String { rawValue }
    var alternateName: String? { self == .classic ? nil : "AppIcon" + rawValue }
    var previewAsset: String { "IconPreview" + rawValue }
    var shortcutName: String { Self.utilityIcons.contains(self) ? title : "Pattern" }
    var title: String {
        switch self {
        case .classic: String(localized: "Classic")
        case .square: String(localized: "Square")
        case .triangles: String(localized: "Triangles")
        case .checker: String(localized: "Checker")
        case .stripes: String(localized: "Stripes")
        case .rings: String(localized: "Rings")
        case .diamonds: String(localized: "Diamonds")
        case .waves: String(localized: "Waves")
        case .hexagons: String(localized: "Hexagons")
        case .mosaic: String(localized: "Mosaic")
        case .calculator: String(localized: "Calculator")
        case .printer: String(localized: "Printer")
        case .wifi: String(localized: "Wi-Fi")
        case .chatbot: String(localized: "Chatbot")
        case .notes: String(localized: "Notes")
        case .weather: String(localized: "Weather")
        case .clock: String(localized: "Clock")
        case .compass: String(localized: "Compass")
        }
    }
}

@MainActor protocol AppIconChanging {
    var supportsAlternateIcons: Bool { get }
    var alternateIconName: String? { get }
    var isApplicationActive: Bool { get }
    func setAlternateIconName(_ name: String?) async throws
}

@MainActor private struct SystemAppIconClient: AppIconChanging {
    var supportsAlternateIcons: Bool { UIApplication.shared.supportsAlternateIcons }
    var alternateIconName: String? { UIApplication.shared.alternateIconName }
    var isApplicationActive: Bool { UIApplication.shared.applicationState == .active }
    func setAlternateIconName(_ name: String?) async throws {
        if let name {
            // An unregistered name can leave iOS's icon-confirmation service busy.
            // Reject it before requesting a change, including in a misconfigured build.
            let key = UIDevice.current.userInterfaceIdiom == .pad ? "CFBundleIcons~ipad" : "CFBundleIcons"
            let icons = Bundle.main.object(forInfoDictionaryKey: key) as? [String: Any]
            let alternates = icons?["CFBundleAlternateIcons"] as? [String: Any]
            guard alternates?[name] != nil else {
                throw CocoaError(.fileNoSuchFile)
            }
        }
        try await UIApplication.shared.setAlternateIconName(name)
    }
}

@MainActor @Observable final class AppIconStore {
    static let shared = AppIconStore()
    private(set) var selected: AppIcon
    private(set) var pending: AppIcon?
    private(set) var errorMessage: String?
    @ObservationIgnored private let client: any AppIconChanging
    @ObservationIgnored private let retryDelay: @MainActor (Duration) async throws -> Void

    var isChanging: Bool { pending != nil }
    var supportsAlternateIcons: Bool { client.supportsAlternateIcons }

    init(client: (any AppIconChanging)? = nil,
         retryDelay: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        let client = client ?? SystemAppIconClient()
        self.client = client
        self.retryDelay = retryDelay
        selected = AppIcon.allCases.first { $0.alternateName == client.alternateIconName } ?? .classic
    }

    // Avoid Swift 6.2's synthesized isolated-deinit crash on iOS 26.2.
    deinit {}

    func refresh() {
        // The OS owns this preference, including persistence across launches.
        selected = AppIcon.allCases.first { $0.alternateName == client.alternateIconName } ?? .classic
    }

    func select(_ icon: AppIcon) async {
        guard !isChanging else { return }
        errorMessage = nil
        refresh()
        // A previous build may have used an icon this version no longer lists.
        // Compare the OS identifier so Classic can still reset that selection.
        guard client.alternateIconName != icon.alternateName else { return }
        guard supportsAlternateIcons else {
            errorMessage = String(localized: "App icon changes aren’t available on this device.")
            return
        }
        pending = icon
        defer { pending = nil }
        for attempt in 0..<3 {
            guard !Task.isCancelled else { return }
            refresh()
            guard client.alternateIconName != icon.alternateName else { return }
            guard client.isApplicationActive else { errorMessage = Self.busyMessage; return }
            do {
                try await client.setAlternateIconName(icon.alternateName)
                refresh()
                return
            } catch {
                refresh()
                // iOS can apply the icon before its confirmation alert fails.
                // Don't retry an already applied change or show a false failure.
                guard client.alternateIconName != icon.alternateName else { return }
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                let failure = error as NSError
                let temporarilyBusy = failure.domain == NSPOSIXErrorDomain && failure.code == Int(POSIXErrorCode.EAGAIN.rawValue)
                guard temporarilyBusy, attempt < 2 else {
                    errorMessage = temporarilyBusy ? Self.busyMessage : error.localizedDescription
                    return
                }
                // Keep requests serialized while iOS releases its confirmation token.
                do { try await retryDelay(.milliseconds(500 * (attempt + 1))) }
                catch { return }
            }
        }
    }

    private static var busyMessage: String {
        String(localized: "iOS is still finishing an app icon change. Wait a moment, then try again. If it keeps happening, restart your device.")
    }

    func dismissError() { errorMessage = nil }
}
