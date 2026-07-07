# Agent VM

A dedicated Incus VM for running AI coding agents (Claude Code CLI) with
real isolation from your workstation, a directory of your choosing shared
in live, and — optionally — the ability to drive VM/container creation
back on the host over Incus's remote HTTPS API.

Built after finding that Claude Code's own hooks, MCP servers, and file
tools run unconstrained on the host even under `bypassPermissions`, and
that the lightweight process-level sandbox (`@anthropic-ai/sandbox-runtime`)
can't reach privileged local services like Incus or Docker (both are
group-gated on their control sockets; bubblewrap drops supplementary
groups). A real VM sidesteps both problems.

## What it gives you

- Real kernel-level isolation: a compromised or careless agent is contained
  to a throwaway VM, not your workstation.
- A directory of your choosing shared in live via virtiofs (read/write, no
  copying, no sync step) — point it at a single project or an entire
  workspace of sibling repos.
- Optional access back to the host's own Incus daemon over Incus's remote
  HTTPS API, so the agent VM can create/manage VMs and containers on the
  host without ever needing local KVM or socket access itself. Useful if
  your workflow involves spinning up test VMs, ephemeral sandboxes, or any
  other Incus-managed infrastructure that genuinely needs host privileges.
  Any existing tooling that shells out to bare `incus` commands (no
  hardcoded remote prefix) works against this transparently — it's just
  talking to a different default remote, no code changes needed.
- The same `guard/hook.py` hardening (blocks `sudo`/`su`/`doas`/`pkexec`
  anywhere in a command chain, blocks `git push` outright, blocks writes to
  its own `.claude/` config) ported in as a second, independent layer on
  top of the VM boundary itself. This holds even with `bypassPermissions`
  as the default mode (`files/claude-settings.json` sets
  `permissions.defaultMode`) — verified live: hooks run and can still deny
  in every permission mode, only the interactive approval prompts go away.
- Interactive shells (plain `ssh`, VS Code's integrated terminal) land in
  `$WORKSPACE_DEST` automatically, since Claude Code's session/project
  history is keyed by the absolute cwd it was started from — landing
  anywhere else silently starts a fresh, historyless project instead of
  resuming. VS Code's Remote-SSH *workspace folder* still needs one manual
  "Open Folder" to `$WORKSPACE_DEST` on first connect; it remembers it per
  host after that.

## What it deliberately doesn't do

- No GUI desktop apps — anything Electron-based needs a display; running
  one would mean adding VNC/remote-desktop, which usually isn't worth it.
  Use Claude Code CLI, plus VS Code's Remote-SSH extension pointed at the
  VM if you want a full IDE.
- No nested virtualization — the VM's `incus` CLI (if you use the remote-API
  feature) is a pure network client to the host's already-running daemon.
  `/dev/kvm` never needs to be passed into the VM.

## Known risk (already checked here, but re-check if you rebuild on a
different host)

