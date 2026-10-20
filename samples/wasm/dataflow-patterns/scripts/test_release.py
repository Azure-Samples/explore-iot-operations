#!/usr/bin/env python3
"""Offline release-stamping and chart regression checks."""
import copy
import importlib.util
import json
import shutil
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

import yaml

SCRIPTS = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("prepare_release", SCRIPTS / "prepare-release.py")
prepare = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(prepare)


class ReleaseTests(unittest.TestCase):
    def test_semver(self):
        for version in ("1.0.0", "1.0.0-rc.1", "0.2.3-review-42"):
            self.assertEqual(prepare.validate_version(version), version)
        for version in ("01.0.0", "1.0.0-01", "1.0", "v1.0.0", "1.0.0+build",
                        "1.0.0;echo injected", "1.0.0\n", ""):
            with self.subTest(version=version), self.assertRaises(ValueError):
                prepare.validate_version(version)

    def test_stamp_graph_preserves_contract(self):
        graph = {
            "metadata": {"name": "sample", "version": "1.0.0"},
            "operations": [
                {"name": "source", "operationType": "source"},
                {"name": "transform", "operationType": "map",
                 "module": f"{prepare.REPOSITORY}/module-dataflow-patterns:1.0.0"},
                {"name": "filter", "operationType": "filter",
                 "module": f"{prepare.REPOSITORY}/module-dataflow-patterns:1.0.0"},
            ],
            "connections": [{"from": {"name": "source"}, "to": {"name": "transform"}}],
            "moduleConfigurations": [{"parameters": {"settings": {"default": '{"role":"align-by-time"}'}}}],
        }
        original = copy.deepcopy(graph)
        result = prepare.stamp_graph(graph, "1.0.0-rc.1")
        self.assertEqual(result["metadata"]["version"], "1.0.0-rc.1")
        self.assertTrue(result["operations"][1]["module"].endswith(":1.0.0-rc.1"))
        self.assertEqual(result["operations"][2]["module"], result["operations"][1]["module"])
        prepare.validate_graph(result, "1.0.0-rc.1")
        self.assertEqual(result["connections"], original["connections"])
        self.assertEqual(result["moduleConfigurations"], original["moduleConfigurations"])

    def test_rejects_missing_or_foreign_modules(self):
        module = f"{prepare.REPOSITORY}/module-dataflow-patterns:1.0.0"
        valid = [{"operationType": kind, "module": module} for kind in ("map", "filter")]
        invalid = [[], valid[:1], valid + [valid[0]],
                   [valid[0], {"operationType": "filter"}]]
        for foreign in ("another/repository:1.0.0",
                        "mcr.microsoft.com/azureiotoperations/module-dataflow-filter:1.0.0",
                        f"{prepare.REPOSITORY}/module-dataflow-patterns:1.0.1",
                        f"{prepare.REPOSITORY}/module-dataflow-patterns:invalid"):
            invalid.append([valid[0], {"operationType": "filter", "module": foreign}])
        for operations in invalid:
            with self.subTest(operations=operations), self.assertRaises(ValueError):
                prepare.stamp_graph({"metadata": {}, "operations": operations}, "1.0.0")
        with self.assertRaises(ValueError):
            prepare.validate_graph({"metadata": {"version": "1.0.0"}, "operations": valid},
                                   "1.0.0-rc.1")

    def test_actual_graphs_preserve_defaults_and_self_contained_filter(self):
        contracts = json.loads((SCRIPTS.parent / "contracts.json").read_text())
        self.assertIn("wasm-graph:processor/filter@1.1.0", contracts["artifacts"]["componentExports"])
        for name in prepare.GRAPHS:
            graph = yaml.safe_load((SCRIPTS.parent / f"{name}.yaml").read_text())
            before = copy.deepcopy(graph)
            stamped = prepare.stamp_graph(graph, "1.0.0-rc.1")
            self.assertEqual(stamped["moduleConfigurations"], before["moduleConfigurations"])
            modules = [op["module"] for op in stamped["operations"] if op.get("module")]
            self.assertEqual(modules, [
                f"{prepare.REPOSITORY}/module-dataflow-patterns:1.0.0-rc.1",
                f"{prepare.REPOSITORY}/module-dataflow-patterns:1.0.0-rc.1",
            ])

    def test_prepare_never_mutates_source(self):
        workspace = SCRIPTS / ".work" / f"test-{uuid.uuid4().hex}"
        source = workspace / "sample"
        source.mkdir(parents=True)
        try:
            (source / "Cargo.toml").write_text('[package]\nname = "module-dataflow-patterns"\nversion = "1.0.0"\n')
            (source / "Cargo.lock").write_text('version = 4\n[[package]]\nname = "module-dataflow-patterns"\nversion = "1.0.0"\n')
            for name in prepare.GRAPHS:
                (source / f"{name}.yaml").write_text(yaml.safe_dump({
                    "metadata": {"version": "1.0.0"},
                    "operations": [
                        {"operationType": kind,
                         "module": f"{prepare.REPOSITORY}/module-dataflow-patterns:1.0.0"}
                        for kind in ("map", "filter")
                    ],
                }))
            shutil.copytree(SCRIPTS.parent / "chart", source / "chart")
            before = {path.relative_to(source): path.read_bytes() for path in source.rglob("*") if path.is_file()}
            output = workspace / "release"
            with patch.object(prepare, "BASE", source):
                prepare.prepare("1.0.0-rc.1", "a" * 40, output)
                with self.assertRaises(ValueError):
                    prepare.prepare("1.0.0-rc.1", "a" * 40, output)
            after = {path.relative_to(source): path.read_bytes() for path in source.rglob("*") if path.is_file()}
            self.assertEqual(before, after)
            self.assertEqual(json.loads((output / "release.json").read_text())["revision"], "a" * 40)
            ledger = json.loads((output / "release.json").read_text())
            self.assertEqual(ledger["chartDefaults"]["profile"], {"create": True})
            self.assertEqual(ledger["chartDefaults"]["profileInstanceCount"], 1)
            self.assertEqual(ledger["dependencies"], [])
            self.assertFalse(ledger["runtimeVerified"])
            self.assertIn('version = "1.0.0-rc.1"', (output / "source" / "Cargo.lock").read_text())
            self.assertEqual(yaml.safe_load((output / "chart" / "values.yaml").read_text())["artifactVersion"],
                             "1.0.0-rc.1")
        finally:
            shutil.rmtree(workspace)


if __name__ == "__main__":
    unittest.main()
