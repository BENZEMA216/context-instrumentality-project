#!/usr/bin/env python3
"""Bootstrap GitHub labels, milestones, issues, and Project V2 items from project/issues.json."""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path
from typing import Any

DEFAULT_PLAN_PATH = Path(__file__).resolve().parent.parent / "project" / "issues.json"
REQUIRED_ISSUE_KEYS = {
    "id",
    "title",
    "milestone",
    "module",
    "priority",
    "effort",
    "labels",
    "depends_on",
    "body",
}


class PlanValidationError(ValueError):
    """Raised when the project plan JSON fails schema or DAG validation."""


def load_plan(plan_path: Path) -> dict[str, Any]:
    """Load and validate the JSON issue plan from disk."""
    raw = json.loads(plan_path.read_text(encoding="utf-8"))
    validate_plan(raw)
    return raw


def validate_plan(plan: dict[str, Any]) -> None:
    """Validate structure, referential integrity, and acyclic dependencies of the plan."""
    if not isinstance(plan, dict):
        raise PlanValidationError("Plan root must be a JSON object.")
    for key in ("milestones", "labels", "issues"):
        if not isinstance(plan.get(key), list):
            raise PlanValidationError(f"Plan missing list field '{key}'.")

    milestone_titles = {m["title"] for m in plan["milestones"] if isinstance(m, dict) and "title" in m}
    if len(milestone_titles) != len(plan["milestones"]):
        raise PlanValidationError("Each milestone must be an object with a unique 'title'.")

    label_names = {lb["name"] for lb in plan["labels"] if isinstance(lb, dict) and "name" in lb}
    if len(label_names) != len(plan["labels"]):
        raise PlanValidationError("Each label must be an object with a unique 'name'.")

    seen_ids: set[str] = set()
    seen_titles: set[str] = set()
    deps_by_id: dict[str, list[str]] = {}

    for issue in plan["issues"]:
        if not isinstance(issue, dict):
            raise PlanValidationError("Each issue entry must be an object.")
        missing = REQUIRED_ISSUE_KEYS - set(issue.keys())
        if missing:
            raise PlanValidationError(f"Issue {issue.get('id', '<unknown>')} missing keys: {sorted(missing)}")

        issue_id = issue["id"]
        title = issue["title"]
        if issue_id in seen_ids:
            raise PlanValidationError(f"Duplicate issue id: {issue_id}")
        if title in seen_titles:
            raise PlanValidationError(f"Duplicate issue title: {title}")
        seen_ids.add(issue_id)
        seen_titles.add(title)

        if issue["milestone"] not in milestone_titles:
            raise PlanValidationError(f"Issue {issue_id} references unknown milestone: {issue['milestone']}")
        unknown_labels = [lb for lb in issue["labels"] if lb not in label_names]
        if unknown_labels:
            raise PlanValidationError(f"Issue {issue_id} references unknown labels: {unknown_labels}")
        deps_by_id[issue_id] = list(issue["depends_on"])

    for issue_id, deps in deps_by_id.items():
        unknown_deps = [d for d in deps if d not in seen_ids]
        if unknown_deps:
            raise PlanValidationError(f"Issue {issue_id} depends on unknown IDs: {unknown_deps}")

    _ensure_acyclic(deps_by_id)


def _ensure_acyclic(deps_by_id: dict[str, list[str]]) -> None:
    """Detect cycles in the issue dependency graph."""
    visiting: set[str] = set()
    visited: set[str] = set()

    def dfs(node: str) -> None:
        if node in visited:
            return
        if node in visiting:
            raise PlanValidationError(f"Cycle detected in depends_on involving '{node}'.")
        visiting.add(node)
        for dep in deps_by_id.get(node, []):
            dfs(dep)
        visiting.remove(node)
        visited.add(node)

    for issue_id in deps_by_id:
        dfs(issue_id)


