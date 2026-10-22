# claude-sb: Claude Code inside sandbox-runtime (srt), whole process.
#
# MCP servers and hooks are child processes of claude, so they run inside the
# sandbox too. This profile is for supervised use: a human watches the
# session, so it guards against overreach (changes outside the project, use of
# credentials), not against a manipulated agent. The network is open.
#
# The policy and claude-sb-run.mjs live in ~/.config/claude-sb/, copied from
# sandbox/ in agent-harness-config, like this file; source the copy from
# ~/.zshrc (see sandbox/README.md). Sourcing it from the repo would let an
# agent working there change the code every new shell runs.

# The policy grants writes to ".", so the folder claude-sb starts in is the
# folder the agent may change. Starting in ~ or a folder directly under it
# (~/Documents, ~/Desktop, ~/projects) would quietly hand over all of it.
_CLAUDE_SB_MIN_DEPTH_UNDER_HOME=2
_CLAUDE_SB_MIN_DEPTH_OUTSIDE_HOME=3
_CLAUDE_SB_DIR="$HOME/.config/claude-sb"
_CLAUDE_SB_POLICY="$_CLAUDE_SB_DIR/policy.json"
_CLAUDE_SB_RUNNER="$_CLAUDE_SB_DIR/claude-sb-run.mjs"
# Tells the agent what the sandbox blocks and what to do instead of working
# around a block; passed only to sandboxed sessions, so plain claude pays no
# context for it.
_CLAUDE_SB_GUIDANCE="$_CLAUDE_SB_DIR/agent-guidance.md"

# The Keychain is closed to the sandbox: with it open, `security` inside could
# read every item it is allowed to, the gh token included. Claude logs in
# with a long-lived token from `claude setup-token` instead, fetched here,
# outside the sandbox, from its own Keychain item.
_CLAUDE_SB_TOKEN_SERVICE="claude-sb-oauth"

