#!/usr/bin/env python3
"""Regression checks for the operator-selection packaging contract."""
import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "check_components", Path(__file__).with_name("check-components.py")
)
components = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(components)


class ComponentTests(unittest.TestCase):
    @patch.object(components.subprocess, "run")
    @patch.object(components.subprocess, "check_output")
    def test_each_component_has_exactly_its_own_world(self, output, validate):
        output.side_effect = [
            "world root {\n  export wasm-graph:processor/map@1.1.0;\n}",
            "world root {\n  export wasm-graph:processor/filter@1.1.0;\n}",
        ]
        components.check(Path("artifacts"))
        self.assertEqual(validate.call_count, 2)
        self.assertEqual(output.call_count, 2)

    @patch.object(components.subprocess, "run")
    @patch.object(components.subprocess, "check_output")
    def test_rejects_dual_exports_missing_world_and_wrong_api(self, output, _validate):
        for exports in (
            "  export wasm-graph:processor/map@1.1.0;\n"
            "  export wasm-graph:processor/filter@1.1.0;\n",
            "  export wasm-graph:processor/filter@1.1.0;\n",
            "  export wasm-graph:processor/map@1.0.0;\n",
            "",
        ):
            output.return_value = f"world root {{\n{exports}}}"
            with self.subTest(exports=exports), self.assertRaises(ValueError):
                components.check(Path("artifacts"))


if __name__ == "__main__":
    unittest.main()
