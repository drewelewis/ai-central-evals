"""
function_app.py
---------------
Azure Functions v2 programming model entry point.

Timer trigger: fires nightly at 02:00 UTC
  1. Discover all Foundry projects / model deployments / agents via ARG
  2. Run baseline eval pack against each target
  3. Ship results to Log Analytics FoundryEvals_CL via Ingestion API
"""

from __future__ import annotations

import logging
import os

import azure.functions as func

from arg_discovery import discover_all_eval_targets
from eval_runner import run_baseline_eval
from la_ingestion import send_eval_results

logger = logging.getLogger(__name__)

app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)

# ---- Nightly eval timer ----
# NCRONTAB: second minute hour day month weekday
# 0 */30 * * * *  → every 30 minutes
@app.timer_trigger(
    arg_name="timer",
    schedule="0 */30 * * * *",
    run_on_startup=False,          # set True in dev to trigger immediately after deploy
    use_monitor=True,
)
def nightly_evals(timer: func.TimerRequest) -> None:
    """
    Nightly AI compliance evaluation run.

    Discovers all Foundry projects + targets in the subscription,
    executes the baseline eval pack, and uploads results to Log Analytics.
    """
    if timer.past_due:
        logger.warning("Timer trigger is past due — running catch-up execution")

    subscription_id: str = os.environ["AZURE_SUBSCRIPTION_ID"]
    tenant_id: str = os.environ.get("AZURE_TENANT_ID", "")
    # Note: AZURE_RESOURCE_GROUP is used for deployment, not for discovery filtering
    # Discovery scans all resource groups in the subscription
    trigger_type: str = "scheduled"
    dataset_path: str = os.environ.get("EVAL_DATASET_PATH", "")

    logger.info(
        "Nightly eval run started | subscription=%s | trigger=%s",
        subscription_id,
        trigger_type,
    )

    try:
        # ---- Step 1: Discover targets (all resource groups in subscription) ----
        targets = discover_all_eval_targets(subscription_id, tenant_id, resource_group=None)
        logger.info("Discovered %d eval target(s)", len(targets))

        if not targets:
            logger.warning("No Foundry targets found in subscription %s — nothing to evaluate", subscription_id)
            return

        # ---- Step 2: Run evals ----
        run_results = []
        for target in targets:
            result = run_baseline_eval(
                target=target,
                trigger_type=trigger_type,
                dataset_path=dataset_path,
            )
            run_results.append(result)

        # ---- Step 3: Upload to Log Analytics ----
        uploaded = send_eval_results(run_results)
        logger.info(
            "Nightly eval run complete | targets=%d | rows_uploaded=%d",
            len(targets),
            uploaded,
        )
    except Exception:
        logger.exception("Nightly eval run FAILED — unhandled exception")
        raise  # re-raise so the Functions runtime marks this invocation as Failed


# ---- HTTP trigger for on-demand / manual runs ----
@app.route(route="run-evals", methods=["POST"], auth_level=func.AuthLevel.FUNCTION)
def run_evals_http(req: func.HttpRequest) -> func.HttpResponse:
    """
    On-demand eval trigger.  POST with optional JSON body:
      { "target_name": "my-deployment", "resource_group": "rg-name", "trigger_type": "manual", "max_targets": 10 }
    
    For full subscription scans, use the timer trigger (runs every 30 minutes).
    HTTP trigger is limited to max_targets (default 10) to avoid gateway timeouts.
    """
    import json

    body: dict = {}
    try:
        body = req.get_json()
    except Exception:  # noqa: BLE001
        pass

    subscription_id: str = os.environ["AZURE_SUBSCRIPTION_ID"]
    tenant_id: str = os.environ.get("AZURE_TENANT_ID", "")
    resource_group: str | None = body.get("resource_group") or None
    trigger_type: str = body.get("trigger_type", "manual")
    dataset_path: str = body.get("dataset_path", os.environ.get("EVAL_DATASET_PATH", ""))
    filter_name: str = body.get("target_name", "")
    max_targets: int = int(body.get("max_targets", 10))  # Limit to avoid gateway timeout

    targets = discover_all_eval_targets(subscription_id, tenant_id, resource_group)
    if filter_name:
        targets = [t for t in targets if t.target_name == filter_name]
    
    total_discovered = len(targets)
    targets = targets[:max_targets]  # Limit targets for HTTP trigger

    run_results = []
    for target in targets:
        result = run_baseline_eval(
            target=target,
            trigger_type=trigger_type,
            dataset_path=dataset_path,
        )
        run_results.append(result)

    uploaded = send_eval_results(run_results)

    summary = {
        "targets_evaluated": len(run_results),
        "total_discovered": total_discovered,
        "limited_to": max_targets,
        "rows_uploaded": uploaded,
        "run_ids": [r.run_id for r in run_results],
        "failures": [
            {"target": r.target.target_name, "error": r.error_message}
            for r in run_results
            if r.error_message
        ],
        "note": f"HTTP trigger limited to {max_targets} targets. Use timer trigger for full subscription scan."
    }
    return func.HttpResponse(
        body=json.dumps(summary),
        status_code=200,
        mimetype="application/json",
    )
