#!/usr/bin/env bash
# Install the supervisor + subagent Claude Code architecture at user scope
# (~/.claude), so it applies to every project on this machine.
#
# Usage:  ./install-home.sh
# Safe to re-run: existing files are backed up before being touched.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
STAMP="$(date +%Y%m%d-%H%M%S)"

backup() {
  if [ -e "$1" ]; then
    cp -r "$1" "$1.bak-${STAMP}"
    echo "  backed up $1 -> $1.bak-${STAMP}"
  fi
}

echo "Installing supervisor + agent architecture into ${CLAUDE_DIR}"
mkdir -p "${CLAUDE_DIR}/agents"

# 1. Agents (user scope: available in all projects). Their memory stays
#    project-scoped (.claude/agent-memory/ in whichever repo you work in).
for agent in scout planner implementer reviewer; do
  src="${REPO_DIR}/.claude/agents/${agent}.md"
  dst="${CLAUDE_DIR}/agents/${agent}.md"
  backup "$dst"
  cp "$src" "$dst"
  echo "  installed agent: ${agent}"
done

# 2. Supervisor manual as its own file, imported from user CLAUDE.md so we
#    never clobber your existing global instructions.
cp "${REPO_DIR}/CLAUDE.md" "${CLAUDE_DIR}/supervisor.md"
echo "  installed ${CLAUDE_DIR}/supervisor.md"

IMPORT_LINE="@supervisor.md"
if [ -f "${CLAUDE_DIR}/CLAUDE.md" ]; then
  if ! grep -qxF "${IMPORT_LINE}" "${CLAUDE_DIR}/CLAUDE.md"; then
    backup "${CLAUDE_DIR}/CLAUDE.md"
    printf '\n%s\n' "${IMPORT_LINE}" >> "${CLAUDE_DIR}/CLAUDE.md"
    echo "  added '${IMPORT_LINE}' import to existing user CLAUDE.md"
  else
    echo "  user CLAUDE.md already imports supervisor.md — skipped"
  fi
else
  printf '%s\n' "${IMPORT_LINE}" > "${CLAUDE_DIR}/CLAUDE.md"
  echo "  created ${CLAUDE_DIR}/CLAUDE.md with supervisor import"
fi

# 3. Settings: enable auto agent memory at user scope. Merged with jq when
#    available so nothing you already configured is lost.
SETTINGS="${CLAUDE_DIR}/settings.json"
if command -v jq >/dev/null 2>&1; then
  backup "$SETTINGS"
  if [ -f "$SETTINGS" ]; then
    jq '.autoMemoryEnabled = true' "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
  else
    printf '{\n  "autoMemoryEnabled": true\n}\n' > "$SETTINGS"
  fi
  echo "  set autoMemoryEnabled=true in ${SETTINGS}"
elif [ ! -f "$SETTINGS" ]; then
  printf '{\n  "autoMemoryEnabled": true\n}\n' > "$SETTINGS"
  echo "  created ${SETTINGS} with autoMemoryEnabled=true"
else
  echo "  NOTE: jq not found and ${SETTINGS} exists — add \"autoMemoryEnabled\": true to it manually."
fi

echo
echo "Done. Restart Claude Code (or start a new session) and check with /agents:"
echo "  scout · planner · implementer · reviewer"
echo "Per-project agent memory will appear in each repo under .claude/agent-memory/."
