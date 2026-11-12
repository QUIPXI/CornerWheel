# Security reporting

## Private vulnerability reports

GitHub private vulnerability reporting is enabled for [QUIPXI/CornerWheel](https://github.com/QUIPXI/CornerWheel). While signed in to GitHub, open [Report a vulnerability](https://github.com/QUIPXI/CornerWheel/security/advisories/new) and submit the report privately to the repository maintainers. The setting was enabled and read back as enabled on November 12, 2026.

No response-time or security-support guarantee is made here.

Do not post exploit details, credentials, private window content or sensitive logs in public issues. Ordinary, non-sensitive bugs can use the bug-report template. If the private reporting page is unavailable, ask the maintainer for a private route through an already established channel without including sensitive details first.

## Useful report details

Include the affected CornerWheel version/build or source commit, macOS version and architecture, a concise impact description, reproduction steps using disposable data, and any suggested mitigation. Remove unrelated titles, document contents, account information and personal paths. Never send signing keys, certificates with private keys, passwords or notarization credentials.

## Scope and handling

The native app uses Accessibility for per-window discovery and user-selected actions, and Sparkle for configured updates. See [PRIVACY.md](PRIVACY.md) for the data flow and logging. Keep reports about the separate website distinct from native app findings.

The project has not established a supported-version security matrix. Maintainers should reproduce against the current source and identify affected published builds before promising a fix. If a credential is exposed, revoke or rotate it with the credential owner's authorization; removing it from a new commit does not remove historical exposure. Coordinate any history rewrite separately.

Source exports use the reviewed allowlist in `Scripts/export_public_source.py`. An export or secret scan is not a guarantee that the repository contains no secrets or vulnerabilities.
