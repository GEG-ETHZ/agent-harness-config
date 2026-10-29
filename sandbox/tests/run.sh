#!/usr/bin/env bash
# Probe the srt policy: what must be blocked, and what must keep working.
#
# Usage: sandbox/tests/run.sh [policy] [launcher] [wrapper]
#        (defaults: the installed copies in ~/.config/claude-sb/)
#        CLAUDE_SB_TEST_REPO=git@github.com:owner/private-repo.git also probes
#        git fetch and push.
#        Your personal policy (~/.config/claude-sb/policy.local.json, or
#        CLAUDE_SB_LOCAL_POLICY) is merged in, as claude-sb does; with a network
#        block in it, hosts outside its allowedDomains must be blocked. With
#        "extends": "strict", the work that needs an exception of your own
#        (other projects, uv, npm, GitHub) is only reported, as "info".
#
# Each probe runs through claude-sb-run.mjs, the way claude-sb starts Claude,
# from a throwaway project that stands in for "the project". The script exits
# non-zero when anything that must be blocked is not, or when normal work
# does not.
#
# A block only counts when the sandbox says so ("Operation not permitted"). A
# probe that fails for another reason, or that fails outside the sandbox too,
# proves nothing and is reported as unclear or skipped.
#
# The block probes target real paths in ~ (~/.zshrc, ~/.claude, ~/Library,
# /opt/homebrew), because that is what the policy protects. They only append
# nothing (": >>") or create a probe file, and remove what they created when a
# block fails. The throwaway project is removed on exit, Ctrl+C included.
#
# Hooks and MCP servers need a real Claude Code session; they are checked by
# hand (see sandbox/README.md).

set -uo pipefail

SETTINGS=${1:-$HOME/.config/claude-sb/policy.json}
RUNNER=${2:-$HOME/.config/claude-sb/claude-sb-run.mjs}
WRAPPER=${3:-$HOME/.config/claude-sb/claude-sb.zsh}
LOCAL_POLICY=${CLAUDE_SB_LOCAL_POLICY:-$HOME/.config/claude-sb/policy.local.json}
NETWORK_TIMEOUT_SECONDS=5
# A private repo the GitHub MCP token can read, as an SSH URL
# (git@github.com:owner/repo.git); fetch and push are probed on it.
PRIVATE_REPO=${CLAUDE_SB_TEST_REPO:-}
SANDBOX_DENIAL='Operation not permitted'
# With a network filter, srt's proxy refuses a host outside allowedDomains.
PROXY_DENIAL='response 403|Operation not permitted|Could not resolve|Failed to connect'
# Launching an app fails with a Launch Services error code instead.
LAUNCH_DENIAL='Operation not permitted|-54|-10822|-600|cannot be opened'
# git push is refused by GitHub, not by the sandbox.
PUSH_DENIAL='Write access to repository not granted|denied to|error: 403'

block_failures=0
unclear=0
core_failures=0
skipped=0
untested=()

