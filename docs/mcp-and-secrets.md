# MCP servers and secrets

The basics are in the [README](../README.md#secrets-for-mcp-servers); this file has the
full details.

## Keeping MCP tokens out of `~/.claude.json`

MCP servers configured in `~/.claude.json` often carry tokens in plaintext there, and
the file is copied into every session. Claude Code expands `${VAR}` in MCP server
config, so the tokens can live in an env file instead:

```json
"headers": { "Authorization": "Bearer ${ELASTIC_TOKEN}" }
```

```sh
# ~/.config/agentcontainer.env (chmod 600), docker env file format
ELASTIC_TOKEN=...
JIRA_PERSONAL_TOKEN=...
```

`run.sh` picks up `~/.config/agentcontainer.env` (`%USERPROFILE%\.config\agentcontainer.env`
for `run.ps1`) on its own if it exists. Otherwise:

```sh
run.sh --env-file ~/secrets/other.env     # or ENV_FILE=... in config/run.local.sh
run.sh --no-env-file                      # none this session (ENV_FILE=off: never)
```

`run.sh` warns if the file is readable by other users or lies inside the mounted project
directory, where the harness could read and edit it.

Expansion works in `env`, `args`, `command`, `url` and `headers`, for servers in
`~/.claude.json` as well as `.mcp.json`. Use your own names: Claude Code leaves
well-known credential variables (such as `ANTHROPIC_API_KEY`) empty in a remote
server's `url` and `headers` instead of expanding them.

The variables reach Claude Code and the MCP servers it starts. With the Bash sandbox (the
default for Claude Code), shell commands don't see them. Names the sandbox itself relies
on (`HTTP_PROXY` and friends, `HOME`, `HOST_*`, `INSPECT`, `PROXY_LOGS`,
`AGENTCONTAINER_*`, ...) are refused, so an env file can't quietly switch off the
allowlist. So are the dynamic loader's `LD_*` variables, `GCONV_PATH` and `OPENSSL_*`:
the container's startup script runs as root with the env file's variables, and e.g.
`LD_LIBRARY_PATH` or `OPENSSL_CONF` pointing into the (agent-writable) project would
make root load a library the agent planted there.

## One-off MCP servers (Claude Code)

For a server you only need now and then, such as one with broader credentials, skip
`~/.claude.json`. Put it in its own config file with `chmod 600`, since it holds the
secret, e.g. `~/.config/mcp/graph-review.mcp.json`. Keep it outside `~/.claude`
(mounted read-write into every session), outside the project, and outside any
`EXTRA_MOUNTS`, so no other session can read it. Then mount it and load it for a single
session with Claude Code's `--mcp-config`:

```json
{
  "mcpServers": {
    "graph-review": {
      "type": "stdio",
      "command": "defender-xdr-mcp",
      "env": {
        "AZURE_TENANT_ID": "<tenant>",
        "AZURE_CLIENT_ID": "<client-id>",
        "AZURE_CLIENT_SECRET": "<secret>",
        "GRAPH_MCP_TOOLSETS": "graph"
      }
    }
  }
}
```

```sh
F="$HOME/.config/mcp/graph-review.mcp.json"
run.sh --mount "${F}:${F}:ro" --mcp-config "$F" --allowedTools mcp__graph-review
```

- `run.sh` handles `--mount` itself and forwards the `-` flags to `claude`.
- The servers in `~/.claude.json` still load alongside this one.
- `--allowedTools` is optional: `mcp__<server>` with no tool name allows every tool of
  that server without a prompt. Only use it for read-only tools.
- Use `$HOME` rather than `~` in `F`: the shell doesn't expand a `~` inside quotes or
  after a `:`. Keep the braces in `${F}:`: zsh would read `$F:r` as a modifier that
  strips the file extension.
- The next plain `run.sh` doesn't have the server, and nothing is written to the host's
  config.
- The secret is readable only in sessions where you mount the file, but there by
  everything, including shell commands under the Bash sandbox (the default).
- With `run.ps1`, pass the translated container path to `--mcp-config`, e.g.
  `/c/Users/me/...`.
