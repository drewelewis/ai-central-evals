"""
main.py
-------
Run the nightly eval pipeline locally without the Azure Functions runtime.

Loads configuration from .env in the repo root (or current directory).

Usage:
    python main.py [--subscription-id <id>] [--dry-run] [--dataset <path.jsonl>]

.env / environment variables:
    AZURE_SUBSCRIPTION_ID             - required
    AZURE_TENANT_ID                   - optional
    DATA_COLLECTION_ENDPOINT_URI      - required unless --dry-run
    DATA_COLLECTION_RULE_IMMUTABLE_ID - required unless --dry-run
    EVAL_SCORE_THRESHOLD              - float 0-1, default 0.7
    EVAL_PACK_VERSION                 - default 1.0.0

--dry-run skips Log Analytics ingestion and just prints results to stdout.
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
from pathlib import Path

# ── Load .env before anything else ───────────────────────────────────────────
# Search from this file's directory upward for a .env file
def _load_dotenv() -> None:
    try:
        from dotenv import load_dotenv
    except ImportError:
        return  # python-dotenv not installed — rely on real env vars
    # Walk up from this file to find .env
    candidate = Path(__file__).resolve().parent
    for _ in range(4):  # search up to 4 levels
        env_file = candidate / ".env"
        if env_file.exists():
            load_dotenv(env_file)
            return
        candidate = candidate.parent

_load_dotenv()

# ── Make sure the package root is on the path when running directly ──────────
sys.path.insert(0, os.path.dirname(__file__))

from arg_discovery import discover_all_eval_targets
from eval_runner import run_baseline_eval, EvalRunResult

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%H:%M:%S",
)
# Silence HTTP-level noise from the Azure SDK (still see our own INFO logs)
logging.getLogger("azure.core.pipeline.policies.http_logging_policy").setLevel(logging.WARNING)
logging.getLogger("azure.identity").setLevel(logging.WARNING)
logger = logging.getLogger("main")


def _print_results(run_result: EvalRunResult) -> None:
    target = run_result.target
    print(f"\n{'='*70}")
    print(f"Run ID   : {run_result.run_id}")
    print(f"Target   : {target.foundry_project_name} / {target.target_name} ({target.target_type})")
    print(f"Trigger  : {run_result.trigger_type}")
    if run_result.error_message:
        print(f"ERROR    : {run_result.error_message}")
    print(f"{'-'*70}")
    print(f"{'Evaluator':<22} {'Category':<12} {'Score':>6}  {'Pass?':<6}  {'Severity'}")
    print(f"{'-'*70}")
    for er in run_result.evaluator_results:
        tick = "PASS" if er.passed else "FAIL"
        print(
            f"{er.evaluator_name:<22} {er.category:<12} {er.score:>6.3f}  {tick:<6}  {er.severity}"
        )
    passed = sum(1 for r in run_result.evaluator_results if r.passed)
    total = len(run_result.evaluator_results)
    print(f"{'-'*70}")
    print(f"Result   : {passed}/{total} evaluators passed")


def main() -> None:
    os.system("cls" if os.name == "nt" else "clear")

    parser = argparse.ArgumentParser(description="Run Foundry evals locally")
    parser.add_argument("--subscription-id", default=os.getenv("AZURE_SUBSCRIPTION_ID"),
                        help="Azure subscription ID (default: AZURE_SUBSCRIPTION_ID env var)")
    parser.add_argument("--tenant-id", default=os.getenv("AZURE_TENANT_ID", ""),
                        help="Azure tenant ID (optional)")
    parser.add_argument("--dataset", default="",
                        help="Path to a JSONL dataset file (default: built-in baseline dataset)")
    parser.add_argument("--dry-run", action="store_true",
                        help="Skip Log Analytics ingestion, print results to stdout only")
    args = parser.parse_args()

    subscription_id: str = args.subscription_id or ""
    if not subscription_id:
        logger.error(
            "No subscription ID provided. Set AZURE_SUBSCRIPTION_ID or use --subscription-id."
        )
        sys.exit(1)

    # Populate env vars expected by la_ingestion if not already set
    if not args.dry_run:
        missing = [
            v for v in ("DATA_COLLECTION_ENDPOINT_URI", "DATA_COLLECTION_RULE_IMMUTABLE_ID")
            if not os.getenv(v)
        ]
        if missing:
            logger.error(
                "Missing env vars for Log Analytics ingestion: %s\n"
                "Set them or use --dry-run to skip ingestion.",
                ", ".join(missing),
            )
            sys.exit(1)

    # ── Step 1: Discover targets ──────────────────────────────────────────────
    logger.info("Discovering eval targets in subscription %s ...", subscription_id)
    targets = discover_all_eval_targets(subscription_id, args.tenant_id)

    if not targets:
        logger.warning("No eval targets found. Nothing to do.")
        return

    logger.info("Found %d target(s)", len(targets))

    # ── Step 2 & 3: Eval + incremental ingestion ─────────────────────────────
    if not args.dry_run:
        from la_ingestion import send_eval_results

    all_results: list[EvalRunResult] = []

    for target in targets:
        logger.info(
            "Evaluating %s / %s (%s) ...",
            target.foundry_project_name,
            target.target_name,
            target.target_type,
        )
        run_result = run_baseline_eval(
            target=target,
            trigger_type="manual",
            dataset_path=args.dataset,
        )
        all_results.append(run_result)
        _print_results(run_result)

        if not args.dry_run:
            try:
                rows_sent = send_eval_results([run_result])
                logger.info("Ingested %d row(s) to Log Analytics", rows_sent)
            except Exception as exc:  # noqa: BLE001
                logger.error("Ingestion failed for run %s: %s", run_result.run_id, exc)

    if args.dry_run:
        logger.info("--dry-run: skipping Log Analytics ingestion")

    # Summary
    total_evals = sum(len(r.evaluator_results) for r in all_results)
    total_passed = sum(
        sum(1 for e in r.evaluator_results if e.passed) for r in all_results
    )
    print(f"\n{'='*70}")
    print(f"SUMMARY: {len(all_results)} target(s) | {total_passed}/{total_evals} evaluator checks passed")
    print(f"{'='*70}\n")


if __name__ == "__main__":
    main()
