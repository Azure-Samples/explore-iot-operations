import json
import os
from pathlib import Path
import stat
import subprocess
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
  local args=() source_config= destination_config= ref repository
  while (( $# )); do
    case "$1" in
      --registry-config) destination_config="$2"; shift 2 ;;
      --from-registry-config) source_config="$2"; shift 2 ;;
      --to-registry-config) destination_config="$2"; shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  printf '%s\n' "${args[*]}" >> "$RUNNER_TEMP/events"
  if [[ "${args[0]}" == login ]]; then
    test "$destination_config" = "$DEST_AUTH_FILE" || return 90
    test "$(cat)" = fixture-token || return 91
    if [[ "$FAILURE" == login ]]; then echo "Login failed" >&2; return 1; fi
    printf '{"auths":{}}\n' > "$DEST_AUTH_FILE"
  elif [[ "${args[0]}" == cp ]]; then
    test "${args[1]}" = --recursive || return 92
    test "$source_config" = "$SOURCE_AUTH_FILE" || return 93
    test "$destination_config" = "$DEST_AUTH_FILE" || return 94
    ref="${args[2]#"$SOURCE_REGISTRY/"}"
    repository="${ref%@*}"
    test "$ref" = "$repository@$EXPECTED_DIGEST" || return 95
    if [[ "$FAILURE" == copy && "$repository" == "$FAILURE_REPOSITORY" ]]; then
      echo "Copy failed" >&2; return 1
    fi
    mkdir -p "$RUNNER_TEMP/destination/$repository"
    cp "$RUNNER_TEMP/fixtures/$repository/"* "$RUNNER_TEMP/destination/$repository/"
  elif [[ "${args[0]} ${args[1]} ${args[2]}" == 'manifest fetch --descriptor' ]]; then
    ref="${args[3]}"
    if [[ "$destination_config" == "$SOURCE_AUTH_FILE" ]]; then
      if [[ "$FAILURE" == resolve && "$ref" == "$SOURCE_REGISTRY/$FAILURE_REPOSITORY:"* ]]; then
        echo "Source unavailable" >&2; return 1
      fi
      if [[ "$FAILURE" == invalid-digest ]]; then echo '{"digest":"invalid"}'; return; fi
    else
      test "$destination_config" = "$DEST_AUTH_FILE" || return 96
      if [[ "$FAILURE" == digest && "$ref" == */"$FAILURE_REPOSITORY:"* ]]; then
        printf '{"digest":"sha256:%064d"}\n' 0 | tr 0 2
        return
      fi
    fi
    jq -n --arg digest "$EXPECTED_DIGEST" '{digest:$digest}'
  else
    echo "Unexpected oras command: ${args[*]}" >&2
    return 1
  fi
}
helm() { echo "Charts must not be modified with Helm" >&2; return 1; }
yq() { echo "Charts must not be rewritten" >&2; return 1; }
cosign() { echo "No signatures may be created" >&2; return 1; }
'''


class AiGhcrWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(dir=ROOT)
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.env = {
            **os.environ,
            "RUNNER_TEMP": str(self.root),
            "GITHUB_ENV": str(self.root / "github-env"),
            "GITHUB_STEP_SUMMARY": str(self.root / "summary"),
            "GITHUB_REPOSITORY": "Azure-Samples/explore-iot-operations",
            "GITHUB_ACTOR": "publisher",
            "GHCR_TOKEN": "fixture-token",
            "SOURCE_REGISTRY": "mqbuilds.azurecr.io",
            "IMAGE_TAG": "1.0.0-rc-1234",
            "CHART_VERSION": "1.0.0-rc-1234-ghcr",
            "EXPECTED_DIGEST": DIGEST,
            "FAILURE": "",
            "FAILURE_REPOSITORY": "",
        }
        self.repositories = (
            "aio-ai-agent", "aio-ai-relay", "helm/aio-ai-agent", "helm/aio-ai-relay",
        )
        for repository in self.repositories:
            fixture = self.root / "fixtures" / repository
            fixture.mkdir(parents=True)
            (fixture / "content").write_bytes(b"original artifact bytes: " + repository.encode())
            (fixture / "referrers.json").write_text(json.dumps({
                "signatures": ["existing-notary-signature"], "sboms": ["original-sbom"],
            }))

    def run_step(self, name):
        result = subprocess.run(
            ["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-s"],
            input=MOCKS + STEPS[name], cwd=self.root, env=self.env,
            capture_output=True, text=True,
        )
        env_file = self.root / "github-env"
        if env_file.exists():
            self.env.update(line.split("=", 1) for line in env_file.read_text().splitlines())
        self.assertNotIn("fixture-token", result.stdout + result.stderr)
        return result

    def run_publish(self):
        for name in (
            "Validate inputs", "Resolve all source artifacts before publishing",
            "Log in to GHCR", "Copy and verify images and prepared charts",
        ):
            result = self.run_step(name)
            if result.returncode:
                return result
        return result

    def test_permissions_and_no_chart_modification_or_signing_tools(self):
        self.assertEqual(WORKFLOW["permissions"], {"contents": "read", "packages": "write"})
        for step in WORKFLOW["jobs"]["publish"]["steps"]:
            if "uses" in step:
                self.assertRegex(step["uses"], r"@[0-9a-f]{40}$")
                self.assertTrue(step["uses"].startswith("oras-project/setup-oras@"))
        scripts = "\n".join(STEPS.values())
        for removed in ("cosign", "helm ", "yq ", "CERTIFICATE_IDENTITY", "PUBLISHED_CHART_VERSION"):
            self.assertNotIn(removed, scripts)
        self.assertEqual(WORKFLOW["jobs"]["publish"]["steps"][-1]["if"], "always()")

    def test_copies_all_artifacts_unchanged_with_referrers_and_exact_versions(self):
        result = self.run_publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        events = (self.root / "events").read_text().splitlines()
        expected = [
            f"manifest fetch --descriptor mqbuilds.azurecr.io/{repository}:"
            + (self.env["CHART_VERSION"] if repository.startswith("helm/") else self.env["IMAGE_TAG"])
            for repository in self.repositories
        ] + ["login ghcr.io --username publisher --password-stdin"]
        for repository in self.repositories:
            tag = self.env["CHART_VERSION"] if repository.startswith("helm/") else self.env["IMAGE_TAG"]
            destination = f"ghcr.io/azure-samples/explore-iot-operations/{repository}:{tag}"
            expected.extend([
                f"cp --recursive mqbuilds.azurecr.io/{repository}@{DIGEST} {destination}",
                f"manifest fetch --descriptor {destination}",
            ])
            for name in ("content", "referrers.json"):
                self.assertEqual((self.root / "fixtures" / repository / name).read_bytes(),
                                 (self.root / "destination" / repository / name).read_bytes())
        self.assertEqual(events, expected)
        summary = (self.root / "summary").read_text()
        self.assertIn("no signatures are created", summary)
        self.assertNotIn("-ghcr-ghcr", summary)
        unrelated = self.root / "unrelated-auth.json"
        unrelated.write_text("preserve")
        self.assertEqual(stat.S_IMODE(Path(self.env["SOURCE_AUTH_FILE"]).stat().st_mode), 0o600)
        self.assertEqual(self.run_step("Remove registry credentials").returncode, 0)
        self.assertFalse(Path(self.env["SOURCE_AUTH_FILE"]).exists())
        self.assertFalse(Path(self.env["DEST_AUTH_FILE"]).exists())
        self.assertEqual(unrelated.read_text(), "preserve")

    def test_fork_changes_destination_only_not_chart_bytes(self):
        self.env["GITHUB_REPOSITORY"] = "ExampleUser/explore-iot-operations"
        result = self.run_publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ghcr.io/exampleuser/explore-iot-operations/helm/",
                      (self.root / "summary").read_text())
        for repository in self.repositories:
            self.assertEqual((self.root / "fixtures" / repository / "content").read_bytes(),
                             (self.root / "destination" / repository / "content").read_bytes())

    def test_source_failures_stop_before_login_or_any_copy(self):
        for failure in ("resolve", "invalid-digest"):
            with self.subTest(failure=failure):
                self.env.update(FAILURE=failure, FAILURE_REPOSITORY="helm/aio-ai-relay")
                (self.root / "events").unlink(missing_ok=True)
                result = self.run_publish()
                self.assertNotEqual(result.returncode, 0)
                events = (self.root / "events").read_text()
                self.assertNotIn("login ", events)
                self.assertNotIn("cp ", events)
                self.assertEqual(self.run_step("Remove registry credentials").returncode, 0)

    def test_copy_and_digest_failures_stop_without_reporting_failed_artifact(self):
        for failure in ("copy", "digest"):
            for repository in ("aio-ai-agent", "helm/aio-ai-agent"):
                with self.subTest(failure=failure, repository=repository):
                    self.env.update(FAILURE=failure, FAILURE_REPOSITORY=repository)
                    for name in ("events", "summary"):
                        (self.root / name).unlink(missing_ok=True)
                    result = self.run_publish()
                    self.assertNotEqual(result.returncode, 0)
                    diagnostic = "Copy failed" if failure == "copy" else "Destination digest mismatch"
                    self.assertIn(diagnostic, result.stdout + result.stderr)
                    summary = self.root / "summary"
                    self.assertNotIn(f"/{repository}:", summary.read_text() if summary.exists() else "")
                    events = (self.root / "events").read_text().splitlines()
                    copies = [line for line in events if line.startswith("cp ")]
                    self.assertEqual(len(copies), self.repositories.index(repository) + 1)
                    self.assertEqual(self.run_step("Remove registry credentials").returncode, 0)

    def test_login_failure_stops_before_copy(self):
        self.env["FAILURE"] = "login"
        result = self.run_publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Login failed", result.stderr)
        self.assertFalse((self.root / "destination").exists())
        self.assertEqual(self.run_step("Remove registry credentials").returncode, 0)

    def test_validates_inputs_without_deriving_a_new_chart_version(self):
        for key, values in {
            "CHART_VERSION": ("01.2.3", "1.0.0+metadata", "1.0.0-" + "a" * 123),
            "SOURCE_REGISTRY": ("https://mqbuilds.azurecr.io", "host/path", "UPPER.example"),
            "IMAGE_TAG": ("bad tag", "a" * 129),
        }.items():
            original = self.env[key]
            for value in values:
                with self.subTest(key=key, value=value):
                    self.env[key] = value
                    self.assertNotEqual(self.run_step("Validate inputs").returncode, 0)
            self.env[key] = original
        for version in ("1.0.0", "1.0.0-rc-1234-ghcr", "1.0.0-" + "a" * 122):
            self.env["CHART_VERSION"] = version
            self.assertEqual(self.run_step("Validate inputs").returncode, 0)
            self.assertEqual(self.env["CHART_VERSION"], version)


if __name__ == "__main__":
    unittest.main()
