# GitHub Demo: Claude Code + GitHub Actions Auto-Fix Loop

How to set up an **auto code → auto test → auto fix** cycle with Claude Code, GitHub, and GitHub Actions.

## Do you need MCP?

No. Claude Code has a shell, so it can use the GitHub CLI (`gh`) to push, watch CI, read failure logs, and manage issues. The GitHub MCP server is optional and only adds richer structured access.

---

## Option 1: Local loop (Claude Code on your PC drives everything)

1. Install and authenticate `gh` (`gh auth login`).
2. Add the loop instructions to `CLAUDE.md` in the repo root:

```markdown
## CI workflow
After finishing a change:
1. Run tests locally first (./gradlew test).
2. Commit and push to a feature branch, never main.
3. Run `gh run watch` on the triggered workflow run.
4. If it fails, run `gh run view <id> --log-failed`,
   diagnose, fix, commit, and push again.
5. Stop after 3 failed attempts and summarize the issue.
6. Never delete or weaken tests to make CI pass.
```

3. Give it a task: *"Implement X, push, and iterate until CI is green."*

Claude pushes, waits on `gh run watch`, reads the failed logs, fixes the code, and pushes again. To work from issues, it can use `gh issue list` / `gh issue view 42` and close them with `Fixes #42` in the commit message.

For unattended runs, use headless mode (`claude -p "..."`) with pre-approved tools in `.claude/settings.json`.

---

## Option 2: Cloud loop (Claude runs inside GitHub Actions)

In Claude Code, run `/install-github-app`. It installs the GitHub app and adds `ANTHROPIC_API_KEY` as a repo secret. After that you can:

- Mention `@claude` in an issue or PR comment to get a fix branch or PR.
- Trigger it automatically when CI fails:

```yaml
on:
  workflow_run:
    workflows: ["CI"]
    types: [completed]
jobs:
  autofix:
    if: github.event.workflow_run.conclusion == 'failure'
    runs-on: ubuntu-latest   # or self-hosted
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.workflow_run.head_branch }}
      - uses: anthropics/claude-code-action@v1
        with:
          anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
          prompt: "CI failed. Read the logs, fix the root cause, push."
```

Use a self-hosted runner if the build needs specific toolchains or hardware (for example C++ builds). Check the `claude-code-action` README for the current inputs.

---

## "Claude Code in the cloud": two different things

| | Claude Code in GitHub Actions | Claude Code on the web |
|---|---|---|
| Where it runs | GitHub runners (hosted or self-hosted) | Anthropic-hosted sandbox |
| Triggered by | Events: CI failure, `@claude`, new issue | You start each task (browser or mobile) |
| Auto-fix on CI failure | Yes | No, not event-driven |
| Best for | Hands-off auto-fix loop | Starting tasks while away from your laptop |

If you want CI to fail and Claude to fix it without you, use **Option 2**.

## Which to use

- **Local**: active development. Fast, sees your full environment and build tools.
- **Cloud**: things that happen while you're away, such as issues filed by others, nightly failures, and PR reviews.

## Guardrails

- Branch protection on `main`; require a human to merge.
- Cap the number of retry attempts.
- Tell Claude not to modify tests or CI config without approval.
- Watch API spend, because a flaky test can trigger the cloud loop repeatedly.
