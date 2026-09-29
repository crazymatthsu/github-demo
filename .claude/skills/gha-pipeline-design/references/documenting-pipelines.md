# Documenting a pipeline with Mermaid diagrams

Read this when asked to document, draw or explain which workflow runs when, or after building a pipeline.

## Contents
1. Where the page lives
2. Page structure
3. Facts first: extract them from the YAML
4. Legend and styles
5. Mermaid on GitHub: layout rules that keep diagrams readable
6. Validate before pushing

## 1. Where the page lives

Write `.github/workflows/README.md`. GitHub renders a folder's README below its file list, so anyone who opens
the workflows folder sees the diagrams. Link it from `.github/README.md` or the root README. Diagrams are fenced
```` ```mermaid ```` blocks; GitHub draws them in place of the code (the GitHub mobile app and some IDE previews
show the source instead).

## 2. Page structure

1. One paragraph: what the page shows, where the settings and bootstrap notes live.
2. A numbered table of contents (one entry per section below).
3. A legend table (section 4).
4. **Overview**: events on the left, workflow files on the right, conditions on dotted arrows. A second small
   diagram: which trigger workflows call which reusable workflows.
5. **One section per pipeline**, each with a one-sentence intro, the diagram, and 2-5 bullets for what the
   diagram cannot show (cancellation, fork behaviour, skipped jobs): push to a branch, pull request and merge
   queue, push to main (and hotfix), release front end, tag push, nightly, base images, and any other schedule.
   Each job node names the reusable workflow it calls and lists its composite actions on its last line
   (`actions: a, b`, or `actions: none`).
6. **Inside the reusable workflows**: one diagram each, steps as nodes, composite-action steps as hexagons.
7. **Composite actions by pipeline**: a matrix (action × pipeline, ✓) and a table (action, what it does,
   used by which workflow and job), then one line on third-party actions.

## 3. Facts first: extract them from the YAML

Draw from the files, not from memory. Dump triggers, jobs, `needs`, `if`, reusable calls and action uses:

```bash
python3 - <<'PY'
import glob, json, subprocess
def load(path):
    try:
        import yaml  # PyYAML turns the key `on` into True
        data = yaml.safe_load(open(path))
        if True in data: data['on'] = data.pop(True)
        return data
    except ImportError:  # mikefarah yq v4 instead (preinstalled on GitHub-hosted runners)
        out = subprocess.run(['yq', '-o=json', '.', path], capture_output=True, text=True, check=True).stdout
        return json.loads(out)
for f in sorted(glob.glob('.github/workflows/*.yml')):
    d = load(f)
    print(f"\n## {f}\non: {json.dumps(d.get('on'), default=str)}")
    for jid, j in (d.get('jobs') or {}).items():
        print(f"  job {jid} needs={j.get('needs')} if={' '.join(str(j.get('if', '')).split())}")
        if j.get('uses'): print(f"    calls {j['uses']} with {json.dumps(j.get('with', {}), default=str)[:200]}")
        for s in j.get('steps') or []:
            if 'uses' in s: print(f"    step {s.get('name', '')!r} uses {s['uses']} if={s.get('if', '')}")
for f in sorted(glob.glob('.github/actions/*/action.yml')):
    d = load(f)
    print(f"\n## {f}: " + ', '.join(s['uses'] for s in d['runs'].get('steps', []) if 'uses' in s))
