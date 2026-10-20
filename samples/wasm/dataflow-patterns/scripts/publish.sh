#!/usr/bin/env bash
# Run after prepare-release.py and the locked WASI build; only called on trusted refs.
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 || ( $# == 2 && "$2" != --stage-only ) ]]; then
  echo "Usage: bash scripts/publish.sh RELEASE_DIRECTORY [--stage-only]" >&2
  exit 2
fi
release="$(cd -- "$1" && pwd)"
rm -f -- "$release/verification.json"
version="$(jq -er .version "$release/release.json")"
revision="$(jq -er .revision "$release/release.json")"
[[ "$revision" =~ ^[0-9a-f]{40}$ ]]
: "${SOURCE_DATE_EPOCH:?Set to the source commit timestamp}"
created="$(date -u -d "@$SOURCE_DATE_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')"
namespace=ghcr.io/azure-samples/explore-iot-operations
source_url=https://github.com/Azure-Samples/explore-iot-operations
python3 - "$release" "$(dirname -- "$0")/prepare-release.py" <<'PY'
import json
import runpy
import sys
from pathlib import Path
import yaml
root = Path(sys.argv[1])
prepare = runpy.run_path(sys.argv[2])
ledger = json.loads((root / "release.json").read_text())
prepare["validate_version"](ledger["version"])
assert ledger["dependencies"] == [], "External module dependencies are forbidden"
for name in prepare["GRAPHS"]:
    graph = yaml.safe_load((root / "artifacts" / f"{name}.yaml").read_text())
    prepare["validate_graph"](graph, ledger["version"])
PY
mkdir -p "$release/layouts"
cp -- "$release/artifacts/module_dataflow_patterns.wasm" \
  "$release/artifacts/module-dataflow-patterns.wasm"
helm lint "$release/chart" --strict
helm package "$release/chart" --destination "$release/artifacts"
# Helm's gzip timestamp and tar mtimes otherwise make same-commit retries differ.
python3 - "$release/artifacts/dataflow-patterns-$version.tgz" "$SOURCE_DATE_EPOCH" <<'PY'
import gzip
import io
import sys
import tarfile
from pathlib import Path
path = Path(sys.argv[1])
with tarfile.open(path) as archive:
    files = [(member, archive.extractfile(member).read()) for member in archive.getmembers() if member.isfile()]
buffer = io.BytesIO()
with tarfile.open(fileobj=buffer, mode="w", format=tarfile.USTAR_FORMAT) as archive:
    for member, data in sorted(files, key=lambda item: item[0].name):
        member.mtime = int(sys.argv[2])
        member.uid = member.gid = 0
        member.uname = member.gname = ""
        member.mode = 0o644
        member.pax_headers = {}
        archive.addfile(member, io.BytesIO(data))
compressed = io.BytesIO()
with gzip.GzipFile(fileobj=compressed, mode="wb", filename="", mtime=0) as archive:
    archive.write(buffer.getvalue())
path.write_bytes(compressed.getvalue())
PY
python3 "$(dirname -- "$0")/check-chart.py" "$release/artifacts/dataflow-patterns-$version.tgz" \
  --version "$version" --revision "$revision"
helm show chart "$release/chart" | python3 -c \
  'import json,sys,yaml; json.dump(yaml.safe_load(sys.stdin),sys.stdout)' > "$release/artifacts/chart-config.json"
: > "$release/artifacts/empty-config.json"
printf '{}\n' > "$release/artifacts/module-config.json"
annotations=(
  --annotation "org.opencontainers.image.source=$source_url"
  --annotation "org.opencontainers.image.url=$source_url/tree/$revision"
  --annotation "org.opencontainers.image.revision=$revision"
  --annotation "org.opencontainers.image.version=$version"
  --annotation "org.opencontainers.image.created=$created"
)
: > "$release/artifacts.tsv"
for name in module-dataflow-patterns graph-align-by-time graph-correlate-by-id graph-versioned-predictor dataflow-patterns; do
  repository="$namespace/dataflow-patterns/$name"
  config="empty-config.json:application/vnd.microsoft.aio.graph.v1+yaml"
  layer="$name.yaml:application/yaml"
  if [[ "$name" == module-* ]]; then
    config="module-config.json:application/vnd.module.wasm.content.layer.v1+wasm"
    layer="$name.wasm:application/wasm"
  elif [[ "$name" == dataflow-patterns ]]; then
    repository="$namespace/helm/dataflow-patterns"
    config="chart-config.json:application/vnd.cncf.helm.config.v1+json"
    layer="dataflow-patterns-$version.tgz:application/vnd.cncf.helm.chart.content.v1.tar+gzip"
  fi
  layout="$release/layouts/$name"
  (
    cd -- "$release/artifacts"
    oras push --oci-layout "$layout:$version" --config "$config" \
      "${annotations[@]}" "$layer" >/dev/null
  )
  digest="$(oras manifest fetch --oci-layout "$layout:$version" --descriptor | jq -er .digest)"
  printf '%s\t%s\t%s\t%s\n' "$name" "$repository" "$digest" "${layer%%:*}" >> "$release/artifacts.tsv"
done
python3 - "$release" "$version" "$revision" <<'PY'
import hashlib
import json
import sys
from pathlib import Path
root, version, revision = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
artifacts = []
for line in (root / "artifacts.tsv").read_text().splitlines():
    name, repository, digest, filename = line.split("\t")
    artifacts.append({
        "name": name, "tagReference": f"{repository}:{version}",
        "digestReference": f"{repository}@{digest}", "manifestDigest": digest,
        "filename": filename,
        "payloadDigest": "sha256:" + hashlib.sha256((root / "artifacts" / filename).read_bytes()).hexdigest(),
    })
(root / "artifacts.json").write_text(json.dumps({
    "version": version, "revision": revision, "artifacts": artifacts,
    "dependencies": [],
    "runtimeVerified": False,
}, indent=2) + "\n")
PY
if [[ "${2:-}" == --stage-only ]]; then
  echo "Prepared local OCI layouts only; nothing published."
  exit 0
fi

check_existing() {
  local reference="$1" expected="$2" actual
  if actual="$(oras manifest fetch "$reference" --descriptor 2>"$release/registry-error.log" | jq -er .digest)"; then
    if [[ "$actual" != "$expected" ]]; then
      echo "Refusing immutable tag conflict: $reference ($actual != $expected). Choose a new version." >&2
      exit 1
    fi
    return 0
  fi
  # An auth/network failure is NOT proof that a tag is absent.
  if ! grep -Eqi 'MANIFEST_UNKNOWN|NAME_UNKNOWN|manifest unknown|not found' "$release/registry-error.log"; then
    cat "$release/registry-error.log" >&2
    exit 1
  fi
  return 1
}
# Check the whole set before publishing anything. The workflow serializes all releases.
while IFS=$'\t' read -r _name repository digest _filename; do
  check_existing "$repository:$version" "$digest" || true
done < "$release/artifacts.tsv"
while IFS=$'\t' read -r name repository digest _filename; do
  if ! check_existing "$repository:$version" "$digest"; then
    oras cp --from-oci-layout "$release/layouts/$name:$version" "$repository:$version"
  fi
  actual="$(oras manifest fetch "$repository:$version" --descriptor | jq -er .digest)"
  [[ "$actual" == "$digest" ]]
done < "$release/artifacts.tsv"
bash "$(dirname -- "$0")/verify-published.sh" "$release"
