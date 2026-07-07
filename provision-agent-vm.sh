#!/bin/bash
# Provisions a dedicated Incus VM to host AI coding agents (Claude Code CLI),
# with a slice of the host filesystem shared in via virtiofs, real kernel-
# level isolation from the host, and -- optionally -- the ability to drive
# VM/container creation on the host itself over Incus's remote HTTPS API.
# That last part matters if your workflow needs the agent to spin up test
# VMs, sandboxes, or other Incus-managed infrastructure that needs real
# host privileges (KVM, storage pools) the isolated VM deliberately
# doesn't have: the agent VM never touches those directly, it just talks
# to the host's already-running Incus daemon over the network, the same
# way any tooling that shells out to bare `incus` commands already does --
# no code changes needed on that side, it just needs to be pointed at the
# host as its default remote instead of the local socket.
#
# Safe to re-run: each step checks for existing state before acting.
#
# Requires: Incus already installed and working on this host (this script
# does not provision Incus itself).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found." >&2
  echo "Copy .env.example to .env, adjust it for your setup, and re-run:" >&2
  echo "  cp $SCRIPT_DIR/.env.example $ENV_FILE" >&2
  exit 1
fi

set -a
# shellcheck source=.env.example
source "$ENV_FILE"
set +a

# ---- configuration -------------------------------------------------------
# Values come from .env; fall back to these only for anything it leaves
# unset (partial/older .env files).
VM_NAME="${VM_NAME:-agent-vm}"
BASE_IMAGE_ALIAS="${BASE_IMAGE_ALIAS:-agent-vm-base}"
BASE_IMAGE_REMOTE="${BASE_IMAGE_REMOTE:-images:debian/13/cloud}"
VM_CPU="${VM_CPU:-4}"
VM_MEMORY="${VM_MEMORY:-8GiB}"
VM_DISK="${VM_DISK:-40GiB}"
VM_STORAGE_POOL="${VM_STORAGE_POOL:-default}"
# Defaults to the parent directory of this script -- drop the agent-vm/
# directory at the root of whatever you want shared into the VM, or set
# WORKSPACE_SRC in .env to share something else.
WORKSPACE_SRC="${WORKSPACE_SRC:-$(cd "$SCRIPT_DIR/.." && pwd)}"
WORKSPACE_DEST="${WORKSPACE_DEST:-/mnt/workspace}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/agent_vm_ed25519}"
REMOTE_NAME="${REMOTE_NAME:-host}"
GUEST_USER="debian"  # default user baked into images:debian/13/cloud

echo "== agent VM provisioning =="
echo "VM name:        $VM_NAME"
echo "Workspace src:  $WORKSPACE_SRC -> $WORKSPACE_DEST"
echo

# ---- 1. base image -------------------------------------------------------
if ! incus image info "$BASE_IMAGE_ALIAS" >/dev/null 2>&1; then
  echo "-- caching $BASE_IMAGE_REMOTE as $BASE_IMAGE_ALIAS (--vm) --"
  incus image copy "$BASE_IMAGE_REMOTE" local: --vm --alias "$BASE_IMAGE_ALIAS" --auto-update
else
  echo "-- base image $BASE_IMAGE_ALIAS already cached, skipping --"
fi

# ---- 2. SSH keypair for VM access ---------------------------------------
if [ ! -f "$SSH_KEY_PATH" ]; then
  echo "-- generating dedicated SSH keypair at $SSH_KEY_PATH --"
  ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -C "$VM_NAME" >/dev/null
else
  echo "-- SSH key $SSH_KEY_PATH already exists, reusing --"
fi
PUBKEY="$(cat "${SSH_KEY_PATH}.pub")"

# ---- 3. cloud-init user-data (static file + this run's pubkey) ----------
# Plain text templating rather than a YAML library dependency: the static
# file is trusted/authored by us, so appending a top-level
# `ssh_authorized_keys:` block is safe and keeps this script dependency-free.
CLOUD_INIT_RENDERED="$(mktemp)"
trap 'rm -f "$CLOUD_INIT_RENDERED"' EXIT
cp "$SCRIPT_DIR/cloud-init.yaml" "$CLOUD_INIT_RENDERED"
{
  echo ""
  echo "ssh_authorized_keys:"
  echo "  - $PUBKEY"
} >> "$CLOUD_INIT_RENDERED"

