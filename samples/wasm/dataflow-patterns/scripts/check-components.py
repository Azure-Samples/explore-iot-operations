#!/usr/bin/env python3
"""Validate both components and reject ambiguous AIO operator exports."""
import argparse
import re
import subprocess
from pathlib import Path


def check(directory):
    for name, interface in (
        ("module_dataflow_patterns.wasm", "map"),
        ("module_dataflow_pattern_filter.wasm", "filter"),
    ):
        component = directory / name
        subprocess.run(["wasm-tools", "validate", str(component)], check=True)
        wit = subprocess.check_output(
            ["wasm-tools", "component", "wit", str(component)], text=True
        )
        exports = re.findall(r"^  export ([^;]+);$", wit, re.MULTILINE)
        expected = [f"wasm-graph:processor/{interface}@1.1.0"]
        if exports != expected:
            raise ValueError(f"{name}: expected only {expected}, found {exports}")
        print(f"{name}: validated; exports only {exports[0]}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    check(parser.parse_args().directory)