def topological_issues(issues: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Order issues so dependencies are created before dependents while preserving plan order."""
    by_id = {issue["id"]: issue for issue in issues}
    visited: set[str] = set()
    ordered: list[dict[str, Any]] = []

    def visit(issue_id: str) -> None:
        if issue_id in visited:
            return
        visited.add(issue_id)
        for dep in by_id[issue_id]["depends_on"]:
            visit(dep)
        ordered.append(by_id[issue_id])

    for issue in issues:
        visit(issue["id"])
    return ordered


def filter_issues(
    issues: list[dict[str, Any]],
    milestone: str | None = None,
    module: str | None = None,
) -> list[dict[str, Any]]:
    """Filter issues by optional milestone title or module name."""
    result = issues
    if milestone:
        result = [item for item in result if item["milestone"] == milestone]
    if module:
        result = [item for item in result if item["module"] == module]
    return result


def format_issue_body(issue: dict[str, Any], issue_numbers: dict[str, int]) -> str:
    """Render an enriched issue body including metadata table and dependency links."""
    deps = issue["depends_on"]
    if deps:
        rendered_deps = ", ".join(
            f"{dep} (#{issue_numbers[dep]})" if dep in issue_numbers else dep for dep in deps
        )
    else:
        rendered_deps = "None"

    meta_block = (
        "<!-- context-instrumentality-managed -->\n"
        "| Track ID | Module | Priority | Effort | Depends On |\n"
        "| :--- | :--- | :--- | :--- | :--- |\n"
        f"| `{issue['id']}` | `{issue['module']}` | `{issue['priority']}` | `{issue['effort']}` | {rendered_deps} |\n\n"
    )
    return meta_block + issue["body"].rstrip() + "\n"


Runner = Callable[[list[str], str | None], subprocess.CompletedProcess[str]]


def default_runner(args: list[str], stdin_text: str | None = None) -> subprocess.CompletedProcess[str]:
    """Execute a subprocess command without shell interpolation."""
    return subprocess.run(
        args,
        input=stdin_text,
        text=True,
        capture_output=True,
        check=True,
    )


def sync_labels(
    labels: list[dict[str, Any]],
    repo: str,
    dry_run: bool,
    runner: Runner,
) -> None:
    """Create or update repository labels idempotently."""
    for label in labels:
        cmd = [
            "gh",
            "label",
            "create",
            label["name"],
            "-c",
            label["color"],
            "-d",
            label["description"],
            "-f",
            "-R",
            repo,
        ]
        if dry_run:
            print(f"[dry-run] {' '.join(cmd)}")
        else:
            runner(cmd, None)
            print(f"[label] synced {label['name']}")


def sync_milestones(
    milestones: list[dict[str, Any]],
    repo: str,
    dry_run: bool,
    runner: Runner,
) -> None:
    """Create missing repository milestones idempotently."""
    existing_titles: set[str] = set()
    if not dry_run:
        res = runner(["gh", "api", f"repos/{repo}/milestones?state=all", "--paginate"], None)
        existing_titles = {item["title"] for item in json.loads(res.stdout)}

    for ms in milestones:
        if ms["title"] in existing_titles:
            print(f"[milestone] skip existing: {ms['title']}")
            continue
        cmd = [
            "gh",
            "api",
            f"repos/{repo}/milestones",
            "-X",
            "POST",
            "-f",
            f"title={ms['title']}",
            "-f",
            f"description={ms['description']}",
            "-f",
            "state=open",
        ]
        if dry_run:
            print(f"[dry-run] {' '.join(cmd)}")
        else:
            runner(cmd, None)
            print(f"[milestone] created {ms['title']}")


def _fetch_existing_issues(repo: str, runner: Runner) -> dict[str, dict[str, Any]]:
    """Fetch existing issues indexed by exact title."""
    res = runner(
        ["gh", "issue", "list", "-R", repo, "--state", "all", "--limit", "500", "--json", "number,title,url"],
        None,
    )
    items = json.loads(res.stdout)
    return {item["title"]: item for item in items}


def _fetch_project_metadata(
    project_number: int,
    project_owner: str,
    runner: Runner,
) -> tuple[str, dict[str, dict[str, Any]]]:
    """Fetch Project V2 node ID and single-select field definitions."""
    view_res = runner(
        ["gh", "project", "view", str(project_number), "--owner", project_owner, "--format", "json"],
        None,
    )
    project_id = json.loads(view_res.stdout)["id"]
    field_res = runner(
        ["gh", "project", "field-list", str(project_number), "--owner", project_owner, "--format", "json"],
        None,
    )
    raw_fields = json.loads(field_res.stdout).get("fields", [])
    fields_by_name: dict[str, dict[str, Any]] = {}
    for field in raw_fields:
        if "options" in field:
            options_map = {opt["name"]: opt["id"] for opt in field["options"]}
            fields_by_name[field["name"]] = {"id": field["id"], "options": options_map}
    return project_id, fields_by_name


def _sync_project_item(
    issue: dict[str, Any],
    issue_url: str,
    project_number: int,
    project_owner: str,
    project_id: str | None,
    fields_by_name: dict[str, dict[str, Any]],
    dry_run: bool,
    runner: Runner,
) -> None:
    """Add issue to Project V2 and populate matching Module/Priority/Effort fields."""
    add_cmd = [
        "gh",
        "project",
        "item-add",
        str(project_number),
        "--owner",
        project_owner,
        "--url",
        issue_url,
        "--format",
        "json",
    ]
    if dry_run:
        print(f"[dry-run] {' '.join(add_cmd)}")
        return

    add_res = runner(add_cmd, None)
    item_id = json.loads(add_res.stdout).get("id")
    if not item_id or not project_id:
        return

    desired_fields = {
        "Module": issue["module"],
        "Priority": issue["priority"],
        "Effort": issue["effort"],
    }
    for field_name, desired_option in desired_fields.items():
        field_meta = fields_by_name.get(field_name)
        if not field_meta:
            continue
        option_id = field_meta["options"].get(desired_option)
        if not option_id:
            continue
        runner(
            [
                "gh",
                "project",
                "item-edit",
                "--project-id",
                project_id,
                "--id",
                item_id,
                "--field-id",
                field_meta["id"],
                "--single-select-option-id",
                option_id,
            ],
            None,
        )


def sync_issues(
    issues: list[dict[str, Any]],
    repo: str,
    dry_run: bool,
    runner: Runner,
    project_number: int | None = None,
    project_owner: str | None = None,
) -> dict[str, int]:
    """Create missing issues in topological order and optionally attach them to a GitHub Project."""
    existing_by_title = {} if dry_run else _fetch_existing_issues(repo, runner)
    issue_numbers: dict[str, int] = {}

    for item in issues:
        existing = existing_by_title.get(item["title"])
        if existing:
            issue_numbers[item["id"]] = int(existing["number"])

    project_id: str | None = None
    fields_by_name: dict[str, dict[str, Any]] = {}
    if project_number is not None and project_owner and not dry_run:
        project_id, fields_by_name = _fetch_project_metadata(project_number, project_owner, runner)

    for issue in topological_issues(issues):
        existing = existing_by_title.get(issue["title"])
        if existing:
            issue_url = existing["url"]
            print(f"[issue] skip existing {issue['id']} -> #{existing['number']} ({issue['title']})")
        else:
            body = format_issue_body(issue, issue_numbers)
            cmd = ["gh", "issue", "create", "-R", repo, "-t", issue["title"], "-F", "-", "-m", issue["milestone"]]
            for label in issue["labels"]:
                cmd.extend(["-l", label])

            if dry_run:
                print(f"[dry-run] {' '.join(cmd)}  (id={issue['id']})")
                issue_url = f"https://github.com/{repo}/issues/<pending-{issue['id']}>"
            else:
                res = runner(cmd, body)
                issue_url = res.stdout.strip()
                number = int(issue_url.rstrip("/").split("/")[-1])
                issue_numbers[issue["id"]] = number
                print(f"[issue] created {issue['id']} -> #{number} ({issue_url})")

        if project_number is not None and project_owner:
            _sync_project_item(
                issue=issue,
                issue_url=issue_url,
                project_number=project_number,
                project_owner=project_owner,
                project_id=project_id,
                fields_by_name=fields_by_name,
                dry_run=dry_run,
                runner=runner,
            )

    return issue_numbers


def build_parser() -> argparse.ArgumentParser:
    """Create CLI argument parser."""
    parser = argparse.ArgumentParser(
        description="Idempotently import Context Instrumentality Project labels, milestones, issues, and Project V2 items via gh CLI."
    )
    parser.add_argument("--plan", type=Path, default=DEFAULT_PLAN_PATH, help="Path to issues.json plan file.")
    parser.add_argument("--repo", help="Target GitHub repository in OWNER/REPO format.")
    parser.add_argument("--project-number", type=int, help="Optional GitHub Project V2 number.")
    parser.add_argument("--project-owner", help="GitHub Project owner login (defaults to repo owner).")
    parser.add_argument("--milestone", help="Only import issues belonging to this milestone title.")
    parser.add_argument("--module", help="Only import issues belonging to this module name.")
    parser.add_argument("--validate-only", action="store_true", help="Validate issues.json locally without calling gh.")
    parser.add_argument("--dry-run", action="store_true", help="Print gh commands without modifying GitHub.")
    return parser


def main(argv: list[str] | None = None, runner: Runner = default_runner) -> int:
    """CLI entry point."""
    parser = build_parser()
    args = parser.parse_args(argv)

    plan = load_plan(args.plan)
    selected_issues = filter_issues(plan["issues"], milestone=args.milestone, module=args.module)

    if args.validate_only:
        print(
            f"[ok] Validated {len(plan['milestones'])} milestones, "
            f"{len(plan['labels'])} labels, and {len(selected_issues)} selected issues."
        )
        return 0

    if not args.repo:
        parser.error("--repo OWNER/REPO is required unless --validate-only is specified.")
    if not args.dry_run and shutil.which("gh") is None:
        print("Error: 'gh' CLI not found on PATH.", file=sys.stderr)
        return 2

    project_owner = args.project_owner or args.repo.split("/", 1)[0]
    sync_labels(plan["labels"], repo=args.repo, dry_run=args.dry_run, runner=runner)
    sync_milestones(plan["milestones"], repo=args.repo, dry_run=args.dry_run, runner=runner)
    sync_issues(
        selected_issues,
        repo=args.repo,
        dry_run=args.dry_run,
        runner=runner,
        project_number=args.project_number,
        project_owner=project_owner if args.project_number is not None else None,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