# The throwaway project lives under ~ in a folder the policy does not open
# for writing, so "write in the project" only passes through the "." rule.
PROBE_ROOT=""
cleanup() { [[ -n $PROBE_ROOT ]] && rm -rf "$PROBE_ROOT"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

setup_project() {
  PROBE_ROOT=$(mktemp -d "$HOME/.claude-sb-test.XXXXXX") || exit 2
  PROJECT="$PROBE_ROOT/project"
  OTHER_PROJECT="$PROBE_ROOT/other-project"
  # The test project's folder in ~/.claude/projects, named as Claude Code does.
  PROJECT_KEY=$(printf '%s' "$PROJECT" | sed 's/[^A-Za-z0-9]/-/g')
  mkdir -p "$PROJECT/.claude" "$OTHER_PROJECT"
  git -C "$PROJECT" init -q
  printf 'SECRET=probe\n' > "$PROJECT/.env"
  printf 'SECRET=probe\n' > "$PROJECT/.env.local"
  printf 'SECRET=\n' > "$PROJECT/.env.example"
  printf 'print("hello")\n' > "$PROJECT/main.py"
  printf 'SECRET=probe\n' > "$OTHER_PROJECT/.env"
  printf 'readme\n' > "$OTHER_PROJECT/README.md"
}

# The variables claude-sb sets (uv, fastmcp, git), taken from the wrapper so
# the probes see what a session sees.
wrapper_env() {
  zsh -c 'source "$1" && print -rl -- $_CLAUDE_SB_ENV' _ "$WRAPPER"
}

# The variables claude-sb removes (ssh-agent, Docker), as `env -u` arguments.
wrapper_unset() {
  zsh -c 'source "$1" && for n in $_CLAUDE_SB_UNSET; do print -rl -- -u $n; done' _ "$WRAPPER"
}

# start_folder_ok PATH: does the wrapper's folder check let claude-sb start there?
start_folder_ok() {
  zsh -c 'source "$1" && _claude_sb_check_folder "$2"' _ "$WRAPPER" "$1" 2>/dev/null
}

sandboxed() {
  (cd "$PROJECT" && env "${UNSET_ARGS[@]}" "${SESSION_ENV[@]}" \
    node "$RUNNER" "$SRT_DIST" "$SETTINGS" ${LOCAL_ARGS[@]+"${LOCAL_ARGS[@]}"} -c "$1") 2>&1
}

# expect_block NAME COMMAND [CLEANUP]: COMMAND must be denied by the sandbox.
# DENIAL overrides the message that counts as a denial. CONTROL_PASSED=1 (set
# by expect_block_checked) means the command succeeded outside, so any failure
# inside is the sandbox's doing.
expect_block() {
  local output
  if output=$(sandboxed "$2"); then
    printf 'FAIL  block  %s\n' "$1"
    block_failures=$((block_failures + 1))
    [[ -n ${3:-} ]] && eval "$3"
  elif [[ ${CONTROL_PASSED:-0} == 1 ]] || grep -qE "${DENIAL:-$SANDBOX_DENIAL}" <<<"$output"; then
    printf 'ok    block  %s\n' "$1"
  else
    printf '??    block  %s (failed, but not with a sandbox denial: %s)\n' "$1" "${output:0:80}"
    unclear=$((unclear + 1))
  fi
}

# expect_block_checked NAME COMMAND: for side-effect-free probes only. Runs
# COMMAND outside the sandbox first; if it fails there too (path missing,
# macOS privacy protection, no such host), a block inside proves nothing.
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

# expect_profile_work NAME COMMAND: normal work the supervised profile allows,
# and the strict one only with an exception of your own. Must work in the
# supervised profile; in the strict one, reported as info either way.
expect_profile_work() {
  if [[ $PROFILE != strict ]]; then
    expect_work core "$1" "$2"
  elif sandboxed "$2" >/dev/null; then
    printf 'info  works  %s\n' "$1"
  else
    printf 'info  closed %s (add an exception if you need it)\n' "$1"
  fi
}

# expect_start start|refuse PATH: the wrapper's folder check.
expect_start() {
  local result=refuse
  start_folder_ok "$2" && result=start
  if [[ $result == "$1" ]]; then
    printf 'ok    start  %s %s\n' "$1" "${2/#$HOME/~}"
  else
    printf 'FAIL  start  %s %s\n' "$1" "${2/#$HOME/~}"
    core_failures=$((core_failures + 1))
  fi
}

# remove_if_created PATH: a cleanup for an append probe (": >> PATH"). If the
# block fails and PATH did not exist, the append created it empty; remove it
# then, and leave a file that has content alone.
remove_if_created() {
  printf '[[ -s %q ]] || rm -f %q' "$1" "$1"
}

reachable() {
  printf 'curl -sS -o /dev/null -m %s %s' "$NETWORK_TIMEOUT_SECONDS" "$1"
}

# host_allowed HOST: is HOST in the effective policy's allowedDomains
# (exact, or under a "*." pattern)? Only asked when the network is filtered.
host_allowed() {
  node -e '
    const [policy, host] = [JSON.parse(process.argv[1]), process.argv[2]];
    const allowed = (policy.network.allowedDomains || []).map((d) => d.replace(/:\d+$/, ""));
    const ok = allowed.some((d) => d === host || (d.startsWith("*.") && host.endsWith(d.slice(1))));
    process.exit(ok ? 0 : 1);' "$EFFECTIVE" "$1"
}

# expect_host NAME HOST URL: reachable with the network open, or when the
# filter allows HOST; blocked when the filter does not.
expect_host() {
  if [[ $NETWORK != filtered ]] || host_allowed "$2"; then
    expect_work core "$1" "$(reachable "$3")"
  else
    DENIAL=$PROXY_DENIAL expect_block "$1 (not in allowedDomains)" "$(reachable "$3")"
  fi
}

if ! command -v srt >/dev/null 2>&1; then
  echo "srt not found: run 'make sandbox-install'" >&2
  exit 2
fi
[[ -r $SETTINGS ]] || { echo "no policy at $SETTINGS" >&2; exit 2; }
[[ -r $RUNNER ]] || { echo "no launcher at $RUNNER" >&2; exit 2; }
[[ -r $WRAPPER ]] || { echo "no wrapper at $WRAPPER" >&2; exit 2; }
# Probes run from the throwaway project, so relative paths would break there.
SETTINGS=$(realpath "$SETTINGS")
RUNNER=$(realpath "$RUNNER")
WRAPPER=$(realpath "$WRAPPER")
SESSION_ENV=()
while IFS= read -r line; do SESSION_ENV+=("$line"); done < <(wrapper_env)
(( ${#SESSION_ENV[@]} > 0 )) || { echo "no session variables from $WRAPPER" >&2; exit 2; }
UNSET_ARGS=()
while IFS= read -r line; do UNSET_ARGS+=("$line"); done < <(wrapper_unset)
SRT_DIST=$(cd "$(dirname "$(readlink -f "$(command -v srt)")")" && pwd)
LOCAL_ARGS=()
[[ -r $LOCAL_POLICY ]] && LOCAL_ARGS=(--local "$(realpath "$LOCAL_POLICY")")
EFFECTIVE=$(node "$RUNNER" --print "$SETTINGS" ${LOCAL_ARGS[@]+"${LOCAL_ARGS[@]}"}) || exit 2
PROFILE=supervised
if (( ${#LOCAL_ARGS[@]} > 0 )); then
  PROFILE=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).extends || "supervised")' \
    "${LOCAL_ARGS[1]}") || exit 2
fi
NETWORK=open
grep -q '"network"' <<<"$EFFECTIVE" && NETWORK=filtered

setup_project
echo "policy: $SETTINGS"
echo "personal policy: ${LOCAL_ARGS[1]:-none}"
echo "profile: $PROFILE"
echo "network: $NETWORK"
echo "launcher: $RUNNER"
echo "project: $PROJECT"

# Canary: if srt cannot start (bad policy, wrong srt version, broken install),
# every block probe would "pass". Stop here instead.
if ! canary=$(sandboxed 'echo canary'); then
  echo "srt does not start with this policy:" >&2
  echo "$canary" >&2
  exit 2
fi
echo

echo "-- credentials and private folders are unreadable"
# The Keychain probes only count if `security` runs inside at all. gh does
# not start inside by design (~/.config/gh is closed), so its probe needs none.
expect_profile_work "security runs inside"   'security list-keychains >/dev/null'
expect_block_checked "read ~/.ssh"              'ls ~/.ssh'
expect_block_checked "read ~/.config/gcloud"    'ls ~/.config/gcloud'
expect_block_checked "read ~/.aws"              'ls ~/.aws'
expect_block_checked "read .env in project"     'cat .env'
expect_block_checked "read .env.local"          'cat .env.local'
expect_block_checked "read .env in another project" "cat $OTHER_PROJECT/.env"
expect_work core "read .env.example"           'cat .env.example'
expect_block_checked "read shell history"       'cat ~/.zsh_history >/dev/null'
expect_block_checked "read Terminal session history" 'ls ~/.zsh_sessions >/dev/null'
# macOS itself protects Documents, Desktop, Downloads, Mail and Cookies from a
# terminal without Full Disk Access, so those probes are often skipped.
# Pictures and Movies are closed by the same kind of rule and are not
# protected by macOS, so they show whether the rule works.
expect_block_checked "read ~/Pictures"          'ls ~/Pictures'
expect_block_checked "read ~/Movies"            'ls ~/Movies'
expect_block_checked "read ~/Documents"         'ls ~/Documents'
expect_block_checked "read ~/Downloads"         'ls ~/Downloads'
expect_block_checked "read ~/Desktop"           'ls ~/Desktop'
expect_block_checked "read Mail"                'ls ~/Library/Mail'
expect_block_checked "read browser cookies"     'ls ~/Library/Cookies'
expect_block_checked "use the ssh-agent"        'ssh-add -l >/dev/null'
expect_profile_work "npm runs (~/.npmrc closed)" 'npm config get registry >/dev/null'
expect_block_checked "read the gh token (Keychain)" \
  'security find-generic-password -s gh:github.com -w >/dev/null'
expect_block_checked "read Claude's login (Keychain)" \
  'security find-generic-password -s "Claude Code-credentials" -w >/dev/null'
expect_block_checked "use the gh login"         'gh api user >/dev/null'

echo "-- nothing outside the project changes"
expect_block "write another project"        "touch $OTHER_PROJECT/srt-probe" \
  "rm -f $OTHER_PROJECT/srt-probe"
expect_block "append to ~/.zshrc"           ': >> ~/.zshrc' \
  "$(remove_if_created ~/.zshrc)"
expect_block "append to ~/.zprofile"        ': >> ~/.zprofile' \
  "$(remove_if_created ~/.zprofile)"
expect_block "edit Claude settings"         ': >> ~/.claude/settings.json' \
  "$(remove_if_created ~/.claude/settings.json)"
expect_block "delete VS Code's lock files"  'mkdir -p ~/.claude/ide && touch ~/.claude/ide/srt-probe.lock' \
  'rm -f ~/.claude/ide/srt-probe.lock'
expect_block "edit a hook script"           ': >> ~/.claude/scripts/hooks/block-no-verify.js' \
  "$(remove_if_created ~/.claude/scripts/hooks/block-no-verify.js)"
expect_block "install a Claude plugin"      'mkdir -p ~/.claude/plugins/srt-probe' \
  'rmdir ~/.claude/plugins/srt-probe'
expect_block "write a user rule"            'touch ~/.claude/rules/srt-probe.md' \
  'rm -f ~/.claude/rules/srt-probe.md'
expect_block "write a user skill"           'mkdir -p ~/.claude/skills/srt-probe' \
  'rm -rf ~/.claude/skills/srt-probe'
expect_block "edit the sandbox policy"      ': >> ~/.config/claude-sb/policy.json' \
  "$(remove_if_created ~/.config/claude-sb/policy.json)"
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
DENIAL=$LAUNCH_DENIAL expect_block "launch an app (open)" \
  'open -g -j /System/Applications/Calculator.app' \
  'osascript -e "quit app \"Calculator\"" 2>/dev/null'

if [[ $PROFILE == strict ]]; then
  echo "-- strict: ~ is closed, the caches and other projects' Claude state too"
  expect_block_checked "read a folder in ~ not reopened" "ls $PROBE_ROOT"
  expect_block "write a cache (~/.cache)"   'mkdir -p ~/.cache/srt-probe' 'rmdir ~/.cache/srt-probe'
  expect_block "write the npm cache"       'mkdir -p ~/.npm/srt-probe' 'rmdir ~/.npm/srt-probe'
  expect_block_checked "read the shell startup files" 'cat ~/.zprofile ~/.zshrc'
  expect_block_checked "read other projects' Claude transcripts" 'ls ~/.claude/projects/*/'
  expect_block "write another project's Claude memory" \
    'mkdir -p ~/.claude/projects/srt-probe' 'rmdir ~/.claude/projects/srt-probe'
  expect_block_checked "read Claude's login file" 'cat ~/.claude/.credentials.json'
  # TODO: probe loopback (127.0.0.0/8, ::1) and link-local in strict. A probe
  # only counts against a listener started outside the sandbox, one that
  # answers there; a closed port fails outside too and proves nothing.
fi

echo "-- claude-sb starts only in a single project folder"
expect_start refuse "$HOME"
expect_start refuse "$HOME/projects"
expect_start start  "$HOME/projects/example"
expect_start refuse "$HOME/Documents/example"
expect_start refuse "$HOME/.config/example"
expect_start refuse /opt/homebrew/bin
expect_start refuse /usr/local/bin
expect_start start  /Volumes/Disk/example

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
expect_work core "write Claude memory"         "mkdir -p ~/.claude/projects/$PROJECT_KEY/memory && touch ~/.claude/projects/$PROJECT_KEY/memory/x && rm -rf ~/.claude/projects/$PROJECT_KEY"
expect_profile_work "read another project"   "cat $OTHER_PROJECT/README.md"
expect_profile_work "uv run in project"      'uv run --no-project python3 main.py'
expect_host "Anthropic API reachable"  api.anthropic.com    https://api.anthropic.com
expect_host "any website reachable"    example.com          https://example.com
expect_host "GitHub API reachable"     api.github.com       https://api.github.com
expect_host "PyPI reachable"           pypi.org             https://pypi.org/simple/
expect_host "npm registry reachable"   registry.npmjs.org   https://registry.npmjs.org/
# Go checks TLS through trustd, not a CA file like curl. A dummy token gets a
# 401 from GitHub, which needs a verified TLS connection first.
expect_profile_work "Go TLS (gh api, GitHub MCP)" \
  'GH_CONFIG_DIR=/tmp/claude-sb-gh GH_TOKEN=dummy gh api /zen 2>&1 | grep -q "Bad credentials"'

echo "-- GitHub through git (the MCP token: read code, never write)"
if [[ -z ${GITHUB_PERSONAL_ACCESS_TOKEN:-} || -z $PRIVATE_REPO ]]; then
  printf 'skip  core   git fetch / push probes (GITHUB_PERSONAL_ACCESS_TOKEN or CLAUDE_SB_TEST_REPO not set)\n'
  skipped=$((skipped + 1))
  untested+=("git push is refused")
else
  expect_profile_work "git fetch a private repo (SSH URL)" "git ls-remote $PRIVATE_REPO HEAD >/dev/null"
  DENIAL="$PUSH_DENIAL|$PROXY_DENIAL" expect_block "git push (token must not write code)" \
    "git push --dry-run $PRIVATE_REPO HEAD:refs/heads/claude-sb-probe"
fi

echo
echo "holes: $block_failures   unclear: $unclear   core broken: $core_failures   skipped: $skipped"
# ${a[@]+...}: an empty array is "unbound" under set -u in macOS's bash 3.2.
for claim in ${untested[@]+"${untested[@]}"}; do
  echo "WARNING: not tested: $claim. Set CLAUDE_SB_TEST_REPO and run again." >&2
done
(( block_failures == 0 && unclear == 0 && core_failures == 0 ))
