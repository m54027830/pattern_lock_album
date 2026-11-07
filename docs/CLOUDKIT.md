# CloudKit configuration and verification

Container: `iCloud.jp.gm.patternlock`. App ID: `jp.gm.patternlock`.

The app uses CloudKit directly, without an application server. Personal backups
are in each user's private database. Shared copies are in separate private zones,
one per recipient, exposed through Apple's shared database after acceptance.
Only encrypted invitation envelopes use the public database.

## Signing

Associate the container with the App ID, enable CloudKit and Push Notifications,
and keep Data Protection at Complete Protection. Regenerate both manual profiles
(`patternlock Development (matt)` and `patternlock AppStore (matt)`) if their
entitlements predate these capabilities. The target uses
`patternlock/patternlock.entitlements`; Debug selects Development/development and
Release selects Production/production for CloudKit/APNs respectively.

This implementation performs cloud work while the app is open. It does not
register push subscriptions or request a Background Mode. It therefore does not
need to read protected media while the phone is locked. Push entitlement is
included for CloudKit compatibility and future change subscriptions.

## Record types and permissions

In CloudKit Console, select this container and its **Development** environment.
Create these types/fields (Data means Bytes in the console). Fields are optional
at the schema level; the client validates required fields when reading.

| Record type | Fields | Used in |
| --- | --- | --- |
| `PatternVaultBackup` | `payload`: Asset; `metadata`: Bytes; `recovery`: Bytes | Private default zone |
| `PatternSharedVault` | `payload`: Asset; `metadata`: Bytes; `recovery`: Bytes | Private zone `Share-<UUID>`, shared read-only |
| `PatternShareInvitation` | `envelope`: Bytes | Public default zone |

Add a **QUERYABLE** index on `recordName` for `PatternVaultBackup` so the private
backup list's `TRUEPREDICATE` query works. The other reads use exact record IDs;
no public invitation query index is needed.

For `PatternShareInvitation`, grant **Create** to `_icloud`, **Read** to `_icloud`,
and **Read/Write** to `_creator`. Do not grant Write to `_icloud` or `_world`.
The app requires iCloud sign-in to create or claim an invitation. Invitation
records must be readable by another signed-in account, while only their creator
can change/delete them. Do not grant public read/write on backup or media types.
Private records and shared zones are governed by private-database access and
the `CKShare` participant permissions, respectively.

Run a Debug build with a development profile to exercise these types. Then
deploy the additive schema and indexes to **Production** in CloudKit Console
before using TestFlight/App Store builds. Development data is not copied to
production. Never reset an environment or delete an existing schema to install
these types. If the container already has types, retain them.

The local `cktool` currently has no management token configured. No remote schema
or permissions were changed by this implementation. An admin can perform the
above steps in CloudKit Console. Do not paste management tokens into chat.

### Restore error: `Field 'recordName' is not marked queryable`

The backup-list query requires the index above. This error occurs before the
app downloads or decrypts a backup; it is a container schema configuration error.

