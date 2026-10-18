# DropForge release procedure

DropForge 1.0.0 is distributed as an Apple-silicon app, DMG, and Sparkle update archive. Nothing in this procedure publishes or pushes automatically.

## Signing key

The Sparkle Ed25519 private seed is stored only at:

`~/.config/dropforge/sparkle_ed25519_private_key`

The directory is mode `0700`; the key is mode `0600`. Never commit, print, or attach that file. The matching public key is committed as `SUPublicEDKey` in `Resources/Info.plist`. Back up the private seed in an encrypted secret store; losing it prevents installed clients from trusting future updates.

## Build and verify

From a clean committed checkout:

```sh
swift test
VERSION=1.0.0 scripts/build-app.sh
VERSION=1.0.0 scripts/make-release.sh
codesign --verify --deep --strict --verbose=2 dist/DropForge.app
hdiutil verify dist/DropForge-1.0.0-arm64.dmg
shasum -a 256 -c dist/checksums.sha256
```

`make-release.sh` refuses a private key whose mode is not `0600`. It signs both the ZIP enclosure and `appcast.xml`, verifies both signatures, and writes `dist/checksums.sha256`.

## GitHub release (manual; not performed)

1. Review the clean commit, tests, artifact hashes, and release notes.
2. Create and push an annotated `v1.0.0` tag only when public release is authorized.
3. Create a normal (not draft/prerelease) GitHub release for `v1.0.0`.
4. Upload exactly:
   - `DropForge-1.0.0-arm64.dmg`
   - `DropForge-1.0.0-arm64.zip`
   - `appcast.xml`
   - `checksums.sha256`
5. Download every public asset anonymously and compare SHA-256 values with the local manifest.
6. Confirm `https://github.com/timowse/DropForge/releases/latest/download/appcast.xml` resolves and that its enclosure URL resolves to the uploaded ZIP.
7. Keep 1.0.0 installed, then publish a separately built/signed no-op 1.0.1 test release. Use **Check for Updates…** in the installed app and confirm discovery, signature validation, replacement, relaunch, version, and process path.

## Distribution limitation

The local build is ad-hoc signed, not signed with an Apple Developer ID and not notarized. Sparkle enforces Ed25519 update signatures, but public downloads may still require a Gatekeeper override until Developer ID signing and notarization are added.
