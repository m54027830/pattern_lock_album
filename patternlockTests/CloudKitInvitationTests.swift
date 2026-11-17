import CloudKit
import XCTest
@testable import patternlock

final class CloudKitInvitationTests: XCTestCase {
    func testBuiltAppDeclaresCloudKitSharingSupport() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CKSharingSupported") as? Bool, true,
                       "The generated app Info.plist must include the CloudKit sharing declaration.")
    }

    func testPrivateOneTimeInvitationUsesAReadOnlyParticipant() throws {
        // This exercises CloudKit itself: addParticipant traps if the signed app
        // lacks icloud-extended-share-access / InProcessOneTimeLinks.
        let zone = "Share-" + UUID().uuidString
        let (share, participantID) = CloudKitVaultTransport.makeInvitationShare(zone: zone)
        XCTAssertEqual(share.recordID.zoneID.zoneName, zone)
        XCTAssertEqual(share.recordID.recordName, CKRecordNameZoneWideShare)
        XCTAssertEqual(share.publicPermission, .none)
        let recipient = try XCTUnwrap(share.participants.first { $0.participantID == participantID })
        XCTAssertEqual(recipient.role, .privateUser)
        XCTAssertEqual(recipient.permission, .readOnly)
        XCTAssertEqual(recipient.acceptanceStatus, .pending)
        XCTAssertNil(recipient.userIdentity.lookupInfo)
        XCTAssertEqual(share.participants.filter { $0.role != .owner }.count, 1)
    }
}
