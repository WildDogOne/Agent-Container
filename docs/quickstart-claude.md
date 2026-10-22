# Quickstart: Claude Code

Run [Claude Code](https://docs.claude.com/en/docs/claude-code) in a throwaway container
that sees your project and `~/.claude`, and nothing else from your home directory.
Claude Code is the default harness, so `run.sh` needs no `--harness` flag.

## 1. Build

```sh
git clone https://github.zhaw.ch/Security-Operations-Center/Agent-Container.git ~/Agent-Container
cd ~/Agent-Container
./build.sh claude              # agentcontainer:claude
```

You don't need Claude Code installed on the host; `harnesses/claude/install.sh`
installs it in the image with `npm install -g @anthropic-ai/claude-code`.

## 2. First run: log in

```sh
cd ~/path/to/some-project
~/Agent-Container/run.sh --allow-config
```

`run.sh` creates `~/.claude` and `~/.claude.json` if they're missing. Claude Code walks
you through onboarding and prints a login URL: open it in a browser on the host and
paste the code back into the terminal. `--allow-config` is needed this once so the
onboarding state in `~/.claude.json` is saved. The login token
(`~/.claude/.credentials.json`) is saved either way.

## 3. Every run after that

```sh
~/Agent-Container/run.sh               # claude --permission-mode auto in $PWD
~/Agent-Container/run.sh --continue    # `-` args are forwarded to claude
~/Agent-Container/run.sh --permission-mode manual   # override the auto default
~/Agent-Container/run.sh bash          # a plain shell instead of claude
```

Add an alias to start it from anywhere: `alias claudecli="$HOME/Agent-Container/run.sh"`.

## How a session works

```mermaid
---
config:
  # mermaid.live look (Mermaid 12 defaults, set explicitly for older renderers)
  theme: redux-color
  look: neo
  layout: elk
  themeVariables:
    fontFamily: '"Recursive Variable", Recursive, "trebuchet ms", verdana, arial, sans-serif'
    fontSize: 14px
  flowchart:
    curve: basis
    padding: 15
    nodeSpacing: 50
    rankSpacing: 50
    diagramPadding: 8
    wrappingWidth: 120
    minNodeWidth: 120
---
flowchart LR
    subgraph host["Host"]
        runsh["run.sh<br/>(default harness)"]
        pwd["Your current folder"]
        state["~/.claude<br/>login, transcripts, history"]
        cfg["~/.claude/settings.json, CLAUDE.md,<br/>agents/, commands/, skills/,<br/>hooks/, plugins/, output-styles/ ..."]
        staged["~/.claude.json<br/>MCP servers, trust state"]
        image[("agentcontainer:claude")]
        buildsh["build.sh"]
    end

    subgraph ctr["Container (--rm, one per session)"]
        pid1["entrypoint.sh<br/>PID 1, root"]
        squid["squid<br/>127.0.0.1:3128"]
        dockerd["nested dockerd"]
        copy["/etc/agentcontainer/staged/<br/>.claude.json (ro)"]
        claude["claude --permission-mode auto<br/>user dev, HOME = host $HOME"]
    end

    allow["Allowlist:<br/>.anthropic.com, .claude.ai, .claude.com,<br/>storage.googleapis.com, telemetry<br/>+ registries, GitHub, Docker Hub"]
    internet(("Internet"))
    buildsh --> |Build Image| image
    runsh -- "docker run" --> image --> pid1
    pid1 -- "1: start" --> squid
    pid1 -- "2: start" --> dockerd
    pid1 -- "3: copy into $HOME" --> copy
    pid1 -- "4: exec sudo -u dev" --> claude

    pwd -. "rw, same path" .-> claude
    state -. "rw" .-> claude
    cfg -. "ro (rw with --allow-config)" .-> claude
    staged -. "ro mount (rw with --allow-config)" .-> copy
    copy -. "edits discarded on exit" .-> claude
    ssh -. "bind mount" .-> claude

    claude -- "HTTPS_PROXY" --> squid
    claude -- "docker CLI" --> dockerd
    squid --> allow --> internet
```

- **Read-write:** your project and `~/.claude`, which Claude Code needs for its login,
  token refreshes, transcripts and history.
- **Read-only:** everything that could make the host's own `claude` run code later
  (settings with hooks, plugins, agents, commands, skills). Installing a plugin or
  changing a setting fails inside the session unless you pass `--allow-config`.
- **Copied in:** `~/.claude.json` is rewritten by Claude Code on every start, so it's
  mounted read-only elsewhere and copied into place. Trust prompts and other state in it
  reset every session.
- **Egress:** only through squid, to the domains in `harnesses/claude/allowed-domains.txt`
  plus the shared defaults.

## Common tweaks

| You want to | Do this |
|---|---|
| Change a setting, install a plugin or MCP server | Run once with `--allow-config`. |
| Keep a statusline script (or another file settings point at) read-only | `EXTRA_CONFIG_RO_PATHS+=(.claude/statusline.sh)` in `config/run.local.sh`. |
| Reach another domain | Add it to `config/allowed-domains.txt` and `./build.sh claude`, or `--allow-list FILE` for one session. |
| Update Claude Code | `./build.sh claude` (always `--no-cache`, pulls the latest release). |

See the [README](../README.md) for every flag, and
[harnesses/claude/harness.conf](../harnesses/claude/harness.conf) for exactly what gets
mounted.
