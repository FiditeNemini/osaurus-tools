#!/usr/bin/env python3
# Regression tests for scripts/validate.py.
#
# Run with:
#   python3 scripts/test_validate.py
#
# No network access, credentials, or minisign installation required.

import hashlib
import importlib.util
import os
import sys
import tempfile
import unittest

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

_spec = importlib.util.spec_from_file_location(
    "validate", os.path.join(SCRIPT_DIR, "validate.py")
)
validate = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(validate)


def _artifact(url, sha256):
    return {
        "os": "macos",
        "arch": "arm64",
        "url": url,
        "sha256": sha256,
        "minisign": {
            "signature": (
                "untrusted comment: sig\n"
                "RWTdummydummydummydummydummydummydummydummydummydummy==\n"
                "trusted comment: ts\n"
                "RWTdummydummydummydummydummydummydummydummydummydummy==\n"
            )
        },
    }


class TestArtifactVerification(unittest.TestCase):
    PUBKEY = "RWTmCafy0+6ViS/ZFdYN+4v3ATECbUamgj4WDgGz7R2/DD1UEHp1eXwt"

    def test_unreachable_artifact_fails(self):
        artifact = _artifact("file:///nonexistent/osaurus-test-artifact.zip", "0" * 64)
        self.assertFalse(
            validate.verify_artifact_signature(artifact, self.PUBKEY, "test")
        )

    def test_sha256_mismatch_fails(self):
        with tempfile.NamedTemporaryFile(suffix=".zip", delete=False) as f:
            f.write(b"artifact contents")
            path = f.name
        try:
            artifact = _artifact("file://" + path, "0" * 64)
            self.assertFalse(
                validate.verify_artifact_signature(artifact, self.PUBKEY, "test")
            )
        finally:
            os.unlink(path)

    @unittest.skipIf(
        validate.shutil.which("minisign") is None, "minisign not installed"
    )
    def test_correct_sha256_reaches_signature_check(self):
        contents = b"artifact contents"
        with tempfile.NamedTemporaryFile(suffix=".zip", delete=False) as f:
            f.write(contents)
            path = f.name
        try:
            sha = hashlib.sha256(contents).hexdigest()
            # sha256 matches but the dummy signature is invalid, so
            # verification must still fail at the minisign step.
            artifact = _artifact("file://" + path, sha)
            self.assertFalse(
                validate.verify_artifact_signature(artifact, self.PUBKEY, "test")
            )
        finally:
            os.unlink(path)


if __name__ == "__main__":
    unittest.main(verbosity=2)
