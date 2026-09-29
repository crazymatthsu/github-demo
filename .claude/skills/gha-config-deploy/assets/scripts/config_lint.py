#!/usr/bin/env python3
"""config_lint.py — lint the config tree <config_dir>/<env>/<flow>/<app>/<instance>/ (skill gha-config-deploy).

Runs the catalogue of the skill's references/config-lint-checks.md for the deployment shape that
.github/config-lint.yml declares, the same way in CI (.github/workflows/_config-lint.yml, a job that feeds the
gate) and on a laptop. Copy it to scripts/ci/config_lint.py and assets/config-lint.example.yml to
.github/config-lint.yml. Python 3.8+, standard library only; YAML through PyYAML, else mikefarah yq v4.

Usage: config_lint.py [--root <dir>] [--config <file>] [--report <file>] [--no-render]
  --root <dir>      repository root (default: the git top level, else .); all other paths are relative to it
  --config <file>   default .github/config-lint.yml; without that file the defaults apply and a WARN says that
                    the env and flow allow-lists are off
  --report <file>   default build/reports/config-lint/config-lint.txt ('' = none); check 12 renders every
                    instance to rendered/<env>/<flow>/<app>/<instance>.yaml next to it
  --no-render       skip the renderings: checks 6 (docker compose) and 12 (helm)

Config keys [default], each documented in assets/config-lint.example.yml: config_dir [config] · envs, flows,
  apps [] (allow-lists, [] = any name) · dev_env_pattern [^([a-z][a-z0-9]*-)?dev$] · pinned_env_pattern
  [^([a-z][a-z0-9]*-)?(qa|staging|prod)$] · runtimes [[helm, compose]], or {helm|compose: <env regex>} ·
  app_config [true] · chart_dir [deploy/helm/{app}] · compose_file [''] · wrapper_vars [CONFIG_DIR, COMMON_DIR
  and PROJECT, as the reference's wrapper sets them] · complete_envs [] · compose_env_allow, values_env_allow,
  secret_keys_allow [] ·
  tag_var [IMAGE_TAG] · inventory [workflows-config.yml] · helm_deploy_script [scripts/ci/helm-deploy-instance.sh]
  · kubernetes_version [''] · kubeconform_args [] · checks: {skip: []}

Checks (catalogue numbers; one INFO line for a check that is skipped or unused by the shape):
   1  naming: kebab tokens, env and flow allow-lists, lengths, no bare-number instance, no file atop the tree
   2  deployables: in apps, a chart (helm) and a compose file (compose) per app; complete_envs hold every app
   3  files: application.yml (app_config), values.yaml (helm), compose.env (compose); no stray, .env or misnamed
      file; flat layers; YAML that parses (reported even when 3 is skipped); an inventory per dev flow
   4  identity: compose.env APP_*, values.yaml identity and env.APP_* equal the path; image.tag equals the tag
      variable; no tag or identity in app-common; app-facing env: only; WARN when the renderings disagree
   5  compose.env: KEY=VALUE lines, no duplicate, allow-listed keys, IMAGE_REPO and the tag variable, host ports
   6  docker compose config --quiet per instance, with wrapper_vars set and placeholders for the secrets
   9  secrets: key material, tokens, literal passwords, URL credentials in any file; secret-named YAML keys
  10  tags: valid strings; pinned envs pin X.Y.Z plus image.digest (compose.env X.Y.Z[@sha256:...])
  11  inventory: schema, one target per instance, kinds, hosts, pools, clusters; known_hosts lines
  12  helm_deploy_script --mode lint and --mode template per instance, then kubeconform -strict -summary
  7, 8, 13 print one TODO line each: merged config against a schema, parity across envs, GitOps generator.

Output: "<SEVERITY> check <n>  <path>: <message>" lines (ERROR, WARN, TODO, INFO) sorted by path, then a count
line; the report holds the same lines. Exit codes: 0 no ERROR · 1 an ERROR · 2 usage (an option, the config
file, no tree, no YAML reader). Environment: CI=true makes a missing docker compose, helm (the adapter exits 5)
or kubeconform an ERROR instead of a WARN · YQ [yq] · DOCKER_BIN [docker] · KUBECONFORM_BIN [kubeconform]. The
adapter runs from the root with HELM_CHART_DIR=<chart_dir> and HELM_CONFIG_DIR=<config_dir>.
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import NamedTuple

DEFAULT_CONFIG = ".github/config-lint.yml"
DEFAULT_REPORT = "build/reports/config-lint/config-lint.txt"
PATH_KEYS = ("config_dir", "chart_dir", "compose_file", "helm_deploy_script")
DEFAULTS = {
    "config_dir": "config", "envs": [], "flows": [], "apps": [],
    "dev_env_pattern": r"^([a-z][a-z0-9]*-)?dev$", "pinned_env_pattern": r"^([a-z][a-z0-9]*-)?(qa|staging|prod)$",
    "runtimes": ["helm", "compose"], "app_config": True, "chart_dir": "deploy/helm/{app}", "compose_file": "",
    "wrapper_vars": {"CONFIG_DIR": "{config}/{env}/{flow}/{app}/{instance}", "PROJECT": "{env}-{flow}-{app}-{instance}",
                     "COMMON_DIR": "{config}/{env}/{flow}/{app}/app-common"},
    "complete_envs": [], "compose_env_allow": [],
    "values_env_allow": [], "secret_keys_allow": [], "tag_var": "IMAGE_TAG", "inventory": "workflows-config.yml",
    "helm_deploy_script": "scripts/ci/helm-deploy-instance.sh", "kubernetes_version": "", "kubeconform_args": [],
    "checks": {"skip": []},
}
SHAPES = {"runtimes": "[helm, compose], or {helm: <env regex>, compose: <env regex>}",
          "checks": "{skip: [check numbers 1 to 13]}", bool: "true or false", list: "a list of strings",
          dict: "a map of variables to values", str: "a string (quote numbers)"}
TODO = {7: "merged configuration (layers 2 to 5) not validated against the app's schema",
        8: "parity of keys across envs not checked",
        13: "GitOps generator dry run not checked (list 13 in checks.skip while no controller is adopted)"}
TOKEN = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")
RELEASE = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
IMAGE_TAG = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$")
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
ENV_VAR = re.compile(r"^[A-Z][A-Z0-9_]*$")
HOST = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$")
LOGIN = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
PLAIN_ABS_PATH = re.compile(r"^(/[A-Za-z0-9_][A-Za-z0-9._-]*)+/?$")
KEYSCAN = re.compile(r"^(@[a-z-]+\s+)?\S+\s+(ssh-[a-z0-9-]+|ecdsa-sha2-[a-z0-9-]+|sk-[a-z0-9@.-]+)\s+[A-Za-z0-9+/]+=*"
                     r"(\s.*)?$")
COMPOSE_VAR = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)")
SECRET_VALUES = [  # the first match of a line is reported; the matched text is never printed
    (re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"), "a PEM private key"),
    (re.compile(r"\b(AKIA|ASIA)[0-9A-Z]{16}\b"), "an AWS access key id"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{36,}|\bgithub_pat_[A-Za-z0-9_]{22,}"), "a GitHub token"),
    (re.compile(r"\bxox[abposr]-[A-Za-z0-9-]{10,}"), "a Slack token"),
    (re.compile(r"(?i);password=[^;\s]+"), "a password in a JDBC URL"),
    (re.compile(r"\b[a-z][a-z0-9+.-]*://[^/\s:@]*:(?!\$\{)[^/\s@]+@"), "credentials in a URL"),
    (re.compile(r"(?:(?i:password|passwd)|(?<![A-Za-z])(?i:pass))[\"']?\s*[:=]\s*[\"']?(?!\$\{|(?i:null)\b|~)"
                r"[^\s\"'#,;]{3,}"), "a literal password"),
]
SECRET_WORDS = {"password", "passwd", "passphrase", "secret", "token", "credential", "credentials", "apikey"}
SECRET_KEY_WORDS = {"api", "access", "private", "secret", "signing", "encryption"}  # <word> key
IDENTITY_VARS = {"env": "APP_ENV", "flow": "APP_FLOW", "app": "APP_NAME", "instance": "APP_INSTANCE"}
APP_FACING = {"JAVA_OPTS", "NODE_OPTIONS", "GOMEMLIMIT", "TZ", "LOG_LEVEL_ROOT", *IDENTITY_VARS.values()}
COMPOSE_KNOBS = {"IMAGE_REPO", "LOGS_DIR", "DATA_DIR", "MEM_LIMIT"}  # and the tag variable and *_HOST_PORT
FRAMEWORK_PREFIXES = ("SPRING_", "LOGGING_", "MANAGEMENT_")
INVENTORY_KEYS = {"env", "flow", "pool", "defaults", "targets"}
TARGET_KEYS = {"instance", "kind", "host", "user", "cluster", "namespace"}
MISNAMED = {"application.yaml": "application.yml", "values.yml": "values.yaml"}
KEEP_ENV = ("PATH", "HOME", "USER", "TMPDIR", "LANG", "SYSTEMROOT", "DOCKER_", "XDG_", "LC_")  # for compose


class UsageError(Exception):
    """An option, the config file or the set-up is wrong: exit 2."""


class Instance(NamedTuple):
    env: str
    flow: str
    app: str
    name: str
    path: Path


def listdir(path):
    """The entries of a directory that the layout governs (dot files and README.md are left alone)."""
    return sorted(p for p in path.iterdir() if not p.name.startswith(".") and p.name != "README.md")


def looks_secret(name):
    """True for names that hold a credential (DB_PASSWORD, clientSecret, api-key); existingSecret is a name."""
    words = [w.lower() for w in re.findall(r"[A-Z]+(?![a-z])|[A-Z]?[a-z]+|[0-9]+", name)]
    if not words or words[-2:] == ["existing", "secret"]:
        return False
    return words[-1] in SECRET_WORDS or (words[-1] == "key" and len(words) > 1 and words[-2] in SECRET_KEY_WORDS)


def allowed(name, patterns):
    """True when name equals or fnmatches (ORDERS_*) an entry of an allow-list."""
    return any(fnmatch.fnmatchcase(name, pattern) for pattern in patterns)


def run(args, **kwargs):
    """subprocess.run with text output captured and no stdin; None when the program cannot start."""
    try:
        return subprocess.run(args, capture_output=True, text=True, stdin=subprocess.DEVNULL, **kwargs)
    except OSError:
        return None


def last_error(result):
    """The telling line of a failed command: helm's [ERROR] and Error: lines first."""
    if result is None:
        return "the program did not start"
    lines = [line.strip() for line in (result.stdout + "\n" + result.stderr).splitlines() if line.strip()]
    ranked = [line for line in lines if "[ERROR]" in line] + [line for line in lines if "Error:" in line]
    ranked += [line for line in lines if "error" in line.lower()] + lines[-1:]
    return ranked[0][:300] if ranked else f"exit {result.returncode}"


