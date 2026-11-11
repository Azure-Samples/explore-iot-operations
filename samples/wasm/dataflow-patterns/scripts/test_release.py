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
    def test_release_graph_set(self):
        self.assertEqual(set(prepare.GRAPHS), {
            "graph-align-by-time", "graph-correlate-by-id", "graph-versioned-predictor",
            "graph-report-by-exception", "graph-stable-alarm", "graph-offline-detection",
            "graph-running-total", "graph-smooth-readings",
        })
        self.assertEqual(len(prepare.GRAPHS), len(set(prepare.GRAPHS)))

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
                 "module": f"{prepare.REPOSITORY}/module-dataflow-pattern-filter:1.0.0"},
            ],
            "connections": [{"from": {"name": "source"}, "to": {"name": "transform"}}],
            "moduleConfigurations": [{"parameters": {"settings": {"default": '{"role":"align-by-time"}'}}}],
        }
        original = copy.deepcopy(graph)
        result = prepare.stamp_graph(graph, "1.0.0-rc.1")
        self.assertEqual(result["metadata"]["version"], "1.0.0-rc.1")
        self.assertTrue(result["operations"][1]["module"].endswith(":1.0.0-rc.1"))
        self.assertEqual(result["operations"][2]["module"],
                         f"{prepare.REPOSITORY}/module-dataflow-pattern-filter:1.0.0-rc.1")
        prepare.validate_graph(result, "1.0.0-rc.1")
        self.assertEqual(result["connections"], original["connections"])
        self.assertEqual(result["moduleConfigurations"], original["moduleConfigurations"])

    def test_rejects_missing_or_foreign_modules(self):
        valid = [{"operationType": kind, "module": f"{prepare.REPOSITORY}/{name}:1.0.0"}
                 for kind, name in prepare.MODULES.items()]
        invalid = [[], valid[:1], valid + [valid[0]],
                   [valid[0], {"operationType": "filter"}]]
        for foreign in ("another/repository:1.0.0",
                        "mcr.microsoft.com/azureiotoperations/module-dataflow-filter:1.0.0",
                        f"{prepare.REPOSITORY}/module-dataflow-patterns:1.0.0",
                        f"{prepare.REPOSITORY}/module-dataflow-pattern-filter:1.0.1",
                        f"{prepare.REPOSITORY}/module-dataflow-pattern-filter:invalid",
                        f"{prepare.REPOSITORY}/module-dataflow-pattern-filter:1.0.0@sha256:abc",
                        f"ghcr.io/{prepare.REPOSITORY}/module-dataflow-pattern-filter:1.0.0"):
            invalid.append([valid[0], {"operationType": "filter", "module": foreign}])
        invalid.extend([
            [{"operationType": "map", "module": valid[1]["module"]}, valid[1]],
            [{"operationType": "sink", "module": valid[0]["module"]}, valid[1]],
            valid + [{"operationType": "source", "module": "foreign/module:1.0.0"}],
        ])
        for operations in invalid:
            with self.subTest(operations=operations), self.assertRaises(ValueError):
                prepare.stamp_graph({"metadata": {}, "operations": operations}, "1.0.0")
        with self.assertRaises(ValueError):
            prepare.validate_graph({"metadata": {"version": "1.0.0"}, "operations": valid},
                                   "1.0.0-rc.1")

    def test_actual_graphs_preserve_defaults_and_two_module_dependencies(self):
        for name in prepare.GRAPHS:
            graph = yaml.safe_load((SCRIPTS.parent / f"{name}.yaml").read_text())
            before = copy.deepcopy(graph)
            stamped = prepare.stamp_graph(graph, "1.0.0-rc.1")
            self.assertEqual(stamped["moduleConfigurations"], before["moduleConfigurations"])
            modules = [op["module"] for op in stamped["operations"] if op.get("module")]
            self.assertEqual(modules, [
                f"{prepare.REPOSITORY}/module-dataflow-patterns:1.0.0-rc.1",
                f"{prepare.REPOSITORY}/module-dataflow-pattern-filter:1.0.0-rc.1",
            ])
            prepare.validate_graph(stamped, "1.0.0-rc.1")

    def test_pinned_crate_versions_and_unrelated_packages_are_not_stamped(self):
        workspace = SCRIPTS / ".work" / f"stamp-test-{uuid.uuid4().hex}"
        workspace.mkdir(parents=True)
        try:
            path = workspace / "Cargo.lock"
            pinned = (
                '[[package]]\nname = "wasm_graph_sdk"\nversion = "1.1.3"\n\n'
                '[[package]]\nname = "module-dataflow-patterns-helper"\nversion = "1.0.0"\n'
            )
            original = 'version = 4\n' + "".join(
                f'[[package]]\nversion = "1.0.0"\nname = "{name}"\n\n'
                for name in prepare.MODULES.values()
            ) + pinned
            path.write_text(original)
            for name in prepare.MODULES.values():
                prepare.stamp_package(path, name, "1.0.0-rc.2", lock=True)
            self.assertIn(pinned, path.read_text())
            self.assertEqual(path.read_text().count('version = "1.0.0-rc.2"'), 2)
            before = path.read_bytes()
            with self.assertRaises(ValueError):
                prepare.stamp_package(path, "missing-package", "1.0.0-rc.2", lock=True)
            self.assertEqual(path.read_bytes(), before)
            path.write_text(original + '[[package]]\nname = "module-dataflow-patterns"\nversion = "1.0.0"\n')
            before = path.read_bytes()
            with self.assertRaises(ValueError):
                prepare.stamp_package(path, "module-dataflow-patterns", "1.0.0-rc.2", lock=True)
            self.assertEqual(path.read_bytes(), before)
        finally:
            shutil.rmtree(workspace)

    def test_prepare_never_mutates_source(self):
        workspace = SCRIPTS / ".work" / f"test-{uuid.uuid4().hex}"
        source = workspace / "sample"
        source.mkdir(parents=True)
        try:
            pins = ('[dependencies]\nwasm_graph_sdk = { version = "=1.1.3", registry = "aio-wg" }\n'
                    'wit-bindgen = "=0.22.0"\nserde_json = "=1.0.145"\n')
            for role, name in prepare.MODULES.items():
                directory = source / "filter" if role == "filter" else source
                directory.mkdir(exist_ok=True)
                (directory / "Cargo.toml").write_text(
                    f'[package]\nedition = "2021"\nname = "{name}"\nversion = "1.0.0-rc.3"\n\n' + pins
                )
            (source / "Cargo.toml").write_text(
                (source / "Cargo.toml").read_text() + '\n[workspace]\nmembers = ["filter"]\n'
            )
            (source / "filter" / "src").mkdir()
            (source / "filter" / "src" / "lib.rs").write_text("// filter component\n")
            lock_pins = ('[[package]]\nname = "wasm_graph_sdk"\nversion = "1.1.3"\n'
                         'source = "registry+https://example.invalid/index"\n\n'
                         '[[package]]\nname = "wit-bindgen"\nversion = "0.22.0"\n')
            (source / "Cargo.lock").write_text(
                'version = 4\n' + "".join(
                    f'[[package]]\nname = "{name}"\nversion = "1.0.0-rc.3"\n\n'
                    for name in prepare.MODULES.values()
                ) + lock_pins
            )
            for name in prepare.GRAPHS:
                (source / f"{name}.yaml").write_text(yaml.safe_dump({
                    "metadata": {"version": "1.0.0-rc.3"},
                    "operations": [
                        {"operationType": kind,
                         "module": f"{prepare.REPOSITORY}/{name}:1.0.0-rc.3"}
                        for kind, name in prepare.MODULES.items()
                    ],
                }))
            shutil.copytree(SCRIPTS.parent / "chart", source / "chart")
            shutil.copytree(SCRIPTS.parent / "manifests", source / "manifests")
            prepare.stamp_manifests(source / "manifests", "1.0.0-rc.3")
            (source / "ticker").mkdir()
            (source / "ticker" / "ticker.py").write_text("# ticker source\n")
            before = {path.relative_to(source): path.read_bytes() for path in source.rglob("*") if path.is_file()}
            output = workspace / "release"
            with patch.object(prepare, "BASE", source):
                prepare.prepare("7.8.9-rc.4", "a" * 40, output)
                with self.assertRaises(ValueError):
                    prepare.prepare("7.8.9-rc.4", "a" * 40, output)
            after = {path.relative_to(source): path.read_bytes() for path in source.rglob("*") if path.is_file()}
            self.assertEqual(before, after)
            self.assertEqual(json.loads((output / "release.json").read_text())["revision"], "a" * 40)
            ledger = json.loads((output / "release.json").read_text())
            self.assertEqual(ledger["chartDefaults"]["profile"], {"create": True})
            self.assertEqual(ledger["chartDefaults"]["profileInstanceCount"], 1)
            self.assertEqual(ledger["dependencies"], [])
            self.assertFalse(ledger["runtimeVerified"])
            stamped_source = output / "source"
            lock = (stamped_source / "Cargo.lock").read_text()
            self.assertIn(lock_pins, lock)
            for name in prepare.MODULES.values():
                self.assertIn(f'name = "{name}"\nversion = "7.8.9-rc.4"', lock)
            for manifest in ("Cargo.toml", "filter/Cargo.toml"):
                text = (stamped_source / manifest).read_text()
                self.assertIn(pins, text)
                self.assertIn('version = "7.8.9-rc.4"', text)
            self.assertEqual((stamped_source / "filter" / "src" / "lib.rs").read_text(),
                             "// filter component\n")
            values = yaml.safe_load((output / "chart" / "values.yaml").read_text())
            self.assertEqual(values["artifactVersion"], "7.8.9-rc.4")
            self.assertFalse(values["ticker"]["enabled"])
            self.assertEqual(values["ticker"]["image"]["repository"], prepare.TICKER_REPOSITORY)
            self.assertEqual(values["ticker"]["image"]["tag"], "7.8.9-rc.4")
            self.assertEqual(ledger["chartDefaults"]["ticker"], values["ticker"])
            self.assertEqual((stamped_source / "ticker" / "ticker.py").read_text(), "# ticker source\n")
            chart = yaml.safe_load((output / "chart" / "Chart.yaml").read_text())
            self.assertEqual(chart["version"], "7.8.9-rc.4")
            self.assertEqual(chart["appVersion"], "7.8.9-rc.4")
            self.assertEqual({p.stem for p in (output / "artifacts").glob("*.yaml")}, set(prepare.GRAPHS))
            for name in prepare.GRAPHS:
                artifact = output / "artifacts" / f"{name}.yaml"
                prepare.validate_graph(yaml.safe_load(artifact.read_text()), "7.8.9-rc.4")
                self.assertEqual(artifact.read_bytes(), (stamped_source / f"{name}.yaml").read_bytes())
            for path in (stamped_source / "manifests").glob("*.yaml"):
                for doc in yaml.safe_load_all(path.read_text()):
                    if doc["kind"] == "DataflowGraph":
                        for node in doc["spec"]["nodes"]:
                            if "graphSettings" in node:
                                self.assertTrue(node["graphSettings"]["artifact"].endswith(":7.8.9-rc.4"))
        finally:
            shutil.rmtree(workspace)


if __name__ == "__main__":
    unittest.main()
