"""
arg_discovery.py
----------------
Queries Azure Resource Graph to discover:
  - AI Foundry Accounts / Hubs (CognitiveServices/accounts kind=AIServices|OpenAI)
  - AI Foundry Projects        (CognitiveServices/accounts/projects)
  - AI Agents                  (via azure-ai-projects SDK per project)

Returns a list of EvalTarget dataclass objects for consumption by eval_runner.py.

Note: Uses the new Azure AI Foundry resource model (CognitiveServices-based,
not the legacy MachineLearningServices/workspaces model).
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass, field
from typing import Any

from azure.identity import ManagedIdentityCredential, DefaultAzureCredential
from azure.mgmt.resourcegraph import ResourceGraphClient
from azure.mgmt.resourcegraph.models import QueryRequest

logger = logging.getLogger(__name__)


@dataclass
class EvalTarget:
    """Represents one thing to evaluate: a model deployment or an agent."""
    target_type: str          # "model" | "agent"
    target_name: str          # deployment name / agent name
    target_version: str       # model version or agent version
    foundry_project_name: str
    foundry_project_id: str   # full ARM resource ID
    resource_group: str
    subscription_id: str
    tenant_id: str
    endpoint_uri: str         # inference / agent endpoint
    extra: dict[str, Any] = field(default_factory=dict)


def _get_credential():
    """Return MI credential in Azure, DefaultAzureCredential locally."""
    if os.getenv("WEBSITE_INSTANCE_ID"):   # running inside Function App
        return ManagedIdentityCredential()
    return DefaultAzureCredential()


def _run_arg_query(client: ResourceGraphClient, subscription_id: str, query: str) -> list[dict]:
    """Execute an ARG query scoped to one subscription and return all rows."""
    request = QueryRequest(
        subscriptions=[subscription_id],
        query=query,
        options={"resultFormat": "objectArray", "$top": 1000},
    )
    response = client.resources(request)
    return response.data or []


def discover_foundry_projects(subscription_id: str) -> list[dict]:
    """
    Return all AI Foundry projects (CognitiveServices/accounts/projects) in the
    subscription.  Each dict contains: id, name, type, kind, resourceGroup,
    subscriptionId, properties (including endpoint URL).
    """
    cred = _get_credential()
    client = ResourceGraphClient(cred)

    query = """
    Resources
    | where type == 'microsoft.cognitiveservices/accounts/projects'
    | project
        id,
        name,
        type,
        kind,
        resourceGroup,
        subscriptionId,
        tenantId,
        properties
    | order by name asc
    """
    rows = _run_arg_query(client, subscription_id, query)
    logger.info("ARG: found %d Foundry project(s)", len(rows))
    return rows


def discover_foundry_accounts(subscription_id: str) -> list[dict]:
    """
    Return all AI Foundry hub accounts (CognitiveServices/accounts with kind
    AIServices or OpenAI) in the subscription.
    """
    cred = _get_credential()
    client = ResourceGraphClient(cred)

    query = """
    Resources
    | where type == 'microsoft.cognitiveservices/accounts'
    | where kind in ('AIServices', 'OpenAI')
    | project
        id,
        name,
        type,
        kind,
        resourceGroup,
        subscriptionId,
        tenantId,
        properties
    | order by name asc
    """
    rows = _run_arg_query(client, subscription_id, query)
    logger.info("ARG: found %d Foundry account(s) (AIServices/OpenAI)", len(rows))
    return rows


def _project_endpoint(project: dict) -> str:
    """Extract the AI Foundry API endpoint URL from a project resource's properties."""
    props: dict = project.get("properties") or {}
    endpoints: dict = props.get("endpoints") or {}
    # Prefer the canonical "AI Foundry API" key; fall back to first available
    return endpoints.get("AI Foundry API", next(iter(endpoints.values()), ""))


def _account_name_from_project_id(project_id: str) -> str:
    """Parse the parent account name from a project resource ID.
    Format: .../accounts/{account-name}/projects/{project-name}
    """
    parts = project_id.split("/")
    try:
        idx = next(i for i, p in enumerate(parts) if p.lower() == "accounts")
        return parts[idx + 1]
    except (StopIteration, IndexError):
        return ""


def _project_short_name(project: dict) -> str:
    """Return just the project name from 'account/project' composite name."""
    name: str = project.get("name", "")
    return name.split("/")[-1] if "/" in name else name


def _build_agent_targets(projects: list[dict], tenant_id: str) -> list[EvalTarget]:
    """
    Enumerate agents per Foundry project using the azure-ai-projects SDK.
    Falls back gracefully if a project is inaccessible.
    """
    targets: list[EvalTarget] = []

    try:
        from azure.ai.projects import AIProjectClient
    except ImportError:
        logger.warning("azure-ai-projects not installed — skipping agent discovery")
        return targets

    cred = _get_credential()

    for proj in projects:
        project_id: str = proj["id"]
        resource_group: str = proj["resourceGroup"]
        subscription_id: str = proj["subscriptionId"]
        project_name: str = _project_short_name(proj)
        endpoint: str = _project_endpoint(proj)

        if not endpoint:
            logger.warning("No endpoint found for project %s — skipping", project_name)
            continue

        try:
            project_client = AIProjectClient(
                endpoint=endpoint,
                credential=cred,
            )
            agents_page = project_client.agents.list_agents()
            for agent in agents_page:
                targets.append(
                    EvalTarget(
                        target_type="agent",
                        target_name=agent.name or agent.id,
                        target_version=getattr(agent, "version", "unknown"),
                        foundry_project_name=project_name,
                        foundry_project_id=project_id,
                        resource_group=resource_group,
                        subscription_id=subscription_id,
                        tenant_id=tenant_id,
                        endpoint_uri=endpoint,
                        extra={"agent_id": agent.id, "model": getattr(agent, "model", "")},
                    )
                )
        except Exception as exc:  # noqa: BLE001
            logger.warning("Could not enumerate agents for project %s: %s", project_name, exc)

    logger.info("SDK: found %d agent(s)", len(targets))
    return targets


def discover_all_eval_targets(subscription_id: str, tenant_id: str) -> list[EvalTarget]:
    """
    Top-level entry point.  Returns a combined list of model + agent EvalTargets.

    Discovery strategy:
    - Projects  : microsoft.cognitiveservices/accounts/projects via ARG
    - Agents    : enumerated per-project via azure-ai-projects SDK
    """
    projects = discover_foundry_projects(subscription_id)
    agent_targets = _build_agent_targets(projects, tenant_id)

    # Build one project-level model target per project (for quality/safety evals
    # that don't require a specific deployment — the project endpoint is enough)
    model_targets: list[EvalTarget] = []
    for proj in projects:
        endpoint = _project_endpoint(proj)
        project_name = _project_short_name(proj)
        model_targets.append(
            EvalTarget(
                target_type="model",
                target_name=project_name,
                target_version="latest",
                foundry_project_name=project_name,
                foundry_project_id=proj["id"],
                resource_group=proj["resourceGroup"],
                subscription_id=proj["subscriptionId"],
                tenant_id=proj.get("tenantId", tenant_id),
                endpoint_uri=endpoint,
                extra={"account_name": _account_name_from_project_id(proj["id"])},
            )
        )

    all_targets = model_targets + agent_targets
    logger.info(
        "Discovery complete: %d project target(s), %d agent target(s)",
        len(model_targets),
        len(agent_targets),
    )
    return all_targets
