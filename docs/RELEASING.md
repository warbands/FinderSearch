# Releasing FinderSearch

A release has to install and update without anyone fighting macOS. Today's builds are
ad-hoc signed, which costs every user three things:

1. **Gatekeeper blocks the first launch.** People have to find *Privacy & Security → Open
   Anyway* in System Settings.
2. **Full Disk Access silently stops working after each update.** macOS ties the grant to the
   app's signature, and an ad-hoc signature changes with every build.
3. **The Keychain asks again after each update.** The index key's access is tied to the same
   signature, so every update asks to allow FinderSearch to use "FinderSearch index key".

Signing with an Apple **Developer ID** and having Apple **notarize** the app fixes all three:
no Gatekeeper warning, and permissions and Keychain access that carry over to updates.

## One-time setup

1. **Join the Apple Developer Program** ($99/year; one membership covers every app you
   publish). Decide first whether to enroll as an **individual** or an **organization**: the
   name you enroll under is the name macOS shows as the developer. An organization needs a
   D-U-N-S number and takes longer to approve.
2. **Create a "Developer ID Application" certificate.** In Xcode: *Settings → Accounts →
   Manage Certificates → + → Developer ID Application*. Only the account holder (or an admin
   they allow) can create one. It lands in your login Keychain; back up its private key (export a `.p12` to
   somewhere safe), since a lost key can't be recovered and Apple limits how many you can make.
3. **Choose the bundle identifier for good**, for example `com.<yourname>.FinderSearch`, and
   set it in `scripts/build.sh` (it is `local.findersearch.app` now). Changing it after people
   install resets their Full Disk Access grant and asks for the Keychain once.
4. **Store notarization credentials in the Keychain, not the repo.** Make an app-specific
   password at [appleid.apple.com](https://appleid.apple.com) (*Sign-In and Security →
   App-Specific Passwords*), then:

   ```sh
   xcrun notarytool store-credentials FinderSearch-notary \
       --apple-id you@example.com --team-id TEAMID1234
   ```

## Before the first public release

- [ ] Bundle identifier chosen and set (step 3 above).
- [ ] `Info.plist` complete: `NSHumanReadableCopyright`. (`CFBundleVersion` and the app
      icon are in place; the icon is drawn by `scripts/make-icon.swift`.)
- [ ] Third-party license texts shipped inside the app. The Rust crates (fsearch's
      dependencies and RustCrypto's `aes-gcm` family) are MIT or Apache-2.0, which require
      their notices in copies. For example, generate `ThirdPartyLicenses.txt` from
      `vendor/fsearch/Cargo.lock` with `cargo about` and copy it into `Contents/Resources`.
- [ ] Upstream changes reviewed: new commits in
      [noahdunnagan/fsearch](https://github.com/noahdunnagan/fsearch) and
      [zeusinsight/FinderSearch](https://github.com/zeusinsight/FinderSearch) since the last sync.
- [ ] Tested on a clean user account (see *Checking a release* below).

## Each release

1. Bump `CFBundleShortVersionString` (and `CFBundleVersion`) in `scripts/build.sh`.
2. Build and sign with your Developer ID:

   ```sh
   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID1234)" scripts/build.sh
   ```

   Without `SIGN_IDENTITY` the build is ad-hoc signed, as before. Either way it uses the
   hardened runtime, which notarization requires.
3. Package and sign a disk image:

   ```sh
   hdiutil create -volname FinderSearch -srcfolder dist/FinderSearch.app \
       -ov -format UDZO dist/FinderSearch.dmg
   codesign --sign "Developer ID Application: Your Name (TEAMID1234)" --timestamp dist/FinderSearch.dmg
   ```
4. Notarize and staple, so it opens without a warning even offline:

   ```sh
   xcrun notarytool submit dist/FinderSearch.dmg --keychain-profile FinderSearch-notary --wait
   xcrun stapler staple dist/FinderSearch.dmg
   ```

   If notarization fails, `xcrun notarytool log <submission-id> --keychain-profile
   FinderSearch-notary` says why.
5. Publish a GitHub release on the fork with the `.dmg` and its SHA-256
   (`shasum -a 256 dist/FinderSearch.dmg`).

## Checking a release

On a user account that has never run FinderSearch:

1. Download the `.dmg` from the release page, open it, drag the app to Applications, launch.
   **Expected:** no Gatekeeper warning. (`spctl -a -vvv /Applications/FinderSearch.app`
   should say `source=Notarized Developer ID`.)
2. Grant Full Disk Access and reopen. **Expected:** files in the home folder and in
   Documents appear in search.
3. In Keychain Access, find "FinderSearch index key". **Expected:** it exists, and
   `~/Library/Caches/FinderSearch` holds only encrypted files.
4. Install the *next* release over it. **Expected:** no Keychain prompt, Full Disk Access
   still works, and the index loads without a full rebuild.
5. *FinderSearch → Forget Search Data…* **Expected:** the folder and the key are gone, and a
   new index is built.