# ---- 4. create the VM, not started yet (idempotent) ----------------------
if incus info "$VM_NAME" >/dev/null 2>&1; then
  echo "-- VM $VM_NAME already exists, skipping create --"
else
  echo "-- creating $VM_NAME (not starting yet) --"
  incus init "$BASE_IMAGE_ALIAS" "$VM_NAME" --vm \
    -c limits.cpu="$VM_CPU" \
    -c limits.memory="$VM_MEMORY" \
    -c "cloud-init.user-data=$(cat "$CLOUD_INIT_RENDERED")" \
    -d root,size="$VM_DISK" \
    -d root,pool="$VM_STORAGE_POOL"
fi

# ---- 5. virtiofs workspace share (idempotent) ----------------------------
# Added while the VM is stopped (cold-plug), not to an already-running
# instance: hot-plugging a virtiofs device into a live QEMU process can
# race the VM's own PCI bus setup and fail with "PCI: slot 0 function 0
# not available for vhost-user-fs-pci" -- confirmed live, it's timing-
# dependent, not deterministic. Cold-plugging avoids the race since QEMU
# allocates every configured device's slot in one coherent boot sequence.
if incus config device show "$VM_NAME" 2>/dev/null | grep -q '^workspace:'; then
  echo "-- workspace share device already present, skipping --"
else
  echo "-- adding virtiofs share $WORKSPACE_SRC -> $WORKSPACE_DEST --"
  incus config device add "$VM_NAME" workspace disk source="$WORKSPACE_SRC" path="$WORKSPACE_DEST"
fi

# ---- 6. start the VM (idempotent) ----------------------------------------
if [ "$(incus list "$VM_NAME" -f csv -c s)" = "RUNNING" ]; then
  echo "-- $VM_NAME already running, skipping start --"
else
  echo "-- starting $VM_NAME --"
  incus start "$VM_NAME"
fi

# ---- 7. wait for boot -----------------------------------------------------
echo "-- waiting for $VM_NAME to become reachable --"
for _ in $(seq 1 60); do
  incus exec "$VM_NAME" -- test -f /var/lib/cloud/agent-vm-bootstrap-done 2>/dev/null && break
  sleep 5
done
incus exec "$VM_NAME" -- test -f /var/lib/cloud/agent-vm-bootstrap-done \
  || { echo "ERROR: cloud-init bootstrap did not complete in time"; exit 1; }
echo "-- cloud-init bootstrap complete --"

# ---- 8. push the security guardrails ------------------------------------
echo "-- pushing guard/hook.py + settings.json --"
incus exec "$VM_NAME" -- mkdir -p "/home/$GUEST_USER/.claude/guard"
incus file push "$SCRIPT_DIR/files/guard-hook.py" "$VM_NAME/home/$GUEST_USER/.claude/guard/hook.py"
incus file push "$SCRIPT_DIR/files/claude-settings.json" "$VM_NAME/home/$GUEST_USER/.claude/settings.json"
incus exec "$VM_NAME" -- chmod 755 "/home/$GUEST_USER/.claude/guard/hook.py"
incus exec "$VM_NAME" -- chown -R "$GUEST_USER:$GUEST_USER" "/home/$GUEST_USER/.claude"

# ---- 8b. permanent bypassPermissions wrapper (idempotent) ----------------
# permissions.defaultMode in settings.json (set above) is unreliable for
# *interactive* sessions -- confirmed live: correct at both user and
# project scope, VM restarted fresh 3x, still prompted. Works fine for
# non-interactive -p invocations, not interactive ones. The CLI flag
# --permission-mode bypassPermissions is what actually holds (confirmed
# live originally). A PATH-shadowing wrapper in ~/.local/bin (ahead of
# /usr/bin in PATH) applies it regardless of how claude gets launched --
# interactive shell, VS Code spawning it, anything doing a PATH lookup --
# unlike a .bashrc alias, which only covers interactive shell invocations.
if incus exec "$VM_NAME" -- test -f "/home/$GUEST_USER/.local/bin/claude" 2>/dev/null; then
  echo "-- bypassPermissions wrapper already present, skipping --"