class YamlReader:
    """Parses YAML with PyYAML when importable, else with mikefarah yq v4 (-o=json); each file once."""

    def __init__(self):
        self.cache, self.yq = {}, os.environ.get("YQ", "yq")
        try:
            import yaml
            self.yaml, self.name = yaml, "PyYAML"
        except ImportError:
            self.yaml, self.name = None, "yq"
            version = run([self.yq, "--version"])
            if version is None or "mikefarah" not in version.stdout:
                raise UsageError(f"reading YAML needs PyYAML or mikefarah yq v4 (YQ, now '{self.yq}')") from None

    def load(self, path):
        """(data, None), or (None, why the file does not parse)."""
        if path not in self.cache:
            self.cache[path] = self.parse_pyyaml(path) if self.yaml else self.parse_yq(path)
        return self.cache[path]

    def parse_pyyaml(self, path):
        try:
            return self.yaml.safe_load(path.read_text(encoding="utf-8")), None
        except UnicodeDecodeError:
            return None, "not UTF-8 text"
        except self.yaml.YAMLError as error:
            mark = getattr(error, "problem_mark", None)
            problem = getattr(error, "problem", None) or str(error).splitlines()[0]
            return None, f"{problem} (line {mark.line + 1})" if mark else problem

    def parse_yq(self, path):
        result = run([self.yq, "-o=json", ".", str(path)])
        if result is None or result.returncode != 0:
            return None, re.sub(r"^Error: (bad file '[^']*': )?", "", last_error(result))
        try:
            return json.loads(result.stdout or "null"), None
        except json.JSONDecodeError:
            return None, "more than one YAML document"


