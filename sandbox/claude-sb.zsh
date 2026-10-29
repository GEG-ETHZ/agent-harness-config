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
# (~/projects) would quietly hand over all of it.
_CLAUDE_SB_MIN_DEPTH_UNDER_HOME=2
_CLAUDE_SB_MIN_DEPTH_OUTSIDE_HOME=3
# Folders under ~ that policy.json closes for reading: a project there would
# be writable but unreadable.
_CLAUDE_SB_UNREADABLE_UNDER_HOME=(Documents Desktop Downloads Pictures Movies Music)
# Outside ~, only these roots may hold a project. Anything else (/opt/homebrew,
# /usr/local, /Applications) holds programs that run later, outside the sandbox.
_CLAUDE_SB_ROOTS_OUTSIDE_HOME=(/Volumes /private/tmp)
_CLAUDE_SB_DIR="$HOME/.config/claude-sb"
_CLAUDE_SB_POLICY="$_CLAUDE_SB_DIR/policy.json"
# Your own additions, merged over policy.json by the launcher (see README.md,
# "Add exceptions"). Optional; never copied from the repo.
_CLAUDE_SB_LOCAL_POLICY="$_CLAUDE_SB_DIR/policy.local.json"
_CLAUDE_SB_RUNNER="$_CLAUDE_SB_DIR/claude-sb-run.mjs"
# Tells the agent what the sandbox blocks and what to do instead of working
# around a block; added only to sandboxed sessions, so plain claude pays no
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

# With the network open, srt allows every socket, local ones included: the
# ssh-agent would sign with your keys although ~/.ssh is closed, and a Docker
# socket would let a container mount ~. Removing the variables stops tools
# from finding them; it does not hide the sockets from a deliberate search.
_CLAUDE_SB_UNSET=(SSH_AUTH_SOCK SSH_AGENT_PID DOCKER_HOST)

