#!/bin/bash
# Removes AI-agent tooling from the BARE HOST once the agent VM (see
# provision-agent-vm.sh) has been verified working end to end. Deliberately
# NOT run automatically by the provisioning script -- run this yourself,
# only after confirming:
#   1. You can SSH/Remote-SSH into the agent VM and use `claude` there.
#   2. Whatever real workflow you rely on works from inside the VM (e.g.
#      if using the remote-API feature: `incus remote switch host` and a
#      real operation against existing host infrastructure succeeds).
#   3. The guard/hook.py guardrails (sudo, git push, .claude self-edit)
#      still block those actions inside the VM.
#
# Leaves Incus and Docker installed -- anything using the VM's remote-API
# access to the host depends on them.
set -euo pipefail

read -r -p "This will remove Claude Code, zcode, sandbox-runtime, ripgrep, and ~/.claude from THIS machine. Continue? [y/N] " CONFIRM
if [ "${CONFIRM,,}" != "y" ]; then
  echo "Aborted."
  exit 1
fi

echo "-- removing npm-installed agent tooling --"
npm uninstall -g @anthropic-ai/claude-code 2>/dev/null || true
npm uninstall -g @anthropic-ai/sandbox-runtime 2>/dev/null || true

echo "-- removing zcode --"
sudo apt-get remove -y zcode 2>/dev/null || true
rm -rf "$HOME/.zcode"

echo "-- removing ripgrep (installed this session only for sandbox-runtime testing) --"
sudo apt-get remove -y ripgrep 2>/dev/null || true

echo "-- removing Claude Code config/guardrails --"
rm -rf "$HOME/.claude" "$HOME/.claude.json"

echo "-- removing sandbox-runtime settings --"
rm -f "$HOME/.srt-settings.json"

echo
echo "Done. Incus and Docker were left untouched (the agent VM's remote-API"
echo "access to the host depends on them, if you're using that feature)."
echo "Use the agent VM for all agentic coding work from now on."