def validate(path, key, value):
    """The config value when it has the shape of its default, else a UsageError."""
    default = DEFAULTS[key]
    if key == "runtimes":
        names = list(value) if isinstance(value, (list, dict)) else []
        patterns = list(value.values()) if isinstance(value, dict) else []
        ok = names and all(name in ("helm", "compose") for name in names) and all(isinstance(p, str) for p in patterns)
    elif key == "checks":
        skip = (value.get("skip") or []) if isinstance(value, dict) and set(value) <= {"skip"} else None
        ok = isinstance(skip, list) and all(type(n) is int and 1 <= n <= 13 for n in skip)
        value, patterns = {"skip": skip}, []
    else:
        members = [*value, *value.values()] if isinstance(value, dict) else value if isinstance(value, list) else []
        ok = type(value) is type(default) and all(isinstance(member, str) for member in members)
        patterns = [value] if ok and key.endswith("_pattern") else []
    if not ok:
        raise UsageError(f"{path}: {key} must be {SHAPES.get(key) or SHAPES[type(default)]}")
    if key in PATH_KEYS and value.startswith("/"):
        raise UsageError(f"{path}: {key} must be a path relative to the repository root")
    for template in value.values() if key == "wrapper_vars" else []:
        try:
            template.format(config="", env="", flow="", app="", instance="")
        except (KeyError, IndexError, ValueError) as error:
            raise UsageError(f"{path}: wrapper_vars: {template!r} uses {error}; the fields are {{config}}, {{env}}, "
                             "{flow}, {app} and {instance}") from None
    for pattern in patterns:
        try:
            re.compile(pattern)
        except re.error as error:
            raise UsageError(f"{path}: {key}: {pattern!r} is not a regex ({error})") from None
    return value


def load_config(path, explicit, reader):
    """(config, found): DEFAULTS overlaid with the config file; a missing default file is not an error."""
    cfg = json.loads(json.dumps(DEFAULTS))
    if not path.is_file():
        if explicit:
            raise UsageError(f"config file {path} not found")
        return cfg, False
    data, error = reader.load(path)
    if error or not isinstance(data, (dict, type(None))):
        raise UsageError(f"{path}: {error or 'must be a mapping'}")
    for key, value in (data or {}).items():
        if key not in DEFAULTS:
            raise UsageError(f"{path}: unknown key '{key}' (see --help)")
        if value is not None:
            cfg[key] = validate(path, key, value)
    cfg["chart_dir"] = cfg["chart_dir"].rstrip("/")
    return cfg, True