else
  echo "-- installing PATH-shadowing wrapper for permanent bypassPermissions --"
  WRAPPER_TMP="$(mktemp)"
  {
    echo '#!/bin/bash'
    echo 'exec /usr/bin/claude --permission-mode bypassPermissions "$@"'
  } > "$WRAPPER_TMP"
  incus exec "$VM_NAME" -- mkdir -p "/home/$GUEST_USER/.local/bin"
  incus file push "$WRAPPER_TMP" "$VM_NAME/home/$GUEST_USER/.local/bin/claude"
  incus exec "$VM_NAME" -- chmod +x "/home/$GUEST_USER/.local/bin/claude"
  incus exec "$VM_NAME" -- chown "$GUEST_USER:$GUEST_USER" "/home/$GUEST_USER/.local/bin/claude"
  rm -f "$WRAPPER_TMP"
fi

# ---- 8c. VS Code extension bypassPermissions (idempotent) ----------------
# The Claude Code VS Code extension spawns its own bundled binary directly
# (~/.vscode-server/extensions/anthropic.claude-code-*/resources/native-
# binary/claude, confirmed live via ps aux) and hardcodes
# --permission-mode acceptEdits as a launch arg -- beats settings.json and
# the PATH wrapper above entirely, since it never goes through PATH.
# claudeCode.initialPermissionMode in VS Code's *remote-machine-scoped*
# settings.json overrides that hardcoded flag. This is genuinely VM-side
# (~/.vscode-server/data/Machine/settings.json), not client-side -- easy
# to assume otherwise since the UI calls it "Remote [SSH: hostname]"
# scope, but the file lives on the VM, confirmed live. Still requires a
# one-time manual step this script can't do: enabling "Allow dangerously
# skip permissions" in the extension's settings panel (client-side UI
# toggle, no equivalent file to script).
VSCODE_MACHINE_SETTINGS="/home/$GUEST_USER/.vscode-server/data/Machine/settings.json"
if incus exec "$VM_NAME" -- test -f "$VSCODE_MACHINE_SETTINGS" 2>/dev/null; then
  echo "-- VS Code machine settings.json already exists, leaving as-is --"
  echo "   (verify it has claudeCode.initialPermissionMode: bypassPermissions)"
else
  echo "-- writing VS Code machine-scoped claudeCode.initialPermissionMode --"
  VSCODE_SETTINGS_TMP="$(mktemp)"
  {
    echo '{'
    echo '  "claudeCode.initialPermissionMode": "bypassPermissions"'
    echo '}'
  } > "$VSCODE_SETTINGS_TMP"
  incus exec "$VM_NAME" -- mkdir -p "/home/$GUEST_USER/.vscode-server/data/Machine"
  incus file push "$VSCODE_SETTINGS_TMP" "$VM_NAME$VSCODE_MACHINE_SETTINGS"
  incus exec "$VM_NAME" -- chown "$GUEST_USER:$GUEST_USER" "$VSCODE_MACHINE_SETTINGS"
  rm -f "$VSCODE_SETTINGS_TMP"
  echo "   Still needed once, manually in VS Code: enable 'Allow dangerously"
  echo "   skip permissions' in the Claude Code extension settings panel,"
  echo "   then reload window."
fi

# ---- 9. land interactive shells in the workspace by default (idempotent) -
# Claude Code's session/project history is keyed by the absolute cwd it was
# started from -- landing anywhere else (e.g. $HOME over a bare SSH login)
# silently starts a fresh, historyless project instead of resuming. This
# covers plain `ssh` logins and VS Code's integrated terminal (both source
# .bashrc); it does NOT auto-pick VS Code's Remote-SSH *workspace folder* on
# first connect -- that still needs one manual "Open Folder" to
# $WORKSPACE_DEST, after which VS Code remembers it per host.
WORKSPACE_CD_LINE=$(printf '[ -n "$PS1" ] && [ -d "%s" ] && cd "%s"' "$WORKSPACE_DEST" "$WORKSPACE_DEST")
if incus exec "$VM_NAME" -- grep -qxF "$WORKSPACE_CD_LINE" "/home/$GUEST_USER/.bashrc" 2>/dev/null; then
  echo "-- .bashrc already lands new shells in $WORKSPACE_DEST, skipping --"
else
  echo "-- landing interactive shells in $WORKSPACE_DEST by default --"
  incus exec "$VM_NAME" -- su - "$GUEST_USER" -c "printf '%s\n' '$WORKSPACE_CD_LINE' >> ~/.bashrc"
fi

# ---- 10. wire the Incus remote API back to the host ----------------------
BRIDGE="$(incus profile device get default eth0 network)"
BRIDGE_IP="$(incus network get "$BRIDGE" ipv4.address | cut -d/ -f1)"
echo "-- host bridge: $BRIDGE ($BRIDGE_IP) --"

