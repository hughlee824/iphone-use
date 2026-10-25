"""Reject missing, stale or altered results in the non-publishing artifact smoke test."""
import hashlib
import importlib.util
from pathlib import Path
import re
import tarfile
import tempfile
import unittest
import zipfile

import yaml

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "artifact_transfer", ROOT / "scripts/checks/check-artifact-transfer.py")
TRANSFER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TRANSFER)


class WorkflowLoader(yaml.BaseLoader):
    # Actions inputs are strings. BaseLoader also preserves the GitHub `on` key
    # instead of interpreting it as a YAML 1.1 boolean, and cannot create objects.
    def construct_mapping(self, node, deep=False):
        result = {}
        for key_node, value_node in node.value:
            key = self.construct_object(key_node, deep=deep)
            assert isinstance(key, str), "Workflow mapping keys must be strings"
            assert key not in result, f"Duplicate YAML key: {key}"
            result[key] = self.construct_object(value_node, deep=deep)
        return result


def load_workflow(text):
    try:
        document = yaml.load(text, Loader=WorkflowLoader)
    except yaml.YAMLError as error:
        raise AssertionError(f"Invalid workflow YAML: {error}") from error
    assert isinstance(document, dict) and isinstance(document.get("jobs"), dict), "Missing workflow jobs"
    return document


def artifact_action(workflow, job, action, name):
    steps = workflow["jobs"][job]["steps"]
    matches = [step for step in steps
               if isinstance(step.get("uses"), str)
               and step["uses"].startswith(f"actions/{action}@")
               and isinstance(step.get("with"), dict)
               and step["with"].get("name") == name]
    assert len(matches) == 1, f"Expected exactly one {job}/{action} for {name}"
    step = matches[0]
    pin = re.fullmatch(rf"actions/{action}@([a-f0-9]{{40}})", step["uses"])
    assert pin, f"Invalid {action} pin"
    assert set(step) <= {"name", "id", "uses", "with", "continue-on-error"}, f"Unexpected {action} step fields"
    assert step.get("continue-on-error", "false") == "false", f"{action} must not ignore errors"
    return pin[1], dict(step["with"])


def check_transfer_contract(ci, release):
    # Defaults are from upload-artifact v7 / download-artifact v8 action.yml.
    # Recheck these when upgrading the pinned actions. Explicit equivalent values
    # are allowed; deleting a required override must restore the unsafe default.
    defaults = {
        "upload-artifact": {"archive": "true", "include-hidden-files": "false",
                            "if-no-files-found": "warn", "overwrite": "false",
                            "compression-level": "6"},
        "download-artifact": {"skip-decompress": "false", "digest-mismatch": "error",
                              "merge-multiple": "false"},
    }
    required = {
        "upload-artifact": {**defaults["upload-artifact"], "include-hidden-files": "true",
                            "if-no-files-found": "error"},
        "download-artifact": defaults["download-artifact"],
    }
    pins = {}
    for label, workflow, upload_job, download_job, name, source, destination, retention in (
        ("CI", ci, "quick", "artifact-transfer", "release-transfer-fixture",
         ".build/artifact-transfer/source/.build/releases", "${{ runner.temp }}/release-transfer-download", "1"),
        ("release", release, "build", "draft", "release-assets", ".build/releases", "release-assets", "7"),
    ):
        workflow = load_workflow(workflow)
        for action, job in (("upload-artifact", upload_job), ("download-artifact", download_job)):
            pin, inputs = artifact_action(workflow, job, action, name)
            if action in pins:
                assert pin == pins[action], f"{action} pins differ"
            pins[action] = pin
            expected = {**required[action], "name": name}
            if action == "upload-artifact":
                expected.update({"retention-days": retention, "path": {f"{source}/{suffix}" for suffix in
                    ("*.tar.gz", "*.tar.gz.sha256", "iphone-use.rb", "*.zip", "*.zip.sha256")}})
                assert isinstance(inputs.get("path"), str), f"{label} upload path must be a string"
                paths = [line.strip() for line in inputs["path"].splitlines() if line.strip()]
                assert len(paths) == len(set(paths)), f"{label} upload path contains duplicate entries"
                inputs["path"] = set(paths)
            else:
                expected["path"] = destination
            # Exact mappings also reject extra selectors (run-id, pattern, token,
            # etc.) that would silently change which artifact is tested.
            actual = {**defaults[action], **inputs}
            assert actual == expected, f"{label} {action} inputs differ: {actual!r} != {expected!r}"


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
        check_transfer_contract(ci, release)
        upload = ci.split("      - name: Prepare artifact transfer fixtures\n", 1)[1].split("\n  artifact-transfer:", 1)[0]
        download = ci.split("\n  artifact-transfer:\n", 1)[1].split("\n  native:\n", 1)[0]
        self.assertIn("needs: quick", download)
        self.assertIn("check-artifact-transfer.py verify", download)
        self.assertNotIn("check-artifact-transfer.py prepare", download)
        self.assertNotIn("continue-on-error:", upload + download)
        gate = ci.split("\n  test:\n", 1)[1]
        self.assertIn("needs: [quick, native, artifact-transfer]", gate)
        self.assertIn("ARTIFACT_RESULT: ${{ needs.artifact-transfer.result }}", gate)
        self.assertIn('test "$ARTIFACT_RESULT" = success', gate)