class Lint:
    """Walks the tree once, runs every check that applies and reports every finding in one run."""

    def __init__(self, root, cfg, config_file, found, reader, render, report):
        self.root, self.cfg, self.reader, self.render, self.report = root, cfg, reader, render, report
        self.config_file, self.found, self.tree = config_file, found, root / cfg["config_dir"]
        self.ci = os.environ.get("CI", "").lower() == "true"
        runtimes = cfg["runtimes"] if isinstance(cfg["runtimes"], dict) else dict.fromkeys(cfg["runtimes"], ".*")
        self.runtimes = {name: re.compile(pattern) for name, pattern in runtimes.items()}
        self.dev, self.pinned = re.compile(cfg["dev_env_pattern"]), re.compile(cfg["pinned_env_pattern"])
        self.skip, self.findings, self.env_files, self.tmp = set(cfg["checks"]["skip"]), set(), {}, None

    # --- helpers --------------------------------------------------------------------------------------------
    def add(self, severity, check, path, message, always=False):
        """Records a finding; a skipped check reports nothing unless always (YAML that does not parse)."""
        if check not in self.skip or always:
            self.findings.add((self.rel(path), check, severity, message))

    def error(self, check, path, message):
        self.add("ERROR", check, path, message)

    def rel(self, path):
        return Path(os.path.relpath(path, self.root)).as_posix()

    def applies(self, runtime, env):
        """True when <runtime> (helm or compose) runs the instances of <env>."""
        return runtime in self.runtimes and bool(self.runtimes[runtime].search(env))

    def mapping(self, path):
        """The YAML mapping of a file ({} when empty); None when it is missing or not a mapping."""
        data, error = self.reader.load(path) if path.is_file() else (None, "missing")
        return (data or {}) if not error and isinstance(data, (dict, type(None))) else None

    def artifact(self, key, app):
        """<app>'s chart_dir or compose_file."""
        return self.root / self.cfg[key].replace("{app}", app)

    def env_file(self, path):
        """(pairs, malformed-line messages) of a compose.env, parsed once; the first definition of a key wins."""
        if path not in self.env_files:
            pairs, problems = {}, []
            for number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
                key, sep, value = line.strip().partition("=")
                if not key or key.startswith("#"):
                    continue
                if not sep or not ENV_VAR.match(key):
                    problems.append(f"line {number}: not KEY=VALUE with an UPPER_SNAKE_CASE key")
                elif key in pairs:
                    problems.append(f"line {number}: {key} is defined twice")
                else:  # like compose: strip matching quotes, or a " #" comment after an unquoted value
                    quoted = len(value) > 1 and value[0] in "\"'" and value.endswith(value[0])
                    pairs[key] = value[1:-1] if quoted else value.split(" #", 1)[0].strip()
            self.env_files[path] = (pairs, problems)
        return self.env_files[path]

    def compose_pairs(self, inst):
        """The pairs of an instance's compose.env; None when compose does not run its env or it is missing."""
        path = inst.path / "compose.env"
        return self.env_file(path)[0] if self.applies("compose", inst.env) and path.is_file() else None

    def tool_missing(self, check, message):
        """A missing tool is an ERROR in CI (CI=true) and a WARN on a laptop."""
        self.add("ERROR" if self.ci else "WARN", check, self.tree, message + ("" if self.ci else " (CI=true: ERROR)"))

    def var_problem(self, name, compose):
        """Why variable <name> may not be set in compose.env (compose) or in a values.yaml env: map; None = ok."""
        allow_key = "compose_env_allow" if compose else "values_env_allow"
        if allowed(name, self.cfg[allow_key]):
            return None
        if not ENV_VAR.match(name):
            return "variable names are UPPER_SNAKE_CASE"
        if name in self.cfg["wrapper_vars"]:
            return "the compose wrapper sets it; never in a file"
        if looks_secret(name):
            return "looks like a secret: " + ("the host environment passes it" if compose else "mount the Secret")
        if name in COMPOSE_KNOBS or name == self.cfg["tag_var"] or name.endswith("_HOST_PORT"):
            return None if compose else "a compose knob: Helm uses image.*, resources and volumes"
        if name in APP_FACING or not self.cfg["app_config"]:
            return None  # an app that reads no config file is configured through its environment
        if name.startswith(FRAMEWORK_PREFIXES):
            return "application config belongs in the YAML layers (credentials in a Secret)"
        return f"not allow-listed ({allow_key})"

    # --- the walk -------------------------------------------------------------------------------------------
    def scan(self):
        """Records envs, flows, apps, instances and layers, and the files the layout has no place for."""
        self.envs, self.flows, self.apps, self.instances, self.platform = [], [], [], [], []
        self.layers, self.shared, self.stray = [], [], []  # stray: (check, path, message)
        for entry in listdir(self.tree):
            if entry.is_file():
                self.stray.append((1, entry, "unexpected file at the top of the tree"))
            elif entry.name != "_common":
                self.scan_env(entry)
            else:
                for app_dir in listdir(entry):
                    if app_dir.is_dir():
                        self.platform.append(app_dir)
                    else:
                        self.stray.append((3, app_dir, "unexpected file: the platform layer is _common/<app>/"))
        self.shared += self.platform
        self.layers += self.shared

    def scan_env(self, env_dir):
        self.envs.append(env_dir)
        for entry in listdir(env_dir):
            if entry.name == "_common" and entry.is_dir():
                self.shared.append(entry)
            elif entry.is_dir():
                self.scan_flow(env_dir.name, entry)
            elif entry.name not in ("known_hosts", self.cfg["inventory"]):  # both are check 11's
                self.stray.append((3, entry, "unexpected file: an env holds _common/, known_hosts and flows"))

    def scan_flow(self, env, flow_dir):
        self.flows.append((env, flow_dir))
        for app_dir in listdir(flow_dir):
            if app_dir.is_file():
                if app_dir.name != self.cfg["inventory"]:
                    self.stray.append((3, app_dir, "unexpected file: a flow holds its inventory and apps"))
                continue
            self.apps.append((env, flow_dir.name, app_dir))
            for layer in listdir(app_dir):
                if layer.is_file():
                    self.stray.append((3, layer, "unexpected file: an app holds app-common/ and instances"))
                    continue
                self.layers.append(layer)
                if layer.name != "app-common":
                    self.instances.append(Instance(env, flow_dir.name, app_dir.name, layer.name, layer))

    def parse_all(self):
        """Every YAML file of the tree parses to a mapping (check 3, reported even when 3 is skipped)."""
        for path in sorted(self.tree.rglob("*")):
            if path.is_file() and path.suffix in (".yml", ".yaml"):
                data, error = self.reader.load(path)
                if error or not isinstance(data, (dict, type(None))):
                    self.add("ERROR", 3, path, f"does not parse: {error}" if error else "must be a mapping", True)

    # --- checks ---------------------------------------------------------------------------------------------
    def check_naming(self):
        """Check 1: tokens, allow-lists, length limits, no file at the top of the tree."""
        for env_dir in self.envs:
            self.name_rule(env_dir, "env", "envs")
        for _, flow_dir in self.flows:
            self.name_rule(flow_dir, "flow", "flows")
        for app_dir in [app_dir for _, _, app_dir in self.apps] + self.platform:
            if self.name_rule(app_dir, "app") and len(app_dir.name) > 20:
                self.error(1, app_dir, f"app '{app_dir.name}' is longer than 20 characters")
        for inst in self.instances:
            if not self.name_rule(inst.path, "instance"):
                continue
            if inst.name.isdigit():
                self.error(1, inst.path, f"instance '{inst.name}' is a bare number: name it after what it serves")
            elif len(inst.name) > 32:
                self.error(1, inst.path, f"instance '{inst.name}' is longer than 32 characters")
            if len(f"{inst.app}-{inst.name}") > 53:
                self.error(1, inst.path, f"release {inst.app}-{inst.name} is longer than Helm's 53 characters")
        for check, path, message in self.stray:
            if check == 1:
                self.error(1, path, message)

    def name_rule(self, path, kind, allow_key=None):
        """True when the directory name is a token (and allow-listed); an ERROR otherwise."""
        allow = self.cfg[allow_key] if allow_key else []
        if not TOKEN.match(path.name):
            problem = "is not a lower-case kebab token"
        elif allow and path.name not in allow:
            problem = f"is not allow-listed ({allow_key}: {', '.join(allow)})"
        else:
            return True
        self.error(1, path, f"{kind} '{path.name}' {problem}")
        return False

    def check_deployables(self):
        """Check 2: every app directory is a deployable; complete_envs hold every deployable app."""
        for env, _, app_dir in self.apps:
            app = app_dir.name
            if self.cfg["apps"] and app not in self.cfg["apps"]:
                self.error(2, app_dir, f"'{app}' is not a deployable app (apps: {', '.join(self.cfg['apps'])})")
                continue
            chart, compose_file = self.artifact("chart_dir", app), self.artifact("compose_file", app)
            if self.applies("helm", env) and not (chart / "Chart.yaml").is_file():
                self.error(2, app_dir, f"no chart for app '{app}': {self.rel(chart)}/Chart.yaml")
            if self.cfg["compose_file"] and self.applies("compose", env) and not compose_file.is_file():
                self.error(2, app_dir, f"no compose file for app '{app}': {self.rel(compose_file)}")
        configured = {app_dir.name for _, _, app_dir in self.apps}
        for app_dir in self.platform:
            if app_dir.name not in configured:
                self.error(2, app_dir, f"a platform layer for '{app_dir.name}', which no env configures")
        deployables = self.deployable_apps() if self.cfg["complete_envs"] else set()
        if deployables is None:
            self.add("WARN", 2, self.tree, "complete_envs needs apps, or {app} in chart_dir or compose_file")
        for env in self.cfg["complete_envs"] if deployables else []:
            for app in sorted(deployables - {app_dir.name for e, _, app_dir in self.apps if e == env}):
                self.error(2, self.tree / env, f"app '{app}' has no directory in {env} (complete_envs)")

    def deployable_apps(self):
        """apps, else the {app} of every chart_dir and compose_file that exists; None when that cannot be told."""
        if self.cfg["apps"]:
            return set(self.cfg["apps"])
        templates = [(self.cfg["chart_dir"], "Chart.yaml")] if "helm" in self.runtimes else []
        templates += [(self.cfg["compose_file"], "")] if "compose" in self.runtimes else []
        templates = [(template, marker) for template, marker in templates if "{app}" in template]
        found = set()
        for template, marker in templates:
            pattern = re.compile(re.escape(template).replace(re.escape("{app}"), "([a-z0-9-]+)") + "$")
            for path in self.root.glob(template.replace("{app}", "*")):
                match = pattern.match(self.rel(path))
                if match and (path / marker if marker else path).is_file():
                    found.add(match.group(1))
        return found if templates else None

    def check_files(self):
        """Check 3: files per runtime; forbidden, stray and misnamed files; flat layers; dev inventories."""
        for check, path, message in self.stray:
            if check == 3:
                self.error(3, path, message)
        for path in sorted(self.tree.rglob("*")):
            name = path.name
            if path.is_file() and name != "compose.env" and (name.startswith(".env") or name.endswith(".env")):
                self.error(3, path, "no .env files: the instance's compose.env is the only env file")
        for layer in self.layers:
            for entry in listdir(layer):
                if entry.is_dir():
                    self.error(3, entry, "layers are flat: no directory inside a layer")
                elif entry.name in MISNAMED:
                    self.error(3, entry, f"never read: name it {MISNAMED[entry.name]}")
        for layer in self.shared:
            for name in ("values.yaml", "compose.env"):
                if (layer / name).is_file():
                    self.error(3, layer / name, f"{name} belongs to app-common or an instance, not to _common")
        for env, flow, app_dir in self.apps:
            if not any(inst.path.parent == app_dir for inst in self.instances):
                self.add("WARN", 3, app_dir, f"no instance: nothing deploys {app_dir.name} in {env}/{flow}")
            self.layer_files(app_dir / "app-common", env, instance=False)
        for inst in self.instances:
            self.layer_files(inst.path, inst.env, instance=True)
        for env, flow_dir in self.flows:
            name = self.cfg["inventory"]
            if name and self.dev.search(env) and not (flow_dir / name).is_file():
                self.error(3, flow_dir, f"dev flow without {name}: deploy-dev would never deploy it")

    def layer_files(self, layer, env, instance):
        """The files an instance or app-common layer needs, and those that nothing reads in its env."""
        helm, compose = self.applies("helm", env), self.applies("compose", env)
        need = (["application.yml"] if self.cfg["app_config"] else []) + (["values.yaml"] if helm else [])
        need += ["compose.env"] if compose and instance else []
        if not layer.is_dir():
            if need:
                self.error(3, layer.parent, f"app-common/ is missing ({', '.join(need)})")
            return
        for name in need:
            if not (layer / name).is_file():
                self.error(3, layer, f"{name} is missing")
        if not helm and (layer / "values.yaml").is_file():
            self.error(3, layer / "values.yaml", f"helm does not run {env} (runtimes): nothing reads this file")
        if (layer / "compose.env").is_file() and not (instance and compose):
            why = "compose does not run " + env + " (runtimes)" if instance else "it belongs to an instance"
            self.error(3, layer / "compose.env", f"{why}: nothing reads this file here")

    def check_identity(self):
        """Check 4: the path restated in compose.env and values.yaml; one tag for both renderings."""
        for env, _, app_dir in self.apps:
            path = app_dir / "app-common" / "values.yaml"
            data = self.mapping(path) if self.applies("helm", env) else None
            if data is None:
                continue
            image = data.get("image") if isinstance(data.get("image"), dict) else {}
            misplaced = [f"image.{key}" for key in ("tag", "digest") if key in image]
            for key in misplaced + (["identity"] if "identity" in data else []):
                self.error(4, path, f"{key} belongs to the instance, not to app-common")
            self.env_map(path, data)
        for inst in self.instances:
            want = {"env": inst.env, "flow": inst.flow, "app": inst.app, "instance": inst.name}
            pairs = self.compose_pairs(inst)
            for key, var in IDENTITY_VARS.items():
                if pairs is not None and pairs.get(var) != want[key]:
                    self.error(4, inst.path / "compose.env", self.differs(var, pairs.get(var), want[key]))
            path = inst.path / "values.yaml"
            data = self.mapping(path) if self.applies("helm", inst.env) else None
            if data is None:
                continue
            identity = data.get("identity")
            if not isinstance(identity, dict):
                self.error(4, path, "identity {env, flow, app, instance} is missing")
                identity = want
            for key in want:
                if identity.get(key) != want[key]:
                    self.error(4, path, self.differs(f"identity.{key}", identity.get(key), want[key]))
            env_map = self.env_map(path, data)
            for key, var in IDENTITY_VARS.items():  # optional for apps that read no config file, checked when set
                if env_map.get(var) != want[key] and (var in env_map or self.cfg["app_config"]):
                    self.error(4, path, self.differs(f"env.{var}", env_map.get(var), want[key]))
            if pairs is not None:
                self.renderings_agree(inst, path, data, env_map, pairs)

    @staticmethod
    def differs(label, value, want):
        return f"{label} is {'missing' if value is None else repr(value)}, the path says '{want}'"

    def env_map(self, path, data):
        """The env: map of a values.yaml ({} when absent), after checking its variable names."""
        env_map = data.get("env")
        if env_map is None:
            return {}
        if not isinstance(env_map, dict):
            self.error(4, path, "env must be a map: Helm replaces lists instead of merging the layers")
            return {}
        for name in env_map:
            problem = self.var_problem(str(name), compose=False)
            if problem:
                self.error(4, path, f"env.{name}: {problem}")
        return {str(name): value for name, value in env_map.items()}

    def renderings_agree(self, inst, path, data, env_map, pairs):
        """image.tag equals the tag variable of compose.env; the merged env: agrees with compose.env (WARN)."""
        tag_var, image = self.cfg["tag_var"], data.get("image")
        tag = image.get("tag") if isinstance(image, dict) else None
        if isinstance(tag, str) and tag_var in pairs and tag != pairs[tag_var].split("@")[0]:
            self.error(4, path, f"image.tag is '{tag}' but compose.env has {tag_var}={pairs[tag_var]}")
        common = self.mapping(inst.path.parent / "app-common" / "values.yaml") or {}
        merged = dict(common.get("env") if isinstance(common.get("env"), dict) else {}, **env_map)
        for name in sorted(set(merged) & set(pairs) - set(IDENTITY_VARS.values())):
            if str(merged[name]) != pairs[name]:
                self.add("WARN", 4, path, f"env.{name} is '{merged[name]}' but compose.env has '{pairs[name]}'")

    def check_compose_env(self):
        """Check 5: KEY=VALUE lines, allow-listed keys, IMAGE_REPO and the tag variable, host ports."""
        published = {}  # (env, flow, port) -> (compose.env, variable) that publishes it first
        for inst in self.instances:
            pairs, path = self.compose_pairs(inst), inst.path / "compose.env"
            if pairs is None:
                continue
            for problem in self.env_file(path)[1]:
                self.error(5, path, problem)
            for name in ("IMAGE_REPO", self.cfg["tag_var"]):
                if name not in pairs:
                    self.error(5, path, f"{name} is missing")
            for name, value in pairs.items():
                problem = self.var_problem(name, compose=True)
                if problem:
                    self.error(5, path, f"{name}: {problem}")
                elif name.endswith("_HOST_PORT") and not (value.isdigit() and 1024 <= int(value) <= 65535):
                    self.error(5, path, f"{name}={value}: a host port is a number in 1024-65535")
                elif name.endswith("_HOST_PORT"):  # a pooled box may run every instance of the flow
                    first = published.setdefault((inst.env, inst.flow, value), (path, name))
                    if first != (path, name):
                        self.add("WARN", 5, path, f"{name}={value} is published by {first[1]} of {self.rel(first[0])} "
                                                  "too: they cannot share a box")

    def check_compose_renders(self):
        """Check 6: docker compose config --quiet per instance, as the wrapper runs it; placeholders for secrets."""
        todo = [inst for inst in self.instances
                if self.compose_pairs(inst) is not None and self.artifact("compose_file", inst.app).is_file()]
        docker = os.environ.get("DOCKER_BIN", "docker")
        version = run([docker, "compose", "version"]) if todo else None
        if todo and (version is None or version.returncode != 0):
            return self.tool_missing(6, f"docker compose not found ({docker}): compose renderings not checked")
        for inst in todo:
            env_path, compose_file = inst.path / "compose.env", self.artifact("compose_file", inst.app)
            env = {name: value for name, value in os.environ.items() if name.startswith(KEEP_ENV)}
            fields = {"config": str(self.tree), "env": inst.env, "flow": inst.flow, "app": inst.app,
                      "instance": inst.name}
            env.update({name: template.format(**fields) for name, template in self.cfg["wrapper_vars"].items()})
            for name in set(COMPOSE_VAR.findall(compose_file.read_text(encoding="utf-8", errors="replace"))):
                if name not in self.compose_pairs(inst) and name not in env and looks_secret(name):
                    env[name] = "lint-placeholder"  # the host environment provides the secrets
            result = run([docker, "compose", "-p", f"lint-{inst.env}-{inst.flow}-{inst.app}-{inst.name}", "--env-file",
                          str(env_path), "-f", str(compose_file), "config", "--quiet"], cwd=self.root, env=env)
            if result is None or result.returncode != 0:
                self.error(6, env_path, f"docker compose config failed: {last_error(result)}")

    def check_secrets(self):
        """Check 9: secret values in every file of the tree, secret-named keys in every YAML file."""
        for path in sorted(p for p in self.tree.rglob("*") if p.is_file()):
            try:
                lines = path.read_text(encoding="utf-8").splitlines()
            except UnicodeDecodeError:
                self.error(9, path, "not UTF-8 text: keystores and other binary secrets never enter the tree")
                continue
            for number, line in enumerate(lines, 1):
                what = next((what for pattern, what in SECRET_VALUES if pattern.search(line)), None)
                if what:
                    self.error(9, path, f"line {number}: looks like {what}; secrets never enter the tree")
            if path.suffix not in (".yml", ".yaml"):
                continue
            allow = self.cfg["secret_keys_allow"]
            for dotted, key in self.leaf_keys(self.reader.load(path)[0]):
                if looks_secret(key) and not (allowed(key, allow) or allowed(dotted, allow)):
                    self.error(9, path, f"key {dotted} names a secret: deliver it through a Secret or the host "
                                        "environment (secret_keys_allow for a false positive)")

    def leaf_keys(self, data, prefix=""):
        """(dotted path, key) of every mapping key that holds a string or a number, at any depth."""
        if isinstance(data, list):
            for index, value in enumerate(data):
                yield from self.leaf_keys(value, f"{prefix}[{index}]")
            return
        for key, value in data.items() if isinstance(data, dict) else []:
            dotted = f"{prefix}.{key}" if prefix else str(key)
            if isinstance(value, (dict, list)):
                yield from self.leaf_keys(value, dotted)
            elif isinstance(value, (str, int, float)) and not isinstance(value, bool):
                yield dotted, str(key)

    def check_tags(self):
        """Check 10: valid string tags everywhere; X.Y.Z plus a sha256 digest in pinned envs."""
        for inst in self.instances:
            pinned, path = bool(self.pinned.search(inst.env)), inst.path / "values.yaml"
            data = self.mapping(path) if self.applies("helm", inst.env) else None
            if data is not None:
                self.values_tag(path, data.get("image"), inst.env, pinned)
            pairs, tag_var = self.compose_pairs(inst), self.cfg["tag_var"]
            if pairs is not None and tag_var in pairs:
                tag, _, digest = pairs[tag_var].partition("@")
                if digest and not DIGEST.match(digest):
                    self.error(10, inst.path / "compose.env", f"the digest after {tag}@ must be sha256:<64 hex>")
                else:
                    self.tag_rule(inst.path / "compose.env", tag_var, tag, digest, inst.env, pinned, False)

    def values_tag(self, path, image, env, pinned):
        """image.tag of an instance values.yaml: present, a string, with a well-formed image.digest."""
        if not isinstance(image, dict) or "tag" not in image:
            return self.error(10, path, 'image.tag is missing ("" = never deployed): the deploys record it there')
        tag, digest = image["tag"], image.get("digest") or ""
        if not isinstance(tag, str):
            self.error(10, path, f"image.tag must be a quoted string, got {tag!r}")
        elif not isinstance(digest, str) or (digest and not DIGEST.match(digest)):
            self.error(10, path, f"image.digest must be sha256:<64 hex>, got {digest!r}")
        else:
            self.tag_rule(path, "image.tag", tag, digest, env, pinned, need_digest=True)

    def tag_rule(self, path, label, tag, digest, env, pinned, need_digest):
        """The tag policy: "" = never deployed; valid everywhere; X.Y.Z (plus a digest for Helm) when pinned."""
        if tag == "" and digest:
            self.error(10, path, f"a digest without {label}")
        elif tag == "" and pinned:
            self.add("WARN", 10, path, f'{env} records no release yet ({label} ""): nothing to deploy')
        elif tag and not IMAGE_TAG.match(tag):
            self.error(10, path, f"{label} {tag!r} is not a valid image tag")
        elif tag and pinned and not RELEASE.match(tag):
            self.error(10, path, f"{env} pins a release X.Y.Z, not {tag!r}: floating tags are for dev")
        elif tag and pinned and need_digest and not digest:
            self.error(10, path, f"{env} pins the digest main tested next to {tag} (image.digest)")

    def check_inventory(self):
        """Check 11: one inventory per dev flow, in step with the instance directories; known_hosts."""
        name, pools = self.cfg["inventory"], {}
        for env_dir in self.envs:
            if (env_dir / name).is_file():
                self.error(11, env_dir / name, f"the inventory is per flow: {env_dir.name}/<flow>/{name}")
            known_hosts = env_dir / "known_hosts"
            lines = known_hosts.read_text("utf-8", "replace").splitlines() if known_hosts.is_file() else []
            for number, line in enumerate(lines, 1):
                text = line.strip()
                if text and not text.startswith("#") and ("PRIVATE KEY" in text or not KEYSCAN.match(text)):
                    self.error(11, known_hosts, f"line {number}: not an ssh-keyscan line (<hosts> <key type> <key>)")
        for env, flow_dir in self.flows:
            path = flow_dir / name
            data = self.mapping(path)  # a missing one is check 3's, one that does not parse too
            if data is not None and not self.dev.search(env):
                self.add("WARN", 11, path, f"{env} is not a dev env: deploy-dev ignores this inventory")
            elif data is not None:
                self.inventory(env, flow_dir.name, path, data, pools)

    def unknown_keys(self, path, where, data, known):
        for key in sorted(set(map(str, data)) - known):
            self.error(11, path, f"{where}unknown key '{key}' ({', '.join(sorted(known))})")

    def inventory(self, env, flow, path, data, pools):
        self.unknown_keys(path, "", data, INVENTORY_KEYS)
        for key, want in (("env", env), ("flow", flow)):
            if data.get(key) != want:
                self.error(11, path, self.differs(key, data.get(key), want))
        hosts = self.pool(path, env, flow, data["pool"], pools) if data.get("pool") is not None else None
        defaults = data.get("defaults") if isinstance(data.get("defaults"), dict) else {}
        self.unknown_keys(path, "defaults: ", defaults, TARGET_KEYS - {"instance"})
        targets = data.get("targets") if isinstance(data.get("targets"), list) else []
        instances = {f"{i.app}/{i.name}" for i in self.instances if (i.env, i.flow) == (env, flow)}
        seen = {}
        for index, target in enumerate(targets):
            where = f"targets[{index}]: "
            if not isinstance(target, dict):
                self.error(11, path, f"{where}not a mapping")
                continue
            self.unknown_keys(path, where, target, TARGET_KEYS)
            instance = str(target.get("instance", ""))
            seen[instance] = seen.get(instance, 0) + 1
            if not instance:
                self.error(11, path, f"{where}instance is missing")
            elif instance not in instances:
                self.error(11, path, f"{where}{flow}/{instance} has no directory")
            for problem in self.target_problems(env, flow, {**defaults, **target}, hosts):
                self.error(11, path, where + problem)
        for instance in sorted(instances):
            if seen.get(instance, 0) != 1:
                self.error(11, path, f"instance {instance} has {seen.get(instance, 0)} targets, not one"
                           + ("" if instance in seen else ": deploy-dev would skip it"))

    def target_problems(self, env, flow, target, hosts):
        """What is wrong with one target (fields from the target, else defaults); hosts: the pool's or None."""
        kind, host, namespace = target.get("kind", "compose"), target.get("host"), str(target.get("namespace", flow))
        if kind not in ("compose", "helm") or not self.applies(kind, env):
            return [f"kind {kind!r} is not a runtime of {env} (compose or helm, see runtimes)"]
        problems = []
        if kind == "compose" and host is None and hosts is None:
            problems.append("a compose target needs a host, or a pool in its flow")
        if kind == "compose" and host is not None and not HOST.match(str(host)):
            problems.append(f"host {host!r} is not a lower-case DNS name or IPv4 address")
        elif kind == "compose" and host is not None and hosts and host not in hosts:
            problems.append(f"host {host} is not one of pool.hosts")
        if kind == "compose" and not LOGIN.match(str(target.get("user", "deploy"))):
            problems.append(f"user {target.get('user')!r} is not a login name")
        if kind == "helm" and not target.get("cluster"):
            problems.append("a helm target needs a cluster (a kube context)")
        if kind == "helm" and not (TOKEN.match(namespace) and len(namespace) <= 63):
            problems.append(f"namespace {namespace!r} is not a DNS label of at most 63 characters")
        return problems

    def pool(self, path, env, flow, pool, pools):
        """Checks pool.hosts, user and root, and one box and root in two pools; returns the hosts."""
        pool = pool if isinstance(pool, dict) else {}
        hosts = [str(host) for host in pool.get("hosts") or []] if isinstance(pool.get("hosts"), list) else []
        user, root = str(pool.get("user", "deploy")), str(pool.get("root", "/opt/platform"))
        self.unknown_keys(path, "pool: ", pool, {"hosts", "user", "root"})
        if not hosts or len(set(hosts)) != len(hosts) or not all(HOST.match(host) for host in hosts):
            self.error(11, path, "pool.hosts must be a non-empty list of unique lower-case hosts")
        if not LOGIN.match(user):
            self.error(11, path, f"pool.user {user!r} is not a login name")
        if not PLAIN_ABS_PATH.match(root):
            self.error(11, path, f"pool.root {root!r} must be an absolute path of plain segments")
        for host in hosts:
            other = pools.setdefault((host, root), f"{env}/{flow}")
            if other != f"{env}/{flow}":
                self.error(11, path, f"box {host} with root {root} is in the pool of {other} too")
        return hosts

    def check_helm_renders(self):
        """Check 12: helm lint and template per instance through the deploy's own adapter, then kubeconform."""
        todo = [inst for inst in self.instances  # an instance without values.yaml or chart is check 3's or 2's
                if self.applies("helm", inst.env) and (inst.path / "values.yaml").is_file()
                and (self.artifact("chart_dir", inst.app) / "Chart.yaml").is_file()]
        script = self.root / self.cfg["helm_deploy_script"]
        if not todo:
            return
        if not script.is_file():
            return self.error(12, script, "the Helm adapter is missing (helm_deploy_script): copy the skill's "
                                          "helm-deploy-instance.sh there")
        if self.report:
            out_dir = self.report.parent / "rendered"
        else:
            out_dir = self.tmp = Path(tempfile.mkdtemp(prefix="config-lint-"))
        env = dict(os.environ, HELM_CHART_DIR=self.cfg["chart_dir"], HELM_CONFIG_DIR=self.cfg["config_dir"])
        rendered = {}
        for inst in todo:
            out = out_dir / inst.env / inst.flow / inst.app / f"{inst.name}.yaml"
            for mode, extra in (("lint", []), ("template", ["--render-out", str(out)])):
                result = run(["bash", str(script), inst.env, inst.flow, inst.app, inst.name, "--mode", mode, *extra],
                             cwd=self.root, env=env)
                if result is not None and result.returncode == 5:
                    return self.tool_missing(12, f"the Helm adapter cannot run: {last_error(result)}")
                if result is None or result.returncode != 0:
                    self.error(12, inst.path, f"helm {mode} failed: {last_error(result)}")
                    break
            else:
                rendered[str(out)] = inst
        if rendered:
            self.kubeconform(rendered, out_dir)

    def kubeconform(self, rendered, out_dir):
        """kubeconform -strict -summary on the rendered releases; each finding on the instance that rendered it."""
        binary = os.environ.get("KUBECONFORM_BIN", "kubeconform")
        if not shutil.which(binary):
            return self.tool_missing(12, f"kubeconform not found ({binary}): the rendered manifests are not validated")
        version = ["-kubernetes-version", self.cfg["kubernetes_version"]] if self.cfg["kubernetes_version"] else []
        result = run([binary, "-strict", "-summary", "-output", "json", *version, *self.cfg["kubeconform_args"],
                      *rendered])
        try:
            report = json.loads(result.stdout) if result else None
        except json.JSONDecodeError:
            report = None
        if not isinstance(report, dict):
            return self.error(12, out_dir, f"kubeconform failed: {last_error(result)}")
        for res in report.get("resources") or []:
            if res.get("status") in ("statusInvalid", "statusError"):
                errors = "; ".join(f"{e.get('path')}: {e.get('msg')}" for e in res.get("validationErrors") or [])
                inst = rendered.get(res.get("filename"))
                self.error(12, inst.path if inst else out_dir,
                           f"kubeconform: {res.get('kind')} {res.get('name')}: {errors or res.get('msg')}")
        count = report.get("summary") or {}
        self.add("INFO", 12, out_dir, "kubeconform: " + ", ".join(f"{count.get(k, 0)} {k}" for k in
                                                                   ("valid", "invalid", "errors", "skipped")))

    # --- the run --------------------------------------------------------------------------------------------
    def not_run(self, number):
        """(severity, message) when check <number> does not run, else None."""
        runtime = "compose" if number in (5, 6) else "helm" if number == 12 else None
        if number in self.skip:
            return "INFO", f"skipped (checks.skip in {self.rel(self.config_file)})"
        if runtime and runtime not in self.runtimes:
            return "INFO", f"not applicable: {runtime} is not in runtimes"
        if number == 11 and not self.cfg["inventory"]:
            return "INFO", "not applicable: no dev inventory (inventory: '')"
        if number == 7 and not self.cfg["app_config"]:
            return "INFO", "not applicable: the apps read no config files (app_config: false)"
        if number == 6 and not self.cfg["compose_file"]:
            return "TODO", "compose renderings not checked: set compose_file"
        if number in (6, 12) and not self.render:
            return "INFO", "skipped (--no-render)"
        return ("TODO", TODO[number]) if number in TODO else None

    def run(self):
        """Every check in order, then the findings; returns the exit code."""
        self.scan()
        self.parse_all()
        if not self.found:
            self.add("WARN", 1, self.config_file, "not found: the defaults apply, and the env and flow allow-lists "
                                                  "are off (any lower-case kebab name passes)")
        checks = {1: self.check_naming, 2: self.check_deployables, 3: self.check_files, 4: self.check_identity,
                  5: self.check_compose_env, 6: self.check_compose_renders, 9: self.check_secrets,
                  10: self.check_tags, 11: self.check_inventory, 12: self.check_helm_renders}
        for number in range(1, 14):
            reason = self.not_run(number)
            if reason:
                self.add(reason[0], number, self.tree, reason[1], always=True)
            else:
                checks[number]()
        if self.tmp:
            shutil.rmtree(self.tmp, ignore_errors=True)
        rank = {"ERROR": 0, "WARN": 1, "TODO": 2, "INFO": 3}
        ordered = sorted(self.findings, key=lambda f: (f[0], f[1], rank[f[2]], f[3]))
        lines = [f"{severity} check {check}  {path}: {message}" for path, check, severity, message in ordered]
        count = {severity: sum(1 for f in ordered if f[2] == severity) for severity in rank}
        lines.append(f"config lint: {count['ERROR']} error(s), {count['WARN']} warning(s), {count['TODO']} todo(s)"
                     f" (YAML read with {self.reader.name})")
        print("\n".join(lines))
        if self.report:
            self.report.parent.mkdir(parents=True, exist_ok=True)
            self.report.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return 1 if count["ERROR"] else 0


