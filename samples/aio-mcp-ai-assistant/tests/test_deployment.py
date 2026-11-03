import json

import pytest
import yaml
from pydantic import ValidationError

from aio_mcp_ai_assistant.common import SampleError
from aio_mcp_ai_assistant.config import Settings
from aio_mcp_ai_assistant.deployment import Deployment, ownership, render, write_manifests


@pytest.mark.parametrize(
    "field, value",
    [
        ("namespace", "azure-iot-operations"),
        ("namespace", "default"),
        ("image", "example.azurecr.io/edge:latest"),
        ("unexpected", True),
    ],
)
def test_configuration_rejects_ambiguous_or_shared_scope(config, field, value):
    config[field] = value
    with pytest.raises(ValidationError):
        Settings.model_validate(config)


@pytest.mark.parametrize("topic", ["edge/#", "edge/+", "/arbitrary", "edge/topic with spaces"])
def test_topic_filters_are_not_allowed(config, topic):
    config["sources"]["person-detections"]["topic"] = topic
    with pytest.raises(ValidationError):
        Settings.model_validate(config)


def test_source_selectors_must_be_unambiguous(config):
    config["sources"]["person-errors"].update({"stage": "inference", "machineId": "person"})
    with pytest.raises(ValidationError, match="distinct stage/machineId"):
        Settings.model_validate(config)


def test_gpu_configuration_requires_an_explicit_node_pool(config):
    config["foundry"]["compute"] = "gpu"
    with pytest.raises(ValidationError, match="nodePool"):
        Settings.model_validate(config)


def test_asset_id_renders_the_v2_source_without_a_legacy_catalog(config, template_dir):
    foundry = config["foundry"]
    asset_id = (
        f"azureml://registries/azureml/models/{foundry['catalogName']}"
        f"/versions/{foundry['catalogVersion']}"
    )
    foundry["assetId"] = asset_id
    spec = render(Settings.model_validate(config), template_dir)["model"][0]["spec"]
    assert spec["model"] == {"assetId": asset_id}


@pytest.mark.parametrize(
    "asset_id",
    [
        "azureml://registries/azureml/models/another-model/versions/1",
        "azureml://registries/azureml/models/qwen3.5-2b-text-generic-cpu/versions/999",
        "https://models.example.test/model",
    ],
)
def test_asset_id_must_identify_the_configured_catalog_version(config, asset_id):
    config["foundry"]["assetId"] = asset_id
    with pytest.raises(ValidationError, match="assetId"):
        Settings.model_validate(config)


def test_asset_id_cannot_use_an_unpinned_version(config):
    foundry = config["foundry"]
    foundry["catalogVersion"] = "latest"
    foundry["assetId"] = (
        f"azureml://registries/azureml/models/{foundry['catalogName']}/versions/latest"
    )
    with pytest.raises(ValidationError, match="concrete catalogVersion"):
        Settings.model_validate(config)


def test_gpu_model_requests_one_device_on_the_selected_pool(config, template_dir):
    config["foundry"].update(
        {
            "compute": "gpu",
            "nodePool": "mcpgpu",
            "catalogName": "qwen3.5-2b-text-cuda-gpu",
        }
    )
    spec = render(Settings.model_validate(config), template_dir)["model"][0]["spec"]
    assert spec["compute"] == "gpu"
    assert spec["model"]["catalog"]["name"] == "qwen3.5-2b-text-cuda-gpu"
    assert spec["replicas"] == 1
    assert spec["resources"]["limits"]["gpu"] == 1
    assert spec["resources"]["requests"] == {"cpu": "1", "memory": "4Gi"}
    assert spec["nodeSelector"] == {"kubernetes.azure.com/agentpool": "mcpgpu"}
    assert spec["tolerations"] == [
        {"key": "sku", "operator": "Equal", "value": "gpu", "effect": "NoSchedule"}
    ]


def test_existing_cpu_configuration_keeps_its_resource_requirements(config, template_dir):
    config["foundry"].pop("compute", None)
    spec = render(Settings.model_validate(config), template_dir)["model"][0]["spec"]
    assert spec["compute"] == "cpu"
    assert spec["resources"] == {
        "requests": {"cpu": "4", "memory": "4Gi"},
        "limits": {"cpu": "8", "memory": "8Gi"},
    }
    assert spec["nodeSelector"] == {}
    assert spec["tolerations"] == []


