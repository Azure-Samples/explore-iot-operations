#!/usr/bin/env bash
# Publish only the saved, tested image; never replace an existing immutable tag.
set -euo pipefail
[[ $# == 1 ]] || { echo "Usage: bash scripts/publish-ticker.sh RELEASE_DIRECTORY" >&2; exit 2; }
: "${DOCKER_CONFIG:?Use isolated Docker credentials}"
python3 - "$1" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile

root = Path(sys.argv[1]).resolve()
marker = root / "ticker-image-verification.json"
marker.unlink(missing_ok=True)
(root / "ticker-image.json").unlink(missing_ok=True)
release = json.loads((root / "release.json").read_text())
version, revision = release["version"], release["revision"]
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?", version):
    raise SystemExit("Invalid release version")
if not re.fullmatch(r"[0-9a-f]{40}", revision):
    raise SystemExit("Invalid source revision")
if version != os.environ.get("RELEASE_VERSION", version) or revision != os.environ.get("GITHUB_SHA", revision):
    raise SystemExit("Candidate does not match this release")
repository = "ghcr.io/azure-samples/explore-iot-operations/dataflow-pattern-ticker"
reference = f"{repository}:{version}"
source = "https://github.com/Azure-Samples/explore-iot-operations"
expected_labels = {
    "org.opencontainers.image.source": source,
    "org.opencontainers.image.revision": revision,
    "org.opencontainers.image.version": version,
    "org.opencontainers.image.url": f"{source}/tree/{revision}",
}


def digest(data):
    return "sha256:" + hashlib.sha256(data).hexdigest()


def run(*args, **kwargs):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, **kwargs).stdout


def labels(config):
    actual = json.loads(config)["config"]["Labels"]
    if any(actual.get(key) != value for key, value in expected_labels.items()):
        raise SystemExit("Ticker config labels do not match release")


archive = root / "ticker-image.tar"
with tarfile.open(archive) as saved:
    manifests = json.load(saved.extractfile("manifest.json"))
    if len(manifests) != 1 or manifests[0]["RepoTags"] != [reference]:
        raise SystemExit("Expected exactly the tested ticker image tag in Docker save")
    config = saved.extractfile(manifests[0]["Config"]).read()
labels(config)
config_digest = digest(config)
run("docker", "load", "--input", str(archive))
loaded = json.loads(run("docker", "image", "inspect", reference))
# Docker's containerd store exposes the manifest ID, with config identity separately.
loaded_config = (
    loaded[0].get("Descriptor", {}).get("annotations", {}).get("config.digest", loaded[0]["Id"])
    if len(loaded) == 1 else None
)
if loaded_config != config_digest:
    raise SystemExit("Loaded image differs from the tested Docker save config")

directory = root / "ticker-anonymous"
directory.mkdir(exist_ok=True)
auth = directory / "auth.json"
auth.write_text('{"auths":{}}\n')


def validate_manifest(data):
    manifest = json.loads(data)
    if manifest.get("schemaVersion") != 2 or not manifest.get("layers"):
        raise SystemExit("Expected a single image manifest with layers")
    if manifest["config"]["digest"] != config_digest:
        raise SystemExit("Refusing immutable ticker tag conflict: config digest differs")
    return manifest


existing = subprocess.run(
    ["oras", "manifest", "fetch", reference],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
)
if existing.returncode == 0:
    # Same config binds labels and uncompressed layer digests. Never push this tag.
    expected_manifest = existing.stdout
    validate_manifest(expected_manifest)
else:
    error = existing.stderr.decode(errors="replace")
    # ORAS 1.3 renders GHCR MANIFEST_UNKNOWN as a reference-qualified "not found".
    missing = re.search(r"\b(?:MANIFEST_UNKNOWN|NAME_UNKNOWN)\b|manifest unknown|name unknown", error, re.I)
    missing = missing or (
        error.startswith("Error response from registry: failed to fetch the content of ")
        and error.rstrip().endswith(f"{reference}: not found")
    )
    if not missing:
        raise SystemExit(f"Cannot establish ticker tag absence: {error}")
    run("docker", "push", reference)
    expected_manifest = run("oras", "manifest", "fetch", reference)
    validate_manifest(expected_manifest)

manifest_digest = digest(expected_manifest)
ledger = {
    "version": version, "revision": revision,
    "tagReference": reference,
    "digestReference": f"{repository}@{manifest_digest}",
    "manifestDigest": manifest_digest, "configDigest": config_digest,
    "runtimeVerified": False,
}
(root / "ticker-image.json").write_text(json.dumps(ledger, indent=2) + "\n")
# Resolve the public tag independently, then fetch blobs by immutable digest.
public = run("oras", "manifest", "fetch", "--registry-config", str(auth), reference)
if digest(public) != manifest_digest:
    raise SystemExit("Anonymous ticker manifest differs from published manifest")
manifest = validate_manifest(public)
(directory / "manifest.json").write_bytes(public)
for descriptor in [manifest["config"], *manifest["layers"]]:
    blob_digest = descriptor["digest"]
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", blob_digest):
        raise SystemExit("Unsupported image blob digest")
    path = directory / blob_digest.replace(":", "-")
    run("oras", "blob", "fetch", "--registry-config", str(auth),
        f"{repository}@{blob_digest}", "--output", str(path))
    hasher = hashlib.sha256()
    with path.open("rb") as blob:
        for chunk in iter(lambda: blob.read(1024 * 1024), b""):
            hasher.update(chunk)
    if f"sha256:{hasher.hexdigest()}" != blob_digest or path.stat().st_size != descriptor["size"]:
        raise SystemExit("Anonymous ticker blob digest/size mismatch")
    if blob_digest == config_digest:
        if path.read_bytes() != config:
            raise SystemExit("Anonymous ticker config differs from tested image")
        labels(path.read_bytes())
marker.write_text(json.dumps({
    **ledger, "anonymousFullPullVerified": True,
    "layersVerified": len(manifest["layers"]),
}, indent=2) + "\n")
print(f"Verified tested ticker image: {ledger['digestReference']}; runtime NOT verified")
PY