# Settings for every sandboxed session: Claude Code's own Bash sandbox off, and
# two hooks. SessionStart prints CLAUDE_SB_GUIDANCE, which Claude Code adds to
# the context on start, /clear and /compact. Not --append-system-prompt-file:
# the VS Code extension sends its own appended prompt, which replaces that one
# (extension 2.1.312). UserPromptSubmit prints CLAUDE_SB_SESSION_MESSAGE (JSON,
# set by the launcher) on the first prompt. Its systemMessage shows in the
# terminal and the VS Code panel alike; a SessionStart hook's message does not
# reach the panel. A marker file per Claude process ($PPID) in /tmp, writable
# in both profiles, keeps it to the first prompt.
_CLAUDE_SB_SETTINGS='{"sandbox":{"enabled":false},"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"cat \"$CLAUDE_SB_GUIDANCE\""}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"f=/tmp/claude-sb-shown.$PPID; [ -e \"$f\" ] && exit 0; : > \"$f\"; printf %s \"$CLAUDE_SB_SESSION_MESSAGE\""}]}]}}'

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
    if (( ${_CLAUDE_SB_UNREADABLE_UNDER_HOME[(Ie)${rel%%/*}]} )); then
      print -u2 "claude-sb: ~/${rel%%/*} is closed for reading inside the sandbox, so the agent could not read this project."
      print -u2 "  Move the project out of it, e.g. to ~/projects."
      return 1
    fi
    if (( $(_claude_sb_depth "/$rel") < _CLAUDE_SB_MIN_DEPTH_UNDER_HOME )); then
      print -u2 "claude-sb: ${dir/#$home/~} is too broad: it holds more than one project."
      print -u2 "  Open a single project folder first, e.g.:  cd ${dir/#$home/~}/my-project"
      return 1
    fi
  else
    local root inside_root=0
    for root in $_CLAUDE_SB_ROOTS_OUTSIDE_HOME; do
      [[ $dir == $root/* ]] && inside_root=1
    done
    if (( ! inside_root )); then
      print -u2 "claude-sb: $dir is a system folder. Projects outside ~ must be under: ${(j:, :)_CLAUDE_SB_ROOTS_OUTSIDE_HOME}"
      return 1
    fi
    if (( $(_claude_sb_depth "$dir") < _CLAUDE_SB_MIN_DEPTH_OUTSIDE_HOME )); then
      print -u2 "claude-sb: $dir is too broad. Open a single project folder first."
      return 1
    fi
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

# _claude_sb_launch CLAUDE [ARGS...]: start CLAUDE (a command, as quoted words)
# inside the sandbox with ARGS. A session also gets the flags every sandboxed
# session needs; a subcommand (`auth status`, `mcp list`: ARGS starting with a
# word, not an option) runs in the sandbox as it is, since it accepts none of
# them. Shared by claude-sb (terminal) and claude-sb-vscode (VS Code).
_claude_sb_launch() {
  # (z) splits into shell words, (Q) removes the quoting ${(q)...} added.
  local -a claude_cmd=("${(@Q)${(z)1}}")
  shift
  # Only a fine-grained token (github_pat_) can be limited to Contents: read.
  # Any other kind (classic ghp_, the gh CLI's OAuth gho_) can push from
  # inside, and do everything else the token allows.
  local github_token=${GITHUB_PERSONAL_ACCESS_TOKEN:-}
  if [[ -n $github_token && $github_token != github_pat_* ]]; then
    print -u2 "claude-sb: GITHUB_PERSONAL_ACCESS_TOKEN is not a fine-grained token (it starts with ${github_token[1,4]}), so it may push code."
    print -u2 "  Use a fine-grained token with Contents: read (see sandbox/README.md, Set up)."
    return 1
  fi
  if ! command -v srt >/dev/null 2>&1; then
    print -u2 "claude-sb: srt not found. In agent-harness-config, run: make sandbox-install"
    return 1
  fi
  local file
  for file in $_CLAUDE_SB_POLICY $_CLAUDE_SB_RUNNER $_CLAUDE_SB_GUIDANCE; do
    if [[ ! -r $file ]]; then
      print -u2 "claude-sb: missing ${file/#$HOME/~} (see sandbox/README.md, Set up)"
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

  local -a local_args
  local profile=supervised network=open
  if [[ -r $_CLAUDE_SB_LOCAL_POLICY ]]; then
    local_args=(--local "$_CLAUDE_SB_LOCAL_POLICY")
    profile=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).extends || "supervised")' \
      "$_CLAUDE_SB_LOCAL_POLICY" 2>/dev/null) || profile="invalid policy.local.json"
    profile+=" + policy.local.json"
  fi
  node "$_CLAUDE_SB_RUNNER" --print "$_CLAUDE_SB_POLICY" $local_args 2>/dev/null | grep -q '"network"' \
    && network=filtered

  local sb_status="sandboxed ($profile): writes -> ${project/#${HOME:A}/~}, network -> $network"
  print -u2 "$sb_status"
  # As a JSON string: backslashes and quotes in the project path escaped.
  local sb_json=${${sb_status//\\/\\\\}//\"/\\\"}

  # A Seatbelt sandbox cannot start another one inside, so Claude Code's own
  # Bash sandbox is switched off for this session; srt already covers Bash.
  # The prompt hook shows the status line in the session itself, where
  # the VS Code panel shows no terminal output: a chat without it did not go
  # through claude-sb. The start hook gives Claude the guidance.
  # Updates write outside the sandbox, so they are left to plain `claude`.
  local -a unset_args session_args
  local name
  for name in $_CLAUDE_SB_UNSET; do unset_args+=(-u $name); done
  if [[ $# -eq 0 || $1 == -* ]]; then
    session_args=(--settings "$_CLAUDE_SB_SETTINGS")
  fi
  env $unset_args $_CLAUDE_SB_ENV \
    CLAUDE_CODE_OAUTH_TOKEN="$token" DISABLE_AUTOUPDATER=1 \
    CLAUDE_SB_SESSION_MESSAGE="{\"systemMessage\":\"claude-sb: $sb_json\"}" \
    CLAUDE_SB_GUIDANCE="$_CLAUDE_SB_GUIDANCE" \
    node "$_CLAUDE_SB_RUNNER" "$srt_dist" "$_CLAUDE_SB_POLICY" $local_args -- \
    $claude_cmd $session_args "$@"
}

claude-sb() {
  if [[ $# -gt 0 && $1 != -* ]]; then
    _claude_sb_launch claude "$@"
  else
    _claude_sb_launch claude --permission-mode auto "$@"
  fi
}

# The VS Code extension runs claudeCode.claudeProcessWrapper with the path of
# the CLI it bundles as the first argument, followed by its own arguments,
# --permission-mode among them, so none is added here (seen with extension
# 2.1.310; not documented, CLAUDE_SB_DEBUG=1 logs what arrives).
claude-sb-vscode() {
  local claude=claude
  if [[ -n ${1:-} && -f $1 && ${1:t} == claude* ]]; then
    claude=${(q)1}
    shift
  elif [[ -n ${1:-} && -f $1 && $1 == *.js ]]; then
    claude="node ${(q)1}"
    shift
  fi
  if [[ -n ${CLAUDE_SB_DEBUG:-} ]]; then
    print -r -- "$(date '+%F %T') cwd=$PWD claude=$claude args=${(q-)@}" >> "${TMPDIR:-/tmp}/claude-sb-vscode.log"
  fi
  _claude_sb_launch "$claude" "$@"
}