Incus has two open upstream bugs around virtiofs directory-sharing into
VMs: broken on **rootless/per-user restricted Incus projects**
([lxc/incus#1682](https://github.com/lxc/incus/issues/1682)), and
separately broken specifically for **`debian/13` VMs**
([forum thread](https://discuss.linuxcontainers.org/t/sharing-directory-with-debian-13-vm-does-not-work/23361)).
Neither reproduced on the setup this was built against (verified live with
a throwaway spike VM before building the real one — read/write both ways
worked). If you're re-running this on a different Incus version or host,
repeat that spike first: launch a throwaway `--vm`, add a disk share, and
check both directions work, before trusting the real provisioning run.

## Usage

```sh
cp .env.example .env    # then edit .env for your setup
./provision-agent-vm.sh
```

The script refuses to run without a `.env` present, rather than silently
falling back to built-in defaults — see `.env.example` for every
configurable variable (`VM_NAME`, `VM_CPU`, `VM_MEMORY`, `VM_DISK`,
`WORKSPACE_SRC`, `WORKSPACE_DEST`, `SSH_KEY_PATH`, `REMOTE_NAME`, `GH_TOKEN`,
`INSTALL_TOKEN_SAVIOR`, `INSTALL_CAVEMAN`) and what each one does. Safe to
re-run afterward — every step checks for existing state first.

Connect:

```sh
ssh -i ~/.ssh/agent_vm_ed25519 debian@<vm-ip>   # incus list agent-vm
```

Or point VS Code's Remote-SSH extension at the same host/key, then run
`claude` in its integrated terminal.

**VS Code Remote-SSH + bypassPermissions gotcha**: the Claude Code VS Code
extension does NOT use the `claude` on PATH or read `~/.claude/settings.json`'s
`permissions.defaultMode` the way a terminal session does. It spawns its own
bundled binary directly (`~/.vscode-server/extensions/anthropic.claude-code-*/
resources/native-binary/claude`, confirmed live via `ps aux`) and hardcodes
`--permission-mode acceptEdits` as a launch argument, which beats every
settings.json layer (user, project, local) and any PATH-based wrapper. If
Claude keeps prompting for approval inside VS Code despite `bypassPermissions`
being set everywhere else, this is why. Fix:

1. Extension settings panel: enable **"Allow dangerously skip permissions"**
   (prerequisite -- without it, step 2 does nothing; this one toggle is
   client-side UI state with no equivalent file, so it can't be scripted).
2. `claudeCode.initialPermissionMode: "bypassPermissions"` in VS Code's
   **remote-machine-scoped** settings. Despite the UI calling this scope
   "Remote [SSH: hostname]" (which reads as client-side) the file is
   actually **on the VM**, at `~/.vscode-server/data/Machine/settings.json`
   -- confirmed live. `provision-agent-vm.sh` step 8c writes this file
   automatically; only step 1's toggle needs doing by hand.
3. Reload window (kills and respawns the extension's claude processes with
   the corrected flag).

Plain `ssh`/terminal sessions don't have this problem the same way, but
`permissions.defaultMode` in settings.json was found unreliable for
*interactive* sessions there too (confirmed live: correct at both scopes,
VM restarted fresh 3x, still prompted -- works fine for non-interactive `-p`
invocations, not interactive ones). `provision-agent-vm.sh` step 8b installs
a `~/.local/bin/claude` wrapper (ahead of `/usr/bin/claude` in PATH) that
always launches with `--permission-mode bypassPermissions` explicitly, which
is what actually holds for terminal/SSH use. That wrapper does not reach the
VS Code extension's spawned process, hence steps 1-3 above.

If you're using the remote-API feature, switch to the host remote before
relying on it (the provisioning script already sets it as default, so this
is normally a no-op — only needed if you've since switched to `local:`):

```sh
incus remote switch host
```

Baseline packages installed inside the VM are deliberately minimal (git,
ssh, build tools, node, uv, gh, incus-client, Claude Code CLI). Add
whatever your own workflow needs to `cloud-init.yaml` — a secrets tool, a
database client, a specific language toolchain, etc.

## Optional add-ons

All off by default in `.env.example` — personal preferences, not defaults
for anyone else reproducing this setup. Enable by setting to `1` in `.env`
and re-running the script (steps 12-14 in `provision-agent-vm.sh`, each
gated on its own flag and checked for existing state before acting).

### `INSTALL_TOKEN_SAVIOR` — [Mibayy/token-savior](https://github.com/Mibayy/token-savior)

Verified: 1.1k stars, actively maintained. Installed via `uv tool install
"token-savior-recall[mcp]"`, then registered as a user-scoped MCP server
(`claude mcp add token-savior -s user`) pointed at `WORKSPACE_ROOTS` — the
comma-separated list of every immediate child of `$WORKSPACE_DEST` that
contains a `.git`, discovered dynamically at provisioning time rather than
hardcoded (a static repo list goes stale exactly like this workspace's own
top-level `CLAUDE.md`, which still says 6 repos when there are 12).

**Known limitations, found in real use**: it can't read lines over ~100k
characters (chokes on minified/single-line files), and pointing
`WORKSPACE_ROOTS` at one parent directory instead of each individual repo
path left the agent stuck on a single "active" project at a time, unable
to browse across sibling repos without an explicit switch. Both are why
`INSTALL_QMD_REMOTE` exists below, and why `WORKSPACE_ROOTS` is built from
individual repo paths, not the shared mount root.

**How to use it**: nothing to invoke — its tools appear in Claude Code's
own tool list (`mcp__token-savior__*`: symbol lookup, call-chain tracing,
cross-session memory, dependency graphs, and more) and Claude reaches for
them on its own wherever `Grep`/`Glob`/`find` would otherwise apply (both
are denied by `guard-hook.py`'s deny list, same policy as the host's
`CLAUDE.md`). Check it's connected with `claude mcp list` from inside the
VM. It also ships a standalone `ts` CLI (status/dashboard/bench) usable
outside of Claude Code, and a `ts init --agent claude` command that
auto-merges Bash-output-compaction hooks into `~/.claude/settings.json` —
deliberately **not** run by the provisioning script, since that file is
the one carrying `bypassPermissions` + the guard hook; run it yourself
only after checking what it changes.

Not the same project as `github.com/awesomo913/Claude-Token-Saver` — an
unrelated, much smaller, similarly-named repo. Verify any third-party tool
independently before pointing this at it; a name match isn't enough (this
one wasn't, the first time around).

### `INSTALL_CAVEMAN` — [JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman)

Verified: 85.7k stars, 4.7k forks, confirmed via the GitHub API directly
(`gh api repos/juliusbrussee/caveman`), not just the README's own claims.
Installed through Claude Code's first-party plugin-marketplace mechanism
(`claude plugin marketplace add` + `claude plugin install`), deliberately
**not** the project's own `curl | bash` installer, which auto-detects and
modifies every agent's config on the machine — broader reach than wanted
here. Confirmed live this does not touch `settings.json`'s hooks or
`permissions.defaultMode`.

**How to use it**: also nothing to invoke — a per-session hook flips agent
output to a terser register automatically once the plugin is enabled.
Toggle it off/on without uninstalling via `claude plugin disable caveman`
/ `claude plugin enable caveman`; check current state with `claude plugin
list`.

### `INSTALL_QMD_REMOTE` — [tobi/qmd](https://github.com/tobi/qmd) (`@tobilu/qmd`) — currently blocked

Complements token-savior: semantic + BM25 search with AST chunking and no
per-line size limit. Designed to run as a daemon on the **host** (`qmd mcp
--http --daemon`), not installed in the VM — qmd's embedding model is
GPU-accelerated and this VM deliberately has no GPU passthrough, so the VM
would be a thin network client to the host's already-built index, same
shape as the Incus remote-API bridge.

**Currently non-functional and the script fails loudly rather than
pretend otherwise**: `@tobilu/qmd` 2.1.0's `--host`/`QMD_HOST` options are
documented but don't work — confirmed live (server stayed bound to
`127.0.0.1` with both set) and confirmed against the installed package's
own bundled source (no host-binding logic present at all, just a
hardcoded `"localhost"` string in the daemon-mode log line). There's no
authentication on this HTTP transport at all, so this was always going to
be bound to the Incus bridge-local IP only, same policy as the Incus
HTTPS API — never `0.0.0.0`/tailscale/LAN — but it can't even get that far
right now. The provisioning step verifies the daemon actually bound where
asked and exits with an error instead of registering an MCP server
pointing at an address the VM can't reach. Re-check
[github.com/tobi/qmd](https://github.com/tobi/qmd) for a fix before
re-enabling.

### Adding your own

Same pattern for anything else you want: install inside the VM via
`incus exec` in a new numbered step, gate it behind its own `.env` flag,
check for existing state before acting. Verify any third-party MCP
server or plugin independently first (stars/forks/last-commit via the
GitHub API, not just the README) before wiring it into a script meant to
run unattended.

## Files

| File | Purpose |
| --- | --- |
| `.env.example` | Every configurable variable, documented. Copy to `.env` and edit — the script won't run without it. |
| `provision-agent-vm.sh` | Host-side: creates the VM, shares a directory in, optionally wires the Incus remote API. Idempotent. |
| `cloud-init.yaml` | In-guest first-boot: baseline packages (git, node, uv, gh, incus-client), SSH server, sudo group. Edit to add your own extras. |
| `files/guard-hook.py` | The security hook — sudo/git-push/self-edit blocking. |
| `files/claude-settings.json` | Wires the hook into Claude Code's `PreToolUse` events inside the VM. |
| `cleanup-host.sh` | **Run manually, only after verifying the VM works.** Strips agent tooling from the bare host. |

## Verifying it worked

1. `ssh` in, check the shared directory is visible and read/write both
   ways, and that you land in `$WORKSPACE_DEST` by default (`pwd`).
2. If using the remote-API feature: `incus list` (no remote prefix) from
   inside the VM should show the host's instances (proves the remote-API
   wiring, not local socket access) — and any real operation against
   existing host infrastructure (not just listing) should actually reach
   it.
3. Confirm the guardrails: inside the VM, `echo hi && sudo whoami` and
   `git push` should both be denied by Claude Code with a `claude-guard:`
   message; writing to `~/.claude/settings.json` or the project's
   `.claude/` should also be denied.
4. Only then run `./cleanup-host.sh` on the bare host.

## If you're driving existing host-side tooling through the remote API

Any pre-existing script that shells out to bare `incus <subcommand>` (no
remote prefix) will transparently follow whatever the default remote is
set to, so switching the default to the host (step above) is normally all
it takes. Two things to watch for, found while validating this against a
real bench/test-VM workflow:

- Anything that literally hardcodes the `local:` remote (an Incus-reserved
  keyword meaning "this machine's own daemon", not "the default remote")
  will keep targeting the VM's own daemon regardless — which doesn't exist
  here, so those specific calls need the destination parameterized, or need
  to be run once directly on the host to seed whatever they're bootstrapping
  (e.g. a cached base image alias).
- Pre-flight checks that inspect local RAM/disk to decide if there's room
  to proceed will read the *VM's* resources, not the actual host's, since
  they don't know the real work now happens elsewhere. If the tooling you're
  driving has env var overrides for these gates, use them; if you own that
  code, it's worth making those checks remote-aware.
