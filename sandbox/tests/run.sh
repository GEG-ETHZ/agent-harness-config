#!/usr/bin/env bash
# Probe the srt policy: what must be blocked, and what must keep working.
#
# Usage: sandbox/tests/run.sh [policy] [launcher] [wrapper]
#        (defaults: the installed copies in ~/.config/claude-sb/)
#
# Each probe runs through claude-sb-run.mjs, the way claude-sb starts Claude,
# from a throwaway git repo that stands in for "the project". The script exits
# non-zero when anything that must be blocked is not, or when normal work
# does not.
#
# A block only counts when the sandbox says so (EPERM, a proxy 403, ...). A
# probe that fails for another reason, or that fails outside the sandbox
# too, proves nothing and is reported as unclear or skipped.
#
# Hooks and MCP servers need a real Claude Code session; they are checked by
# hand (see sandbox/README.md).

set -uo pipefail

SETTINGS=${1:-$HOME/.config/claude-sb/policy.json}
RUNNER=${2:-$HOME/.config/claude-sb/claude-sb-run.mjs}
WRAPPER=${3:-$HOME/.config/claude-sb/claude-sb.zsh}
NETWORK_TIMEOUT_SECONDS=5
PROBE_ROOT="$HOME/.cache/claude-sb-test"
PROJECT="$PROBE_ROOT/project"
OTHER_PROJECT="$PROBE_ROOT/other-project"
# A private repo the GitHub MCP token can read, as an SSH URL
# (git@github.com:owner/repo.git); fetch and push are probed on it.
PRIVATE_REPO=${CLAUDE_SB_TEST_REPO:-}
SANDBOX_DENIAL='Operation not permitted|response 403|Write access to repository not granted|blocked-by-sandbox|Connection refused|denied|-54|-10822|-600|cannot be opened'

block_failures=0
unclear=0
core_failures=0
skipped=0

setup_project() {
  rm -rf "$PROBE_ROOT"
  mkdir -p "$PROJECT/.claude"
  git -C "$PROJECT" init -q
  printf 'SECRET=probe\n' > "$PROJECT/.env"
  printf 'SECRET=probe\n' > "$PROJECT/.env.local"
  printf 'SECRET=\n' > "$PROJECT/.env.example"
  mkdir -p "$OTHER_PROJECT"
  printf 'SECRET=probe\n' > "$OTHER_PROJECT/.env"
  printf 'print("hello")\n' > "$PROJECT/main.py"
}

# The variables claude-sb sets (uv, fastmcp, git), taken from the wrapper so
# the probes see what a session sees.
wrapper_env() {
  zsh -c 'source "$1" && print -rl -- $_CLAUDE_SB_ENV' _ "$WRAPPER"
}

sandboxed() {
  (cd "$PROJECT" && env "${SESSION_ENV[@]}" node "$RUNNER" "$SRT_DIST" "$SETTINGS" -c "$1") 2>&1
}

# expect_block NAME COMMAND [CLEANUP]: COMMAND must be denied by the sandbox.
# CONTROL_PASSED=1 (set by expect_block_checked) means the command succeeded
# outside, so any failure inside is the sandbox's doing.
expect_block() {
  local output
  if output=$(sandboxed "$2"); then
    printf 'FAIL  block  %s\n' "$1"
    block_failures=$((block_failures + 1))
    [[ -n ${3:-} ]] && eval "$3"
  elif [[ ${CONTROL_PASSED:-0} == 1 ]] || grep -qE "$SANDBOX_DENIAL" <<<"$output"; then
    printf 'ok    block  %s\n' "$1"
  else
    printf '??    block  %s (failed, but not with a sandbox denial: %s)\n' "$1" "${output:0:80}"
    unclear=$((unclear + 1))
  fi
}

# expect_block_checked NAME COMMAND: for side-effect-free probes only. Runs
# COMMAND outside the sandbox first; if it fails there too (path missing,
# macOS privacy prompt, no such host), a block inside proves nothing.
expect_block_checked() {
  if ! (cd "$PROJECT" && bash -c "$2") >/dev/null 2>&1; then
    printf 'skip  block  %s (fails outside the sandbox too)\n' "$1"
    skipped=$((skipped + 1))
    return
  fi
  CONTROL_PASSED=1 expect_block "$1" "$2"
}