# MCP servers get their tokens from the shell as usual (GitHub, Confluence,
# Jira). Their tool calls show in the session and go through auto mode's
# checks, so a watching person sees what the agent does with them.
#
# Two variables keep MCP servers working inside the sandbox:
# - uvx takes a lock in its tool folder (~/.local/share/uv/tools), which is
#   closed so that `uv tool install` cannot install globally; uvx gets its
#   own tool folder in the cache instead.
# - fastmcp-based servers read .env from the project folder and crash when
#   the sandbox denies it, instead of skipping it.
#
# git reaches GitHub with the GitHub MCP token, over HTTPS. That token may
# read code but not write it, so fetch and clone work (private repos too) and
# GitHub itself refuses a push. The settings go in as GIT_CONFIG_* variables,
# so ~/.gitconfig and plain claude are untouched:
# - the helper list is cleared first; osxkeychain cannot reach the Keychain;
# - the helper hands git the token, read when git asks, not now;
# - SSH remotes (git@github.com:...) go over HTTPS, since ~/.ssh is closed.
# If the token ever gets Contents: write, push works too; tests/run.sh checks.
_CLAUDE_SB_GIT_HELPER='!f() { echo username=x-access-token; echo "password=$GITHUB_PERSONAL_ACCESS_TOKEN"; }; f'
_CLAUDE_SB_ENV=(UV_TOOL_DIR="$HOME/.cache/claude-sb/uv-tools"
  FASTMCP_ENV_FILE=/dev/null
  GIT_CONFIG_COUNT=4
  GIT_CONFIG_KEY_0=credential.https://github.com.helper GIT_CONFIG_VALUE_0=
  GIT_CONFIG_KEY_1=credential.https://github.com.helper GIT_CONFIG_VALUE_1="$_CLAUDE_SB_GIT_HELPER"
  GIT_CONFIG_KEY_2=url.https://github.com/.insteadOf GIT_CONFIG_VALUE_2=git@github.com:
  GIT_CONFIG_KEY_3=url.https://github.com/.insteadOf GIT_CONFIG_VALUE_3=ssh://git@github.com/)

_claude_sb_depth() {
  # Number of path components in $1 ("/a/b" -> 2).
  local -a parts
  parts=("${(@s:/:)1}")
  print -r -- ${#${parts:#}}
}

_claude_sb_check_folder() {
  local dir=$1
  local home=${HOME:A}
  if [[ $dir == "$home" || $dir == / ]]; then
    print -u2 "claude-sb: not starting in ${dir/#$home/~}."
    print -u2 "  The agent may change everything in the folder it starts in."
    print -u2 "  Open your project folder first, e.g.:  cd ~/projects/my-thesis"
    return 1
  fi
  if [[ $dir == $home/* ]]; then
    local rel=${dir#$home/}
    # Hidden folders and ~/Library hold configuration and login items
    # (~/.ssh, ~/.config, ~/Library/LaunchAgents), never a project.
    if [[ /$rel == */.* || $rel == Library || $rel == Library/* ]]; then
      print -u2 "claude-sb: ${dir/#$home/~} is a settings folder, not a project. Open a project folder first."
      return 1
    fi
    if (( $(_claude_sb_depth "/$rel") < _CLAUDE_SB_MIN_DEPTH_UNDER_HOME )); then
      print -u2 "claude-sb: ${dir/#$home/~} is too broad: it holds more than one project."
      print -u2 "  Open a single project folder first, e.g.:  cd ${dir/#$home/~}/my-project"
      return 1
    fi
  elif (( $(_claude_sb_depth "$dir") < _CLAUDE_SB_MIN_DEPTH_OUTSIDE_HOME )); then
    print -u2 "claude-sb: $dir is a system-level folder. Open a project folder first."
    return 1
  fi
  return 0
}

_claude_sb_token() {
  security find-generic-password -s "$_CLAUDE_SB_TOKEN_SERVICE" -a "$USER" -w 2>/dev/null && return 0
  print -u2 "claude-sb: no login token yet. Set it up once:"
  print -u2 "  1. claude setup-token        (copy the token it prints)"
  print -u2 "  2. security add-generic-password -U -s $_CLAUDE_SB_TOKEN_SERVICE -a \"\$USER\" -w"
  print -u2 "     (paste the token at the prompt; it never lands in your shell history)"
  return 1
}

claude-sb() {
  if ! command -v srt >/dev/null 2>&1; then
    print -u2 "claude-sb: srt not found. Install it with:"
    print -u2 "  npm i -g @anthropic-ai/sandbox-runtime@0.0.79"
    return 1
  fi
  local file
  for file in $_CLAUDE_SB_POLICY $_CLAUDE_SB_RUNNER $_CLAUDE_SB_GUIDANCE; do
    if [[ ! -r $file ]]; then
      print -u2 "claude-sb: missing ${file/#$HOME/~} (see sandbox/README.md, Install)"
      return 1
    fi
  done
  # The srt command is a link into the package; the launcher needs its dist/.
  local srt_dist=${$(command -v srt):A:h}
  # :A resolves symlinks, so a link to ~ cannot pass for a project folder;
  # srt itself resolves "." to the real path.
  local project=${PWD:A}
  _claude_sb_check_folder "$project" || return 1
  local token
  token=$(_claude_sb_token) || return 1

  print -u2 "sandboxed: writes -> ${project/#${HOME:A}/~}, network -> open (exit and run 'claude' for unsandboxed work)"

  # A Seatbelt sandbox cannot start another one inside, so Claude Code's own
  # Bash sandbox is switched off for this session; srt already covers Bash.
  # Updates write outside the sandbox, so they are left to plain `claude`.
  env $_CLAUDE_SB_ENV \
    CLAUDE_CODE_OAUTH_TOKEN="$token" DISABLE_AUTOUPDATER=1 \
    node "$_CLAUDE_SB_RUNNER" "$srt_dist" "$_CLAUDE_SB_POLICY" -- \
    claude --permission-mode auto --settings '{"sandbox":{"enabled":false}}' \
    --append-system-prompt-file "$_CLAUDE_SB_GUIDANCE" "$@"
}
