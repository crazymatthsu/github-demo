#!/usr/bin/env python3
"""Affected-subproject detection for CI (D7 §5.4, §6.3; D1 §6.9).

Maps the paths changed between two commits onto Gradle projects with .github/affected-map.yml and
prints what the PR workflow must build and test. Standard library only; the YAML map is converted
with `yq` (preinstalled on GitHub-hosted runners) or PyYAML when available.

    python3 scripts/ci/affected.py --base origin/main            # what CI does for this branch
    python3 scripts/ci/affected.py --files a/b.java docs/x.md    # classify explicit paths
    python3 scripts/ci/affected.py --full --reason "label ci:full"

Outputs (stdout as JSON; `key=value` lines appended to --github-output, a table to --summary):
  projects        JSON list of Gradle projects to build (every project when full)
  image-projects  the subset that produces images
  matrix          the subset that has integration tests (the component IT matrix)
  full            true when shared inputs changed, a path is unmapped, or --full was given
  docs-only       true when nothing build-relevant changed (docs, repository metadata, or no change)
  config-changed  true when config/** changed (config-lint must run)
  base-changed    true when a company base image changed (build it locally, do not pull it)
  reason          one line explaining the decision

Exit codes: 0 success, 2 usage or map error, 3 git error.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys

DEFAULT_MAP = ".github/affected-map.yml"


def fail(message: str, code: int) -> None:
    print(f"affected.py: {message}", file=sys.stderr)
    sys.exit(code)


def glob_to_regex(glob: str) -> re.Pattern[str]:
    """`**/` = zero or more directories, `**` = anything, `*` / `?` = within one path segment."""
    out: list[str] = []
    i = 0
    while i < len(glob):
        if glob.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif glob.startswith("**", i):
            out.append(".*")
            i += 2
        elif glob[i] == "*":
            out.append("[^/]*")
            i += 1
        elif glob[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(glob[i]))
            i += 1
    return re.compile("^" + "".join(out) + "$")


def load_map(path: str) -> dict:
    if not os.path.isfile(path):
        fail(f"map not found: {path}", 2)
    if path.endswith(".json"):
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    if shutil.which("yq"):
        # mikefarah yq v4 (GitHub-hosted runners) needs -o=json; the Python jq wrapper emits JSON already.
        for command in (["yq", "-o=json", ".", path], ["yq", ".", path]):
            result = subprocess.run(command, capture_output=True, text=True)
            if result.returncode == 0:
                try:
                    return json.loads(result.stdout)
                except json.JSONDecodeError:
                    continue
        fail(f"yq could not convert {path} to JSON: {result.stderr.strip()}", 2)
    try:
        import yaml  # type: ignore[import-not-found]
    except ImportError:
        fail("neither yq nor PyYAML is available to read the YAML map", 2)
    with open(path, encoding="utf-8") as handle:
        return yaml.safe_load(handle)


def validate_map(cfg: dict) -> None:
    if not isinstance(cfg, dict) or cfg.get("schema") != 1:
        fail("map must be a mapping with `schema: 1`", 2)
    projects = cfg.get("projects")
    if not isinstance(projects, dict) or not projects:
        fail("map needs a non-empty `projects` mapping", 2)
    for rule in cfg.get("paths", []):
        unknown = [p for p in rule.get("projects", []) if p not in projects]
        if unknown or "glob" not in rule:
            fail(f"bad `paths` rule {rule!r} (unknown projects: {unknown})", 2)


def git(*args: str) -> str:
    result = subprocess.run(["git", *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout


def changed_files(base: str | None, head: str, default_branch: str) -> tuple[list[str] | None, str]:
    """Returns (files, description); files is None when no usable base exists (caller goes full)."""
    try:
        head_sha = git("rev-parse", "--verify", f"{head}^{{commit}}").strip()
        if base and set(base) == {"0"}:
            base = None  # a push that created the branch reports an all-zero `before`
        if base:
            base_sha = git("rev-parse", "--verify", f"{base}^{{commit}}").strip()
            merge_base = git("merge-base", base_sha, head_sha).strip()
            described = f"merge-base({base[:12]}, {head[:12]})"
        else:
            merge_base = git("merge-base", default_branch, head_sha).strip()
            described = f"merge-base({default_branch}, {head[:12]})"
    except RuntimeError as error:
        return None, f"no usable diff base ({error})"
    if merge_base == head_sha and base is None:
        return [], f"{described}: HEAD is already on {default_branch}"
    try:
        out = git("diff", "--name-only", "--no-renames", merge_base, head_sha)
    except RuntimeError as error:
        fail(str(error), 3)
    return [line for line in out.splitlines() if line.strip()], f"{described}..{head[:12]}"


def classify(files: list[str], cfg: dict) -> dict:
    compiled = {
        section: [(g, glob_to_regex(g)) for g in cfg.get(section, [])]
        for section in ("docs", "config", "shared", "base-images")
    }
    path_rules = [(r["glob"], glob_to_regex(r["glob"]), r["projects"]) for r in cfg.get("paths", [])]

    def first(section: str, path: str) -> str | None:
        return next((g for g, rx in compiled[section] if rx.match(path)), None)

    rows, projects = [], set()
    full = config_changed = base_changed = False
    unmapped: list[str] = []
    for path in files:
        if first("base-images", path):
            base_changed = True
        if (g := first("docs", path)) is not None:
            rows.append((path, "docs", g))
        elif (g := first("config", path)) is not None:
            config_changed = True
            rows.append((path, "config", g))
        elif (g := first("shared", path)) is not None:
            full = True
            rows.append((path, "shared → all", g))
        else:
            rule = next(((g, p) for g, rx, p in path_rules if rx.match(path)), None)
            if rule:
                projects.update(rule[1])
                rows.append((path, ", ".join(rule[1]), rule[0]))
            else:
                full = True
                unmapped.append(path)
                rows.append((path, "unmapped → all", "—"))
    return {
        "rows": rows,
        "projects": projects,
        "full": full,
        "config_changed": config_changed,
        "base_changed": base_changed,
        "unmapped": unmapped,
    }


def decide(files: list[str] | None, cfg: dict, force_full: bool, full_reason: str, diff_note: str) -> dict:
    all_projects = list(cfg["projects"].keys())
    if files is None:
        result = {"rows": [], "projects": set(all_projects), "full": True, "config_changed": True,
                  "base_changed": False, "unmapped": []}
        reason = f"full: {diff_note}"
    else:
        result = classify(files, cfg)
        if force_full:
            reason = f"full: {full_reason or 'forced'}"
        elif result["full"]:
            shared = [r[0] for r in result["rows"] if r[1] in ("shared → all", "unmapped → all")]
            reason = f"full: shared or unmapped paths changed ({', '.join(shared[:5])}{', …' if len(shared) > 5 else ''})"
        elif result["projects"]:
            reason = f"affected: {', '.join(sorted(result['projects']))}"
        elif result["config_changed"]:
            reason = "config-only: config-lint, no build"
        elif files:
            reason = "docs-only: nothing to build or test"
        else:
            reason = "no changed files: nothing to build or test"
    full = force_full or result["full"]
    selected = all_projects if full else [p for p in all_projects if p in result["projects"]]
    meta = cfg["projects"]
    return {
        "projects": selected,
        "image-projects": [p for p in selected if meta[p].get("image")],
        "matrix": [p for p in selected if meta[p].get("it")],
        "full": full,
        "docs-only": not full and not selected and not result["config_changed"],
        "config-changed": result["config_changed"],
        "base-changed": result["base_changed"],
        "reason": reason,
        "rows": result["rows"],
        "diff": diff_note,
    }


def write_outputs(decision: dict, github_output: str | None, summary: str | None) -> None:
    keys = ("projects", "image-projects", "matrix", "full", "docs-only", "config-changed", "base-changed", "reason")
    if github_output:
        with open(github_output, "a", encoding="utf-8") as handle:
            for key in keys:
                value = decision[key]
                text = value if isinstance(value, str) else json.dumps(value, separators=(",", ":"))
                handle.write(f"{key}={text}\n")
    if summary:
        rows = decision["rows"]
        lines = [
            "### Affected subprojects",
            "",
            f"**{decision['reason']}** — diff {decision['diff']}",
            "",
            f"| full | docs-only | config-changed | base-changed | IT matrix |",
            "|---|---|---|---|---|",
            f"| {str(decision['full']).lower()} | {str(decision['docs-only']).lower()} | "
            f"{str(decision['config-changed']).lower()} | {str(decision['base-changed']).lower()} | "
            f"{', '.join(f'`{p}`' for p in decision['matrix']) or '—'} |",
            "",
        ]
        if rows:
            lines += ["<details><summary>Changed paths (" + str(len(rows)) + ")</summary>", "",
                      "| path | maps to | rule |", "|---|---|---|"]
            lines += [f"| `{p}` | {m} | `{g}` |" for p, m, g in rows[:200]]
            if len(rows) > 200:
                lines.append(f"| … {len(rows) - 200} more | | |")
            lines += ["", "</details>", ""]
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--map", default=DEFAULT_MAP, help=f"path to the map (default {DEFAULT_MAP})")
    parser.add_argument("--base", default="", help="diff base commit or ref (default: merge-base with --default-branch)")
    parser.add_argument("--head", default="HEAD", help="head commit or ref (default HEAD)")
    parser.add_argument("--default-branch", default="origin/main", help="ref used when --base is empty")
    parser.add_argument("--files", nargs="*", help="classify these paths instead of running git diff")
    parser.add_argument("--full", default="false", nargs="?", const="true", help="force everything (true/false)")
    parser.add_argument("--reason", default="", help="why --full was forced (shown in the summary)")
    parser.add_argument("--github-output", default=None, help="append key=value outputs here (GITHUB_OUTPUT)")
    parser.add_argument("--summary", default=None, help="append a Markdown table here (GITHUB_STEP_SUMMARY)")
    args = parser.parse_args()

    cfg = load_map(args.map)
    validate_map(cfg)
    if args.files is not None:
        files, note = args.files, "explicit --files"
    else:
        files, note = changed_files(args.base or None, args.head, args.default_branch)
    force_full = str(args.full).strip().lower() == "true"
    decision = decide(files, cfg, force_full, args.reason, note)
    write_outputs(decision, args.github_output, args.summary)
    printable = {k: v for k, v in decision.items() if k != "rows"}
    print(json.dumps(printable, indent=2))


if __name__ == "__main__":
    main()
