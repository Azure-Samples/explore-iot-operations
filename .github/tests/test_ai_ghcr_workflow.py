import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = yaml.load(
    (ROOT / ".github/workflows/ai-ghcr.yaml").read_text(), Loader=yaml.BaseLoader
)
STEPS = {step["name"]: step["run"] for step in WORKFLOW["jobs"]["publish"]["steps"]
         if "run" in step}
DIGEST = "sha256:" + "1" * 64

MOCKS = r'''
oras() {
  local args=() ref chart layer digit
  while (( $# )); do
    case "$1" in
      --registry-config|--from-registry-config|--to-registry-config) shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  if [[ "${args[0]}" == login ]]; then
    cat >/dev/null
    printf '{"auths":{}}\n' > "$DEST_AUTH_FILE"
  elif [[ "${args[0]}" == cp ]]; then
    printf 'copy %s\n' "${args[*]}" >> "$RUNNER_TEMP/events"
  elif [[ "${args[0]} ${args[1]}" == 'manifest fetch' ]]; then
    if [[ "${args[2]}" == --descriptor ]]; then
      ref="${args[3]}"
      digit=1
      if [[ "$ref" == ghcr.io/*/helm/* ]]; then digit=2; fi
      if [[ "$FAILURE" == image-copy && "$ref" == ghcr.io/* && "$ref" != */helm/* ]]; then digit=3; fi
      if [[ "$FAILURE" == tag-drift && -f "$RUNNER_TEMP/verified" ]]; then digit=3; fi
      printf '{"digest":"sha256:%064d"}\n' 0 | tr 0 "$digit"
    else
      ref="${args[2]}"
      chart="${ref##*/}"
      chart="${chart%%[:@]*}"
      if [[ "$ref" == ghcr.io/* ]]; then
        layer="sha256:$(sha256sum "$RUNNER_TEMP/uploads/$chart-$PUBLISHED_CHART_VERSION.tgz" | cut -d ' ' -f 1)"
        if [[ "$FAILURE" == published-content ]]; then layer=sha256:incorrect; fi
      else
        layer="sha256:$(sha256sum "$RUNNER_TEMP/fixtures/$chart.tgz" | cut -d ' ' -f 1)"
      fi
      jq -n --arg layer "$layer" \
        '{layers:[{mediaType:"application/vnd.cncf.helm.chart.content.v1.tar+gzip",digest:$layer}]}'
    fi
  elif [[ "${args[0]} ${args[1]}" == 'blob fetch' ]]; then
    chart="${args[2]##*/}"
    chart="${chart%%[:@]*}"
    cp "$RUNNER_TEMP/fixtures/$chart.tgz" "${args[4]}"
  else
    echo "Unexpected oras command: ${args[*]}" >&2
    return 1
  fi
}
helm() {
  if [[ "$1" == push ]]; then
    printf 'push %s\n' "$*" >> "$RUNNER_TEMP/events"
    cp "$2" "$RUNNER_TEMP/uploads/"
  elif [[ "$1" == dependency ]]; then
    echo "Do not refresh frozen dependencies" >&2
    return 1
  else
    command helm "$@"
  fi
}
cosign() {
  printf 'cosign %s\n' "$*" >> "$RUNNER_TEMP/events"
  if [[ "$FAILURE" == "$1" ]]; then
    echo "Simulated cosign $1 failure" >&2
    return 1
  fi
  if [[ "$1" == verify ]]; then
    touch "$RUNNER_TEMP/verified"
    echo '[{"verified":true}]'
  fi
}
'''


class AiGhcrWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(dir=ROOT)
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        for name in ("fixtures", "uploads"):
            (self.root / name).mkdir()
        self.env = {
            **os.environ,
            "RUNNER_TEMP": str(self.root),
            "GITHUB_ENV": str(self.root / "github-env"),
            "GITHUB_STEP_SUMMARY": str(self.root / "summary"),
            "GITHUB_REPOSITORY": "Azure-Samples/explore-iot-operations",
            "GITHUB_SERVER_URL": "https://github.com",
            "GITHUB_WORKFLOW_REF": "Azure-Samples/explore-iot-operations/.github/workflows/ai-ghcr.yaml@refs/heads/main",
            "GITHUB_ACTOR": "publisher",
            "GHCR_TOKEN": "fixture-token",
            "SOURCE_REGISTRY": "mqbuilds.azurecr.io",
            "IMAGE_TAG": "1.0.0-rc-1234",
            "CHART_VERSION": "1.0.0-rc-1234",
            "FAILURE": "",
        }
        for chart in ("aio-ai-agent", "aio-ai-relay"):
            is_agent = chart == "aio-ai-agent"
            chart_dir = self.root / "fixtures" / chart
            (chart_dir / "templates").mkdir(parents=True)
            image = {"containerRegistry": "mqbuilds.azurecr.io", "repository": chart, "tag": "1.0.0"}
            values = {"agent": {"enabled": False, "image": image}, "mcp": {"enabled": True}} if is_agent else {"image": image}
            metadata = {"apiVersion": "v2", "name": chart, "version": self.env["CHART_VERSION"]}
            if is_agent:
                metadata["dependencies"] = [{
                    "name": "frozen", "version": "1.2.3",
                    "repository": "file://../frozen", "condition": "mcp.enabled",
                }]
                child = chart_dir / "charts/frozen"
                child.mkdir(parents=True)
                (child / "Chart.yaml").write_text("apiVersion: v2\nname: frozen\nversion: 1.2.3\n")
                (child / "values.yaml").write_text("image: original.example/frozen:1.2.3\n")
            (chart_dir / "Chart.yaml").write_text(yaml.safe_dump(metadata))
            (chart_dir / "values.yaml").write_text(yaml.safe_dump(values))
            image_path = ".Values.agent.image" if is_agent else ".Values.image"
            deployment = (
                "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: sample\n"
                "spec:\n  selector:\n    matchLabels:\n      app: sample\n"
                "  template:\n    metadata:\n      labels:\n        app: sample\n"
                "    spec:\n      containers:\n      - name: sample\n"
                f'        image: "{{{{ {image_path}.containerRegistry }}}}/'
                f'{{{{ {image_path}.repository }}}}:{{{{ {image_path}.tag }}}}"\n'
            )
            if is_agent:
                deployment = "{{- if .Values.agent.enabled }}\n" + deployment + "{{- end }}\n"
            (chart_dir / "templates/deployment.yaml").write_text(deployment)
            result = subprocess.run(["helm", "package", str(chart_dir), "-d", str(self.root / "fixtures")],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            (self.root / "fixtures" / f"{chart}-{self.env['CHART_VERSION']}.tgz").rename(
                self.root / "fixtures" / f"{chart}.tgz"
            )

    def run_step(self, name):
        result = subprocess.run(
            ["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-s"],
            input=MOCKS + STEPS[name], cwd=self.root, env=self.env,
            capture_output=True, text=True,
        )
        env_file = self.root / "github-env"
        if env_file.exists():
            self.env.update(line.split("=", 1) for line in env_file.read_text().splitlines())
        return result

    def run_publish(self):
        for name in (
            "Validate inputs", "Resolve all source artifacts before publishing",
            "Prepare and validate GHCR chart variants", "Log in to GHCR",
            "Copy and verify images", "Publish, sign, and verify GHCR charts",
        ):
            result = self.run_step(name)
            if result.returncode:
                return result
        return result

    def test_permissions_pinned_actions_and_signature_verification(self):
        self.assertEqual(WORKFLOW["permissions"], {
            "contents": "read", "packages": "write", "id-token": "write",
        })
        for step in WORKFLOW["jobs"]["publish"]["steps"]:
            if "uses" in step:
                self.assertRegex(step["uses"], r"@[0-9a-f]{40}$")
        signing = STEPS["Publish, sign, and verify GHCR charts"]
        self.assertIn('cosign sign --yes "$digest_reference"', signing)
        self.assertIn('--certificate-identity "$CERTIFICATE_IDENTITY"', signing)
        self.assertIn("--certificate-oidc-issuer https://token.actions.githubusercontent.com", signing)
        self.assertNotIn("--insecure", signing)
        self.assertNotIn("COSIGN_PRIVATE_KEY", signing)

    def test_prepares_and_signs_both_charts_preserving_frozen_dependencies(self):
        result = self.run_publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.env["PUBLISHED_CHART_VERSION"], "1.0.0-rc-1234-ghcr")
        self.assertEqual(self.env["DEST_AUTH_FILE"], str(Path(self.env["DOCKER_CONFIG"]) / "config.json"))
        events = (self.root / "events").read_text().splitlines()
        self.assertEqual(sum(line.startswith("copy ") for line in events), 2)
        self.assertTrue(all("/helm/" not in line for line in events if line.startswith("copy ")))
        self.assertTrue(all(line.startswith("copy ") for line in events[:2]))
        self.assertEqual(sum(line.startswith("cosign sign ") for line in events), 2)
        self.assertEqual(sum(line.startswith("cosign verify ") for line in events), 2)
        for chart in ("aio-ai-agent", "aio-ai-relay"):
            with tarfile.open(self.root / "uploads" / f"{chart}-{self.env['PUBLISHED_CHART_VERSION']}.tgz") as archive:
                values = yaml.safe_load(archive.extractfile(f"{chart}/values.yaml"))
                image = values["agent"]["image"] if chart == "aio-ai-agent" else values["image"]
                self.assertEqual(image, {
                    "containerRegistry": "ghcr.io",
                    "repository": f"azure-samples/explore-iot-operations/{chart}",
                    "tag": self.env["IMAGE_TAG"],
                })
                metadata = yaml.safe_load(archive.extractfile(f"{chart}/Chart.yaml"))
                self.assertEqual(metadata["version"], self.env["PUBLISHED_CHART_VERSION"])
                self.assertEqual(metadata["annotations"]["azureiotoperations.microsoft.com/source-digest"], DIGEST)
                if chart == "aio-ai-agent":
                    self.assertFalse(values["agent"]["enabled"])
                    with tarfile.open(self.root / "fixtures" / f"{chart}.tgz") as original:
                        for member in original.getmembers():
                            if member.isfile() and "/charts/" in member.name:
                                self.assertEqual(archive.extractfile(member.name).read(),
                                                 original.extractfile(member.name).read())
        self.assertEqual(self.run_step("Remove registry credentials").returncode, 0)
        self.assertFalse(Path(self.env["SOURCE_AUTH_FILE"]).exists())
        self.assertFalse(Path(self.env["DEST_AUTH_FILE"]).exists())

    def test_fork_destination_and_signing_identity(self):
        self.env["GITHUB_REPOSITORY"] = "ExampleUser/explore-iot-operations"
        self.env["GITHUB_WORKFLOW_REF"] = "ExampleUser/explore-iot-operations/.github/workflows/ai-ghcr.yaml@refs/heads/main"
        result = self.run_publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = (self.root / "summary").read_text()
        self.assertIn("ghcr.io/exampleuser/explore-iot-operations/helm/", summary)
        self.assertIn("https://github.com/" + self.env["GITHUB_WORKFLOW_REF"], summary)

    def test_failures_do_not_report_success(self):
        failures = {
            "image-copy": "Destination digest mismatch",
            "published-content": "Published chart content does not match",
            "sign": "Simulated cosign sign failure",
            "verify": "Simulated cosign verify failure",
            "tag-drift": "Chart tag moved during signing",
        }
        for failure, diagnostic in failures.items():
            with self.subTest(failure=failure):
                self.env["FAILURE"] = failure
                (self.root / "events").unlink(missing_ok=True)
                (self.root / "verified").unlink(missing_ok=True)
                result = self.run_publish()
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(diagnostic, result.stdout + result.stderr)
                summary = self.root / "summary"
                self.assertNotIn("Cosign signature verified", summary.read_text() if summary.exists() else "")
                if failure == "image-copy":
                    self.assertNotIn("push ", (self.root / "events").read_text())
                if failure == "published-content":
                    self.assertNotIn("cosign sign", (self.root / "events").read_text())
                self.assertEqual(self.run_step("Remove registry credentials").returncode, 0)

    def test_rejects_unsafe_archive_before_publication(self):
        package = self.root / "fixtures/aio-ai-agent.tgz"
        with tarfile.open(package, "w:gz") as archive:
            member = tarfile.TarInfo("../escaped")
            member.size = 3
            archive.addfile(member, io.BytesIO(b"bad"))
        result = self.run_publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unsafe or unexpected chart archive member", result.stderr)
        self.assertFalse((self.root / "events").exists())

    def test_rejects_invalid_and_overlong_versions(self):
        for version in ("01.2.3", "1.0.0+metadata", "1.0.0-" + "a" * 120):
            with self.subTest(version=version):
                self.env["CHART_VERSION"] = version
                self.assertNotEqual(self.run_step("Validate inputs").returncode, 0)
        self.env["CHART_VERSION"] = "1.0.0-preview.1"
        self.assertEqual(self.run_step("Validate inputs").returncode, 0)
        self.assertEqual(self.env["PUBLISHED_CHART_VERSION"], "1.0.0-preview.1-ghcr")


if __name__ == "__main__":
    unittest.main()
