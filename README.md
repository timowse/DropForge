# DropForge

DropForge is a free, local-first macOS file conversion and workflow app for Apple silicon. It lives in the menu bar and provides a file-action wheel, batch processing, progress tracking, and safe output handling without uploads, accounts, subscriptions, analytics, or artificial file limits.

## Install

1. Download `DropForge-1.0.0-arm64.dmg` from [Releases](https://github.com/timowse/DropForge/releases/latest).
2. Open the DMG and copy **DropForge** to **Applications**.
3. Start DropForge. Its icon appears in the macOS menu bar rather than the Dock.

The current community build is ad-hoc signed rather than Apple Developer ID signed/notarized. macOS may therefore require **Control-click → Open** on first launch.

Requires macOS 14 or later on Apple silicon.

## Use

- Drag files, then press the configured modifier key to open a conversion, tool, or action wheel at the pointer.
- Alternatively select **Choose Files…** from the menu-bar icon.
- Use **Check for Updates…** in the menu for cryptographically signed Sparkle updates.
- Originals are never overwritten. Name collisions receive numbered filenames.

## Included workflows

- Images: JPEG, PNG, HEIC, WebP, AVIF, SVG rendering, resize, crop, compression, metadata and QR reading
- Audio/video: common FFmpeg-backed conversions, extraction, trimming and GIF output
- Documents: Markdown, PDF, DOCX, EPUB, CSV/TSV and LibreOffice/iWork-assisted workflows when those apps are available
- Archives and files: ZIP creation/extraction, rename, organize, combine and other local actions

See the sections above for supported workflows. Some advanced editing and format combinations remain partial; RAR creation and high-fidelity PDF-to-XLSX are not supported.

## Privacy and security

Conversions run locally. DropForge does not upload files or require an account. Update archives are verified with Sparkle Ed25519 signatures before installation. The private update-signing key is not stored in this repository.

## Build from source

```sh
swift test
VERSION=1.0.0 scripts/build-app.sh
```

The repository vendors Sparkle 2 under its own license. FFmpeg and WebP command-line helpers are bundled into release builds with notices in `Resources/THIRD_PARTY_NOTICES.md`.

