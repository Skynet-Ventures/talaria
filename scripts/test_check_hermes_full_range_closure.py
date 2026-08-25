from __future__ import annotations

import copy
import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("check_hermes_full_range_closure.py")
SPEC = importlib.util.spec_from_file_location("check_hermes_full_range_closure", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class FullRangeClosureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.manifest = MODULE.load_manifest()

    def test_repository_manifest_closes_all_seven_ledgers(self) -> None:
        MODULE.verify_manifest(self.manifest)
        self.assertEqual(len(self.manifest["ledgers"]), 7)
        self.assertEqual(
            self.manifest["conclusion"]["undispositionedPortableGapCount"], 0)
        self.assertEqual(
            [row["pullRequest"] for row in self.manifest["conclusion"]["openImplementationSlices"]],
            [73, 91, 94, 95, 98],
        )

    def test_component_hash_or_endpoint_drift_fails_closed(self) -> None:
        changed = copy.deepcopy(self.manifest)
        changed["ledgers"][0]["metadataSha256"] = "0" * 64
        with self.assertRaisesRegex(MODULE.CheckError, "metadata hash drift"):
            MODULE.verify_manifest(changed)

        changed = copy.deepcopy(self.manifest)
        changed["targetCommit"] = "1" * 40
        with self.assertRaisesRegex(MODULE.CheckError, "endpoint drift"):
            MODULE.verify_manifest(changed)

    def test_open_slice_and_blocker_drift_fails_closed(self) -> None:
        changed = copy.deepcopy(self.manifest)
        changed["conclusion"]["openImplementationSlices"].pop()
        with self.assertRaisesRegex(MODULE.CheckError, "slice inventory drift"):
            MODULE.verify_manifest(changed)

        changed = copy.deepcopy(self.manifest)
        changed["conclusion"]["upstreamContractBlockers"].pop()
        with self.assertRaisesRegex(MODULE.CheckError, "blocker inventory drift"):
            MODULE.verify_manifest(changed)


if __name__ == "__main__":
    unittest.main()