def main(argv=None):
    parser = argparse.ArgumentParser(prog="config_lint.py", add_help=False, usage="%(prog)s [--root <dir>] "
                                     "[--config <file>] [--report <file>] [--no-render] [--help]")
    parser.add_argument("-h", "--help", action="store_true")
    parser.add_argument("--root")
    parser.add_argument("--config")
    parser.add_argument("--report", default=DEFAULT_REPORT)
    parser.add_argument("--no-render", action="store_true")
    args = parser.parse_args(argv)
    if args.help:
        print(__doc__.strip())
        return 0
    top = run(["git", "rev-parse", "--show-toplevel"])
    root = Path(args.root or (top.stdout.strip() if top and top.returncode == 0 else ".")).resolve()
    try:
        if not root.is_dir():
            raise UsageError(f"--root {root} is not a directory")
        reader = YamlReader()
        config_file = root / (args.config or DEFAULT_CONFIG)
        cfg, found = load_config(config_file, bool(args.config), reader)
        if not (root / cfg["config_dir"]).is_dir():
            raise UsageError(f"the config tree {root / cfg['config_dir']} does not exist (config_dir, --root)")
    except UsageError as error:
        print(f"config_lint.py: {error}", file=sys.stderr)
        return 2
    report = root / args.report if args.report else None
    return Lint(root, cfg, config_file, found, reader, not args.no_render, report).run()


if __name__ == "__main__":
    sys.exit(main())