class ArtifactWorkflowContractTests(unittest.TestCase):
    def setUp(self):
        self.ci = (ROOT / ".github/workflows/ci.yml").read_text()
        self.release = (ROOT / ".github/workflows/release.yml").read_text()

    def test_check_jobs_install_pinned_yaml_in_isolated_environment(self):
        pin = next(line for line in (ROOT / "scripts/tests/requirements.txt").read_text().splitlines()
                   if line.startswith("PyYAML=="))
        self.assertEqual(yaml.__version__, pin.split("==", 1)[1])
        for workflow, job, suffix in ((self.ci, "quick", " --suite quick"),
                                       (self.ci, "native", " --suite native"),
                                       (self.release, "build", "")):
            with self.subTest(job=job):
                steps = load_workflow(workflow)["jobs"][job]["steps"]
                runs = [step["run"] for step in steps if "scripts/check.py" in step.get("run", "")]
                self.assertEqual(len(runs), 1)
                self.assertEqual(runs[0].splitlines(), [
                    "python3 -m venv .build/test-venv",
                    ".build/test-venv/bin/python -m pip install -r scripts/tests/requirements.txt",
                    ".build/test-venv/bin/python scripts/check.py" + suffix,
                ])

    def change_input(self, workflow, action, key, value):
        """Change only the transfer action, not a similarly named other step."""
        document = load_workflow(workflow)
        name = "release-transfer-fixture" if "artifact-transfer" in document["jobs"] else "release-assets"
        matches = [step for job in document["jobs"].values() for step in job["steps"]
                   if step.get("uses", "").startswith(f"actions/{action}@")
                   and step.get("with", {}).get("name") == name]
        self.assertEqual(len(matches), 1)
        inputs = matches[0]["with"]
        if value is None:
            inputs.pop(key, None)
        else:
            inputs[key] = value
        return yaml.safe_dump(document, sort_keys=False)

    def test_wrong_and_missing_transfer_options_fail_in_either_workflow(self):
        cases = (
            ("upload-artifact", "include-hidden-files", "false"),
            ("upload-artifact", "include-hidden-files", None),
            ("upload-artifact", "archive", "false"),
            ("upload-artifact", "if-no-files-found", "warn"),
            ("upload-artifact", "if-no-files-found", None),
            ("upload-artifact", "overwrite", "true"),
            ("upload-artifact", "compression-level", "0"),
            ("download-artifact", "skip-decompress", "true"),
            ("download-artifact", "digest-mismatch", "warn"),
            ("download-artifact", "merge-multiple", "true"),
            ("download-artifact", "run-id", "123"),
            ("download-artifact", "name", "wrong-artifact"),
            ("download-artifact", "path", "wrong-directory"),
        )
        for target in ("ci", "release", "both"):
            for action, key, value in cases:
                with self.subTest(target=target, action=action, key=key, value=value):
                    ci = self.change_input(self.ci, action, key, value) if target != "release" else self.ci
                    release = self.change_input(self.release, action, key, value) if target != "ci" else self.release
                    with self.assertRaisesRegex(AssertionError, rf"{key}|exactly one"):
                        check_transfer_contract(ci, release)

    def test_explicit_and_implicit_safe_defaults_pass(self):
        ci, release = self.ci, self.release
        for action, key, value in (("upload-artifact", "archive", "true"),
                                   ("download-artifact", "skip-decompress", "false"),
                                   ("download-artifact", "digest-mismatch", "error")):
            release = self.change_input(release, action, key, value)
        ci = self.change_input(ci, "download-artifact", "skip-decompress", None)
        ci = self.change_input(ci, "download-artifact", "digest-mismatch", None)
        check_transfer_contract(ci, release)

    def test_pins_steps_and_inventory_cannot_disappear_or_be_duplicated(self):
        pin, _ = artifact_action(load_workflow(self.release), "build", "upload-artifact", "release-assets")
        mutations = (
            self.release.replace(f"upload-artifact@{pin}", "upload-artifact@v7"),
            self.release.replace(pin, "0" * 40),
            self.release.replace("actions/upload-artifact@", "actions/other-action@"),
            self.release.replace("            .build/releases/*.zip.sha256\n", ""),
            self.release.replace("            .build/releases/*.zip.sha256\n", "            .build/releases/*.zip.sha256\n            .build/releases/extra.txt\n"),
            self.release.replace("          name: release-assets\n", "          name: release-assets\n          name: release-assets\n"),
        )
        for index, release in enumerate(mutations):
            with self.subTest(index=index), self.assertRaises(AssertionError):
                check_transfer_contract(self.ci, release)

    def test_duplicate_action_and_comments_cannot_satisfy_contract(self):
        start = self.release.index("      - uses: actions/upload-artifact@")
        end = self.release.index("\n  draft:", start)
        duplicate = self.release[:end] + self.release[start:end] + self.release[end:]
        commented = self.release.replace("          include-hidden-files: true",
                                         "          # include-hidden-files: true")
        for release in (duplicate, commented):
            with self.assertRaises(AssertionError):
                check_transfer_contract(self.ci, release)

    def test_named_duplicate_upload_and_download_steps_fail(self):
        for target, original, job_names in (("ci", self.ci, ("quick", "artifact-transfer")),
                                            ("release", self.release, ("build", "draft"))):
            for job_name, action in zip(job_names, ("upload-artifact", "download-artifact")):
                with self.subTest(target=target, action=action):
                    document = load_workflow(original)
                    steps = document["jobs"][job_name]["steps"]
                    step = next(s for s in steps if s.get("uses", "").startswith(f"actions/{action}@")
                                and s.get("with", {}).get("name") != "client-plugins")
                    steps.append({"name": "Duplicate transfer", **step})
                    changed = yaml.safe_dump(document, sort_keys=False)
                    with self.assertRaisesRegex(AssertionError, "Expected exactly one"):
                        check_transfer_contract(changed if target == "ci" else self.ci,
                                                changed if target == "release" else self.release)

    def test_names_comments_field_order_and_path_order_are_equivalent(self):
        variants = []
        for original in (self.ci, self.release):
            document = load_workflow(original)
            for job in document["jobs"].values():
                for index, step in enumerate(job["steps"]):
                    if any(step.get("uses", "").startswith(f"actions/{action}@") for action in
                           ("upload-artifact", "download-artifact")):
                        step = {"name": "Transfer files", "id": f"transfer_{index}", **step}
                        if "upload-artifact@" in step["uses"]:
                            paths = step["with"]["path"].splitlines()
                            step["with"]["path"] = "\n".join(reversed(paths)) + "\n"
                        job["steps"][index] = dict(reversed(list(step.items())))
            variants.append(yaml.safe_dump(document, sort_keys=False))
        check_transfer_contract(*variants)
        for original, target in ((self.ci, "ci"), (self.release, "release")):
            # Comments and literal block chomping affect syntax, not the inputs.
            changed = original.replace("        with:\n", "        # Inputs for this action\n        with:\n")
            changed = changed.replace("          path: |\n", "          path: |-\n")
            check_transfer_contract(changed if target == "ci" else self.ci,
                                    changed if target == "release" else self.release)

    def test_yaml_errors_and_duplicate_keys_fail(self):
        for text, message in (("jobs: [", "Invalid workflow YAML"),
                              ("jobs: {}\njobs: {}\n", "Duplicate YAML key"),
                              (self.release.replace("          name: release-assets\n",
                               "          name: release-assets\n          name: other\n"), "Duplicate YAML key")):
            with self.subTest(message=message), self.assertRaisesRegex(AssertionError, message):
                load_workflow(text)

    def test_duplicate_path_entries_are_not_hidden_by_set_comparison(self):
        changed = self.release.replace("            .build/releases/iphone-use.rb\n",
                                       "            .build/releases/iphone-use.rb\n" * 2)
        with self.assertRaisesRegex(AssertionError, "duplicate entries"):
            check_transfer_contract(self.ci, changed)


if __name__ == "__main__":
    unittest.main()
