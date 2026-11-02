# Pattern

A native SwiftUI photo and video library. Open `patternlock.xcodeproj` in Xcode 26.2 or later, select the `patternlock` scheme, and run on an iPhone or iPad with iOS 26.2 or later. The app and tests use the selected Xcode's iOS SDK. Keep the shared project in its current compatible format (`objectVersion = 77`) when saving it from newer Xcode versions.

## Included

- A 5×5 pattern lock on cold launch and every return from the background.
- First-time pattern registration with a matching second entry; at least four unique dots are required.
- A privacy window hides the library and presented media before app-switcher snapshots.
- Different patterns open separate vaults, each with its own media, folders, and exports.
- New vault creation with a name, unique pattern, and matching confirmation.
- Import multiple photos and videos through the system Photos picker, with progress and partial-failure reporting.
- After importing, keep the originals or choose **Delete originals from Photos** for successfully saved items, with Photos permission and system confirmation.
- Browse all media, photos, or videos. Sort by import date or filename.
- Create, rename, color, and delete folders. Move selected media between folders.
- Multi-select, select all, and permanently delete app copies with confirmation. Deleting a folder keeps its media in the library.
- Full-screen paging, pinch/double-tap photo zoom, and native video playback.
- Export original files through the system share sheet, including Save to Files and iCloud Drive destinations when available. Duplicate filenames are preserved with numbered suffixes.
- Per-vault settings for name, file count, storage usage, pattern changes, encrypted backups, recovery phrases, duress behavior, and vault deletion.

## Storage and backup

Each vault has its own original media, thumbnails, and versioned JSON manifest under `Library/Application Support/Vaults/<vault-id>`. The original library keeps its existing `Vaults/Personal` directory; new vaults use UUID directories. Imports are independent copies. Originals stay in Photos unless you explicitly choose to delete them after importing and confirm with Photos. Only originals with successfully committed, still-present vault copies are eligible; failed imports and items without Photos identifiers are never included. File operations run through an actor, manifests are written atomically, and deletion staging is recovered after an interrupted operation. Media and metadata request iOS complete file protection.

Deleting originals also affects iCloud Photos and synced devices. Deleted items may remain in Photos’ Recently Deleted collection for up to 30 days; Pattern does not empty it. Live Photo deletion is declined because the current importer saves only the still image, not the motion resource. If permission is denied, limited access excludes an original, or an asset cannot be deleted, the vault copies remain available. You can manage those originals directly in Photos. Locking, switching vaults, or backgrounding cancels a deletion request that is still waiting for permission.

The library is eligible for normal **iCloud device backup** when the user enables backup for this app, unless a duress unlock has disabled backups on this device. Separately, vault settings can create an encrypted `.patternbackup` file and save it through Files to iCloud Drive or another location. This is a manual backup, not automatic backup or live iCloud sync. Pattern-derived encryption of the local media, onboarding, and app-wide settings remain future work.

No network service or third-party dependency is required. Importing uses the system picker without requesting general Photos access. Read/write Photos permission is requested only when you choose to delete originals. Temporary export copies are removed when the share sheet closes.

## Pattern lock

The first confirmed pattern opens the Personal vault. Inside a library, tap the vault name at the top and choose **New vault**. Enter a name, draw a new pattern, and repeat it to confirm. A pattern already assigned to a vault cannot be reused. Choose **Switch vault** or **Lock vault** from the same menu to return to the neutral lock screen; the next valid pattern opens its corresponding vault. An unknown pattern never creates a vault automatically.

Existing single-pattern installations are migrated atomically without moving or modifying their photos and folders. Cancelling new-vault setup returns to the previously unlocked vault. Backgrounding during setup discards the unconfirmed pattern and requires authentication again.

Draw a pattern, then draw it again to save it. Crossed dots are included automatically, and a dot cannot be reused in one gesture. VoiceOver users can select the dots individually and choose Use pattern.

Vault IDs, names, and a separately salted PBKDF2-HMAC-SHA256 verifier (600,000 iterations) for each pattern are stored in one atomic Keychain record with `kSecAttrAccessibleWhenUnlocked`; raw patterns are never persisted. Vault names and contents are not listed on the lock screen. Five wrong attempts trigger a 30-second cooldown, with longer delays for further failures. Retry state survives app restarts. Keychain errors keep the library locked. **Recover vault** on the lock screen resets a pattern using the vault’s recovery phrase, when one has been configured. Recovery attempts share the persistent cooldown.

Backgrounding discards incomplete setup, requires a fresh unlock, dismisses library presentations, and invalidates outstanding export presentations. Brief interruptions such as a system permission prompt show the privacy cover without discarding an already unlocked session. A delayed authentication result cannot reopen the app after it has entered the background.

This is an application access lock. Existing media continues to use iOS file protection; it is not yet encrypted with a key derived from the pattern.

## Vault settings

Tap the gear in the library header, or choose **Vault settings** in the vault menu. Details show the current vault’s name, media count, and the total size of its local media, thumbnails, and manifest. Pattern changes require the current pattern, then the new pattern twice; a pattern already assigned to another vault is rejected. Changing or recovering a pattern, or deleting the vault, locks every open window using that vault. Windows share vault stores so imports, backups, and deletion cannot overlap on the same vault.

