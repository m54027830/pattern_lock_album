import LocalAuthentication
import XCTest
@testable import patternlock

@MainActor final class DeviceBiometricsTests: XCTestCase {
    func testFaceIDAndTouchIDUseFreshBiometricsWithoutPasscodeFallback() async {
        for kind in [LABiometryType.faceID, .touchID] {
            let context = BiometricContextStub(kind: kind)
            let authenticator = FaceIDAuthenticator(makeContext: { context })
            let result = await authenticator.authenticate(reason: "Unlock test vault")
            XCTAssertEqual(result, .authenticated)
            XCTAssertEqual(context.evaluatedPolicies, [.deviceOwnerAuthenticationWithBiometrics])
            XCTAssertEqual(context.localizedFallbackTitle, "")
            XCTAssertEqual(context.touchIDAuthenticationAllowableReuseDuration, 0)
            XCTAssertTrue(context.invalidated)
        }
    }

    func testUnavailableBiometricsDoNotTryDevicePasscode() async {
        let context = BiometricContextStub(kind: .touchID, available: false)
        let authenticator = FaceIDAuthenticator(makeContext: { context })
        let result = await authenticator.authenticate(reason: "Unlock test vault")
        XCTAssertEqual(result, .failed)
        XCTAssertTrue(context.evaluatedPolicies.isEmpty)
        XCTAssertTrue(context.invalidated)
    }

    func testTouchIDFailureAndInterruptionKeepExistingOutcomes() async {
        for (code, expected) in [(LAError.authenticationFailed, FaceIDResult.failed), (.userCancel, .failed), (.systemCancel, .interrupted)] {
            let context = BiometricContextStub(kind: .touchID)
            context.evaluationError = NSError(domain: LAError.errorDomain, code: code.rawValue)
            let authenticator = FaceIDAuthenticator(makeContext: { context })
            let result = await authenticator.authenticate(reason: "Unlock test vault")
            XCTAssertEqual(result, expected)
        }
    }
}

// LAContext is injected only at its system boundary. These tests exercise the
// production authenticator, including its selected policy and error mapping.
private final class BiometricContextStub: LAContext, @unchecked Sendable {
    private let kind: LABiometryType
    private let available: Bool
    var evaluatedPolicies: [LAPolicy] = []
    var evaluationError: Error?
    var invalidated = false

    init(kind: LABiometryType, available: Bool = true) {
        self.kind = kind
        self.available = available
        super.init()
    }

    override var biometryType: LABiometryType { kind }
    override func canEvaluatePolicy(_ policy: LAPolicy, error: NSErrorPointer) -> Bool { available }
    override func evaluatePolicy(_ policy: LAPolicy, localizedReason: String, reply: @escaping @Sendable (Bool, Error?) -> Void) {
        evaluatedPolicies.append(policy)
        reply(evaluationError == nil, evaluationError)
    }
    override func invalidate() { invalidated = true }
}