def test_cpu_model_can_target_a_dedicated_tainted_pool(config, template_dir):
    config["foundry"]["nodePool"] = "mcpcpu"
    spec = render(Settings.model_validate(config), template_dir)["model"][0]["spec"]
    assert spec["nodeSelector"] == {"kubernetes.azure.com/agentpool": "mcpcpu"}
    assert spec["tolerations"] == [
        {"key": "sku", "operator": "Equal", "value": "cpu", "effect": "NoSchedule"}
    ]
    assert "gpu" not in spec["resources"]["limits"]


def test_rendered_manifests_preserve_boundaries_and_typed_values(settings, template_dir, tmp_path):
    manifests = render(settings, template_dir)
    write_manifests(settings, manifests, tmp_path)
    documents = [
        document
        for path in tmp_path.glob("*.yaml")
        for document in yaml.safe_load_all(path.read_text())
    ]
    deployments = {
        item["metadata"]["name"]: item for item in documents if item["kind"] == "Deployment"
    }
    agent = deployments["edge-assistant"]["spec"]["template"]["spec"]
    assert agent["automountServiceAccountToken"] is False
    assert agent["imagePullSecrets"] == []
    assert len(agent["containers"]) == 2
    volumes = {volume["name"]: volume for volume in agent["volumes"]}
    assert volumes["resource-ca"]["secret"]["items"] == [{"key": "ca.crt", "path": "ca.crt"}]
    assert (
        volumes["foundry-token"]["projected"]["sources"][0]["serviceAccountToken"]["audience"]
        == settings.foundry.token_audience
    )
    assert all(
        document["metadata"]["labels"].items() >= ownership(settings).items()
        for document in documents
    )
    assert not any(
        item["kind"] == "Service" and item["metadata"]["name"] == "edge-assistant"
        for item in documents
    )
    model = manifests["model"][0]
    assert model["spec"]["authenticationMethods"][0]["roles"][0]["authorizedSubjects"] == [
        {"serviceAccountName": "edge-assistant", "serviceAccountNamespace": settings.namespace}
    ]
    roles = [item for item in documents if item["kind"] in {"Role", "ClusterRole"}]
    assert not any("*" in json.dumps(role["rules"]) for role in roles)
    model_reader = next(
        role for role in roles if role["rules"][0]["resources"] == ["modeldeployments"]
    )
    assert model_reader["rules"][0]["resourceNames"] == [settings.foundry.deployment_name]
    assert "${" not in yaml.safe_dump_all(documents)
    rule = json.loads((tmp_path / "broker-rule.json").read_text())
    service_account = next(
        item
        for item in manifests["namespace"]
        if item["kind"] == "ServiceAccount" and item["metadata"]["name"] == "edge-assistant"
    )
    assert (
        rule["principals"]["attributes"][0]["edge-assistant"]
        == service_account["metadata"]["annotations"]["aio-broker-auth/edge-assistant"]
    )
    assert [resource["method"] for resource in rule["brokerResources"]] == ["Connect", "Subscribe"]
    assert rule["brokerResources"][1]["topics"] == [
        source.topic for source in settings.sources.values()
    ]


def test_unowned_resource_is_rejected_before_apply(settings, template_dir, monkeypatch):
    deployment = Deployment(settings, render(settings, template_dir))
    calls = []

    def kubectl(*args, **kwargs):
        calls.append(args)
        return json.dumps(
            {
                "metadata": {
                    "labels": {
                        "app.kubernetes.io/part-of": "aio-mcp-ai-assistant",
                        "app.kubernetes.io/instance": "another-instance",
                    }
                }
            }
        )

    monkeypatch.setattr(deployment, "kubectl", kubectl)
    with pytest.raises(SampleError, match="not owned"):
        deployment.model()
    assert all(args[0] == "get" for args in calls)


