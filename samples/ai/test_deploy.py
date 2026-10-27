import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("deploy.sh")
APP_ID = "11111111-1111-1111-1111-111111111111"
TENANT_ID = "22222222-2222-2222-2222-222222222222"
OUTPUTS = {
    "endpoints": {"value": [{
        "protocol": "mcp",
        "hybridConnectionName": "hybridconnection",
        "relayUrl": "https://relay.example/hybridconnection",
        "apimGatewayUrl": "https://apim.example/mcp/hybridconnection",
        "sasKeyName": "listen",
    }]},
    "mcpOAuthProtectedResourceMetadataUrl": {"value": ""},
}
MOCKS = r"""
AZ_ACCOUNT_CHECKS=0
az() {
    jq -cn --arg profile "${AZURE_CONFIG_DIR:-}" --args \
        '{profile:$profile, args:$ARGS.positional}' -- "$@" >> "$TEST_AZ_LOG"
    case "$1 ${2:-} ${3:-}" in
        "account show --output")
            AZ_ACCOUNT_CHECKS=$((AZ_ACCOUNT_CHECKS + 1))
            if [[ "$AZ_ACCOUNT_CHECKS" -gt 1 && "$TEST_SESSION" == 0 ]]; then return 1; fi ;;
        "account show --query")
            if [[ "$4" == user.name ]]; then echo test-operator
            else printf '%s\n' "$TEST_TENANT"; fi ;;
        login*) return "$TEST_LOGIN_STATUS" ;;
        "ad app list") printf '%s\n' "$TEST_APP_LIST" ;;
        "ad app create") printf '%s\n' "$TEST_APP_RESPONSE" ;;
        "ad sp create") printf '%s\n' "$TEST_SP_RESPONSE" ;;
        "ad app update"|"ad sp update"|"deployment group create") ;;
        "deployment group show") printf '%s\n' "$TEST_OUTPUTS" ;;
        "relay hyco authorization-rule") echo mock-sas-key ;;
        *) echo "Unexpected az call: $*" >&2; return 99 ;;
    esac
}
helm() {
    jq -cn --args '$ARGS.positional' -- "$@" >> "$TEST_HELM_LOG"
    if [[ "$1" == pull ]]; then : > "$6/aio-ai-relay-$4.tgz"; fi
}
kubectl() {
    jq -cn --args '$ARGS.positional' -- "$@" >> "$TEST_KUBE_LOG"
    case "$1 ${2:-}" in
        "config current-context") echo test-context ;;
        "create secret"|apply*) cat >/dev/null ;;
    esac
}
source "$@"
"""


