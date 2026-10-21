import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "deploy.sh"
APP_ID = "11111111-1111-4111-8111-111111111111"
TENANT_ID = "22222222-2222-4222-8222-222222222222"
BASE_ARGS = [
    "--resource-group", "test-rg",
    "--relay-namespace-name", "test-relay",
    "--apim-name", "test-apim",
    "--apim-publisher-email", "test@example.com",
    "--apim-publisher-name", "Test",
    "--cluster-name", "test-cluster",
    "--aio-extension-name", "test-extension",
    "--mcp-role", "Reader",
]
EXISTING_ARGS = ["--entra-app-id", APP_ID, "--entra-tenant-id", TENANT_ID]
STUB = r"""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["CALLS"], "a") as log:
    log.write(json.dumps([name, *args]) + "\n")
if name == "az":
    if args[:2] == ["account", "show"]:
        if "--query" in args:
            print(os.environ["TEST_TENANT_ID"])
    elif args[:1] == ["ad"]:
        if os.environ.get("EXISTING"):
            sys.exit("Unexpected Graph call in existing-app mode")
        if args[1:3] == ["app", "list"]:
            print('[{}]' if os.environ.get("APP_EXISTS") else '[]')
        elif args[1:3] == ["app", "create"]:
            print(json.dumps({"appId": os.environ["TEST_APP_ID"]}))
        elif args[1:3] == ["sp", "create"]:
            print('{"id":"test-sp-id"}')
        elif args[1:3] not in (["app", "update"], ["sp", "update"]):
            sys.exit("Unexpected Graph operation")
    elif args[:3] == ["deployment", "group", "create"]:
        if os.environ.get("FAIL_DEPLOY"):
            sys.exit("Simulated deployment error")
    elif args[:3] == ["deployment", "group", "show"]:
        print(json.dumps([{
            "protocol": "mcp",
            "relayUrl": "https://test.servicebus.windows.net/hybridconnection",
            "hybridConnectionName": "hybridconnection",
            "apimGatewayUrl": "https://test.azure-api.net/mcp/hybridconnection"
        }]))
    else:
        sys.exit("Unexpected Azure operation")
elif name == "helm":
    if args[0] == "pull":
        version = args[args.index("--version") + 1]
        dest = Path(args[args.index("--destination") + 1])
        (dest / f"aio-ai-relay-{version}.tgz").touch()
    elif args[:2] != ["upgrade", "--install"]:
        sys.exit("Unexpected Helm operation")
elif name == "kubectl":
    if args == ["config", "current-context"]:
        print("test-context")
    elif args[:2] == ["create", "namespace"]:
        print("{}")
    elif args[:1] == ["apply"]:
        sys.stdin.read()
    elif args[:2] != ["rollout", "status"]:
        sys.exit("Unexpected kubectl operation")
else:
    sys.exit("Unexpected tool")
"""


class DeployTests(unittest.TestCase):
    def run_script(self, args=(), **variables):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for tool in ("az", "helm", "kubectl"):
                executable = root / tool
                executable.write_text(STUB)
                executable.chmod(0o700)
            log = root / "calls.jsonl"
            env = dict(os.environ, **variables)
            env.update(
                PATH=f"{root}{os.pathsep}{os.environ['PATH']}",
                CALLS=str(log),
                TEST_APP_ID=APP_ID,
                TEST_TENANT_ID=TENANT_ID,
            )
            result = subprocess.run(
                ["bash", str(SCRIPT), *BASE_ARGS, *args],
                env=env, capture_output=True, text=True, timeout=30,
            )
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return result, calls

    def test_existing_app_skips_graph_and_preserves_authenticated_deployment(self):
        result, calls = self.run_script(EXISTING_ARGS, EXISTING="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(call[:2] == ["az", "ad"] for call in calls))
        deployment = next(call for call in calls if call[:4] == ["az", "deployment", "group", "create"])
        for parameter in (
            f"entraAppId={APP_ID}", f"entraTenantId={TENANT_ID}",
            "entraAppRole=AIOMcpAdmin", "authMode=SystemAssignedManagedIdentity",
        ):
            self.assertIn(parameter, deployment)
        helm = next(call for call in calls if call[:3] == ["helm", "upgrade", "--install"])
        self.assertIn("endpoint.url=https://aio-mcp-frontend.azure-iot-operations:443/mcp", helm)
        self.assertIn("endpoint.serviceAccountTokens[0].audience=aio-mcp-frontend", helm)
        self.assertIn('serviceAccount.annotations={"aio-mcp-auth/roles":"[\\"Reader\\"]"}', helm)
        self.assertIn("[mcp] Public endpoint:", result.stdout)

    def test_default_still_creates_and_configures_app(self):
        result, calls = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(["az", "ad", "app", "create", "--display-name", "aio-ai-relay", "-o", "json"], calls)
        self.assertIn(["az", "ad", "sp", "update", "--id", APP_ID, "--set", "appRoleAssignmentRequired=true", "--output", "none"], calls)
        self.assertTrue(any(call[:4] == ["az", "deployment", "group", "create"] for call in calls))

    def test_conflicting_or_incomplete_ids_fail_before_side_effects(self):
        for args in (
            ["--entra-app-id", APP_ID],
            ["--entra-tenant-id", TENANT_ID],
            ["--entra-app-id", f"api://{APP_ID}", "--entra-tenant-id", TENANT_ID],
            ["--entra-app-id", APP_ID, "--entra-tenant-id", "invalid"],
            [*EXISTING_ARGS, "--entra-app-name", "new-app"],
            [*EXISTING_ARGS, "--entra-azure-config-dir", "/unused"],
        ):
            with self.subTest(args=args):
                result, calls = self.run_script(args)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Error:", result.stderr)
                self.assertEqual(calls, [])

    def test_deployment_failure_does_not_install_relay(self):
        result, calls = self.run_script(EXISTING_ARGS, EXISTING="1", FAIL_DEPLOY="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Simulated deployment error", result.stderr)
        self.assertFalse(any(call[:2] == ["helm", "upgrade"] for call in calls))
        self.assertNotIn("Public endpoint:", result.stdout)

    def test_registration_mode_still_rejects_existing_name(self):
        result, calls = self.run_script(["--entra-app-name", "existing"], APP_EXISTS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already exists", result.stderr)
        self.assertFalse(any(call[:4] == ["az", "ad", "app", "create"] for call in calls))
        self.assertFalse(any(call[:2] == ["az", "deployment"] for call in calls))


if __name__ == "__main__":
    unittest.main()
