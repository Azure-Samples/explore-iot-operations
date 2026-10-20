#!/usr/bin/env bash
# Anonymous full downloads, byte/digest checks, graph/module metadata and packaged Helm tests.
set -euo pipefail
if [[ $# != 1 ]]; then
  echo "Usage: bash scripts/verify-published.sh RELEASE_DIRECTORY" >&2
  exit 2
fi
release="$(cd -- "$1" && pwd)"
scripts="$(cd -- "$(dirname -- "$0")" && pwd)"
version="$(jq -er .version "$release/release.json")"
revision="$(jq -er .revision "$release/release.json")"
rm -f -- "$release/verification.json"
python3 - "$release" "$scripts/prepare-release.py" <<'PY'
import hashlib
import json
import re
import runpy
import sys
from pathlib import Path
import yaml
root = Path(sys.argv[1])
prepare = runpy.run_path(sys.argv[2])
release = json.loads((root / "release.json").read_text())
version = prepare["validate_version"](release["version"])
ledger = json.loads((root / "artifacts.json").read_text())
assert ledger["version"] == version and ledger["revision"] == release["revision"]
assert release["dependencies"] == ledger["dependencies"] == []
expected_names = set(prepare["MODULES"].values()) | set(prepare["GRAPHS"]) | {"dataflow-patterns"}
rows = [line.split("\t") for line in (root / "artifacts.tsv").read_text().splitlines()]
assert len(rows) == len(ledger["artifacts"]) == len(expected_names) == 6
assert {row[0] for row in rows} == {item["name"] for item in ledger["artifacts"]} == expected_names
for name, repository, digest, filename in rows:
    prefix = "helm" if name == "dataflow-patterns" else "dataflow-patterns"
    assert repository == f"ghcr.io/azure-samples/explore-iot-operations/{prefix}/{name}"
    assert re.fullmatch(r"sha256:[0-9a-f]{64}", digest)
    expected_file = (f"dataflow-patterns-{version}.tgz" if name == "dataflow-patterns"
                     else f"{name}.wasm" if name in prepare["MODULES"].values() else f"{name}.yaml")
    assert filename == expected_file
    item = next(item for item in ledger["artifacts"] if item["name"] == name)
    assert item["tagReference"] == f"{repository}:{version}"
    assert item["digestReference"] == f"{repository}@{digest}"
    assert item["manifestDigest"] == digest and item["filename"] == filename
    assert item["payloadDigest"] == "sha256:" + hashlib.sha256((root / "artifacts" / filename).read_bytes()).hexdigest()
for name in prepare["GRAPHS"]:
    prepare["validate_graph"](yaml.safe_load((root / "artifacts" / f"{name}.yaml").read_text()), version)
PY
mkdir -p "$release/anonymous"
auth="$release/anonymous/auth.json"
printf '{"auths":{}}\n' > "$auth"
while IFS=$'\t' read -r name repository digest filename; do
  reference="$repository:$version"
  if ! oras manifest fetch --registry-config "$auth" "$reference" > "$release/anonymous/$name.manifest.json"; then
    echo "Anonymous access failed for $reference. An authorized package administrator must make it public; no visibility is assumed." >&2
    exit 1
  fi
  actual="sha256:$(sha256sum "$release/anonymous/$name.manifest.json" | cut -d ' ' -f1)"
  [[ "$actual" == "$digest" ]]
  jq -e --arg revision "$revision" --arg version "$version" \
    '.annotations["org.opencontainers.image.revision"] == $revision and
     .annotations["org.opencontainers.image.version"] == $version and
     .annotations["org.opencontainers.image.url"] == ("https://github.com/Azure-Samples/explore-iot-operations/tree/" + $revision) and
     .annotations["org.opencontainers.image.source"] == "https://github.com/Azure-Samples/explore-iot-operations"' \
    "$release/anonymous/$name.manifest.json" >/dev/null
  config_type=application/vnd.microsoft.aio.graph.v1+yaml
  layer_type=application/yaml
  if [[ "$name" == module-* ]]; then
    config_type=application/vnd.module.wasm.content.layer.v1+wasm
    layer_type=application/wasm
  elif [[ "$name" == dataflow-patterns ]]; then
    config_type=application/vnd.cncf.helm.config.v1+json
    layer_type=application/vnd.cncf.helm.chart.content.v1.tar+gzip
  fi
  jq -e --arg config "$config_type" --arg layer "$layer_type" --arg file "$filename" \
    '.config.mediaType == $config and (.layers | length) == 1 and
     .layers[0].mediaType == $layer and
     .layers[0].annotations["org.opencontainers.image.title"] == $file' \
    "$release/anonymous/$name.manifest.json" >/dev/null
  config_digest="$(jq -er .config.digest "$release/anonymous/$name.manifest.json")"
  oras blob fetch --registry-config "$auth" "$repository@$config_digest" \
    --output "$release/anonymous/$name.config"
  [[ "sha256:$(sha256sum "$release/anonymous/$name.config" | cut -d ' ' -f1)" == "$config_digest" ]]
  expected_config="empty-config.json"
  if [[ "$name" == module-* ]]; then
    expected_config="module-config.json"
  elif [[ "$name" == dataflow-patterns ]]; then
    expected_config="chart-config.json"
  fi
  cmp -- "$release/artifacts/$expected_config" "$release/anonymous/$name.config"
  if [[ "$name" == dataflow-patterns ]]; then
    jq -e --arg version "$version" --arg revision "$revision" \
      '.name == "dataflow-patterns" and .version == $version and .appVersion == $version and
       .annotations["org.opencontainers.image.revision"] == $revision' \
      "$release/anonymous/$name.config" >/dev/null
  fi
  mkdir -p "$release/anonymous/$name"
  # Pull by digest after resolving the tag, so a tag race cannot change the payload.
  oras pull --registry-config "$auth" "$repository@$digest" --output "$release/anonymous/$name"
  cmp -- "$release/artifacts/$filename" "$release/anonymous/$name/$filename"
  printf '%s\t%s\n' "$reference" "$digest"
done < "$release/artifacts.tsv"
# Helm must also recognize and pull the artifact, not just ORAS.
mkdir -p "$release/anonymous/helm"
mkdir -p "$release/anonymous/docker"
printf '{"auths":{}}\n' > "$release/anonymous/docker/config.json"
# Helm can fall back to Docker credentials even with a separate registry config.
DOCKER_CONFIG="$release/anonymous/docker" HELM_REGISTRY_CONFIG="$auth" helm pull \
  oci://ghcr.io/azure-samples/explore-iot-operations/helm/dataflow-patterns \
  --version "$version" --destination "$release/anonymous/helm"
chart="$release/anonymous/helm/dataflow-patterns-$version.tgz"
cmp -- "$release/artifacts/dataflow-patterns-$version.tgz" "$chart"
python3 "$scripts/check-chart.py" "$chart" --version "$version" --revision "$revision"
python3 - "$release" "$version" "$scripts/prepare-release.py" <<'PY'
import runpy
import sys
from pathlib import Path
import yaml
root, version = Path(sys.argv[1]), sys.argv[2]
prepare = runpy.run_path(sys.argv[3])
for name in prepare["GRAPHS"]:
    graph = yaml.safe_load((root / "anonymous" / name / f"{name}.yaml").read_text())
    prepare["validate_graph"](graph, version)
print("Anonymous full pulls and published chart/graph/module consistency passed.")
print("This is artifact validation, not proof of execution on an AIO runtime.")
PY
python3 - "$release" <<'PY'
import json
import sys
from pathlib import Path
root = Path(sys.argv[1])
ledger = json.loads((root / "artifacts.json").read_text())
ledger.update(anonymousFullPullsVerified=True, packagedChartVerified=True, runtimeVerified=False)
(root / "verification.json").write_text(json.dumps(ledger, indent=2) + "\n")
PY
