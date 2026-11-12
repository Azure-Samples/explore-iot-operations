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
    assert [container["name"] for container in agent["containers"]] == ["agent"]
    assert set(deployments) == {"edge-assistant"}
    volumes = {volume["name"]: volume for volume in agent["volumes"]}
    assert "broker-token" not in volumes and "resource-token" not in volumes
    assert (
        volumes["frontend-token"]["projected"]["sources"][0]["serviceAccountToken"]["audience"]
        == settings.mcp.token_audience
    )
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
    assert len(roles) == 1
    assert not any("*" in json.dumps(role["rules"]) for role in roles)
    model_reader = next(
        role for role in roles if role["rules"][0]["resources"] == ["modeldeployments"]
    )
    assert model_reader["rules"][0]["resourceNames"] == [settings.foundry.deployment_name]
    assert "${" not in yaml.safe_dump_all(documents)
    access = json.loads((tmp_path / "mcp-access.json").read_text())
    service_account = next(
        item
        for item in manifests["namespace"]
        if item["kind"] == "ServiceAccount" and item["metadata"]["name"] == "edge-assistant"
    )
    assert access["roles"] == json.loads(
        service_account["metadata"]["annotations"]["aio-mcp-auth/roles"]
    )
    assert access["roles"] == ["Reader", "DataReader"]
    assert access["applicationTopics"]["publish"] == []
    assert access["applicationTopics"]["subscribe"] == [
        source.topic for source in settings.sources.values()
    ]
    assert not (tmp_path / "broker-rule.json").exists()


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
    assert deleted_secrets == set()
    assert not any(args[2] in {"aio-mcp", "aio-mcp-frontend"} for args in deletes)


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
        if args[:3] == ("get", "service", "aio-mcp-frontend"):
            return json.dumps({"spec": {"ports": [{"port": 443}]}})
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


def test_action_inventory_uses_frontend_admin_and_exact_application_topics(
    action_settings, template_dir, tmp_path
):
    write_manifests(action_settings, render(action_settings, template_dir), tmp_path)
    access = json.loads((tmp_path / "mcp-access.json").read_text())
    assert access["roles"] == ["Reader", "DataReader", "Admin"]
    assert access["applicationTopics"]["publish"] == [
        action_settings.camera.topic("requests", action)
        for action in ("ContinuousMove", "Stop", "GetStatus")
    ] + [action_settings.recommendations.topic]
    assert access["applicationTopics"]["subscribe"][-1] == action_settings.camera.topic(
        "responses", "GetStatus"
    )
    assert not any(
        "#" in topic or "+" in topic
        for topics in access["applicationTopics"].values()
        for topic in topics
    )


def test_actions_remain_disabled_when_omitted(config):
    config.pop("camera")
    config.pop("recommendations")
    settings = Settings.model_validate(config)
    assert not settings.camera.enabled
    assert not settings.recommendations.enabled
    assert settings.simulator is None


def test_legacy_direct_broker_configuration_is_not_silently_used(config):
    config["broker"] = {"host": "old-broker", "port": 18883}
    with pytest.raises(ValidationError, match="Extra inputs"):
        Settings.model_validate(config)


def test_camera_requires_native_graph_configuration(config):
    config["camera"]["enabled"] = True
    with pytest.raises(ValidationError, match="cameraGraphs"):
        Settings.model_validate(config)


def test_camera_graph_rendering_keeps_custom_target_and_separate_actions(
    action_settings, template_dir, tmp_path
):
    settings = action_settings.model_copy(
        update={"camera": action_settings.camera.model_copy(update={"asset_name": "other-camera"})}
    )
    write_manifests(settings, render(settings, template_dir), tmp_path)
    parameters = json.loads((tmp_path / "camera-actions.parameters.json").read_text())["parameters"]
    assert parameters["cameraAssetName"]["value"] == "other-camera"
    for stage in ("get-status", "continuous-move", "stop"):
        graph = yaml.safe_load((tmp_path / f"camera-{stage}-graph.yaml").read_text())
        assert graph["operations"][1]["module"].endswith(
            f"/{stage}:{settings.camera_graphs.artifact_version}"
        )
        assert set(graph["moduleConfigurations"][0]["parameters"]) == {
            "asset_name",
            "profile_token",
        }


def test_legacy_cleanup_requires_new_workload_and_preserves_platform(
    settings, template_dir, monkeypatch
):
    deployment = Deployment(settings, render(settings, template_dir))
    calls = []

    def kubectl(*args, **kwargs):
        calls.append(args)
        if args[:3] == ("get", "deployment", "edge-assistant"):
            return json.dumps({"spec": {"template": {"spec": {"containers": [{"name": "agent"}]}}}})
        if args[0] == "get":
            return json.dumps({"metadata": {"labels": ownership(settings)}})
        return ""

    monkeypatch.setattr(deployment, "kubectl", kubectl)
    monkeypatch.setattr(deployment, "client", lambda command: calls.append(("client", command)))
    deployment.remove_legacy_mcp()
    deletes = [args for args in calls if args[0] == "delete"]
    assert calls.index(("client", "check")) < calls.index(deletes[0])
    assert any(args[2] == "edge-resource-mcp" for args in deletes)
    assert not any(
        args[2]
        in {"aio-mcp", "aio-mcp-frontend", "edge-assistant", settings.foundry.deployment_name}
        for args in deletes
    )
    assert not any(args[1] == "namespace" for args in deletes)


@pytest.mark.parametrize("old_sidecar", [True, False])
def test_legacy_cleanup_deletes_nothing_before_workload_and_ownership_checks(
    settings, template_dir, monkeypatch, old_sidecar
):
    deployment = Deployment(settings, render(settings, template_dir))
    calls = []

    def kubectl(*args, **kwargs):
        calls.append(args)
        if args[:3] == ("get", "deployment", "edge-assistant"):
            containers = [{"name": "agent"}]
            if old_sidecar:
                containers.append({"name": "mqtt-mcp"})
            return json.dumps({"spec": {"template": {"spec": {"containers": containers}}}})
        if args[0] == "get":
            labels = {} if args[1] == "secret" else ownership(settings)
            return json.dumps({"metadata": {"labels": labels}})
        return ""

    monkeypatch.setattr(deployment, "kubectl", kubectl)
    monkeypatch.setattr(deployment, "client", lambda command: None)
    with pytest.raises(SampleError):
        deployment.remove_legacy_mcp()
    assert not any(args[0] == "delete" for args in calls)


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
