# Preparing a public source copy

`Scripts/export_public_source.py` prepares a local source-only directory from an exact reviewed file allowlist. It does not create a repository, commit, tag or remote; change visibility; upload anything; or sign/build an application. Original files and Git history remain untouched, including uncommitted work.

The initial public release uses the existing application-icon/title cards. Actual window-content previews are separate future work; see [the roadmap](../ROADMAP.md).

## Export and review

From the project root, using Python 3.11.8 or later:

```sh
python3 -m unittest discover -s Tests/ReleaseTools -v
python3 Scripts/export_public_source.py
```

The default output is a new UTC-stamped directory under ignored `Build/PublicSource/`. Use `--name reviewed-source` to choose a simple directory name. Existing directories and review manifests are never overwritten; choose a new name after changing the inputs. The script fails clearly on missing approved files, unreviewed source layout, symlinks, path traversal, invalid exclusion markers, changed projection assumptions or broken local documentation links.

The adjacent `.review.json` file records each source/export SHA-256 and whether a public projection changed its bytes. It remains **outside** the export. Review that file, the exported documentation and the complete file list before any later publication. The export reflects the current working tree, including reviewed uncommitted changes; it does not claim to be a committed revision.

The allowlist includes native sources, bundled assets and license notices, the Xcode project/shared scheme/lockfile, native and helper tests, public documentation, issue/PR templates, CI, and generic build/release helpers. Generic recovery tools remain available only with an explicitly configured private destination. No owner-specific backup destination is supplied.

It excludes Git metadata/history, local release settings, website code, generated output, evidence/screenshots/logs, historical and internal audits, and the owner-specific backup helper. Source directories are checked against the allowlist so a newly added implementation or asset cannot be silently left out. Known generated Xcode user data and Python cache directories are omitted. Other root files and documents are not implicitly copied.

## One maintained set of documentation

The original public-facing documents remain the source of truth. Private-only paragraphs use balanced HTML comments named `public-source:exclude:start` and `public-source:exclude:end`; the exporter removes those blocks. A small set of explicit, checked text projections replaces historical/internal cross-references with self-contained public guidance. CI's shell check omits the excluded owner-specific helper, and the generic packager's help points to the included release guide.

Those transformations are deterministic and recorded by the manifest. A changed assumption fails rather than silently copying a newly edited private paragraph. Review both the source and projection when that happens; do not make manual edits only inside an exported copy. An already projected public tree can be exported again using the same allowlist.

## Verify the copy

Change into the printed source directory and follow [CONTRIBUTING.md](../CONTRIBUTING.md) for the exact build and test commands. The exported tree has no `.git` directory; Git-specific diff/lockfile checks become applicable after an independently authorized repository initialization. App builds and tests do not require Git history or the maintainer's Apple Developer account. Resolve the pinned dependency normally, or point Xcode at an already reviewed local dependency cache while testing the copy.

Run an established secret scanner over the export, inspect findings without printing candidate values, and review media and documentation separately. This allowlist exporter is not a secret detector or a guarantee of confidentiality. Do not publish its parent directory, private review manifest, generated build output or recovery archives.

Public source publication and signed binary distribution remain separate decisions. [ReleasePreparation.md](ReleasePreparation.md) describes signing/notarization prerequisites and the effects of release commands. Do not run those commands as a source-export check.