1. Open [CloudKit Console](https://icloud.developer.apple.com/), select the app's
   developer team (`K9VR4GV3NX`), then container `iCloud.jp.gm.patternlock`.
2. Select **Development** for the app's Debug build from Xcode.
3. Under **Schema → Indexes**, add an index with record type
   `PatternVaultBackup`, name `backupRecordNameQueryable`, type **QUERYABLE**,
   and field **recordName**, then save it.
4. Reopen Restore from iCloud after the index becomes available.
5. For Release, TestFlight, and App Store builds, deploy the schema/index change
   to **Production** and verify that the index is present there as well.

Do not add a new custom field called `recordName`; use the existing system field.
No app rebuild is needed for this index change. No public database permissions
need to change. See Apple's
[schema and index instructions](https://developer.apple.com/documentation/cloudkit/inspecting-and-editing-an-icloud-container-s-schema).

## Device verification before release

Use disposable test vaults and two physical devices with **different** Apple
Accounts, both using the same CloudKit environment. Also test a second device
on the recipient's account. Tests with the injected transport verify the app's
logic, not Apple's claim semantics, quotas, account permissions, or delivery.

1. Create a vault with photos, a video, and folders. Backup must initially be
   off. Enable it with the correct recovery phrase. Wait for a completed date.
2. Confirm cloud payloads are CKAssets and encrypted metadata/envelopes. No
   readable names, filenames, pattern, recovery phrase, or archive secret should
   appear in fields. Sizes, timestamps, and account metadata remain observable.
3. Add/remove media while the vault is open. Verify backup completion updates.
   Interrupt an upload, reopen, and verify retry. Check quota/network errors
   without losing the previous completed backup.
4. Reinstall the app on a test device. Confirm onboarding appears, then use
   Restore from iCloud and the saved phrase. Verify original media bytes,
   folders, a new local pattern, and that no existing vault is replaced.
5. Change the recovery phrase and finish another backup. New phrase must work;
   old phrase must fail for that cloud copy. An old exported file must retain
   its original phrase.
6. With Unlimited, create a share. Claim it on account B with the sharing phrase.
   Claiming on unrelated account C must fail. Reimporting on another device on
   B's account must work with the original sharing phrase. Confirm the actual
   CKShare participant is read-only and publicPermission remains none.
7. Verify recipient photos/videos/folders, fullscreen video, hidden edit actions,
   and export enabled/disabled. Update the owner's vault, then reopen the
   recipient's vault to receive the new version. Recipients cannot upload edits.
8. Test expiration, open limits across relaunch, recording detection and
   screenshot-triggered lock. These are app policies: screenshots can already
   exist before notification, and reinstall/removal can reset local open counts.
9. Revoke while online and while offline. A pending revocation must remain
   queued across relaunch and complete later. After server revocation, recipient
   opening must fail even with cached media. Open sessions recheck every 30s.
10. Trigger duress with several owned shares. Verify all are queued for
    revocation, cloud uploads stop, the surviving vault opens normally with a
    new recovery phrase, and prior personal cloud backups remain restorable.
11. Change/sign out of iCloud. Do not overwrite/delete another account's data;
    show a sign-in/account error. Local owned vaults should still open offline.
12. Verify legacy file export/import, free recipient access beyond owned-vault
    quotas, and profile entitlements in a signed Release/TestFlight build.

## Current boundaries

- Automatic backups are opt-in per owned vault and run in the foreground. Local
  vaults remain primary. Restore creates an independent vault; this is not
  bidirectional synchronization of a user's devices.
- Full encrypted archives are uploaded after changes. There is one latest
  committed backup per configured vault, without incremental deduplication or
  historical versions. The archive reader/writer uses bounded 1 MiB chunks.
- Each recipient gets an independent copy in the owner's private CloudKit zone.
  Media storage therefore uses the owner's iCloud quota, not a public media pool.
- Public lookup names are hashes of generated 140-bit sharing phrases. The
  envelope uses a separate PBKDF2 salt and authenticated encryption. Neither the
  phrase nor raw key is in CloudKit. Record metadata can still link invitations
  created by the same account.
- Apple's one-time URL participant enforces the claim and its read-only ACL.
  Expiration, open counters and export/capture controls are additional app rules.
  Revocation cannot erase copies a recipient already exported or photographed.
- Received vaults require online access checks. Removing a received vault does
  not delete the owner's cloud copy. Duress revocations are durable locally but
  uninstalling before an offline revocation reaches Apple removes that queue.

Apple references: [one-time participants](https://developer.apple.com/documentation/cloudkit/ckshare/participant/onetimeurlparticipant%28%29),
[CKShare](https://developer.apple.com/documentation/cloudkit/ckshare),
[CloudKit setup](https://developer.apple.com/documentation/xcode/configuring-icloud-services/).
