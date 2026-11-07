import CloudKit
import Foundation

nonisolated protocol VaultCloudTransport: Sendable {
    func accountID() async throws -> String
    func backups() async throws -> [CloudBackupSummary]
    func uploadBackup(id: String, archive: URL, metadata: Data, recovery: CloudEnvelope) async throws
    func downloadBackup(id: String) async throws -> CloudVaultDownload
    func uploadShare(zone: String, archive: URL, metadata: Data) async throws
    func createInvitation(zone: String) async throws -> URL
    func publishInvitation(id: String, envelope: CloudEnvelope) async throws
    func invitation(id: String) async throws -> CloudEnvelope
    func acceptInvitation(_ url: URL, expectedZone: String) async throws -> (zone: String, owner: String)
    func sharedMetadata(zone: String, owner: String) async throws -> Data
    func downloadShare(zone: String, owner: String) async throws -> CloudVaultDownload
    func delete(_ deletion: CloudDeletion) async throws
}

/// Only authenticated ciphertext enters a CKAsset. A record save publishes the
/// asset and metadata together, so a failed upload leaves the previous backup.
actor CloudKitVaultTransport: VaultCloudTransport {
    static let containerID = "iCloud.jp.gm.patternlock"
    private let container: CKContainer
    init(container: CKContainer = CKContainer(identifier: containerID)) { self.container = container }

    func accountID() async throws -> String {
        guard try await container.accountStatus() == .available else { throw VaultCloudError.signedOut }
        return try await container.userRecordID().recordName
    }

    func backups() async throws -> [CloudBackupSummary] {
        let database = container.privateCloudDatabase
        let query = CKQuery(recordType: "PatternVaultBackup", predicate: NSPredicate(value: true))
        var page = try await database.records(matching: query, desiredKeys: [], resultsLimit: 100)
        var result: [CloudBackupSummary] = []
        while true {
            for (_, recordResult) in page.matchResults {
                let record = try recordResult.get()
                result.append(CloudBackupSummary(id: record.recordID.recordName, date: record.modificationDate ?? .distantPast))
            }
            guard let cursor = page.queryCursor else { break }
            try Task.checkCancellation()
            page = try await database.records(continuingMatchFrom: cursor, desiredKeys: [], resultsLimit: 100)
        }
        return result.sorted { $0.date > $1.date }
    }

    func uploadBackup(id: String, archive: URL, metadata: Data, recovery: CloudEnvelope) async throws {
        try await upload(type: "PatternVaultBackup", id: CKRecord.ID(recordName: id), archive: archive, metadata: metadata, recovery: recovery)
    }

    func downloadBackup(id: String) async throws -> CloudVaultDownload {
        try await download(database: container.privateCloudDatabase, id: CKRecord.ID(recordName: id))
    }

    func uploadShare(zone: String, archive: URL, metadata: Data) async throws {
        let zoneID = CKRecordZone.ID(zoneName: zone)
        _ = try await container.privateCloudDatabase.save(CKRecordZone(zoneID: zoneID))
        try Task.checkCancellation()
        try await upload(type: "PatternSharedVault", id: CKRecord.ID(recordName: "vault", zoneID: zoneID), archive: archive, metadata: metadata, recovery: nil)
    }

    func createInvitation(zone: String) async throws -> URL {
        let share = CKShare(recordZoneID: CKRecordZone.ID(zoneName: zone))
        share.publicPermission = .none
        let participant = CKShare.Participant.oneTimeURLParticipant()
        participant.permission = .readOnly
        share.addParticipant(participant)
        share[CKShare.SystemFieldKey.title] = "Shared vault" as CKRecordValue
        guard let saved = try await container.privateCloudDatabase.save(share) as? CKShare,
              let url = saved.oneTimeURL(for: participant.participantID) else { throw VaultCloudError.invalidData }
        return url
    }

    func publishInvitation(id: String, envelope: CloudEnvelope) async throws {
        let record = CKRecord(recordType: "PatternShareInvitation", recordID: CKRecord.ID(recordName: id))
        record["envelope"] = try JSONEncoder().encode(envelope) as CKRecordValue
        _ = try await container.publicCloudDatabase.save(record)
    }

    func invitation(id: String) async throws -> CloudEnvelope {
        let record = try await container.publicCloudDatabase.record(for: CKRecord.ID(recordName: id))
        guard let data = record["envelope"] as? Data, data.count < 65_536 else { throw VaultCloudError.invalidData }
        return try JSONDecoder().decode(CloudEnvelope.self, from: data)
    }

    func acceptInvitation(_ url: URL, expectedZone: String) async throws -> (zone: String, owner: String) {
        guard url.scheme == "https", url.host == "www.icloud.com" || url.host == "icloud.com" else { throw VaultCloudError.invalidPhrase }
        let metadata = try await container.shareMetadata(for: url)
        guard metadata.containerIdentifier == Self.containerID,
              metadata.share.recordID.zoneID.zoneName == expectedZone,
              metadata.share.publicPermission == .none,
              metadata.participantPermission == .readOnly else { throw VaultCloudError.unavailable }
        _ = try await container.accept(metadata)
        let zone = metadata.share.recordID.zoneID
        return (zone.zoneName, zone.ownerName)
    }

    func sharedMetadata(zone: String, owner: String) async throws -> Data {
        let id = CKRecord.ID(recordName: "vault", zoneID: CKRecordZone.ID(zoneName: zone, ownerName: owner))
        let records = try await container.sharedCloudDatabase.records(for: [id], desiredKeys: ["metadata"])
        guard let result = records[id], let data = try result.get()["metadata"] as? Data else { throw VaultCloudError.invalidData }
        return data
    }

    func downloadShare(zone: String, owner: String) async throws -> CloudVaultDownload {
        try await download(database: container.sharedCloudDatabase, id: CKRecord.ID(recordName: "vault", zoneID: CKRecordZone.ID(zoneName: zone, ownerName: owner)))
    }

    func delete(_ deletion: CloudDeletion) async throws {
        // Revoke access first. Leaving an encrypted lookup record temporarily is
        // harmless; leaving an accessible share after reporting success is not.
        if let zone = deletion.zoneName {
            do { _ = try await container.privateCloudDatabase.deleteRecordZone(withID: CKRecordZone.ID(zoneName: zone)) }
            catch where Self.isMissing(error) {}
            do { _ = try await container.publicCloudDatabase.deleteRecord(withID: CKRecord.ID(recordName: deletion.recordID)) }
            catch where Self.isMissing(error) {}
        } else {
            do { _ = try await container.privateCloudDatabase.deleteRecord(withID: CKRecord.ID(recordName: deletion.recordID)) }
            catch where Self.isMissing(error) {}
        }
    }

    private func upload(type: String, id: CKRecord.ID, archive: URL, metadata: Data, recovery: CloudEnvelope?) async throws {
        let database = container.privateCloudDatabase
        let record: CKRecord
        do {
            let records = try await database.records(for: [id], desiredKeys: [])
            guard let result = records[id] else { throw VaultCloudError.invalidData }
            record = try result.get()
        }
        catch where Self.isMissing(error) { record = CKRecord(recordType: type, recordID: id) }
        try Task.checkCancellation()
        record["payload"] = CKAsset(fileURL: archive)
        record["metadata"] = metadata as CKRecordValue
        record["recovery"] = try recovery.map { try JSONEncoder().encode($0) } as CKRecordValue?
        // Default ifServerRecordUnchanged avoids silently overwriting a newer save.
        _ = try await database.save(record)
    }

    private func download(database: CKDatabase, id: CKRecord.ID) async throws -> CloudVaultDownload {
        let record = try await database.record(for: id)
        try Task.checkCancellation()
        guard let source = (record["payload"] as? CKAsset)?.fileURL,
              let metadata = record["metadata"] as? Data else { throw VaultCloudError.invalidData }
        let directory = FileManager.default.temporaryDirectory.appending(path: "CloudVault-" + UUID().uuidString)
        try LocalVaultStorage.prepareDirectory(directory)
        do {
            let target = directory.appending(path: "encrypted.patternbackup")
            try FileManager.default.copyItem(at: source, to: target)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: target.path)
            let recovery = try (record["recovery"] as? Data).map { try JSONDecoder().decode(CloudEnvelope.self, from: $0) }
            return CloudVaultDownload(url: target, metadata: metadata, recoveryEnvelope: recovery)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    nonisolated static func isMissing(_ error: Error) -> Bool {
        guard let error = error as? CKError else { return false }
        return error.code == .unknownItem || error.code == .zoneNotFound || error.code == .userDeletedZone
    }
}