class RelayDeployTests(unittest.TestCase):
    def run_deploy(self, extra=(), existing=False, environment=None):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            temporary = directory / "temporary"
            temporary.mkdir()
            arguments = [
                "--resource-group", "test", "--relay-namespace-name", "test",
                "--apim-name", "test", "--apim-publisher-email", "test@example.invalid",
                "--apim-publisher-name", "test", "--cluster-name", "test",
                "--aio-extension-name", "test",
            ]
            if existing:
                arguments += ["--entra-app-id", APP_ID, "--entra-tenant-id", TENANT_ID]
            environment = {
                **os.environ, "AZURE_CONFIG_DIR": "", "TMPDIR": str(temporary),
                "TEST_AZ_LOG": str(directory / "az.jsonl"),
                "TEST_HELM_LOG": str(directory / "helm.jsonl"),
                "TEST_KUBE_LOG": str(directory / "kubectl.jsonl"),
                "TEST_SESSION": "1", "TEST_LOGIN_STATUS": "0", "TEST_TENANT": TENANT_ID,
                "TEST_APP_LIST": "[]", "TEST_APP_RESPONSE": json.dumps({"appId": APP_ID}),
                "TEST_SP_RESPONSE": json.dumps({"id": "33333333-3333-3333-3333-333333333333"}),
                "TEST_OUTPUTS": json.dumps(OUTPUTS),
                **(environment or {}),
            }
            result = subprocess.run(
                ["bash", "-c", MOCKS, "--", str(SCRIPT.resolve()), *arguments, *extra],
                cwd=directory, env=environment, capture_output=True, text=True, check=False,
            )
            self.assertEqual(list(temporary.iterdir()), [], result.stderr)
            logs = []
            for name in ("az", "helm", "kubectl"):
                path = directory / f"{name}.jsonl"
                logs.append([json.loads(line) for line in path.read_text().splitlines()]
                            if path.exists() else [])
            return result, *logs

    def test_cli_profiles_and_existing_app(self):
        cases = [
            ((), False, {}, 0, False),
            (("--entra-azure-config-dir", "isolated"), False, {}, 0, False),
            (("--entra-azure-config-dir", "isolated"), False, {"TEST_SESSION": "0"}, 0, True),
            (("--entra-azure-config-dir", "isolated"), False,
             {"TEST_SESSION": "0", "TEST_LOGIN_STATUS": "37"}, 37, True),
            ((), False, {"TEST_SESSION": "0"}, 1, False),
            ((), True, {"TEST_SESSION": "0"}, 0, False),
        ]
        for extra, existing, environment, status, login in cases:
            with self.subTest(extra=extra, existing=existing, environment=environment):
                result, calls, helm, _ = self.run_deploy(extra, existing, environment)
                self.assertEqual(result.returncode, status, result.stderr)
                logins = [call for call in calls if call["args"][0] == "login"]
                self.assertEqual(len(logins), int(login))
                if login:
                    self.assertEqual(logins[0]["args"], ["login", "--allow-no-subscriptions"])
                    self.assertEqual(logins[0]["profile"], "isolated")
                graph = [call for call in calls if call["args"][0] == "ad"]
                if status:
                    self.assertEqual(graph, [])
                    self.assertFalse(any(call["args"][:3] == ["deployment", "group", "create"]
                                         for call in calls))
                    self.assertFalse(any(call[0] == "upgrade" for call in helm))
                    if not login:
                        self.assertIn("Run 'az login'", result.stderr)
                elif existing:
                    self.assertEqual(graph, [])
                    self.assertEqual(sum(call["args"][:2] == ["account", "show"] for call in calls), 1)
                else:
                    self.assertTrue(graph)
                    for call in graph:
                        self.assertEqual(call["profile"], "isolated" if extra else "")
                        self.assertNotIn("--service-management-reference", call["args"])
                    if not login:
                        self.assertIn("Reusing Entra Azure CLI session: test-operator", result.stdout)
                if not status:
                    deployment = next(call for call in calls
                                      if call["args"][:3] == ["deployment", "group", "create"])
                    self.assertEqual(deployment["profile"], "")
                    self.assertEqual(helm[0][:4], [
                        "pull", "oci://ghcr.io/azure-samples/explore-iot-operations/helm/aio-ai-relay",
                        "--version", "0.1.3",
                    ])

    def test_rejects_malformed_registration_responses(self):
        cases = [
            ({"TEST_APP_LIST": "{}"}, "Expected an Entra app array"),
            ({"TEST_APP_LIST": '[{"appId":"existing"}]'}, "already exists"),
            ({"TEST_APP_RESPONSE": '{"appId":42}'}, "Expected an Entra appId"),
            ({"TEST_SP_RESPONSE": '{"id":false}'}, "Expected an Entra service principal ID"),
        ]
        for environment, message in cases:
            with self.subTest(environment=environment):
                result, calls, helm, _ = self.run_deploy(environment=environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertFalse(any(call["args"][:3] == ["deployment", "group", "create"]
                                     for call in calls))
                self.assertFalse(any(call[0] == "upgrade" for call in helm))
                if "TEST_APP_LIST" in environment:
                    self.assertFalse(any(call["args"][:3] == ["ad", "app", "create"] for call in calls))

    def test_rejects_malformed_outputs_before_kubernetes_changes(self):
        cases = []
        for value in (None, {}):
            output = copy.deepcopy(OUTPUTS)
            output["endpoints"]["value"] = value
            cases.append((output, "Expected deployment endpoints"))
        output = copy.deepcopy(OUTPUTS)
        output["mcpOAuthProtectedResourceMetadataUrl"]["value"] = False
        cases.append((output, "Expected the OAuth metadata URL output"))
        for field, message in (
            ("hybridConnectionName", "Expected a Hybrid Connection name"),
            ("relayUrl", "Expected a Relay URL"),
            ("apimGatewayUrl", "Expected an APIM gateway URL"),
        ):
            for value in ("", 42, []):
                output = copy.deepcopy(OUTPUTS)
                output["endpoints"]["value"][0][field] = value
                cases.append((output, message))
        for value in (None, 42, ["listen"], ""):
            output = copy.deepcopy(OUTPUTS)
            output["endpoints"]["value"][0]["sasKeyName"] = value
            cases.append((output, "sasKeyName" if value == "" else "Expected a SAS key name"))
        for output, message in cases:
            with self.subTest(output=output):
                result, calls, helm, kubectl = self.run_deploy(
                    ("--auth-mode", "sas"), existing=True,
                    environment={"TEST_OUTPUTS": json.dumps(output)},
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertFalse(any(call[0] == "upgrade" for call in helm))
                self.assertFalse(any(call[0] != "config" for call in kubectl))
                self.assertFalse(any(call["args"][:3] == ["relay", "hyco", "authorization-rule"]
                                     for call in calls))

    def test_cli_validation_keeps_chart_checks_and_migration_guidance(self):
        cases = [
            (("--aio-mcp-release-name", "old"), "use --mcp-frontend-service-name"),
            (("--chart-reference", "https://example.invalid"), "must be an OCI URI"),
            (("--chart-version", "not-semver"), "must be SemVer"),
            (("--apim-capacity", "0"), "positive integer"),
            (("--values", "missing.yaml"), "values file not found"),
            (("--entra-app-id", "invalid"), "both be supplied as GUIDs"),
        ]
        for extra, message in cases:
            with self.subTest(extra=extra):
                result, calls, helm, kubectl = self.run_deploy(extra)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertEqual((calls, helm, kubectl), ([], [], []))

    def test_valid_sas_outputs_install_each_protocol(self):
        for protocol in ("mcp", "a2a", "both"):
            with self.subTest(protocol=protocol):
                output = copy.deepcopy(OUTPUTS)
                legs = ("mcp", "a2a") if protocol == "both" else (protocol,)
                output["endpoints"]["value"] = [
                    {**OUTPUTS["endpoints"]["value"][0], "protocol": leg} for leg in legs
                ]
                result, _, helm, _ = self.run_deploy(
                    ("--auth-mode", "sas", "--endpoint-protocol", protocol,
                     "--endpoint-url", "https://agent.example/a,b"),
                    existing=True, environment={"TEST_OUTPUTS": json.dumps(output)},
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(sum(call[0] == "upgrade" for call in helm), len(legs))


if __name__ == "__main__":
    unittest.main()
