# Distribution (GitHub + Sparkle)

This project ships outside the Mac App Store using Developer ID signing,
notarization, GitHub Releases, and Sparkle appcast updates.

## One-time setup

1. Enroll in the Apple Developer Program.
2. Create Developer ID certificates (Developer ID Application).
3. Install Sparkle tools:
   - Download the official distribution archive from
     [Sparkle releases](https://github.com/sparkle-project/Sparkle/releases).
   - Extract the archive and set `SPARKLE_BIN` to its `bin` directory.
4. Generate Sparkle EdDSA keys:
   - Run `generate_keys` from Sparkle tools.
   - Replace `REPLACE_WITH_SPARKLE_PUBLIC_KEY` in `Lodge/Info.plist`.
   - Store the private key securely (CI secret or local keychain).
5. Update `SUFeedURL` in `Lodge/Info.plist` to point at your repo:
   - `https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml`
6. Set up notarization credentials:
   - Create an App Store Connect API key.
   - Store the key as a base64 secret for CI, or use `notarytool store-credentials` locally.

## GitHub Actions (recommended)

Cut a release from `main` with vesnik (settings in `.vesnik.yaml`):

```sh
vesnik release --yes
```

vesnik bumps `MARKETING_VERSION` in `Lodge.xcodeproj/project.pbxproj`, writes
`CHANGELOG.md`, commits to `main`, tags the commit `vX.Y.Z`, pushes both, and
creates the GitHub Release with its notes. Pushing the tag starts the Release
workflow. It runs the unit tests, then sets `CURRENT_PROJECT_VERSION` to the
commit count in its own checkout. The number is not committed, and it grows on
`main`, so it stays above the last shipped build. Sparkle compares it. The
workflow then builds, signs, notarizes, uploads the app and DMG to the release,
and updates Sparkle and the Homebrew tap.

The workflow downloads Sparkle 2.9.2 from its official release archive and checks
the pinned SHA-256 checksum before extraction. Homebrew is not required for
these tools. The tooling version is separate from the app's framework version.

### Retry a release with an existing tag

If a run failed after the tag was pushed, run the workflow again on that tag:

```sh
gh workflow run release.yml --repo nklmilojevic/Lodge --ref main -f tag=v1.2.0
```

This uses the current workflow but checks out the existing tag. It verifies the
tag and app version, runs tests, and builds that exact commit with the same
commit-count build number as the first run. It does not change the tag, and it
updates the release's assets without replacing its notes. The workflow refuses a
run with `existing_tag` set to false. A new version is a new release: run
`vesnik release --yes`.

The **Re-run jobs** button uses the workflow from the failed run, so it does not
apply a later workflow fix.

Required GitHub Secrets:

- `APPLE_TEAM_ID`
- `MACOS_CERTIFICATE_P12` (Developer ID Application certificate, base64)
- `MACOS_CERTIFICATE_PASSWORD`
- `NOTARY_KEY_ID` (App Store Connect API key ID)
- `NOTARY_ISSUER_ID` (App Store Connect issuer ID)
- `NOTARY_KEY_P8` (API key file, base64)
- `SPARKLE_PRIVATE_KEY` (Sparkle EdDSA private key, base64)

Base64 helpers:

```sh
base64 -i AuthKey_ABC123.p8 | pbcopy
base64 -i sparkle_private_key | pbcopy
```

## Manual release (local)

1. Bump `MARKETING_VERSION` in Xcode, and set `CURRENT_PROJECT_VERSION` above the
   last shipped build (`sparkle:version` in `appcast.xml`). The GitHub workflow
   sets it to the commit count instead.
2. Update `scripts/export-options.plist` with your `teamID`.
3. Build, sign, notarize, and package artifacts:

   ```sh
   NOTARY_PROFILE="LodgeNotary" scripts/release.sh
   ```

4. Generate the Sparkle appcast and signatures:

   ```sh
   DOWNLOAD_URL_PREFIX="https://github.com/<owner>/<repo>/releases/download/<tag>" \
     SPARKLE_PRIVATE_KEY="/path/to/sparkle_private_key" \
     scripts/generate-appcast.sh
   ```

5. Create a GitHub Release and upload the artifacts:

   ```sh
   gh release create <tag> build/Lodge.dmg build/updates/Lodge.app.zip appcast.xml
   ```

## Required environment variables (local)

- `NOTARY_PROFILE`: The `notarytool` keychain profile name.
- `DOWNLOAD_URL_PREFIX`: The GitHub release download URL prefix.
- `SPARKLE_PRIVATE_KEY`: Path to Sparkle EdDSA private key.
- `SPARKLE_BIN` (optional): Override Sparkle tools path.

## Artifacts

- `build/Lodge.dmg`: user-facing download.
- `build/updates/Lodge.app.zip`: Sparkle update bundle.
- `appcast.xml`: Sparkle feed uploaded with the release.
