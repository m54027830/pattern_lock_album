import Foundation
import LocalAuthentication

nonisolated enum FaceIDResult: Sendable {
    case authenticated, failed, interrupted
}

@MainActor protocol FaceIDAuthenticating: Sendable {
    func authenticate(reason: String) async -> FaceIDResult
    func cancel()
}

@MainActor final class FaceIDAuthenticator: FaceIDAuthenticating {
    private var context: LAContext?
    private let makeContext: () -> LAContext

    init(makeContext: @escaping () -> LAContext = { LAContext() }) {
        self.makeContext = makeContext
    }

    func authenticate(reason: String) async -> FaceIDResult {
        cancel()
        let context = makeContext()
        self.context = context
        context.localizedFallbackTitle = ""
        context.touchIDAuthenticationAllowableReuseDuration = 0
        defer { if self.context === context { self.context = nil }; context.invalidate() }
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error),
              context.biometryType == .faceID || context.biometryType == .touchID else {
            return .failed
        }
        return await withTaskCancellationHandler {
            do {
                let accepted = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
                return Task.isCancelled ? .interrupted : accepted ? .authenticated : .failed
            } catch {
                if Task.isCancelled { return .interrupted }
                if let error = error as? LAError, [.appCancel, .systemCancel, .invalidContext].contains(error.code) { return .interrupted }
                // Cancellation by the user, no match, denial, and lockout all
                // show the chosen dummy. They never activate duress.
                return .failed
            }
        } onCancel: {
            context.invalidate()
        }
    }

    func cancel() { context?.invalidate(); context = nil }
}

/// Keep the existing credential keys and authentication flow compatible with
/// saved vaults; the same biometric requirement uses this device's hardware.
nonisolated enum DeviceBiometrics {
    static let usesTouchID: Bool = {
        let context = LAContext()
        defer { context.invalidate() }
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType == .touchID
    }()

    static var name: String { usesTouchID ? "Touch ID" : "Face ID" }
    static var symbol: String { usesTouchID ? "touchid" : "faceid" }
}

nonisolated struct FaceIDChallenge: Equatable, Sendable {
    let id: UUID
    let vaultID: String
}

nonisolated enum VaultAccessError: LocalizedError {
    case chooseDummy, invalidDummy, faceIDRequired, changed, interrupted
    var errorDescription: String? {
        switch self {
        case .chooseDummy: String(localized: "Choose a different vault to display when \(DeviceBiometrics.name) fails.")
        case .invalidDummy: String(localized: "The dummy vault is no longer available. Unlock with \(DeviceBiometrics.name) and choose another in settings.")
        case .faceIDRequired: String(localized: "\(DeviceBiometrics.name) must succeed to change these access settings. Make sure \(DeviceBiometrics.name) is enabled for Pattern on this device.")
        case .changed: String(localized: "Vault access changed during authentication. Enter your pattern again.")
        case .interrupted: String(localized: "Authentication was interrupted. Enter your pattern again.")
        }
    }
}
