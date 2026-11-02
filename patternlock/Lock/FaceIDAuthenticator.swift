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

    func authenticate(reason: String) async -> FaceIDResult {
        cancel()
        let context = LAContext()
        self.context = context
        context.localizedFallbackTitle = ""
        context.touchIDAuthenticationAllowableReuseDuration = 0
        defer { if self.context === context { self.context = nil }; context.invalidate() }
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error), context.biometryType == .faceID else {
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

nonisolated struct FaceIDChallenge: Equatable, Sendable {
    let id: UUID
    let vaultID: String
}

nonisolated enum VaultAccessError: LocalizedError {
    case chooseDummy, invalidDummy, faceIDRequired, changed, interrupted
    var errorDescription: String? {
        switch self {
        case .chooseDummy: "Choose a different vault to display when Face ID fails."
        case .invalidDummy: "The dummy vault is no longer available. Unlock with Face ID and choose another in settings."
        case .faceIDRequired: "Face ID must succeed to change these access settings. Make sure Face ID is enabled for Pattern on this device."
        case .changed: "Vault access changed during authentication. Enter your pattern again."
        case .interrupted: "Authentication was interrupted. Enter your pattern again."
        }
    }
}