PY
```

It needs PyYAML or mikefarah yq v4, nothing else.

## 4. Legend and styles

Use the same shapes and colours in every diagram and explain them once:

| Shape | Mermaid | Meaning |
|---|---|---|
| blue pill | `id(["..."]):::trigger` | trigger event, or the caller of a reusable workflow |
| grey box | `id["..."]:::wf` | a whole workflow file |
| white box | `id["..."]` | a job, or a step running shell commands |
| violet box with side bars | `id[["..."]]:::reusable` | a reusable workflow, or a job calling one |
| amber hexagon | `id{{"..."}}:::act` | a step using a composite action |
| green parallelogram | `id[/"..."/]:::out` | what the run produces: images, a commit, a PR, a release |
| dotted arrow | `a -.->\|"condition"\| b` | runs only under the condition, or an indirect effect |

Start every diagram with the directive and the class definitions it uses:

```text
%%{init: {"flowchart": {"wrappingWidth": 320}}}%%
flowchart TD
  classDef default fill:#ffffff,stroke:#64748b,color:#0f172a
  classDef trigger fill:#dbeafe,stroke:#2563eb,color:#0f172a
  classDef wf fill:#e2e8f0,stroke:#334155,color:#0f172a
  classDef reusable fill:#ede9fe,stroke:#7c3aed,color:#0f172a
  classDef act fill:#fef3c7,stroke:#d97706,color:#0f172a
  classDef out fill:#dcfce7,stroke:#16a34a,color:#0f172a
```

Light fills with dark text read well in both GitHub themes; `classDef default` restyles plain nodes, which
Mermaid's dark theme would otherwise paint dark grey.

## 5. Mermaid on GitHub: layout rules that keep diagrams readable

- **Wrapping.** Node labels wrap at `wrappingWidth` (default 200 px) and break inside hyphenated names
  (`_gradle-` / `build.yml`). Set `wrappingWidth: 320` and write the line breaks yourself with `<br/>`: at most
  ~26 characters per line for nodes that sit side by side, ~34 for nodes in a single chain.
- **Edge labels ignore `wrappingWidth`** and wrap at ~200 px: keep them to ~24 characters per line and use words
  instead of long globs ("config tree, Helm chart or compose template changed", not three `**/` paths).
- **Width.** GitHub scales a diagram to the page width (~1000 px). Anything much wider becomes unreadable; prefer
  `flowchart TD` for chains of steps and keep at most 3-4 nodes per rank.
- **Characters.** Quote every label (`id["..."]`). Avoid `<` and `>` (read as HTML), `#` and `;`; write
  `pr-4-5d2c2c9` rather than `pr-<n>-<sha7>`. Do not use `end` as a node id.
- **Layout control.** Declaration order influences left-to-right placement; an invisible link (`a ~~~ b`) forces
  `b` below `a` without drawing anything. Avoid putting several triggers in one subgraph: it pins their order and
  crosses edges; give schedule-plus-manual triggers one node per workflow instead of one shared "manual run" node.
- **Portability.** Plain flowchart syntax (`[[ ]]`, `{{ }}`, `[/ /]`, `([ ])`, `:::class`, `&`, `~~~`, `-.->|x|`)
  renders on every current GitHub Mermaid; avoid the newer `@{ shape: ... }` syntax.

## 6. Validate before pushing

```bash
npm install --no-save --prefix "${TMPDIR:-/tmp}/mmd" mermaid@11 playwright-core jsdom
NODE_PATH="${TMPDIR:-/tmp}/mmd/node_modules" node <skill>/scripts/render-mermaid.cjs .github/workflows/README.md --out /tmp/mmd-light
NODE_PATH="${TMPDIR:-/tmp}/mmd/node_modules" node <skill>/scripts/render-mermaid.cjs .github/workflows/README.md --out /tmp/mmd-dark --theme dark
# no Chromium available (blocked download, locked-down machine): the syntax at least, in Node on jsdom
NODE_PATH="${TMPDIR:-/tmp}/mmd/node_modules" node <skill>/scripts/render-mermaid.cjs .github/workflows/README.md --parse-only
```

It exits 1 on any diagram that does not parse and flags diagrams wider than ~1000 px. Rendering needs a
Chromium (`CHROMIUM_PATH`, or `npx playwright install chromium`); `--parse-only` with jsdom installed needs none,
but then widths and crossed edges stay unchecked, so say so when you report. Look at a few PNGs: crossed
edges and labels attached to the wrong arrow are the usual layout problems. Then push and open the folder on
github.com.

Keep the page true: a PR that changes a workflow's triggers, jobs or actions updates the diagrams in the same PR.
