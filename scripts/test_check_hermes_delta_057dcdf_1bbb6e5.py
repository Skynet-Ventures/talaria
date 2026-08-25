from __future__ import annotations

import copy
import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("check_hermes_delta_057dcdf_1bbb6e5.py")
SPEC = importlib.util.spec_from_file_location("check_hermes_delta_057dcdf_1bbb6e5", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class HermesDeltaAuditTests(unittest.TestCase):
    def setUp(self) -> None:
        self.manifest = MODULE.load_manifest()

    def test_repository_manifest_is_complete_and_holds_pin(self) -> None:
        commits, paths = MODULE.verify_manifest(self.manifest)
        self.assertEqual(len(commits), 130)
        self.assertEqual(len(paths), 324)
        self.assertFalse(self.manifest["pinDecision"]["canMoveCanonicalPin"])

    def test_inventory_hash_and_count_drift_fail_closed(self) -> None:
        changed = copy.deepcopy(self.manifest)
        changed["range"]["commitInventorySha256"] = "0" * 64
        with self.assertRaisesRegex(MODULE.CheckError, "inventory hash drift"):
            MODULE.verify_manifest(changed)

        changed = copy.deepcopy(self.manifest)
        changed["range"]["changedPathCount"] = 323
        with self.assertRaisesRegex(MODULE.CheckError, "path inventory count drift"):
            MODULE.verify_manifest(changed)

    def test_authority_and_pin_drift_fail_closed(self) -> None:
        changed = copy.deepcopy(self.manifest)
        changed["authorityFiles"][0]["changed"] = True
        with self.assertRaisesRegex(MODULE.CheckError, "changed-file count drift|changed flag drift"):
            MODULE.verify_manifest(changed)

        changed = copy.deepcopy(self.manifest)
        changed["pinDecision"]["canMoveCanonicalPin"] = True
        changed["pinDecision"]["nextPin"] = MODULE.TARGET
        with self.assertRaisesRegex(MODULE.CheckError, "canonical pin moved"):
            MODULE.verify_manifest(changed)

    def test_open_portable_delta_cannot_silently_disappear(self) -> None:
        changed = copy.deepcopy(self.manifest)
        changed["portableDeltas"].pop()
        with self.assertRaisesRegex(MODULE.CheckError, "portable delta inventory drift"):
            MODULE.verify_manifest(changed)


if __name__ == "__main__":
    unittest.main()
