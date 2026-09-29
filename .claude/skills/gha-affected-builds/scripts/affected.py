#!/usr/bin/env python3
"""Affected-project detection for monorepo CI (GitHub Actions, or a laptop: same answer).

Maps the paths changed between two commits onto the projects of a monorepo with a checked-in path
map (default .github/affected-map.yml) and prints what CI must build and test. Run it from the
repository root.

    python3 affected.py --base origin/main                  # what CI selects for this branch
    python3 affected.py --files services/api/app.py docs/a.md
    python3 affected.py --full --reason "label ci:full"
    git ls-files | python3 affected.py --files-from -       # audit the map: see "unmapped"

Rules: a changed path gets the class of the FIRST map section that matches, in this order
    docs -> config -> shared -> paths -> (no match: unmapped, handled like shared)
docs: nothing to build | config: config lint only | shared, unmapped: every project (full) |
paths: the projects of the first matching rule. The flag sections (base-images, deploy-test and
each entry of `flags`) are raised by any matching path, whatever its class.
Globs: `**` spans directories (`**/` also matches none), `*` and `?` stay inside one segment.

Outputs (JSON on stdout; key=value lines appended to --github-output; Markdown to --summary):
  projects        JSON list of the projects to build, in map order (every project when full)
  image-projects  the selected projects with `image: true`
  matrix          the selected projects with `it: true` (the integration-test matrix)
  full            true: shared or unmapped paths changed, no usable diff base, or --full
  docs-only       true: nothing build-relevant changed (only docs paths, or no change at all)
  config-changed  true: a `config` path changed (config lint must run)
  base-changed    true: a `base-images` path changed (build base images locally, do not pull)
  deploy-test     true: full, or a `deploy-test` path changed
  flags           JSON object of the map's `flags` (name -> true/false); --github-output also
                  gets one line per flag under its own name
  reason          one line explaining the decision
stdout also carries "unmapped" (paths no section matched) and "diff" (what was compared).

Requirements: python3 >= 3.8 and git (git only without --files/--files-from). Standard library
only: a YAML map is read with mikefarah yq v4 (preinstalled on GitHub-hosted runners) or with
PyYAML, whichever is available; a map whose name ends in .json needs neither.

Exit codes: 0 success, 2 usage or map error, 3 git error.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys

DEFAULT_MAP = ".github/affected-map.yml"
DEFAULT_BRANCH = "origin/main"
CLASS_SECTIONS = ("docs", "config", "shared")
# Fixed flag sections: section -> (output name, also raised when the run is full).
FIXED_FLAGS = {"base-images": ("base-changed", False), "deploy-test": ("deploy-test", True)}
OUTPUT_KEYS = ("projects", "image-projects", "matrix", "full", "docs-only", "config-changed",
               "base-changed", "deploy-test", "flags", "reason")
TOP_LEVEL_KEYS = {"schema", "projects", "paths", "flags", *CLASS_SECTIONS, *FIXED_FLAGS}
FLAG_NAME = re.compile(r"^[a-z][a-z0-9-]*$")
SHARED, UNMAPPED = "shared -> all", "unmapped -> all"


class GitError(Exception):
    pass


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
    return re.compile("^" + "".join(out) + "$", re.DOTALL)


def load_map(path: str):
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError as error:
        fail(f"cannot read the map {path}: {error.strerror} (run from the repository root or pass --map)", 2)
    if path.endswith(".json"):
        try:
            return json.loads(text)
        except json.JSONDecodeError as error:
            fail(f"{path}: {error}", 2)
    yq_error = ""
    if shutil.which("yq"):
        # mikefarah yq v4 needs -o=json; the Python yq wrapper (jq syntax) prints JSON already.
        for command in (["yq", "-o=json", ".", path], ["yq", ".", path]):
            result = subprocess.run(command, capture_output=True, encoding="utf-8", errors="replace")
            if result.returncode == 0:
                try:
                    return json.loads(result.stdout)
                except json.JSONDecodeError:
                    continue
            yq_error = yq_error or result.stderr.strip()
    try:
        import yaml  # type: ignore[import-not-found]
    except ImportError:
        detail = f" (yq: {yq_error})" if yq_error else ""
        fail(f"cannot read {path}: install mikefarah yq v4 or PyYAML, or use a .json map{detail}", 2)
    try:
        return yaml.safe_load(text)
    except yaml.YAMLError as error:
        fail(f"{path}: {error}", 2)


def validate_map(cfg) -> dict:
    """Checks the map, reports every problem at once, returns it normalized."""
    if not isinstance(cfg, dict) or cfg.get("schema") != 1:
        fail("the map must be a mapping with `schema: 1`", 2)
    problems: list[str] = []

    def globs(value, where: str) -> list[str]:
        if value is None:
            return []
        if not isinstance(value, list) or not all(isinstance(g, str) and g.strip() for g in value):
            problems.append(f"`{where}` must be a list of glob strings")
            return []
        problems.extend(f"`{where}`: {g!r} must be relative to the repository root (no leading / or ./)"
                        for g in value if g.startswith(("/", "./")))
        return value

    unknown = sorted(str(k) for k in cfg if k not in TOP_LEVEL_KEYS and not str(k).startswith("x-"))
    if unknown:
        problems.append(f"unknown top-level keys {unknown} (custom keys must start with x-)")
    projects = cfg.get("projects")
    if not isinstance(projects, dict) or not projects:
        fail("the map needs a non-empty `projects` mapping", 2)
    meta: dict[str, dict] = {}
    for name, value in projects.items():
        value = {} if value is None else value
        if not isinstance(name, str) or not isinstance(value, dict):
            problems.append(f"project {name!r}: key must be a string, value a mapping like {{image: true, it: false}}")
            continue
        problems.extend(f"project {name!r}: `{key}` must be true or false"
                        for key in ("image", "it") if not isinstance(value.get(key, False), bool))
        meta[name] = value

    rules: list[tuple[str, list[str]]] = []
    raw_rules = cfg.get("paths") or []
    if not isinstance(raw_rules, list):
        problems.append("`paths` must be a list of {glob, projects} rules")
        raw_rules = []
    for rule in raw_rules:
        ok = (isinstance(rule, dict) and isinstance(rule.get("glob"), str) and rule["glob"].strip()
              and isinstance(rule.get("projects"), list) and rule["projects"]
              and not [k for k in rule if k not in ("glob", "projects") and not str(k).startswith("x-")])
        if not ok:
            problems.append(f"bad `paths` rule {rule!r}: needs `glob` and a non-empty `projects` list")
            continue
        missing = [p for p in rule["projects"] if p not in meta]
        if missing:
            problems.append(f"`paths` rule {rule['glob']!r} names projects missing from `projects`: {missing}")
        globs([rule["glob"]], f"paths[{rule['glob']}]")
        rules.append((rule["glob"], list(rule["projects"])))

    flags: dict[str, tuple[list[str], bool]] = {}
    raw_flags = cfg.get("flags") or {}
    if not isinstance(raw_flags, dict):
        problems.append("`flags` must be a mapping: <name>: {globs: [...], on-full: true|false}")
        raw_flags = {}
    for name, spec in raw_flags.items():
        if not isinstance(name, str) or not FLAG_NAME.match(name) or name in OUTPUT_KEYS:
            problems.append(f"flag {name!r}: name must match [a-z][a-z0-9-]* and differ from {list(OUTPUT_KEYS)}")
            continue
        if not isinstance(spec, dict) or [k for k in spec if k not in ("globs", "on-full")]:
            problems.append(f"flag {name!r}: expected {{globs: [...], on-full: true|false}}")
            continue
        flag_globs = globs(spec.get("globs"), f"flags.{name}.globs")
        on_full = spec.get("on-full", True)
        if not flag_globs:
            problems.append(f"flag {name!r}: needs at least one glob")
        if not isinstance(on_full, bool):
            problems.append(f"flag {name!r}: on-full must be true or false")
        flags[name] = (flag_globs, on_full is True)

    normalized = {section: globs(cfg.get(section), section) for section in (*CLASS_SECTIONS, *FIXED_FLAGS)}
    if problems:
        fail("invalid map:\n  - " + "\n  - ".join(problems), 2)
    normalized.update(projects=meta, paths=rules, flags=flags)
    return normalized


def git(*args: str) -> str:
    try:
        result = subprocess.run(["git", *args], capture_output=True)
    except FileNotFoundError:
        fail("git not found (use --files or --files-from without git)", 3)
    if result.returncode != 0:
        raise GitError(f"git {' '.join(args)}: {result.stderr.decode('utf-8', 'replace').strip()}")
    return result.stdout.decode("utf-8", "surrogateescape")


def changed_files(base: str | None, head: str, default_branch: str) -> tuple[list[str] | None, str]:
    """Returns (files, note); files is None when no usable diff base exists (the caller goes full)."""
    if base and set(base) == {"0"}:
        base = None  # a push that created the branch reports an all-zero `before`
    against = base or default_branch
    try:
        head_sha = git("rev-parse", "--verify", f"{head}^{{commit}}").strip()
        base_sha = git("rev-parse", "--verify", f"{against}^{{commit}}").strip()
        merge_base = git("merge-base", base_sha, head_sha).strip()
    except GitError as error:
        try:
            shallow = git("rev-parse", "--is-shallow-repository").strip() == "true"
        except GitError:
            shallow = False
        hint = "; the clone is shallow: check out with fetch-depth: 0" if shallow else ""
        return None, f"no usable diff base ({error}{hint})"
    note = f"merge-base({against[:40]}, {head[:40]})"
    if merge_base == head_sha and base is None:
        return [], f"{note}: HEAD is already on {default_branch}"
    try:
        # -z: paths verbatim, NUL-terminated. Without it git C-quotes non-ASCII or unusual names
        # ("docs/caf\303\251.md"), which then match no glob and force a full run.
        out = git("diff", "--name-only", "--no-renames", "-z", merge_base, head_sha)
    except GitError as error:
        fail(str(error), 3)
    return [p for p in out.split("\0") if p], f"{note}..{head[:40]}"


def classify(files: list[str], cfg: dict) -> dict:
    compiled = {s: [(g, glob_to_regex(g)) for g in cfg[s]] for s in (*CLASS_SECTIONS, *FIXED_FLAGS)}
    custom = {name: [glob_to_regex(g) for g in globs] for name, (globs, _) in cfg["flags"].items()}
    rules = [(g, glob_to_regex(g), p) for g, p in cfg["paths"]]

    def first(section: str, path: str) -> str | None:
        return next((g for g, rx in compiled[section] if rx.match(path)), None)

    rows: list[tuple[str, str, str]] = []
    selected: set[str] = set()
    unmapped: list[str] = []
    full = config_changed = False
    fixed = dict.fromkeys(FIXED_FLAGS, False)
    raised = dict.fromkeys(custom, False)
    for path in files:
        for section in FIXED_FLAGS:
            fixed[section] = fixed[section] or first(section, path) is not None
        for name, regexes in custom.items():
            raised[name] = raised[name] or any(rx.match(path) for rx in regexes)
        if (g := first("docs", path)) is not None:
            rows.append((path, "docs", g))
        elif (g := first("config", path)) is not None:
            config_changed = True
            rows.append((path, "config", g))
        elif (g := first("shared", path)) is not None:
            full = True
            rows.append((path, SHARED, g))
        else:
            rule = next(((g, p) for g, rx, p in rules if rx.match(path)), None)
            if rule:
                selected.update(rule[1])
                rows.append((path, ", ".join(rule[1]), rule[0]))
            else:
                full = True
                unmapped.append(path)
                rows.append((path, UNMAPPED, "-"))
    return {"rows": rows, "projects": selected, "full": full, "config_changed": config_changed,
            "fixed": fixed, "custom": raised, "unmapped": unmapped}


def listing(paths: list[str]) -> str:
    return ", ".join(paths[:5]) + (", ..." if len(paths) > 5 else "")


def decide(files: list[str] | None, cfg: dict, force_full: bool, full_reason: str, diff_note: str) -> dict:
    all_projects = list(cfg["projects"])
    if files is None:
        # No usable base: build everything; base images are not rebuilt without evidence they changed.
        result = {"rows": [], "projects": set(all_projects), "full": True, "config_changed": True,
                  "fixed": dict.fromkeys(FIXED_FLAGS, False), "custom": dict.fromkeys(cfg["flags"], False),
                  "unmapped": []}
        reason = f"full: {diff_note}"
    else:
        result = classify(files, cfg)
        shared = [r[0] for r in result["rows"] if r[1] == SHARED]
        if force_full:
            reason = f"full: {full_reason or 'forced'}"
        elif result["full"]:
            parts = ([f"shared paths changed ({listing(shared)})"] if shared else []) + \
                    ([f"unmapped paths changed ({listing(result['unmapped'])})"] if result["unmapped"] else [])
            reason = "full: " + "; ".join(parts)
        elif result["projects"]:
            reason = "affected: " + ", ".join(p for p in all_projects if p in result["projects"])
        elif result["config_changed"]:
            reason = "config-only: config lint, no build"
        elif files:
            reason = "docs-only: nothing to build or test"
        else:
            reason = "no changed files: nothing to build or test"
    full = force_full or result["full"]
    selected = all_projects if full else [p for p in all_projects if p in result["projects"]]
    meta = cfg["projects"]
    decision = {
        "projects": selected,
        "image-projects": [p for p in selected if meta[p].get("image", False)],
        "matrix": [p for p in selected if meta[p].get("it", False)],
        "full": full,
        "docs-only": not full and not selected and not result["config_changed"],
        "config-changed": result["config_changed"],
    }
    for section, (output, on_full) in FIXED_FLAGS.items():
        decision[output] = (full and on_full) or result["fixed"][section]
    decision["flags"] = {name: (full and on_full) or result["custom"][name]
                         for name, (_, on_full) in cfg["flags"].items()}
    decision.update(reason=reason, unmapped=result["unmapped"], diff=diff_note, rows=result["rows"])
    return decision


def one_line(value) -> str:
    if isinstance(value, str):
        return re.sub(r"[\r\n]+", " ", value)
    return json.dumps(value, separators=(",", ":"))


def cell(text: str) -> str:
    return one_line(text).replace("|", "\\|")


def write_outputs(decision: dict, github_output: str | None, summary: str | None) -> None:
    if github_output:
        lines = [f"{key}={one_line(decision[key])}" for key in OUTPUT_KEYS]
        lines += [f"{name}={one_line(value)}" for name, value in decision["flags"].items()]
        with open(github_output, "a", encoding="utf-8", errors="replace") as handle:
            handle.write("\n".join(lines) + "\n")
    if summary:
        flags = list(decision["flags"])
        head = ["full", "docs-only", "config-changed", "base-changed", "deploy-test", *flags]
        values = [decision[k] for k in head[:5]] + [decision["flags"][f] for f in flags]
        lines = [
            "### Affected projects",
            "",
            f"**{cell(decision['reason'])}** (diff: {cell(decision['diff'])})",
            "",
            "| " + " | ".join(head) + " | IT matrix |",
            "|" + "---|" * (len(head) + 1),
            "| " + " | ".join(str(v).lower() for v in values) + " | "
            + (", ".join(f"`{p}`" for p in decision["matrix"]) or "-") + " |",
            "",
        ]
        rows = decision["rows"]
        if rows:
            lines += [f"<details><summary>Changed paths ({len(rows)})</summary>", "",
                      "| path | maps to | rule |", "|---|---|---|"]
            lines += [f"| `{cell(p)}` | {cell(m)} | `{cell(g)}` |" for p, m, g in rows[:200]]
            if len(rows) > 200:
                lines.append(f"| ... {len(rows) - 200} more | | |")
            lines += ["", "</details>", ""]
        with open(summary, "a", encoding="utf-8", errors="replace") as handle:
            handle.write("\n".join(lines) + "\n")


def parse_bool(text: str) -> bool:
    word = str(text).strip().lower()
    if word in ("true", "1", "yes", "on"):
        return True
    if word in ("false", "0", "no", "off", ""):
        return False
    fail(f"--full expects true or false, got {text!r}", 2)
    return False


def read_file_list(source: str) -> list[str]:
    try:
        if source == "-":
            data = sys.stdin.buffer.read()
        else:
            with open(source, "rb") as handle:
                data = handle.read()
    except OSError as error:
        fail(f"cannot read {source}: {error.strerror}", 2)
    text = data.decode("utf-8", "surrogateescape")
    return [p for p in (text.split("\0") if "\0" in text else text.splitlines()) if p.strip()]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--map", default=DEFAULT_MAP, help=f"path of the map (default {DEFAULT_MAP})")
    parser.add_argument("--base", default="",
                        help="diff base commit or ref; empty or all zeros: the merge-base with --default-branch")
    parser.add_argument("--head", default="HEAD", help="head commit or ref (default HEAD)")
    parser.add_argument("--default-branch", default=DEFAULT_BRANCH,
                        help=f"ref used when --base is empty (default {DEFAULT_BRANCH})")
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--files", nargs="*", metavar="PATH",
                        help="classify these repository-relative paths instead of running git diff")
    source.add_argument("--files-from", metavar="FILE",
                        help="read the paths from FILE ('-' = stdin), one per line or NUL-separated")
    parser.add_argument("--full", default="false", nargs="?", const="true", metavar="BOOL",
                        help="force every project: bare --full, or --full true|false")
    parser.add_argument("--reason", default="", help="why --full was forced (shown in reason and summary)")
    parser.add_argument("--github-output", metavar="FILE", help="append key=value outputs here ($GITHUB_OUTPUT)")
    parser.add_argument("--summary", metavar="FILE",
                        help="append a Markdown report here ($GITHUB_STEP_SUMMARY; /dev/stdout to preview)")
    args = parser.parse_args()

    force_full = parse_bool(args.full)
    cfg = validate_map(load_map(args.map))
    if args.files is not None:
        files, note = args.files, "explicit --files"
    elif args.files_from is not None:
        files, note = read_file_list(args.files_from), f"--files-from {args.files_from}"
    else:
        files, note = changed_files(args.base or None, args.head, args.default_branch)
    decision = decide(files, cfg, force_full, args.reason, note)
    try:
        write_outputs(decision, args.github_output, args.summary)
    except OSError as error:
        fail(f"cannot write outputs: {error}", 2)
    print(json.dumps({k: v for k, v in decision.items() if k != "rows"}, indent=2))


if __name__ == "__main__":
    main()
