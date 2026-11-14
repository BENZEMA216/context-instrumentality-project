"""Tests for project/issues.json schema integrity and scripts/bootstrap_github.py."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT_DIR / "scripts"))

import bootstrap_github  # noqa: E402


def _ok_process(stdout: str = "") -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess(args=["gh"], returncode=0, stdout=stdout, stderr="")


def test_real_issues_plan_is_valid_and_complete() -> None:
    plan = bootstrap_github.load_plan(ROOT_DIR / "project" / "issues.json")
    assert len(plan["milestones"]) == 1
    assert len(plan["issues"]) == 10
    ordered = bootstrap_github.topological_issues(plan["issues"])
    seen: set[str] = set()
    for item in ordered:
        for dep in item["depends_on"]:
            assert dep in seen, f"{item['id']} appeared before dependency {dep}"
        seen.add(item["id"])


def test_validate_plan_detects_cycle() -> None:
    bad_plan = {
        "milestones": [{"title": "M0", "description": "d"}],
        "labels": [{"name": "mod:hub", "color": "000000", "description": "d"}],
        "issues": [
            {
                "id": "A",
                "title": "Issue A",
                "milestone": "M0",
                "module": "hub",
                "priority": "P0",
                "effort": "S",
                "labels": ["mod:hub"],
                "depends_on": ["B"],
                "body": "a",
            },
            {
                "id": "B",
                "title": "Issue B",
                "milestone": "M0",
                "module": "hub",
                "priority": "P0",
                "effort": "S",
                "labels": ["mod:hub"],
                "depends_on": ["A"],
                "body": "b",
            },
        ],
    }
    with pytest.raises(bootstrap_github.PlanValidationError, match="Cycle detected"):
        bootstrap_github.validate_plan(bad_plan)


def test_dry_run_makes_no_subprocess_calls(capsys: pytest.CaptureFixture[str]) -> None:
    calls: list[list[str]] = []

    def fake_runner(args: list[str], stdin_text: str | None = None) -> subprocess.CompletedProcess[str]:
        calls.append(args)
        return _ok_process()

    exit_code = bootstrap_github.main(
        [
            "--repo",
            "BENZEMA216/open-context",
            "--project-number",
            "1",
            "--milestone",
            "M0: Research - Channels & Integration Method",
            "--dry-run",
        ],
        runner=fake_runner,
    )
    assert exit_code == 0
    assert calls == []
    out = capsys.readouterr().out
    assert "[dry-run] gh issue create" in out
    assert "[dry-run] gh project item-add" in out


def test_idempotent_sync_skips_existing_and_resolves_dependencies() -> None:
    recorded: list[tuple[list[str], str | None]] = []

    def fake_runner(args: list[str], stdin_text: str | None = None) -> subprocess.CompletedProcess[str]:
        recorded.append((args, stdin_text))
        if args[:3] == ["gh", "api", "repos/owner/repo/milestones?state=all"]:
            return _ok_process(json.dumps([{"title": "M0: Research - Channels & Integration Method"}]))
        if args[:3] == ["gh", "issue", "list"]:
            return _ok_process(
                json.dumps(
                    [
                        {
                            "number": 10,
                            "title": "[Channels] 确定 Context 渠道清单、定义与优先级",
                            "url": "https://github.com/owner/repo/issues/10",
                        }
                    ]
                )
            )
        if args[:3] == ["gh", "project", "view"]:
            return _ok_process(json.dumps({"id": "PVT_1"}))
        if args[:3] == ["gh", "project", "field-list"]:
            return _ok_process(
                json.dumps(
                    {
                        "fields": [
                            {"id": "F_MOD", "name": "Module", "options": [{"id": "O_CH", "name": "channels"}]},
                            {"id": "F_PRIO", "name": "Priority", "options": [{"id": "O_P0", "name": "P0"}]},
                        ]
                    }
                )
            )
        if args[:3] == ["gh", "issue", "create"]:
            return _ok_process("https://github.com/owner/repo/issues/11\n")
        if args[:3] == ["gh", "project", "item-add"]:
            return _ok_process(json.dumps({"id": "PVTI_1"}))
        return _ok_process("{}")

    plan = bootstrap_github.load_plan(ROOT_DIR / "project" / "issues.json")
    subset = bootstrap_github.filter_issues(
        plan["issues"], milestone="M0: Research - Channels & Integration Method"
    )[:2]

    numbers = bootstrap_github.sync_issues(
        subset,
        repo="owner/repo",
        dry_run=False,
        runner=fake_runner,
        project_number=1,
        project_owner="owner",
    )

    assert numbers["R-01"] == 10
    assert numbers["R-02"] == 11

    create_calls = [(args, body) for args, body in recorded if args[:3] == ["gh", "issue", "create"]]
    assert len(create_calls) == 1
    assert create_calls[0][1] is not None
    assert "R-01 (#10)" in create_calls[0][1]

    edit_calls = [args for args, _ in recorded if args[:3] == ["gh", "project", "item-edit"]]
    assert len(edit_calls) == 4  # 2 issues * (Module + Priority)
