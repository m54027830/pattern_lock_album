import Observation
import UIKit

nonisolated enum AppIcon: String, CaseIterable, Identifiable, Sendable {
    case classic = "Classic", square = "Square", triangles = "Triangles", checker = "Checker"
    case stripes = "Stripes", rings = "Rings", diamonds = "Diamonds", waves = "Waves"
    case hexagons = "Hexagons", mosaic = "Mosaic"

    var id: String { rawValue }
    var alternateName: String? { self == .classic ? nil : "AppIcon" + rawValue }
    var previewAsset: String { "IconPreview" + rawValue }
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
        }
    }
}

@MainActor protocol AppIconChanging {
    var supportsAlternateIcons: Bool { get }
    var alternateIconName: String? { get }
    func setAlternateIconName(_ name: String?) async throws
}

@MainActor private struct SystemAppIconClient: AppIconChanging {
    var supportsAlternateIcons: Bool { UIApplication.shared.supportsAlternateIcons }
    var alternateIconName: String? { UIApplication.shared.alternateIconName }
    func setAlternateIconName(_ name: String?) async throws {
        try await UIApplication.shared.setAlternateIconName(name)
    }
}

@MainActor @Observable final class AppIconStore {
    static let shared = AppIconStore()
    private(set) var selected: AppIcon
    private(set) var pending: AppIcon?
    private(set) var errorMessage: String?
    @ObservationIgnored private let client: any AppIconChanging

    var isChanging: Bool { pending != nil }
    var supportsAlternateIcons: Bool { client.supportsAlternateIcons }

    init(client: (any AppIconChanging)? = nil) {
        let client = client ?? SystemAppIconClient()
        self.client = client
        selected = AppIcon.allCases.first { $0.alternateName == client.alternateIconName } ?? .classic
    }

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
        do {
            try await client.setAlternateIconName(icon.alternateName)
            refresh()
        } catch {
            refresh()
            // iOS can apply the icon before its confirmation alert fails.
            // Report failure only if the requested icon did not become current.
            if client.alternateIconName != icon.alternateName { errorMessage = error.localizedDescription }
        }
    }

    func dismissError() { errorMessage = nil }
}
