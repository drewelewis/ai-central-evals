"""
la_ingestion.py
---------------
Sends EvalRunResult rows to the centralized Log Analytics workspace
via the Azure Monitor Logs Ingestion API (azure-monitor-ingestion SDK).

Each EvaluatorResult within an EvalRunResult becomes one row in FoundryEvals_CL.
Authentication uses the Managed Identity of the Function App (or DefaultAzureCredential
locally), so no secrets are required.
"""

from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timezone
from typing import Any

from azure.identity import DefaultAzureCredential, ManagedIdentityCredential
from azure.monitor.ingestion import LogsIngestionClient
from azure.core.exceptions import HttpResponseError

from eval_runner import EvalRunResult, EvaluatorResult
from arg_discovery import EvalTarget

logger = logging.getLogger(__name__)

# Loaded from App Settings (set by Bicep / azd)
DATA_COLLECTION_ENDPOINT_URI: str = os.environ["DATA_COLLECTION_ENDPOINT_URI"]
DATA_COLLECTION_RULE_IMMUTABLE_ID: str = os.environ["DATA_COLLECTION_RULE_IMMUTABLE_ID"]
STREAM_NAME: str = "Custom-FoundryEvals_CL"


def _get_credential():
    if os.getenv("WEBSITE_INSTANCE_ID"):
        return ManagedIdentityCredential()
    return DefaultAzureCredential()


def _build_row(
    run_result: EvalRunResult,
    evaluator_result: EvaluatorResult,
    now_utc: str,
) -> dict[str, Any]:
    """Convert one EvaluatorResult into a FoundryEvals_CL schema-conformant dict."""
    t: EvalTarget = run_result.target
    return {
        "TimeGenerated": now_utc,
        "TenantId_s": t.tenant_id,
        "SubscriptionId_s": t.subscription_id,
        "ResourceGroup_s": t.resource_group,
        "FoundryProjectName_s": t.foundry_project_name,
        "FoundryProjectId_s": t.foundry_project_id,
        "TargetType_s": t.target_type,
        "TargetName_s": t.target_name,
        "TargetVersion_s": t.target_version,
        "EvalPackVersion_s": os.getenv("EVAL_PACK_VERSION", "1.0.0"),
        "EvalRunId_s": run_result.run_id,
        "EvalDatasetPath_s": run_result.dataset_path,
        "TriggerType_s": run_result.trigger_type,
        "EvaluatorName_s": evaluator_result.evaluator_name,
        "EvaluatorCategory_s": evaluator_result.category,
        "Score_d": evaluator_result.score,
        "Threshold_d": evaluator_result.threshold,
        "Passed_b": evaluator_result.passed,
        "Severity_s": evaluator_result.severity,
        "ErrorMessage_s": evaluator_result.error_message or run_result.error_message,
        "DurationMs_d": evaluator_result.duration_ms,
        "RawOutput_s": evaluator_result.raw_output,
    }


def send_eval_results(run_results: list[EvalRunResult]) -> int:
    """
    Upload all evaluator rows from a list of EvalRunResults to FoundryEvals_CL.

    Args:
        run_results: Output from eval_runner.run_baseline_eval() calls.

    Returns:
        Total number of rows successfully uploaded.
    """
    if not run_results:
        logger.info("No eval results to upload.")
        return 0

    cred = _get_credential()
    client = LogsIngestionClient(
        endpoint=DATA_COLLECTION_ENDPOINT_URI,
        credential=cred,
        logging_enable=False,
    )

    now_utc = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    rows: list[dict[str, Any]] = []

    for run_result in run_results:
        if not run_result.evaluator_results:
            # Run failed with no evaluator output — emit a single error row
            rows.append(
                {
                    "TimeGenerated": now_utc,
                    "TenantId_s": run_result.target.tenant_id,
                    "SubscriptionId_s": run_result.target.subscription_id,
                    "ResourceGroup_s": run_result.target.resource_group,
                    "FoundryProjectName_s": run_result.target.foundry_project_name,
                    "FoundryProjectId_s": run_result.target.foundry_project_id,
                    "TargetType_s": run_result.target.target_type,
                    "TargetName_s": run_result.target.target_name,
                    "TargetVersion_s": run_result.target.target_version,
                    "EvalPackVersion_s": os.getenv("EVAL_PACK_VERSION", "1.0.0"),
                    "EvalRunId_s": run_result.run_id,
                    "EvalDatasetPath_s": run_result.dataset_path,
                    "TriggerType_s": run_result.trigger_type,
                    "EvaluatorName_s": "RunError",
                    "EvaluatorCategory_s": "error",
                    "Score_d": 0.0,
                    "Threshold_d": float(os.getenv("EVAL_SCORE_THRESHOLD", "0.7")),
                    "Passed_b": False,
                    "Severity_s": "critical",
                    "ErrorMessage_s": run_result.error_message,
                    "DurationMs_d": 0.0,
                    "RawOutput_s": "",
                }
            )
            continue

        for ev_result in run_result.evaluator_results:
            rows.append(_build_row(run_result, ev_result, now_utc))

    if not rows:
        return 0

    # The Logs Ingestion API accepts up to 1 MB per request. Batch in chunks.
    BATCH_SIZE = 500
    uploaded = 0
    for i in range(0, len(rows), BATCH_SIZE):
        batch = rows[i : i + BATCH_SIZE]
        try:
            client.upload(
                rule_id=DATA_COLLECTION_RULE_IMMUTABLE_ID,
                stream_name=STREAM_NAME,
                logs=batch,
            )
            uploaded += len(batch)
            logger.info("Uploaded %d row(s) to %s (batch %d)", len(batch), STREAM_NAME, i // BATCH_SIZE + 1)
        except HttpResponseError as exc:
            logger.error(
                "Failed to upload batch %d to Log Analytics: %s (status=%s)",
                i // BATCH_SIZE + 1,
                exc.message,
                exc.status_code,
            )
        except Exception as exc:  # noqa: BLE001
            logger.error("Unexpected error uploading to Log Analytics: %s", exc)

    return uploaded