CURRENT_HTTPS_ADDR="$(incus config get core.https_address || true)"
if [ "$CURRENT_HTTPS_ADDR" != "$BRIDGE_IP:8443" ]; then
  echo "-- binding Incus HTTPS API to $BRIDGE_IP:8443 (bridge-local only) --"
  incus config set core.https_address="$BRIDGE_IP:8443"
else
  echo "-- Incus HTTPS API already bound to $BRIDGE_IP:8443, skipping --"
fi

if ! incus exec "$VM_NAME" -- test -f "/home/$GUEST_USER/.config/incus/client.crt" 2>/dev/null; then
  echo "-- generating VM's Incus client certificate --"
  # `remote list` is a local, no-network operation and does NOT generate a
  # client keypair. Only an actual `remote add` attempt does, as a side
  # effect of trying to authenticate -- confirmed live. Uses a throwaway
  # remote name so it can't collide with the real add below, and removes
  # whatever partial entry it left behind. `</dev/null`: without an
  # explicit redirect this can land on an interactive "Trust token for
  # host:" prompt and hang forever on whatever stdin the script inherited
  # (a real terminal never sends EOF) -- confirmed live, this is what
  # "stuck on generating client certificate" actually was. Closing stdin
  # makes it fail fast instead.
  incus exec "$VM_NAME" -- su - "$GUEST_USER" -c \
    "incus remote add _certgen $BRIDGE_IP:8443 --accept-certificate --auth-type=tls --token=''" </dev/null >/dev/null 2>&1 || true
  incus exec "$VM_NAME" -- su - "$GUEST_USER" -c "incus remote remove _certgen >/dev/null 2>&1" || true
fi

# Compare the VM's *current* cert fingerprint against what's actually
# trusted under this name -- not just whether the name exists. After an
# `incus delete` + recreate, the new VM gets a brand-new client cert but
# the old trust entry (same name, stale fingerprint) is still sitting
# there; a name-only check silently "skips" re-trusting, leaving the new
# cert never actually trusted -- confirmed live: this is what made the
# subsequent `remote add host` below fall back to an interactive
# trust-token prompt (real cert unrecognized) and hang on the same
# unredirected-stdin issue.
VM_CERT_TMP="$(mktemp)"
incus file pull "$VM_NAME/home/$GUEST_USER/.config/incus/client.crt" "$VM_CERT_TMP"
CURRENT_FP="$(openssl x509 -in "$VM_CERT_TMP" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f' | cut -c1-12)"
TRUSTED_FP="$(incus config trust list -f csv 2>/dev/null | grep "^${VM_NAME}-vm," | cut -d',' -f4)" || true
if [ "$CURRENT_FP" = "$TRUSTED_FP" ]; then
  echo "-- VM client cert already trusted, skipping --"
else
  if [ -n "$TRUSTED_FP" ]; then
    echo "-- removing stale trust entry for ${VM_NAME}-vm (cert changed since last trust) --"
    incus config trust remove "$TRUSTED_FP"
  fi
  echo "-- trusting VM's client certificate --"
  incus config trust add-certificate "$VM_CERT_TMP" --name "${VM_NAME}-vm"
fi
rm -f "$VM_CERT_TMP"

if incus exec "$VM_NAME" -- su - "$GUEST_USER" -c "incus remote list -f csv" 2>/dev/null \
    | cut -d',' -f1 | grep -qE "^${REMOTE_NAME}( \(current\))?\$"; then
  echo "-- VM already has remote '$REMOTE_NAME', skipping add --"
else
  echo "-- adding host as remote '$REMOTE_NAME' from inside the VM --"
  incus exec "$VM_NAME" -- su - "$GUEST_USER" -c "incus remote add $REMOTE_NAME $BRIDGE_IP:8443 --accept-certificate" </dev/null
fi
incus exec "$VM_NAME" -- su - "$GUEST_USER" -c "incus remote switch $REMOTE_NAME"

