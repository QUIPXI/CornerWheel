# Third-party notices

CornerWheel's own code and bundled icon are licensed under the [MIT License](LICENSE). Third-party components retain their own copyright notices and license terms.

The only Swift package dependency recorded in `project.yml` and `CornerWheel.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` is [Sparkle 2.10.1](https://github.com/sparkle-project/Sparkle/tree/ab7d71291238df6e0492143b120c9b696a35f603), revision `ab7d71291238df6e0492143b120c9b696a35f603`, used for optional app updates.

The complete, unmodified upstream license and bundled-component notices are retained in [Resources/ThirdPartyNotices.txt](Resources/ThirdPartyNotices.txt). That file is included in the application bundle and available through **Settings → About CornerWheel → Third-party Notices**. It includes:

| Component identified by Sparkle's license | Terms retained in the notice file |
| --- | --- |
| Sparkle | MIT |
| `bspatch.c` and `bsdiff.c`, bsdiff 4.3, Colin Percival | Two-clause BSD-style terms |
| `sais.c` and `sais.h`, sais-lite, Yuta Mori | MIT |
| Portable Ed25519 implementation, Orson Peters | zlib-style terms |
| `SUSignatureVerifier.m`, Mark Hamlin | Two-clause BSD-style terms |

On November 12, 2026, the bundled notice file was compared byte-for-byte with `LICENSE` in the resolved Sparkle checkout at the revision above; they matched. The [upstream license at that revision](https://github.com/sparkle-project/Sparkle/blob/ab7d71291238df6e0492143b120c9b696a35f603/LICENSE) is the source of this inventory. Preserve the complete notices when distributing source or app bundles, and repeat this comparison after updating Sparkle.

The tracked application artwork consists of seven sizes of the CornerWheel icon in `Resources/Assets.xcassets/AppIcon.appiconset/`. Its drawing source is `Scripts/make_app_icon.swift`. App icons displayed for other installed applications are obtained at runtime; copies of those applications' icons are not bundled in this native repository. The separately versioned, ignored `Website/` directory is outside this native repository's asset inventory.
