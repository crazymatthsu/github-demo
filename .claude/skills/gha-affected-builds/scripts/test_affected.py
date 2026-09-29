#!/usr/bin/env python3
"""Self-test for affected.py: rules, output contract, map validation, git mode, YAML readers and the
run step of the affected-matrix composite action. Builds throwaway git repositories in a temp dir.

    python3 test_affected.py                    # needs python3 >= 3.8, git and bash
    AFFECTED_PY=scripts/ci/affected.py python3 test_affected.py   # test a copy elsewhere
    YQ=/path/to/yq python3 test_affected.py     # also read the YAML map through that yq binary

YAML tests are skipped when neither yq nor PyYAML is available; the example-map and action tests are
skipped when the skill's assets/ folder is not next to this script. Exit code: 0 pass, 1 failure.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = Path(os.environ.get("AFFECTED_PY", HERE / "affected.py")).resolve()
ASSETS = HERE.parent / "assets"
EXAMPLE_MAP = ASSETS / "affected-map.example.yml"
ACTION = ASSETS / "actions" / "affected-matrix" / "action.yml"
OUTPUT_KEYS = ["projects", "image-projects", "matrix", "full", "docs-only", "config-changed",
               "base-changed", "deploy-test", "flags", "reason"]
ALL = ["libs/common", "services/api", "services/worker", "services/web"]
MAP = {
    "schema": 1,
    "x-owners": {"services/api": "team-a"},
    "projects": {"libs/common": {"image": False, "it": False}, "services/api": {"image": True, "it": True},
                 "services/worker": {"image": True, "it": True}, "services/web": None},
    "docs": ["docs/**", "**/*.md"],
    "config": ["config/**"],
    "shared": [".github/**", "*.lock", "docker/**"],
    "paths": [{"glob": "libs/common/**", "projects": ["libs/common", "services/api", "services/worker"]},
              {"glob": "services/api/**", "projects": ["services/api"]},
              {"glob": "services/worker/**", "projects": ["services/worker"]},
              {"glob": "services/web/**", "projects": ["services/web"]}],
    "base-images": ["docker/base/**"],
    "deploy-test": ["**/helm/**", "config/**"],
    "flags": {"e2e": {"globs": ["services/web/**"]},
              "migrations": {"globs": ["services/*/migrations/**"], "on-full": False}},
}
TMP = Path(tempfile.mkdtemp(prefix="affected-test-"))


def run(*args: str, cwd=None, stdin: bytes | None = None, env=None) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(SCRIPT), *args], cwd=cwd, input=stdin, capture_output=True, env=env)


def write_map(name: str, cfg) -> str:
    path = TMP / name
    path.write_text(json.dumps(cfg), encoding="utf-8")
    return str(path)


def decide(*paths: str, extra=(), cfg_path=None) -> dict:
    proc = run("--map", cfg_path or write_map("map.json", MAP), *extra, "--files", *paths)
    assert proc.returncode == 0, proc.stderr.decode()
    return json.loads(proc.stdout)


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()


class Rules(unittest.TestCase):
    def test_docs_only_and_no_change(self):
        d = decide("docs/a.md", "README.md")
        self.assertEqual((d["docs-only"], d["full"], d["projects"]), (True, False, []))
        self.assertTrue(d["reason"].startswith("docs-only"))
        self.assertTrue(decide()["reason"].startswith("no changed files"))

    def test_one_project_and_library_dependents_in_map_order(self):
        d = decide("services/api/src/app.py")
        self.assertEqual((d["projects"], d["image-projects"], d["matrix"]), (["services/api"],) * 3)
        self.assertEqual((d["full"], d["docs-only"], d["deploy-test"]), (False, False, False))
        d = decide("services/worker/x.py", "libs/common/c.py")
        self.assertEqual(d["projects"], ["libs/common", "services/api", "services/worker"])
        self.assertEqual(d["matrix"], ["services/api", "services/worker"])

    def test_shared_and_unmapped_mean_everything(self):
        d = decide(".github/workflows/pr.yml")
        self.assertEqual((d["full"], d["projects"], d["deploy-test"], d["base-changed"]), (True, ALL, True, False))
        self.assertEqual(d["flags"], {"e2e": True, "migrations": False})  # on-full: false stays down
        self.assertIn("shared paths changed", d["reason"])
        d = decide("newdir/file.txt")
        self.assertEqual((d["full"], d["unmapped"]), (True, ["newdir/file.txt"]))
        self.assertIn("unmapped paths changed", d["reason"])

    def test_config_only(self):
        d = decide("config/dev/app.yml")
        self.assertEqual((d["config-changed"], d["docs-only"], d["full"], d["projects"], d["deploy-test"]),
                         (True, False, False, [], True))
        self.assertTrue(d["reason"].startswith("config-only"))

    def test_first_match_wins_and_flags_ignore_the_class(self):
        self.assertTrue(decide("services/api/README.md")["docs-only"])  # docs before paths
        d = decide("docker/base/Dockerfile")  # shared, and raises the base-images flag
        self.assertEqual((d["full"], d["base-changed"]), (True, True))
        d = decide("services/api/helm/README.md")  # docs, yet the deploy-test flag is raised
        self.assertEqual((d["docs-only"], d["deploy-test"]), (True, True))
        d = decide("services/worker/migrations/001.sql")
        self.assertEqual((d["projects"], d["flags"]), (["services/worker"], {"e2e": False, "migrations": True}))

    def test_glob_segments(self):
        self.assertIn("shared", decide("yarn.lock")["reason"])  # *.lock: root only
        self.assertIn("unmapped", decide("sub/yarn.lock")["reason"])
        self.assertTrue(decide("a/b/c/deep.md")["docs-only"])  # **/*.md: any depth, also zero dirs

    def test_force_full(self):
        d = decide("docs/a.md", extra=("--full", "--reason", "label ci:full"))
        self.assertEqual((d["full"], d["docs-only"], d["projects"], d["reason"]), (True, False, ALL, "full: label ci:full"))
        self.assertTrue(decide("docs/a.md", extra=("--full", "false"))["docs-only"])
        proc = run("--map", write_map("map.json", MAP), "--full", "maybe", "--files", "x")
        self.assertEqual(proc.returncode, 2)

    def test_github_output_and_summary(self):
        out, summary = TMP / "out.txt", TMP / "summary.md"
        for _ in range(2):  # both files are appended to, like GITHUB_OUTPUT / GITHUB_STEP_SUMMARY
            proc = run("--map", write_map("map.json", MAP), "--github-output", str(out), "--summary", str(summary),
                       "--files", "services/api/x.py", "docs/a|b.md")
            self.assertEqual(proc.returncode, 0, proc.stderr.decode())
        lines = out.read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(lines), 2 * (len(OUTPUT_KEYS) + 2))
        values = dict(line.split("=", 1) for line in lines)
        self.assertEqual(list(values), OUTPUT_KEYS + ["e2e", "migrations"])
        self.assertEqual((values["projects"], values["matrix"], values["full"], values["docs-only"]),
                         ('["services/api"]', '["services/api"]', "false", "false"))
        self.assertEqual((values["flags"], values["e2e"], values["reason"]),
                         ('{"e2e":false,"migrations":false}', "false", "affected: services/api"))
        text = summary.read_text(encoding="utf-8")
        self.assertEqual(text.count("### Affected projects"), 2)
        self.assertIn("| `services/api/x.py` | services/api | `services/api/**` |", text)
        self.assertIn("docs/a\\|b.md", text)  # a pipe in a path cannot break the table

    def test_files_from(self):
        for data in (b"services/api/x.py\0docs/a.md\0", b"services/api/x.py\r\ndocs/a.md\n\n"):
            proc = run("--map", write_map("map.json", MAP), "--files-from", "-", stdin=data)
            self.assertEqual(json.loads(proc.stdout)["projects"], ["services/api"], proc.stderr.decode())

    def test_newline_in_a_path(self):  # legal in git: must neither match "*.md" nor break GITHUB_OUTPUT
        out = TMP / "out-newline.txt"
        proc = run("--map", write_map("map.json", MAP), "--github-output", str(out), "--files-from", "-",
                   stdin=b"notes.md\n\0")
        self.assertEqual(json.loads(proc.stdout)["unmapped"], ["notes.md\n"], proc.stderr.decode())
        self.assertEqual(len(out.read_text(encoding="utf-8").splitlines()), len(OUTPUT_KEYS) + 2)


class MapValidation(unittest.TestCase):
    def expect_error(self, cfg, *messages: str):
        proc = run("--map", write_map("bad.json", cfg), "--files", "x")
        self.assertEqual(proc.returncode, 2, proc.stdout.decode())
        for message in messages:
            self.assertIn(message, proc.stderr.decode())

    def test_errors(self):
        self.expect_error({**MAP, "schema": 2}, "schema: 1")
        self.expect_error({**MAP, "projects": {}}, "non-empty `projects`")
        bad_rules = [{"glob": "a/**"}, {"glob": "b/**", "projects": ["nope"]}, {"glob": "./c/**", "projects": ["libs/common"]}]
        # every problem at once
        self.expect_error({**MAP, "share": ["x"], "paths": bad_rules, "docs": "docs/**"},
                          "unknown top-level keys ['share']", "non-empty `projects` list", "missing from `projects`: ['nope']",
                          "no leading / or ./", "`docs` must be a list")
        self.expect_error({**MAP, "projects": {"a": {"image": "yes"}}, "paths": []}, "`image` must be true or false")
        self.expect_error({**MAP, "flags": {"full": {"globs": ["x"]}}}, "name must match")
        self.expect_error({**MAP, "flags": {"e2e": {"globs": []}}}, "needs at least one glob")
        proc = run("--map", str(TMP / "missing.yml"), "--files", "x")
        self.assertEqual(proc.returncode, 2)
        self.assertIn("cannot read the map", proc.stderr.decode())


class GitMode(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo = repo = TMP / "repo"
        repo.mkdir()
        (TMP / "no-hooks").mkdir()
        git(repo, "init", "-q")
        git(repo, "symbolic-ref", "HEAD", "refs/heads/main")  # `init -b` needs git 2.28
        for key, value in (("user.email", "test@example.com"), ("user.name", "test"),
                           ("commit.gpgsign", "false"), ("core.hooksPath", str(TMP / "no-hooks"))):
            git(repo, "config", key, value)

        def commit(files: dict, message: str, remove=()):
            for name in remove:
                git(repo, "rm", "-q", name)
            for name, text in files.items():
                (repo / name).parent.mkdir(parents=True, exist_ok=True)
                (repo / name).write_text(text, encoding="utf-8")
            git(repo, "add", "-A")
            git(repo, "commit", "-q", "-m", message)

        commit({".github/affected-map.json": json.dumps(MAP), "docs/a.md": "a", "services/api/app.py": "1",
                "services/api/moved.py": "m", "services/worker/w.py": "1", "services/web/index.js": "1",
                "libs/common/c.py": "1"}, "init")
        git(repo, "branch", "feat")
        git(repo, "branch", "docs")
        git(repo, "branch", "move")
        commit({"services/worker/w.py": "2"}, "main moves on")  # must NOT show up in the branches' diffs
        git(repo, "update-ref", "refs/remotes/origin/main", "main")
        git(repo, "checkout", "-q", "feat")
        commit({"services/api/app.py": "2"}, "api change")
        git(repo, "checkout", "-q", "docs")
        commit({"docs/café.md": "x", "docs/with space.md": "y", "services/web/naïve.js": "z"}, "unusual names")
        git(repo, "checkout", "-q", "move")
        git(repo, "mv", "services/api/moved.py", "services/web/moved.py")
        commit({}, "move across projects and delete", remove=["services/worker/w.py"])
        git(repo, "checkout", "-q", "feat")

    def affected(self, *args: str, cwd=None) -> dict:
        proc = run("--map", ".github/affected-map.json", *args, cwd=cwd or self.repo)
        self.assertEqual(proc.returncode, 0, proc.stderr.decode())
        return json.loads(proc.stdout)

    def test_merge_base_diff(self):
        for args in ((), ("--base", git(self.repo, "rev-parse", "main")), ("--base", "0" * 40)):
            d = self.affected(*args, "--head", "feat")
            self.assertEqual((d["projects"], d["full"]), (["services/api"], False), args)

    def test_unusual_names_are_classified(self):  # git would C-quote them without -z
        d = self.affected("--head", "docs", "--default-branch", "main")
        self.assertEqual((d["projects"], d["full"], d["unmapped"]), (["services/web"], False, []), d["reason"])

    def test_renames_and_deletions_count(self):
        d = self.affected("--head", "move")  # both sides of a rename, and the deleted file
        self.assertEqual(d["projects"], ["services/api", "services/worker", "services/web"])

    def test_head_already_on_default_branch(self):
        d = self.affected("--head", "main")
        self.assertEqual((d["docs-only"], d["projects"]), (True, []))
        self.assertIn("HEAD is already on origin/main", d["diff"])

    def test_no_usable_base_goes_full(self):
        d = self.affected("--base", "no-such-ref")
        self.assertEqual((d["full"], d["projects"], d["deploy-test"]), (True, ALL, True))
        self.assertIn("no usable diff base", d["reason"])
        shallow = TMP / "shallow"
        subprocess.run(["git", "clone", "-q", "--depth", "1", "-b", "feat", self.repo.as_uri(), str(shallow)],
                       check=True, capture_output=True)
        d = self.affected(cwd=shallow)
        self.assertEqual(d["full"], True)
        self.assertIn("fetch-depth: 0", d["reason"])

    @unittest.skipUnless(ACTION.is_file() and shutil.which("bash"), "action template or bash not available")
    def test_composite_action_run_step(self):
        lines = ACTION.read_text(encoding="utf-8").splitlines()
        start = lines.index("      run: |") + 1
        body = "\n".join(line[8:] for line in lines[start:] if line.startswith("        ") or not line.strip())
        git(self.repo, "update-ref", "refs/remotes/origin/trunk", "feat")  # "trunk" already holds the change
        cases = [("", "", ["services/api"]),        # no default branch in the event: origin/main
                 ("trunk", "", []),                 # the event's default branch: origin/trunk
                 ("trunk", "main", ["services/api"])]  # an explicit input wins
        for repo_default, default_branch, projects in cases:
            out, summary = TMP / "action-out.txt", TMP / "action-summary.md"
            out.write_text("")
            env = {**os.environ, "GITHUB_WORKSPACE": str(self.repo), "GITHUB_OUTPUT": str(out),
                   "GITHUB_STEP_SUMMARY": str(summary), "BASE_REF": "", "HEAD_REF": "feat",
                   "DEFAULT_BRANCH": default_branch, "REPO_DEFAULT_BRANCH": repo_default, "FORCE_FULL": "false",
                   "FORCE_FULL_REASON": "", "MAP": ".github/affected-map.json", "SCRIPT": str(SCRIPT)}
            proc = subprocess.run(["bash", "-c", body], cwd=self.repo, env=env, capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            values = dict(line.split("=", 1) for line in out.read_text().splitlines())
            self.assertEqual(json.loads(values["projects"]), projects, (repo_default, default_branch))
            self.assertIn("### Affected projects", summary.read_text(encoding="utf-8"))
        env["SCRIPT"] = "scripts/ci/missing.py"
        proc = subprocess.run(["bash", "-c", body], cwd=self.repo, env=env, capture_output=True, text=True)
        self.assertEqual(proc.returncode, 2)
        self.assertIn("::error::affected-matrix: classifier not found", proc.stdout)


def has_pyyaml() -> bool:
    return subprocess.run([sys.executable, "-c", "import yaml"], capture_output=True).returncode == 0


def is_mikefarah(yq: str) -> bool:
    return "mikefarah" in subprocess.run([yq, "--version"], capture_output=True, text=True).stdout


YQS = sorted({p for p in (os.environ.get("YQ"), shutil.which("yq")) if p})


@unittest.skipUnless(EXAMPLE_MAP.is_file() and (YQS or has_pyyaml()), "no example map, or no yq and no PyYAML")
class YamlMaps(unittest.TestCase):
    CASES = {  # the decisions the example map's comments promise
        ("docs/intro.md", "README.md", ".github/CODEOWNERS", ".claude/skills/x/SKILL.md"): {"docs-only": True},
        ("services/api/src/app.py",): {"projects": ["services/api"], "deploy-test": True, "flags": {"e2e": True, "db-migrations": False}},
        ("libs/common/x.go",): {"projects": ["libs/common", "services/api", "services/worker"], "full": False},
        ("pnpm-lock.yaml",): {"full": True, "flags": {"e2e": True, "db-migrations": False}},
        ("config/dev/api.yml",): {"projects": [], "config-changed": True, "docs-only": False, "deploy-test": True},
        ("services/worker/migrations/001.sql",): {"projects": ["services/worker"], "flags": {"e2e": False, "db-migrations": True}},
        ("docker/base/jre/Dockerfile",): {"full": True, "base-changed": True},
        ("newdir/x",): {"full": True, "unmapped": ["newdir/x"]},
    }

    def isolated(self, yq: str | None, pyyaml: bool) -> dict:
        """Environment where only the chosen YAML readers are visible."""
        bin_dir, blocker = TMP / f"bin-{abs(hash(yq))}", TMP / "no-pyyaml"
        bin_dir.mkdir(exist_ok=True)
        blocker.mkdir(exist_ok=True)
        (blocker / "yaml.py").write_text("raise ImportError('PyYAML hidden by the test')\n")
        if yq and not (bin_dir / "yq").exists():
            (bin_dir / "yq").symlink_to(yq)
        env = {**os.environ, "PATH": str(bin_dir)}
        if not pyyaml:
            env["PYTHONPATH"] = str(blocker)
        return env

    def test_example_map_decisions(self):
        for paths, expected in self.CASES.items():
            d = decide(*paths, cfg_path=str(EXAMPLE_MAP))
            self.assertEqual({k: d[k] for k in expected}, expected, paths)

    def test_each_yaml_reader(self):
        # PyYAML is hidden to prove a mikefarah yq is really used; the Python yq wrapper needs PyYAML itself.
        readers = [(yq, not is_mikefarah(yq)) for yq in YQS] + ([(None, True)] if has_pyyaml() else [])
        for yq, pyyaml in readers:
            proc = run("--map", str(EXAMPLE_MAP), "--files", "services/web/x", env=self.isolated(yq, pyyaml))
            self.assertEqual(proc.returncode, 0, (yq, proc.stderr.decode()))
            self.assertEqual(json.loads(proc.stdout)["projects"], ["services/web"], yq)
        proc = run("--map", str(EXAMPLE_MAP), "--files", "x", env=self.isolated(None, False))
        self.assertEqual(proc.returncode, 2)
        self.assertIn("install mikefarah yq v4 or PyYAML", proc.stderr.decode())


if __name__ == "__main__":
    if {"-h", "--help"} & set(sys.argv[1:]):
        print(__doc__)  # then unittest adds its own options (-k PATTERN, -f, ...)
    try:
        result = unittest.main(exit=False, verbosity=2).result
    finally:
        shutil.rmtree(TMP, ignore_errors=True)
    sys.exit(0 if result.wasSuccessful() else 1)