# expect_work KIND NAME COMMAND: COMMAND must succeed inside the sandbox.
expect_work() {
  if sandboxed "$3" >/dev/null; then
    printf 'ok    %-6s %s\n' "$1" "$2"
  else
    printf 'FAIL  %-6s %s\n' "$1" "$2"
    core_failures=$((core_failures + 1))
  fi
}

reachable() {
  printf 'curl -sS -o /dev/null -m %s %s' "$NETWORK_TIMEOUT_SECONDS" "$1"
}

if ! command -v srt >/dev/null 2>&1; then
  echo "srt not found: npm i -g @anthropic-ai/sandbox-runtime@0.0.79" >&2
  exit 2
fi
[[ -r $SETTINGS ]] || { echo "no policy at $SETTINGS" >&2; exit 2; }
[[ -r $RUNNER ]] || { echo "no launcher at $RUNNER" >&2; exit 2; }
[[ -r $WRAPPER ]] || { echo "no wrapper at $WRAPPER" >&2; exit 2; }
# Probes run from the throwaway project, so relative paths would break there.
SETTINGS=$(realpath "$SETTINGS")
RUNNER=$(realpath "$RUNNER")
SESSION_ENV=()
while IFS= read -r line; do SESSION_ENV+=("$line"); done < <(wrapper_env)
(( ${#SESSION_ENV[@]} > 0 )) || { echo "no session variables from $WRAPPER" >&2; exit 2; }
SRT_DIST=$(cd "$(dirname "$(readlink -f "$(command -v srt)")")" && pwd)

setup_project
echo "policy: $SETTINGS"
echo "launcher: $RUNNER"
echo "project: $PROJECT"

# Canary: if srt cannot start (bad policy, broken install), every block probe
# would "pass". Stop here instead.
if ! canary=$(sandboxed 'echo canary'); then
  echo "srt does not start with this policy:" >&2
  echo "$canary" >&2
  exit 2
fi
echo

echo "-- credentials and private folders are unreadable"
# The Keychain probes only count if `security` runs inside at all. gh does
# not start inside by design (~/.config/gh is closed), so its probe needs none.
expect_work core "security runs inside"        'security list-keychains >/dev/null'
expect_block_checked "read ~/.ssh"              'ls ~/.ssh'
expect_block_checked "read ~/.config/gcloud"    'ls ~/.config/gcloud'
expect_block_checked "read ~/.aws"              'ls ~/.aws'
expect_block_checked "read .env in project"     'cat .env'
expect_block_checked "read .env.local"          'cat .env.local'
expect_block_checked "read .env in another project" "cat $OTHER_PROJECT/.env"
expect_work core "read .env.example"           'cat .env.example'
expect_block_checked "read ~/Documents"         'ls ~/Documents'
expect_block_checked "read ~/Downloads"         'ls ~/Downloads'
expect_block_checked "read ~/Desktop"           'ls ~/Desktop'
expect_block_checked "read Mail"                'ls ~/Library/Mail'
expect_block_checked "read browser cookies"     'ls ~/Library/Cookies'
expect_block_checked "read shell history"       'cat ~/.zsh_history >/dev/null'
expect_work core "npm runs (~/.npmrc closed)" 'npm config get registry >/dev/null'
expect_block_checked "read the gh token (Keychain)" \
  'security find-generic-password -s gh:github.com -w >/dev/null'
expect_block_checked "read Claude's login (Keychain)" \
  'security find-generic-password -s "Claude Code-credentials" -w >/dev/null'
expect_block_checked "use the gh login"         'gh api user >/dev/null'

echo "-- nothing outside the project changes"
expect_block "append to ~/.zshrc"           ': >> ~/.zshrc'
expect_block "append to ~/.zprofile"        ': >> ~/.zprofile'
expect_block "edit Claude settings"         ': >> ~/.claude/settings.json'
expect_block "edit a hook script"          ': >> ~/.claude/scripts/hooks/block-no-verify.js'
expect_block "write a user rule"           'touch ~/.claude/rules/srt-probe.md' 'rm -f ~/.claude/rules/srt-probe.md'
expect_block "write a user skill"          'mkdir -p ~/.claude/skills/srt-probe' 'rm -rf ~/.claude/skills/srt-probe'
expect_block "edit the sandbox policy"      ': >> ~/.config/claude-sb/policy.json'
expect_block "write a dotfile in ~"         'touch ~/.srt-probe' 'rm -f ~/.srt-probe'
expect_block "brew/npm -g (/opt/homebrew)"  'touch /opt/homebrew/.srt-probe' \
  'rm -f /opt/homebrew/.srt-probe'
expect_block "pip --user (~/Library/Python)" 'mkdir -p ~/Library/Python/.srt-probe' \
  'rmdir ~/Library/Python/.srt-probe'
expect_block "uv tool / pipx (~/.local)"    'mkdir -p ~/.local/.srt-probe' \
  'rmdir ~/.local/.srt-probe'
expect_block "login item (~/Library/LaunchAgents)" 'touch ~/Library/LaunchAgents/srt-probe.plist' \
  'rm -f ~/Library/LaunchAgents/srt-probe.plist'
expect_block_checked "run sudo (setuid)"    '/usr/bin/sudo --version'
expect_block "launch an app (open)"         'open -g -j /System/Applications/Calculator.app' \
  'osascript -e "quit app \"Calculator\"" 2>/dev/null'

echo "-- project files srt itself always protects"
expect_block "write .git/hooks"             'touch .git/hooks/pre-commit'
expect_block "write .git/config"            ': >> .git/config'
expect_block "write .vscode (tasks.json)"   'mkdir -p .vscode'

echo "-- normal work"
expect_work core "write a file in the project" 'echo x > notes.txt'
expect_work core "git add + commit"            'git add main.py && git -c user.name=probe -c user.email=probe@example.invalid commit -qm probe'
expect_work core "run python"                  'python3 main.py'
expect_work core "write AGENTS.md / CLAUDE.md" 'echo x > AGENTS.md && echo x > CLAUDE.md'
expect_work core "write .claude/settings.json" 'echo "{}" > .claude/settings.json'
expect_work core "write .github/workflows"     'mkdir -p .github/workflows'
expect_work core "write Claude history"        ': >> ~/.claude/history.jsonl'
expect_work core "write Claude memory"         'mkdir -p ~/.claude/projects/srt-probe/memory && touch ~/.claude/projects/srt-probe/memory/x && rm -rf ~/.claude/projects/srt-probe'
expect_work core "read another project"        'ls ~/projects >/dev/null'
expect_work core "uv run in project"           'uv run --no-project python3 main.py'
expect_work core "Anthropic API reachable"     "$(reachable https://api.anthropic.com)"
expect_work core "any website reachable"       "$(reachable https://example.com)"
expect_work core "GitHub API reachable"        "$(reachable https://api.github.com)"
expect_work core "PyPI reachable"              "$(reachable https://pypi.org/simple/)"
expect_work core "npm registry reachable"      "$(reachable https://registry.npmjs.org/)"
# Go checks TLS through trustd, not a CA file like curl. A dummy token gets a
# 401 from GitHub, which needs a verified TLS connection first.
expect_work core "Go TLS (gh api, GitHub MCP)" \
  'GH_CONFIG_DIR=/tmp/claude-sb-gh GH_TOKEN=dummy gh api /zen 2>&1 | grep -q "Bad credentials"'

echo "-- GitHub through git (the MCP token: read code, never write)"
if [[ -z ${GITHUB_PERSONAL_ACCESS_TOKEN:-} || -z $PRIVATE_REPO ]]; then
  printf 'skip  core   git fetch / push probes (GITHUB_PERSONAL_ACCESS_TOKEN or CLAUDE_SB_TEST_REPO not set)\n'
  skipped=$((skipped + 1))
else
  expect_work core "git fetch a private repo (SSH URL)" "git ls-remote $PRIVATE_REPO HEAD >/dev/null"
  expect_block "git push (token must not write code)" \
    "git push --dry-run $PRIVATE_REPO HEAD:refs/heads/claude-sb-probe"
fi

rm -rf "$PROBE_ROOT"

echo
echo "holes: $block_failures   unclear: $unclear   core broken: $core_failures   skipped: $skipped"
(( block_failures == 0 && unclear == 0 && core_failures == 0 ))