def test_cleanup_never_deletes_namespaces_or_registry_credentials(
    settings,
    template_dir,
    monkeypatch,
):
    deployment = Deployment(settings, render(settings, template_dir))
    calls = []

    def kubectl(*args, **kwargs):
        calls.append(args)
        if args[0] == "get":
            return json.dumps({"metadata": {"labels": ownership(settings)}})
        return ""

    monkeypatch.setattr(deployment, "kubectl", kubectl)
    deployment.cleanup()
    deletes = [args for args in calls if args[0] == "delete"]
    assert deletes
    assert not any(args[1] == "namespace" for args in deletes)
    deleted_secrets = {args[2] for args in deletes if args[1] == "secret"}
    assert deleted_secrets == {"edge-resource-ca", "edge-resource-tls"}


def test_prepare_creates_namespace_before_namespaced_server_dry_runs(
    settings,
    template_dir,
    monkeypatch,
):
    deployment = Deployment(settings, render(settings, template_dir))
    namespace_exists = False
    applied = []

    def kubectl(*args, stdin=None, **kwargs):
        nonlocal namespace_exists
        if args[0] == "apply":
            documents = list(yaml.safe_load_all(stdin))
            for document in documents:
                if document["metadata"].get("namespace") == settings.namespace:
                    assert namespace_exists, "A dry run does not persist its Namespace"
                if "--dry-run=server" not in args:
                    applied.append(document["kind"])
                    if document["kind"] == "Namespace":
                        namespace_exists = True
        return ""

    monkeypatch.setattr(deployment, "kubectl", kubectl)
    monkeypatch.setattr(
        deployment,
        "trust",
        lambda: {
            "kind": "ConfigMap",
            "metadata": {"name": "edge-assistant-trust", "namespace": settings.namespace},
        },
    )
    deployment.prepare()
    assert applied[0] == "Namespace"
    assert "ServiceAccount" in applied


def test_action_permissions_are_exact_and_only_enabled_explicitly(
    action_settings, template_dir, tmp_path
):
    write_manifests(action_settings, render(action_settings, template_dir), tmp_path)
    resources = json.loads((tmp_path / "broker-rule.json").read_text())["brokerResources"]
    assert resources[-1] == {
        "method": "Publish",
        "topics": [
            action_settings.camera.action_topic(action)
            for action in ("ContinuousMove", "Stop", "GetStatus")
        ]
        + [action_settings.recommendations.topic],
    }
    assert resources[1]["topics"][-1] == action_settings.camera_response_topic
    assert not any(
        "#" in topic or "+" in topic for rule in resources for topic in rule.get("topics", [])
    )


def test_previous_configs_remain_read_only(config):
    config.pop("camera")
    config.pop("recommendations")
    settings = Settings.model_validate(config)
    assert not settings.camera.enabled
    assert not settings.recommendations.enabled
    assert settings.simulator is None


@pytest.mark.parametrize("topic", ["edge/#", "edge/+", "edge/predictive-inference/person/results"])
def test_publication_cannot_target_wildcards_or_observation_sources(config, topic):
    config["recommendations"]["topic"] = topic
    with pytest.raises(ValidationError):
        Settings.model_validate(config)


def test_simulator_credentials_are_reused_without_rotation(config, template_dir, monkeypatch):
    config["simulator"] = {"image": "example.azurecr.io/simulator:0.1.0"}
    settings = Settings.model_validate(config)
    deployment = Deployment(settings, render(settings, template_dir))
    stored = {}
    monkeypatch.setattr(deployment, "require_owned", lambda *args, **kwargs: None)

    def kubectl(*args, **kwargs):
        if args[0] == "get":
            value = stored.get((args[2], args[4]))
            return json.dumps(value) if value else ""
        return ""

    def apply(documents):
        for document in documents:
            if document["kind"] == "Secret":
                metadata = document["metadata"]
                stored[(metadata["name"], metadata["namespace"])] = document

    monkeypatch.setattr(deployment, "kubectl", kubectl)
    monkeypatch.setattr(deployment, "apply", apply)
    deployment.simulator()
    before = json.dumps(list(stored.values()), sort_keys=True)
    deployment.simulator()
    assert json.dumps(list(stored.values()), sort_keys=True) == before
    sample_data = stored[(settings.camera_secret, settings.namespace)]["data"]
    connector_data = stored[(settings.camera_secret, settings.aio_namespace)]["data"]
    assert connector_data == {key: sample_data[key] for key in ("username", "password")}
    assert "admin-token" not in connector_data