# ---- 11. optional read-only gh/git auth (idempotent) ---------------------
# GH_TOKEN, if set in .env, should be a fine-grained PAT scoped Read-only --
# see .env.example for why classic PATs can't do this for private repos.
# Piped via stdin (not a -c argument) so it never appears in `ps` output on
# either host or guest. Persists to the guest's own gh/git config, so this
# holds regardless of shell type (interactive or not) -- unlike an env var
# that would only reach interactive shells via .bashrc.
if [ -n "${GH_TOKEN:-}" ]; then
  if incus exec "$VM_NAME" -- su - "$GUEST_USER" -c "gh auth status" >/dev/null 2>&1; then
    echo "-- gh already authenticated in the VM, skipping --"
  else
    echo "-- authenticating gh (and git, via setup-git) with the provided token --"
    incus exec "$VM_NAME" -- su - "$GUEST_USER" -c "gh auth login --hostname github.com --with-token" <<< "$GH_TOKEN"
    incus exec "$VM_NAME" -- su - "$GUEST_USER" -c "gh auth setup-git"
  fi
fi

# ---- 12. optional token-savior MCP (idempotent) ---------------------------
# github.com/Mibayy/token-savior -- verified live (1.1k stars, actively
# maintained). Gives the agent structural code-navigation/memory tools in
# place of the raw grep/find/Glob the guard hook's deny list blocks. NOT
# the same project as github.com/awesomo913/Claude-Token-Saver (unrelated,
# much smaller, similarly-named repo) -- confirmed by checking both
# directly rather than assuming a name match.
#
# WORKSPACE_ROOTS is documented as a comma-separated list of *individual*
# project roots, not one parent directory -- pointing it at $WORKSPACE_DEST
# alone (a single non-git parent containing sibling repos) left the agent
# effectively stuck on one active project at a time, unable to browse
# across repos without an explicit switch -- confirmed live. Discovered
# dynamically (each immediate child of $WORKSPACE_DEST containing a `.git`)
# rather than hardcoded, since a static repo list goes stale exactly like
# this workspace's own CLAUDE.md did (still says 6 repos; there are 12).
if [ "${INSTALL_TOKEN_SAVIOR:-0}" = "1" ]; then
  if incus exec "$VM_NAME" -- su - "$GUEST_USER" -c "test -x ~/.local/bin/token-savior" 2>/dev/null; then
    echo "-- token-savior already installed, skipping --"
  else
    echo "-- installing token-savior-recall via uv --"
    incus exec "$VM_NAME" -- su - "$GUEST_USER" -c "uv tool install 'token-savior-recall[mcp]'"
  fi
  WORKSPACE_ROOTS_LIST="$(incus exec "$VM_NAME" -- su - "$GUEST_USER" -c \
    "for d in $WORKSPACE_DEST/*/; do [ -e \"\${d}.git\" ] && printf '%s,' \"\${d%/}\"; done")"
  WORKSPACE_ROOTS_LIST="${WORKSPACE_ROOTS_LIST%,}"
  WORKSPACE_ROOTS_LIST="${WORKSPACE_ROOTS_LIST:-$WORKSPACE_DEST}"
  if incus exec "$VM_NAME" -- su - "$GUEST_USER" -c "claude mcp list" 2>/dev/null | grep -q "^token-savior:"; then
    echo "-- token-savior MCP server already registered, skipping (re-run with a removed"
    echo "   registration if the repo list has changed since it was added) --"
  else
    echo "-- registering token-savior as a user-scoped MCP server ($(echo "$WORKSPACE_ROOTS_LIST" | tr ',' '\n' | wc -l) roots) --"
    incus exec "$VM_NAME" -- su - "$GUEST_USER" -c \
      "claude mcp add token-savior -s user -e WORKSPACE_ROOTS=$WORKSPACE_ROOTS_LIST -e TOKEN_SAVIOR_CLIENT=claude-code -- token-savior"
  fi
fi

# ---- 13. optional caveman plugin (idempotent) -----------------------------
# github.com/JuliusBrussee/caveman -- verified live via the GitHub API
# directly (85.7k stars, 4.7k forks, not just the README's own claims).
# Installed through Claude Code's first-party plugin-marketplace
# mechanism, deliberately not the project's own `curl | bash` installer
# (which auto-detects and modifies every agent's config on the machine --
# broader reach than wanted here, and not something to run unexamined).
# Confirmed live this does not touch settings.json's hooks/defaultMode.
if [ "${INSTALL_CAVEMAN:-0}" = "1" ]; then
  if incus exec "$VM_NAME" -- su - "$GUEST_USER" -c "claude plugin list" 2>/dev/null | grep -q "caveman@caveman"; then
    echo "-- caveman plugin already installed, skipping --"
  else
    echo "-- adding caveman marketplace and installing the plugin --"
    incus exec "$VM_NAME" -- su - "$GUEST_USER" -c "claude plugin marketplace add JuliusBrussee/caveman"
    incus exec "$VM_NAME" -- su - "$GUEST_USER" -c "claude plugin install caveman"
  fi
fi

# ---- 14. optional qmd remote bridge (idempotent) --------------------------
# github.com/tobi/qmd (@tobilu/qmd on npm/bun) -- semantic + BM25 search
# with AST chunking, no per-line size limit (unlike token-savior, which
# chokes reading lines over ~100k chars). Complements token-savior rather
# than replacing it: token-savior for code-symbol navigation, qmd for
# large/single-line files and its own indexed collections.
#
# Runs as a server on the HOST, not installed in the VM: qmd's embedding
# model is GPU-accelerated (verified live against the host's actual
# install: CUDA, 530MB index) and this VM deliberately has no GPU
# passthrough. Reinstalling qmd + re-embedding the whole workspace on VM
# CPU alone would be slow and would duplicate an index that already
# exists. Same remote-API shape as the Incus bridge above: the VM is a
# thin client, the host does the heavy lifting.
#
# No authentication exists on qmd's HTTP transport (confirmed against its
# own docs) -- bound to the bridge-local IP only, same as Incus's HTTPS
# API, never 0.0.0.0/tailscale/LAN.
#
# KNOWN BUG as of @tobilu/qmd 2.1.0: `--host`/`QMD_HOST` are documented but
# do not actually change the bind address -- confirmed live (both tested
# directly, server still bound to 127.0.0.1 either way) and confirmed
# against the installed package's own bundled source (no host/bind
# configuration logic present at all, just a hardcoded "localhost" in the
# daemon-mode log line). Until that's fixed upstream, this step verifies
# the daemon actually bound where asked and fails loudly rather than
# registering an MCP server pointing at an address the VM can't reach.
if [ "${INSTALL_QMD_REMOTE:-0}" = "1" ]; then
  QMD_HTTP_PORT="${QMD_HTTP_PORT:-8181}"
  if ! command -v qmd >/dev/null 2>&1; then
    echo "ERROR: INSTALL_QMD_REMOTE=1 but 'qmd' isn't on this host's PATH." >&2
    echo "Install it on the host first (github.com/tobi/qmd), then re-run." >&2
    exit 1
  fi
  QMD_PID_FILE="$HOME/.cache/qmd/mcp.pid"
  if [ -f "$QMD_PID_FILE" ] && kill -0 "$(cat "$QMD_PID_FILE")" 2>/dev/null; then
    echo "-- qmd HTTP daemon already running on the host, skipping start --"
  else
    echo "-- starting qmd HTTP daemon on the host, bound to $BRIDGE_IP:$QMD_HTTP_PORT --"
    qmd mcp --http --host "$BRIDGE_IP" --port "$QMD_HTTP_PORT" --daemon
    sleep 1
  fi
  if ! ss -tln 2>/dev/null | grep -q "${BRIDGE_IP}:${QMD_HTTP_PORT} "; then
    echo "ERROR: qmd did not bind to $BRIDGE_IP:$QMD_HTTP_PORT (see comment above --" >&2
    echo "known upstream bug where --host/QMD_HOST is ignored). Not registering" >&2
    echo "an MCP server that would just fail to connect. Check 'qmd mcp stop'" >&2
    echo "and https://github.com/tobi/qmd for a fix before retrying." >&2
    exit 1
  fi
  if incus exec "$VM_NAME" -- su - "$GUEST_USER" -c "claude mcp list" 2>/dev/null | grep -q "^qmd:"; then
    echo "-- qmd MCP server already registered in the VM, skipping --"
  else
    echo "-- registering the host's qmd server as an MCP server in the VM --"
    incus exec "$VM_NAME" -- su - "$GUEST_USER" -c \
      "claude mcp add --transport http qmd http://$BRIDGE_IP:$QMD_HTTP_PORT/mcp -s user"
  fi
fi

echo
echo "== done =="
echo "SSH in with:  ssh -i $SSH_KEY_PATH $GUEST_USER@$(incus list "$VM_NAME" -f csv -c 4 | cut -d' ' -f1)"
echo "VS Code:      Remote-SSH using the same key/host, then run 'claude' in its terminal."
echo "Remote check: from inside the VM, 'incus list' should show the host's instances."
