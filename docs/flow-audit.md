# Auditing the flow logs

Deep dive for `tools/flowaudit.py`; the summary is in the
[README](../README.md#auditing-the-flow-logs). It analyzes the per-session proxy logs
that `run.sh --proxy-logs` (or `PROXY_LOGS=1` in `config/run.local.sh`) saves to
`~/.local/state/agentcontainer/logs/<timestamp>-<harness>/` (on Windows:
`%LOCALAPPDATA%\agentcontainer\logs\...`).

`tools/flowaudit.py` turns those logs into a scheduled security review with a model.
It starts one headless sandbox session (`run.sh --harness opencode -- run --auto
<prompt>`), mounts the session logs and `flowlog.py` read-only into it, and sends a
predefined prompt (template in `config/flowaudit-prompt.md`, copy it from
`config/flowaudit-prompt.example.md`) plus a pre-computed `flowlog` digest. The agent
drills past the digest with `flowlog` itself and writes
`~/.local/state/agentcontainer/audits/<timestamp>/report.md` ending in
`VERDICT: clean|suspicious|malicious`; flowaudit exits 0/1/2 for clean/findings/run
failed, so a cron entry or systemd timer alerts exactly when it should. The audit's
own proxy logs go to a separate directory, so an audit never audits itself. One
analysis session can only hold so much, so each run audits at most `--max-sessions`
(default 20, oldest first) and the next run takes the rest - a scheduled `flowaudit`
drains the backlog batch by batch. If the analysis session exceeds `--timeout`,
flowaudit stops the container by its `agentcontainer.audit` label (killing the
`docker run` client alone would leave it running).

```sh
tools/flowaudit.py list        # which sessions exist, which were audited
tools/flowaudit.py --dry-run   # build the digest, start no container
tools/flowaudit.py             # audit everything not audited yet
```

The analysis session needs the model provider's key like any other session, and the
container's environment is rebuilt from scratch at startup - so for unattended runs
put it in the standard `~/.config/agentcontainer.env` (which `run.sh` picks up on
its own), or pass it through: `flowaudit --env OPENAI_API_KEY` takes the value from
flowaudit's own environment.

The analysis sees what `--proxy-logs` recorded: hosts, denials and status codes by
default, full (secret-redacted) request/response bodies with `--inspect`.

## Allowlist suggestions

`flowaudit suggest` closes the loop the other way: it aggregates every allowlist
denial across the sessions host-side (per host+port: counts, sessions, methods,
first/last seen, and whether the host is actually in the baked lists - a denial for
a listed host means that session ran with a `--allow-list` override), then has a
headless session triage each one with full drill-down. It classifies each host
`ALLOW` / `KEEP-DENIED` / `REVIEW` / `OVERRIDE` and flowaudit writes the accepted
syntax back as `suggested-allowed-domains.txt` - you merge the lines you agree with
into `config/allowed-domains.txt` and rebuild; the tool never edits the allowlist
itself. Prompt template: `config/flowallow-prompt.md` (from the `.example`).
Exit: 0 nothing to add, 1 suggestions to review, 2 run failed.
