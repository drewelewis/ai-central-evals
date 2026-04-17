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
from azure.mgmt.cognitiveservices import CognitiveServicesManagementClient

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


def discover_foundry_projects(subscription_id: str, resource_group: str | None = None) -> list[dict]:
    """
    Return all AI Foundry projects (CognitiveServices/accounts/projects) in the
    subscription.  Each dict contains: id, name, type, kind, resourceGroup,
    subscriptionId, properties (including endpoint URL).

    Args:
        subscription_id: Azure subscription ID to query
        resource_group: If provided, only return projects in this resource group
    """
    cred = _get_credential()
    client = ResourceGraphClient(cred)

    rg_filter = ""
    if resource_group:
        rg_filter = f"| where resourceGroup =~ '{resource_group}'"

    query = f"""
    Resources
    | where type == 'microsoft.cognitiveservices/accounts/projects'
    {rg_filter}
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
    logger.info("ARG: found %d Foundry project(s)%s", len(rows), f" in resource group '{resource_group}'" if resource_group else "")
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


def _build_model_targets(subscription_id: str, tenant_id: str, resource_group: str | None = None) -> list[EvalTarget]:
    """
    Discover model deployments via Cognitive Services Management SDK.
    ARG doesn't index deployments, so we:
    1. Query ARG for Cognitive Services accounts
    2. Use the management SDK to list deployments for each account
    """
    cred = _get_credential()
    arg_client = ResourceGraphClient(cred)

    rg_filter = ""
    if resource_group:
        rg_filter = f"| where resourceGroup =~ '{resource_group}'"

    # Step 1: Find Cognitive Services accounts (AI Services / OpenAI) via ARG
    query = f"""
    Resources
    | where type == 'microsoft.cognitiveservices/accounts'
    | where kind in~ ('AIServices', 'OpenAI')
    {rg_filter}
    | project
        name,
        resourceGroup,
        subscriptionId,
        tenantId
    | order by name asc
    """
    accounts = _run_arg_query(arg_client, subscription_id, query)
    logger.info("ARG: found %d Cognitive Services account(s)%s", len(accounts), f" in resource group '{resource_group}'" if resource_group else "")

    # Step 2: Use management SDK to list deployments for each account
    targets: list[EvalTarget] = []
    cs_client = CognitiveServicesManagementClient(cred, subscription_id)
    
    for account in accounts:
        account_name = account.get("name", "")
        account_rg = account.get("resourceGroup", "")
        
        try:
            deployments = cs_client.deployments.list(resource_group_name=account_rg, account_name=account_name)
            for deployment in deployments:
                model_info = deployment.properties.model if deployment.properties else None
                model_name = model_info.name if model_info and model_info.name else deployment.name
                model_version = model_info.version if model_info and model_info.version else "unknown"
                
                endpoint = f"https://{account_name}.cognitiveservices.azure.com/"
                
                targets.append(
                    EvalTarget(
                        target_type="model",
                        target_name=model_name,
                        target_version=model_version,
                        foundry_project_name=account_name,
                        foundry_project_id=deployment.id or "",
                        resource_group=account_rg,
                        subscription_id=account.get("subscriptionId", subscription_id),
                        tenant_id=account.get("tenantId", tenant_id),
                        endpoint_uri=endpoint,
                        extra={
                            "deployment_name": deployment.name,
                            "account_name": account_name,
                            "sku_name": deployment.sku.name if deployment.sku else "",
                            "sku_capacity": deployment.sku.capacity if deployment.sku else 0,
                        },
                    )
                )
            logger.info("Found %d model deployment(s) in account '%s'", sum(1 for _ in cs_client.deployments.list(resource_group_name=account_rg, account_name=account_name)), account_name)
        except Exception as e:
            logger.warning("Failed to list deployments for account '%s': %s", account_name, e)
    
    logger.info("Total model targets discovered: %d", len(targets))
    return targets


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

    logger.info("Agent discovery: checking %d project(s) for agents", len(projects))

    try:
        from azure.ai.projects import AIProjectClient
    except ImportError:
        logger.error("azure-ai-projects not installed — skipping agent discovery")
        return targets

    cred = _get_credential()
    projects_checked = 0
    projects_with_endpoints = 0

    for proj in projects:
        project_id: str = proj["id"]
        resource_group: str = proj["resourceGroup"]
        subscription_id: str = proj["subscriptionId"]
        project_name: str = _project_short_name(proj)
        endpoint: str = _project_endpoint(proj)

        if not endpoint:
            logger.warning("Agent discovery: no endpoint for project %s — skipping", project_name)
            continue

        projects_with_endpoints += 1
        logger.info("Agent discovery: checking project %s endpoint %s", project_name, endpoint[:50])

        try:
            project_client = AIProjectClient(
                endpoint=endpoint,
                credential=cred,
            )
            agents_page = project_client.agents.list_agents()
            agent_count = 0
            for agent in agents_page:
                agent_count += 1
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
            logger.info("Agent discovery: project %s has %d agent(s)", project_name, agent_count)
            projects_checked += 1
        except Exception as exc:  # noqa: BLE001
            logger.error("Agent discovery FAILED for project %s: %s [%s]", project_name, type(exc).__name__, exc)

    logger.info(
        "Agent discovery complete: %d project(s) with endpoints, %d checked successfully, %d agent(s) found",
        projects_with_endpoints, projects_checked, len(targets)
    )
    return targets


def discover_all_eval_targets(subscription_id: str, tenant_id: str, resource_group: str | None = None) -> list[EvalTarget]:
    """
    Top-level entry point.  Returns a combined list of model + agent EvalTargets.

    Discovery strategy:
    - Projects  : microsoft.cognitiveservices/accounts/projects via ARG
    - Models    : microsoft.cognitiveservices/accounts/deployments via ARG
    - Agents    : enumerated per-project via azure-ai-projects SDK

    Args:
        subscription_id: Azure subscription ID to query
        tenant_id: Azure tenant ID
        resource_group: If provided, only discover targets in this resource group
    """
    projects = discover_foundry_projects(subscription_id, resource_group)
    agent_targets = _build_agent_targets(projects, tenant_id)
    model_targets = _build_model_targets(subscription_id, tenant_id, resource_group)

    # Build one project-level target per project (for quality/safety evals
    # that don't require a specific deployment — the project endpoint is enough)
    project_targets: list[EvalTarget] = []
    for proj in projects:
        endpoint = _project_endpoint(proj)
        project_name = _project_short_name(proj)
        project_targets.append(
            EvalTarget(
                target_type="project",
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

    all_targets = project_targets + model_targets + agent_targets
    logger.info(
        "Discovery complete: %d project(s), %d model(s), %d agent(s)",
        len(project_targets),
        len(model_targets),
        len(agent_targets),
    )
    return all_targets
