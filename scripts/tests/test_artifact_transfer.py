"""Reject missing, stale or altered results in the non-publishing artifact smoke test."""
import hashlib
import importlib.util
from pathlib import Path
import re
import tarfile
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "artifact_transfer", ROOT / "scripts/checks/check-artifact-transfer.py")
TRANSFER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TRANSFER)


class ArtifactTransferTests(unittest.TestCase):
    def test_round_trip_and_archive_contents(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "downloads"
            TRANSFER.prepare(path)
            TRANSFER.verify(path)
            self.assertEqual(len(list(path.iterdir())), 5)
            with tarfile.open(next(path.glob("*.tar.gz"))) as archive:
                self.assertEqual(archive.getnames(), ["iphone-use/README.txt"])
                tar_text = archive.extractfile("iphone-use/README.txt").read()
            with zipfile.ZipFile(next(path.glob("*.zip"))) as archive:
                self.assertEqual(archive.read("iphone-use/README.txt"), tar_text)
            self.assertIn("中文".encode(), tar_text)
            for checksum in path.glob("*.sha256"):
                digest, name = checksum.read_text().split()
                self.assertEqual(digest, hashlib.sha256((path / name).read_bytes()).hexdigest())

    def test_missing_extra_renamed_and_nested_files_fail(self):
        for change in ("missing", "extra", "renamed", "nested"):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as temporary:
                path = Path(temporary) / "downloads"
                TRANSFER.prepare(path)
                target = path / "iphone-use.rb"
                if change == "missing":
                    target.unlink()
                elif change == "extra":
                    (path / "unexpected.txt").write_text("extra")
                elif change == "renamed":
                    target.rename(path / "wrong.rb")
                else:
                    (path / "release-assets").mkdir()
                    target.rename(path / "release-assets/iphone-use.rb")
                with self.assertRaisesRegex(ValueError, "inventory differs"):
                    TRANSFER.verify(path)

    def test_each_file_is_verified_including_checksums(self):
        for name in TRANSFER.fixture_files():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                path = Path(temporary) / "downloads"
                TRANSFER.prepare(path)
                (path / name).write_bytes(b"corrupted")
                with self.assertRaisesRegex(ValueError, "digest differs"):
                    TRANSFER.verify(path)

    def test_corruption_with_recomputed_sidecar_still_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "downloads"
            TRANSFER.prepare(path)
            archive = next(path.glob("*.zip"))
            archive.write_bytes(b"wrong archive")
            archive.with_name(archive.name + ".sha256").write_text(
                f"{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}\n")
            with self.assertRaisesRegex(ValueError, "digest differs"):
                TRANSFER.verify(path)

    def test_old_output_and_missing_download_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "downloads"
            with self.assertRaisesRegex(ValueError, "Missing"):
                TRANSFER.verify(path)
            TRANSFER.prepare(path)
            with self.assertRaises(FileExistsError):
                TRANSFER.prepare(path)

    def test_symlink_cannot_substitute_for_downloaded_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "downloads"
            TRANSFER.prepare(path)
            target = path / "iphone-use.rb"
            outside = Path(temporary) / "baseline.rb"
            target.rename(outside)
            target.symlink_to(outside)
            with self.assertRaisesRegex(ValueError, "not a regular file"):
                TRANSFER.verify(path)

    def test_ci_exercises_release_action_pins_and_requires_transfer_success(self):
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        release = (ROOT / ".github/workflows/release.yml").read_text()
        upload = ci.split("      - name: Prepare artifact transfer fixtures\n", 1)[1].split("\n  artifact-transfer:", 1)[0]
        download = ci.split("\n  artifact-transfer:\n", 1)[1].split("\n  native:\n", 1)[0]
        for action, section in (("upload-artifact", upload), ("download-artifact", download)):
            pattern = rf"actions/{action}@([a-f0-9]{{40}})"
            self.assertEqual(re.findall(pattern, section), re.findall(pattern, release))
        self.assertIn("include-hidden-files: true", upload)
        self.assertIn("if-no-files-found: error", upload)
        for suffix in ("*.tar.gz", "*.tar.gz.sha256", "iphone-use.rb", "*.zip", "*.zip.sha256"):
            self.assertIn(".build/releases/" + suffix, upload)
            self.assertIn(".build/releases/" + suffix, release)
        self.assertIn("needs: quick", download)
        self.assertIn("digest-mismatch: error", download)
        self.assertIn("skip-decompress: false", download)
        self.assertIn("check-artifact-transfer.py verify", download)
        self.assertNotIn("check-artifact-transfer.py prepare", download)
        self.assertNotIn("continue-on-error:", upload + download)
        gate = ci.split("\n  test:\n", 1)[1]
        self.assertIn("needs: [quick, native, artifact-transfer]", gate)
        self.assertIn("ARTIFACT_RESULT: ${{ needs.artifact-transfer.result }}", gate)
        self.assertIn('test "$ARTIFACT_RESULT" = success', gate)


if __name__ == "__main__":
    unittest.main()
