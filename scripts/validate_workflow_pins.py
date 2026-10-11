#!/usr/bin/env python3
"""Reject mutable GitHub Action references in repository workflows."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
USES = re.compile(r"^\s*-?\s*uses:\s*([^\s#]+)", re.MULTILINE)
FULL_SHA = re.compile(r"^[0-9a-f]{40}$")


def mutable_references() -> list[str]:
    findings: list[str] = []
    for workflow in sorted(WORKFLOWS.glob("*.y*ml")):
        for reference in USES.findall(workflow.read_text(encoding="utf-8")):
            if reference.startswith("./"):
                continue
            separator = reference.rfind("@")
            revision = reference[separator + 1 :] if separator >= 0 else ""
            if not FULL_SHA.fullmatch(revision):
                findings.append(f"{workflow.relative_to(ROOT)}: {reference}")
    return findings


def main() -> int:
    findings = mutable_references()
    if findings:
        print("Mutable GitHub Action references found:", file=sys.stderr)
        for finding in findings:
            print(f"- {finding}", file=sys.stderr)
        return 1
    print("All external GitHub Action references are pinned to full SHAs.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
