# Pattern

A native SwiftUI photo and video library. Open `patternlock.xcodeproj`, select the `patternlock` scheme, and run on an iPhone or iPad. The project currently targets the original project's iOS 27 SDK/deployment target.

## Included

- A 5×5 pattern lock on cold launch and every return from the background.
- First-time pattern registration with a matching second entry; at least four unique dots are required.
- A privacy window hides the library and presented media before app-switcher snapshots.
- Different patterns open separate vaults, each with its own media, folders, and exports.
- New vault creation with a name, unique pattern, and matching confirmation.
- Import multiple photos and videos through the system Photos picker, with progress and partial-failure reporting.
- Browse all media, photos, or videos. Sort by import date or filename.
- Create, rename, color, and delete folders. Move selected media between folders.
- Multi-select, select all, and permanently delete app copies with confirmation. Deleting a folder keeps its media in the library.
- Full-screen paging, pinch/double-tap photo zoom, and native video playback.
- Export original files through the system share sheet, including Save to Files and iCloud Drive destinations when available. Duplicate filenames are preserved with numbered suffixes.

## Storage and backup

Each vault has its own original media, thumbnails, and versioned JSON manifest under `Library/Application Support/Vaults/<vault-id>`. The original library keeps its existing `Vaults/Personal` directory; new vaults use UUID directories. Imports are independent copies; the app never deletes the source Photos assets. File operations run through an actor, manifests are written atomically, and deletion staging is recovered after an interrupted operation. Media and metadata request iOS complete file protection.

The library is eligible for normal **iCloud device backup** when the user enables backup for this app. This is not live iCloud sync or an in-app backup/restore service. Explicit iCloud backup controls, pattern-derived media encryption, onboarding, and settings are future work.

No network service or third-party dependency is required. The system picker grants access only to the media the user selects. Temporary export copies are removed when the share sheet closes.

## Pattern lock

The first confirmed pattern opens the Personal vault. Inside a library, tap the vault name at the top and choose **New vault**. Enter a name, draw a new pattern, and repeat it to confirm. A pattern already assigned to a vault cannot be reused. Choose **Switch vault** or **Lock vault** from the same menu to return to the neutral lock screen; the next valid pattern opens its corresponding vault. An unknown pattern never creates a vault automatically.

Existing single-pattern installations are migrated atomically without moving or modifying their photos and folders. Cancelling new-vault setup returns to the previously unlocked vault. Backgrounding during setup discards the unconfirmed pattern and requires authentication again.

Draw a pattern, then draw it again to save it. Crossed dots are included automatically, and a dot cannot be reused in one gesture. VoiceOver users can select the dots individually and choose Use pattern.

Vault IDs, names, and a separately salted PBKDF2-HMAC-SHA256 verifier (600,000 iterations) for each pattern are stored in one atomic Keychain record with `kSecAttrAccessibleWhenUnlocked`; raw patterns are never persisted. Vault names and contents are not listed on the lock screen. Five wrong attempts trigger a 30-second cooldown, with longer delays for further failures. Retry state survives app restarts. Keychain errors keep the library locked. Pattern reset/recovery is not implemented yet.

Backgrounding discards incomplete setup, requires a fresh unlock, dismisses library presentations, and invalidates outstanding export presentations. Brief interruptions such as a system permission prompt show the privacy cover without discarding an already unlocked session. A delayed authentication result cannot reopen the app after it has entered the background.

This is an application access lock. Existing media continues to use iOS file protection; it is not yet encrypted with a key derived from the pattern.

## Verification

Run Product → Test in Xcode. Simulator builds must remain ad-hoc signed so Keychain entitlements are available. The XCTest target covers photo/video imports, original-byte preservation, persistence, folder operations, deletion, duplicate export filenames, rejected imports, unreadable manifests, interrupted-delete recovery, and backup eligibility. Pattern tests cover confirmation, gesture geometry, Keychain round trips, cooldown persistence, background/cold-launch locking, stale authentication results, and the privacy window lifecycle. Vault tests cover distinct-pattern routing, rejected duplicate patterns/names, confirmation and cancellation, legacy migration, and isolation of media, folders, deletion, and exports. File-protection attributes are checked on physical devices; the simulator does not emulate them.

```sh
xcodebuild -project patternlock.xcodeproj -scheme patternlock \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
```