Recovery setup generates 20 random words (140 bits of randomness), or accepts a custom phrase of at least 8 words and 40 characters. The app requires the phrase to be repeated and the current pattern to be confirmed before saving. Ordinary recovery setup keeps only a salted PBKDF2 verifier in Keychain. A phrase generated automatically during a duress unlock is also retained in the protected Keychain record until the user confirms they saved it; it is never written to a file or included in a vault export. Custom phrases depend on the user choosing unpredictable words. Replacing a phrase invalidates the old phrase for local recovery; existing backups still require their original phrase.

**Back up to iCloud Drive** asks for the configured recovery phrase, encrypts the vault, and opens Files so the user can select iCloud Drive. Encryption is always enabled. The archive uses AES-256-GCM with a fresh 32-byte salt and a PBKDF2-HMAC-SHA256 key derived with 600,000 iterations. Media is processed in 1 MiB chunks; each encrypted record authenticates the header and its position, and a final authenticated marker detects truncation. Vault names, filenames, folders, and media are all encrypted. The format is versioned and restores reject altered data, missing files, invalid paths, and unsupported versions.

**Restore a backup**, available in settings and on the lock screen, opens a backup with the phrase used to create it. It creates a new vault with a unique name and newly confirmed pattern; existing vaults are never overwritten. Set up a new recovery phrase in the restored vault. Files handles cloud download/upload and provider errors; a successful export means Files accepted the save, not that iCloud has finished uploading it.

**Use a duress vault** marks the current vault and its existing pattern for duress. Setup explains the consequences and requires acknowledgment and the current pattern. It does not activate immediately. Each subsequent unlock with that pattern atomically removes every other vault’s local pattern and recovery credentials, generates a new recovery phrase for the surviving vault, disables new manual backups, and invalidates active export leases. The vault opens normally. All windows close existing presentations; revoked libraries also clear their cached state. In-flight exports and backup creation check revocation before exposing results. The local Vaults directory and existing child directories are excluded from future device backups, and this policy survives relaunch, disabling duress, or deleting/recreating the last vault.

Removed vault files are retained on disk, but their old patterns and phrases no longer recover them in Pattern. Restoring a separately saved encrypted backup is an explicit way to regain its contents in a new vault. This is local app access revocation, not cryptographic erasure of media or a concealment guarantee. **Save new recovery phrase** in settings requires the surviving vault’s pattern and confirmation that the phrase has been saved; the display copy is then removed from Keychain. Confirming patterns within settings does not trigger duress. Disabling duress only stops future activations; it does not undo prior revocations or re-enable backups. Earlier decoy configurations migrate to ordinary vaults so an upgrade cannot silently arm destructive behavior.

Sharing currently sends file copies through the system share sheet. Duress closes active sharing and removes temporary export files; it cannot revoke copies already delivered to recipients or Files providers, remove existing iCloud backups, or stop a provider upload already handed off. Automatic iCloud sync and access-controlled share links are not implemented. These limits are stated in duress setup and help.

**Delete this vault** requires typing the vault name and confirming its current pattern. It removes that vault’s local media and Keychain entry, leaving other vaults, Photos originals, and exported backups intact. Deletion stages the directory before committing the Keychain update; a failed update rolls back, and interrupted transactions are recovered or cleaned up on a later launch. Deleting the final vault returns to first-time setup.

## Verification

Run Product → Test in Xcode. Simulator builds must remain ad-hoc signed so Keychain entitlements are available. The XCTest target covers photo/video imports, original-byte preservation, persistence, folder operations, deletion, duplicate export filenames, rejected imports, unreadable manifests, interrupted-delete recovery, and backup eligibility. Pattern tests cover confirmation, gesture geometry, Keychain round trips, cooldown persistence, background/cold-launch locking, stale authentication results, and the privacy window lifecycle. Vault tests cover distinct-pattern routing, rejected duplicate patterns/names, confirmation and cancellation, legacy migration, and isolation of media, folders, deletion, and exports. File-protection attributes are checked on physical devices; the simulator does not emulate them.

Import-store tests use a fake Photos deletion service to verify explicit consent, partial imports, duplicate/missing identifiers, failed manifest writes, denied permission, cancellation, missing vault copies, and stale confirmations. On a device, also verify the Photos permission and deletion prompts with disposable photos/videos, including limited access and a Live Photo.

Settings tests cover renaming, current-pattern checks, recovery rotation and throttling, last-vault deletion, and Keychain failure recovery. Backup tests cover encrypted round trips over multiple chunks, wrong phrases, tampering, truncation, trailing data, missing media, unsafe paths, and restoring without replacing existing vaults. Verify iCloud Drive upload/download on a device signed into iCloud; the simulator checks do not exercise an iCloud account.

```sh
xcodebuild -project patternlock.xcodeproj -scheme patternlock \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
```

The command above uses the iOS 26.2 simulator included with Xcode 26.2; install that runtime or select another installed simulator running iOS 26.2 or later. When multiple Xcode versions are installed, prefix the command with `DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer` to choose the version to verify.

Duress tests cover explicit arming/disarming, atomic failure, phrase rotation, persistent credential revocation and backup disabling, cached repository access, active export cleanup, stale unlock/restore results, and migration of earlier decoys. The disposable simulator walkthrough also verified duress setup, normal library opening after activation, backups showing Off, and saving the newly rotated phrase.
