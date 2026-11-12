import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "export_public_source", Path(__file__).resolve().parents[2] / "Scripts/export_public_source.py")
exporter = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(exporter)


class PublicSourceExportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "Sources").mkdir()
        (self.root / "Sources/App.swift").write_text("// sample public source\n")
        (self.root / "README.md").write_text(
            "# Sample\n\n[Source](Sources/App.swift)\n"
            + exporter.START + "\nPrivate review text\n" + exporter.END + "\n")
        self.paths = ("README.md", "Sources/App.swift")
        self.allowlist = patch.object(exporter, "PUBLIC_FILES", self.paths)
        self.layout = patch.object(exporter, "STRICT_ROOTS", ("Sources",))
        self.allowlist.start()
        self.layout.start()
        self.addCleanup(self.allowlist.stop)
        self.addCleanup(self.layout.stop)

    def test_export_excludes_history_unlisted_files_and_private_blocks(self):
        for name in (".git/config", "Docs/PrivateNotes.md", "Build/private.log", "Website/index.html"):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("excluded fixture")
        original = (self.root / "README.md").read_bytes()
        target, report = exporter.export_source(self.root, "reviewed")
        self.assertEqual({str(p.relative_to(target)) for p in target.rglob("*") if p.is_file()}, set(self.paths))
        self.assertNotIn("Private review text", (target / "README.md").read_text())
        self.assertEqual((self.root / "README.md").read_bytes(), original)
        self.assertEqual((target / "Sources/App.swift").read_bytes(), (self.root / "Sources/App.swift").read_bytes())
        manifest = json.loads(report.read_text())
        self.assertEqual(manifest["file_count"], 2)
        self.assertEqual(report.parent, target.parent)
        self.assertFalse((target / report.name).exists())
        self.assertTrue(next(item for item in manifest["files"] if item["path"] == "README.md")["projected"])

    def test_refuses_existing_export_without_overwriting_it(self):
        target, _ = exporter.export_source(self.root, "reviewed")
        (target / "README.md").write_text("reviewer work")
        with self.assertRaisesRegex(exporter.ExportError, "already exists"):
            exporter.export_source(self.root, "reviewed")
        self.assertEqual((target / "README.md").read_text(), "reviewer work")

    def test_refuses_path_traversal_and_absolute_output_names(self):
        for name in ("../escape", "/escape", "nested/output", "nested\\output", "..", ""):
            with self.subTest(name=name), self.assertRaises(exporter.ExportError):
                exporter.export_source(self.root, name)
        self.assertFalse((self.root / "Build").exists())

    def test_refuses_symlink_input_file_and_input_directory(self):
        source = self.root / "Sources/App.swift"
        source.unlink()
        source.symlink_to(self.root / "README.md")
        with self.assertRaisesRegex(exporter.ExportError, "Symlink"):
            exporter.export_source(self.root, "file-link")
        source.unlink()
        (self.root / "Sources").rmdir()
        (self.root / "Sources").symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(exporter.ExportError, "symlinked"):
            exporter.export_source(self.root, "directory-link")

    def test_refuses_symlink_output_ancestor(self):
        elsewhere = self.root / "elsewhere"
        elsewhere.mkdir()
        (self.root / "Build").symlink_to(elsewhere, target_is_directory=True)
        with self.assertRaisesRegex(exporter.ExportError, "Symlink"):
            exporter.export_source(self.root, "outside")
        self.assertEqual(list(elsewhere.iterdir()), [])

    def test_refuses_unreviewed_source_file_and_missing_approved_file(self):
        extra = self.root / "Sources/unreviewed.txt"
        extra.write_text("must not be silently exported or omitted")
        with self.assertRaisesRegex(exporter.ExportError, "Unreviewed source file"):
            exporter.export_source(self.root, "unknown")
        extra.unlink()
        (self.root / "Sources/App.swift").unlink()
        with self.assertRaisesRegex(exporter.ExportError, "Missing approved"):
            exporter.export_source(self.root, "missing")

    def test_refuses_broken_or_outside_markdown_links(self):
        for link in ("Docs/PrivateNotes.md", "../../outside.md", "/absolute.md"):
            with self.subTest(link=link), self.assertRaises(exporter.ExportError):
                exporter.validate_links({"README.md": f"[link]({link})".encode()})

    def test_exclusion_markers_are_balanced_and_projection_is_idempotent(self):
        for value in (exporter.START, exporter.END, exporter.START + "\n" + exporter.START):
            with self.subTest(value=value), self.assertRaises(exporter.ExportError):
                exporter.strip_private_blocks(value)
        projected = exporter.strip_private_blocks((self.root / "README.md").read_text())
        self.assertEqual(exporter.strip_private_blocks(projected), projected)

    def test_unsafe_allowlist_paths_are_rejected(self):
        for path in ("../outside", "/outside", ".git/config", "Sources/../outside", "Sources\\outside"):
            with self.subTest(path=path), self.assertRaises(exporter.ExportError):
                exporter.relative_path(path)

    def test_changed_public_projection_requires_review(self):
        self.assertEqual(exporter.replace_reviewed("before", "before", "after"), "after")
        self.assertEqual(exporter.replace_reviewed("after", "before", "after"), "after")
        with self.assertRaises(exporter.ExportError):
            exporter.replace_reviewed("unreviewed change", "before", "after")


class PublicationPolicyTests(unittest.TestCase):
    def test_real_policy_includes_build_inputs_and_excludes_owner_material(self):
        paths = set(exporter.PUBLIC_FILES)
        for required in ("LICENSE", "project.yml", "Resources/Info.plist",
                         "CornerWheel.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
                         "Scripts/export_public_source.py", "Tests/ReleaseTools/test_export_public_source.py"):
            self.assertIn(required, paths)
        for private in ("Scripts/backup_project.sh", "Scripts/release.local.env", "Docs/PublicationAudit.md",
                        "Docs/LegalRiskAudit-2026-10-26.md", "Docs/OpenSourcePreparation.md"):
            self.assertNotIn(private, paths)
        self.assertFalse(any(path.startswith((".git/", "Website/", "Build/")) for path in paths))


if __name__ == "__main__":
    unittest.main()
