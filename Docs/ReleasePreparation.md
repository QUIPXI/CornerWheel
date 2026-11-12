# Build and release preparation

Contributor builds need Xcode and its macOS SDK, Git, and network access for the pinned Sparkle package. They do not need an Apple Developer account, a signing certificate, a notary profile, or access to the maintainer's Keychain. The committed project already contains the shared `CornerWheel` scheme. The deployment target remains macOS 14.0. The existing release packager produces Apple silicon (`arm64`) builds; Intel runtime support is not established by that packaging flow.

## Build and test a checkout

Select a full Xcode installation as the active developer directory. From the repository root:

```sh
xcodebuild -project CornerWheel.xcodeproj -scheme CornerWheel \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath Build/DerivedData \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build

xcodebuild -project CornerWheel.xcodeproj -scheme CornerWheel \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath Build/DerivedData \
  -onlyUsePackageVersionsFromResolvedFile \
  -parallel-testing-enabled NO \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test

python3 -m unittest discover -s Tests/ReleaseTools -v
bash -n Scripts/prepare_release.sh Scripts/build_update.sh Scripts/release.env
```

The development app is `Build/DerivedData/Build/Products/Debug/CornerWheel.app`. It uses an ad-hoc signature, not Developer ID signing or notarization. The Debug-only entitlement permits the embedded Sparkle framework to load without a shared Apple signing team. Do not distribute this development app as an approved public release. Changes to an ad-hoc build can require renewed Accessibility approval. Test commands do not establish interactive permission or cross-application behavior; use the [manual checklist](ManualTestChecklist.md).

The release helpers need Python 3.11.8 or later, including `tarfile` data-filter support. Swift Package Manager uses the committed `CornerWheel.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (Sparkle 2.10.1). Keep that lockfile under version control. XcodeGen 2.45.3 or later is optional for editing `project.yml`; run `xcodegen generate` after changing the specification and review both files. A clean checkout builds directly from the committed Xcode project without XcodeGen.

CI runs the same Debug build, native tests, Python release-tool tests and shell syntax checks. It uses the [GitHub-hosted `macos-15` runner](https://github.com/actions/runner-images/blob/main/README.md) and a [pinned checkout action](https://github.com/actions/checkout/commit/3d3c42e5aac5ba805825da76410c181273ba90b1), with read-only repository access, no persisted checkout credentials and no release secrets. Runner images change over time; CI prints its actual toolchain. A hosted CI pass remains unverified until this workflow runs on GitHub.

## Public release prerequisites

Public packaging is a separate maintainer operation. Review the [roadmap](../ROADMAP.md), source-publication checks and manual acceptance checklist before distributing a new build. Required inputs are:

- A reviewed, committed source revision with a clean working tree and a new increasing build number. Existing published filenames and build numbers must not be reused.
- A valid Developer ID Application certificate with its private key and matching Apple Developer team. Release builds enable the hardened runtime and reject development entitlements.
- A working `notarytool` Keychain profile for Apple notarization; the profile name is configuration, while its credentials remain in Keychain. Follow [Apple's notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
- The existing Sparkle signing key for updates to the existing app, matching the configured public key, plus the tools from the pinned Sparkle 2.10.1 distribution. Do not generate a replacement key casually. See [Sparkle publishing](https://sparkle-project.org/documentation/publishing/).
- Authorized HTTPS hosting for the final ZIP, release notes and signed feed. Independent forks must configure their own update key and hosting before enabling updates; Debug builds leave the feed empty.
- An explicitly chosen **private** recovery repository and GitHub CLI authentication if the maintainer elects to use the existing backup/staging flow. Configure `CORNERWHEEL_BACKUP_REPOSITORY=owner/repository`; the tool verifies that it is private before pushing. A public source repository cannot also satisfy this private recovery requirement.

### Moving to a source repository without old release history

A fresh public source repository has no previous release tags, local recovery history or staged appcast. The release tool cannot infer the existing published build number from that empty history: its fallback previous-build floor is 1. Verify the highest build number in the actual published update feed and release records, then explicitly set `CORNERWHEEL_PREVIOUS_BUILD` to that integer in the ignored local release configuration. Choose a new `CORNERWHEEL_RELEASE_BUILD` greater than that verified floor. Do not rely on the fallback, reuse a published build number, or infer the current published version from this source tree's development label.

If the next appcast should retain existing releases, populate the new checkout's `Build/Releases/staging/` with **only verified public** ZIP archives, the existing feed and its release-note files. Verify their origin, bytes and signatures against the existing release records before copying, and review the resulting feed before publishing it. The packager carries forward that public staging directory; without it, the generated feed contains only the newly prepared archive. Do not copy private recovery ZIPs, source bundles, logs, review manifests, credentials or the entire old `Build/` directory into public staging. Keep the original private recovery store unchanged.

Copy `Scripts/release.env` to ignored `Scripts/release.local.env` only if the local file does not already exist, fill in the release settings, and source that local file from the repository root. Never commit credentials. Review any existing local file's version/build before a future release. The tracked template intentionally has no signing identity, team, notary profile or release version/build defaults.

Resolve Sparkle's pinned release tools when needed:

```sh
xcodebuild -resolvePackageDependencies -project CornerWheel.xcodeproj \
  -scheme CornerWheel -derivedDataPath Build/ReleaseDependencies \
  -onlyUsePackageVersionsFromResolvedFile
source Scripts/release.local.env
./Scripts/prepare_release.sh --check
```

`--check` validates local configuration, a clean committed source tree, the available signing identity and matching Sparkle Keychain key. It does not contact Apple or establish that notarization credentials work. It may fail on the intentionally uncommitted preparation work until the owner reviews and commits it.

## Side effects of release commands

Run each operation only when its effects are intended:

| Command | Effects |
| --- | --- |
| `prepare_release.sh --check` | Local preflight; no build, tag or upload. |
| `prepare_release.sh --prepare` | Archives and exports with Developer ID signing, submits to Apple, checks acceptance, staples and validates the ticket, creates the final ZIP and Sparkle signature, seals local recovery files, and creates an annotated local Git tag. No GitHub upload or public feed publication. |
| `backup_release.py … --stage` | Pushes the sealed tag to the explicitly configured private repository, uploads and publishes a private recovery release, downloads and verifies it, then stages the public ZIP/feed locally. |
| `prepare_release.sh --release` | Combines preparation with the private backup/staging operation above. |
| `build_update.sh` | Replaces and launches the local `Build/CornerWheel.app` using a persistent local signing identity. It can stop that installed app and preserves a backup; it is not a contributor prerequisite or public-release packager. |

The release packager fails when signing or notarization verification fails. It does not fall back to an unsigned public package. Failed preparation keeps working files and logs for investigation. Keep these private: recovery archives include Git history, build paths, logs, source and symbols. Do not attach them wholesale to public issues or releases.

After an explicitly authorized preparation, upload the verified final ZIP and release notes to the configured HTTPS host first, then publish the signed feed. Verify the hosted bytes with `Scripts/check_update_host.py` and complete a real two-version update test on a separate test account/Mac. Retain recovery archives privately; `Scripts/rebuild_release.py --help` describes the separate rebuild tool. Never attach a recovery archive to a public release. No signing, notarization, tag creation, upload, installation or public release is performed merely by adding this guide or CI.
