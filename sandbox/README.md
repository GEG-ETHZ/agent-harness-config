# claude-sb: Claude Code in a sandbox

`claude-sb` runs the whole Claude Code process inside Anthropic's
[`sandbox-runtime`](https://github.com/anthropics/sandbox-runtime) (`srt`), so
MCP servers, hooks and every Bash command share one boundary set by macOS. It
is for **supervised use**: you watch the session, and the sandbox stops the
agent from changing things outside the project or using your logins. That is
what lets the session run in `auto` permission mode. Plain `claude` is
unchanged.

## Install (once)

In a normal terminal, not inside `claude-sb`, from the root of this repo:

```bash
make sandbox-install
claude setup-token     # prints a long-lived login token
security add-generic-password -U -s claude-sb-oauth -a "$USER" -w   # paste it
```

`make sandbox-install` installs the `srt` version the launcher is pinned to,
copies the files to `~/.config/claude-sb/`, and adds the line that loads
`claude-sb` to `~/.zshrc`. Running it again only adds what is missing. The
sandbox cannot use the Keychain, so `claude-sb` fetches the login token before
it starts the sandbox and passes it to Claude Code.

The files are copied, not linked: an agent working in this repo must not be
able to change its own live policy, or the code every new shell runs. After
changing one of them here, run `make sandbox-install` again and open a new
terminal; `make doctor` reports an installed copy that is out of date.

## Use

```bash
cd ~/projects/my-project
claude-sb
```

It starts only in a single project folder, because the agent may change
everything in the folder it starts in. It refuses `~` and folders directly
under it (`~/projects`), hidden folders, `~/Library`, the folders the policy
closes for reading (`~/Documents`, `~/Desktop`, `~/Downloads`, ...), and, outside
`~`, anything not under `/Volumes` or `/private/tmp` (`/opt/homebrew/bin` or
`/usr/local` hold programs that run later, outside the sandbox).

## Use in VS Code

1. Open VS Code's settings file: Cmd+Shift+P, "Preferences: Open User
   Settings (JSON)".
2. Add this line, with the full path; `~` does not work there:

   ```json
   "claudeCode.claudeProcessWrapper": "/Users/<you>/.config/claude-sb/claude-sb-vscode"
   ```

3. Reload the window: Cmd+Shift+P, "Developer: Reload Window".

Every chat in the Claude Code panel now runs in the sandbox, with the same
policy and start-folder rules as `claude-sb`. Pick the permission mode in the
panel as usual. To go back, remove the line and reload.

The extension starts the wrapper with the path of the Claude Code it bundles as
the first argument, then its own options, including the permission mode; it
also runs `auth status`, which runs in the sandbox without the session flags.
This is not documented and was checked with extension 2.1.310, so a later
version may change it. The wrapper runs as a login shell (`zsh -l`), because
VS Code started from the Dock does not have your terminal's `PATH`; `node`,
`srt` and your tokens must come from `~/.zprofile`. The extension notes two
side effects of any wrapper: plan mode is not restored when a conversation is
resumed, and the "conversation still open" check is skipped.

If the panel does not start, set `CLAUDE_SB_DEBUG` for the Claude process in
VS Code's settings and read `$TMPDIR/claude-sb-vscode.log`, one line per start:

```json
"claudeCode.environmentVariables": [{ "name": "CLAUDE_SB_DEBUG", "value": "1" }]
```

## What it blocks

- **Writing** anywhere except the project folder, `/tmp`, Claude Code's own
  state and the download caches. Global installs (`brew`, `npm -g`,
  `pip --user`, `uv tool install`) fail, and so do edits to your permission
  rules, hooks, rules, skills, agents and commands in `~/.claude`. Other
  projects are readable but not writable.
- **Reading** known credential locations (SSH and GPG keys, cloud and GitHub
  CLI logins, the Keychain, `.env` files, shell histories, package, container
  and other tool logins) and private folders (Documents, Desktop, Downloads,
  photos, mail, messages, browser profiles and cookies). The list cannot be
  complete; see Limitations.
- **Using the ssh-agent and Docker**: their variables are removed, so `ssh`,
  `git` and `docker` do not find them.
- **Pushing code.** `git fetch` and `git clone` from GitHub work, private repos
  included; `git push` does not, as long as the GitHub token may only read
  code. Push from a normal terminal.

The network is open, and MCP servers run with their usual tokens.

Anything that needs one of these, such as an install into `~/.claude`, a global
install or a push, runs in a normal terminal. Commands started with `!` inside
`claude-sb` run inside the sandbox too.

## When something is blocked

`claude-sb` adds `agent-guidance.md` to Claude's system prompt: what the
sandbox blocks, and that a block is handed to you, not worked around. When a
block looks like a policy problem (ordinary work the sandbox should allow),
the agent drafts a report with the blocked path, the error, the narrowest rule
that would allow it and what else that rule would open. Filing it is up to you.

To change the policy:

1. See what was denied: file blocks show in
   `/usr/bin/log stream --style compact --predicate 'sender == "Sandbox"'`.
2. Add the narrowest rule to `sandbox/policy.json` and to the tables below.
3. Run `make sandbox-test`, then `make sandbox-install`, and restart `claude-sb`.

## What it protects against, and what not

The agent is assumed to be well-meaning but able to **overreach**: delete or
change things outside the project, install globally, use your credentials to
act on other systems. The sandbox stops that.

It does **not** stop a **manipulated** agent (prompt injection) from doing harm
on purpose. Such an attack needs three things, and all three are present
inside:

- **Private data:** every file outside the closed credential and private
  folders, and the MCP tokens and Claude's login token in the environment.
- **Untrusted text:** web pages, docs, issues and cloned repos, all read as
  part of normal work.
- **A way out:** the network is open, and MCP servers can write, for example
  issues and comments on GitHub.

Against a manipulated agent, the person watching is the control, not the
sandbox. Closing these would cost ordinary work: a domain allowlist, reading
only an allowlist of `~`, closed project files. Limitations, at the end, lists
what stays open in detail.

## The policy, entry by entry

`policy.json` uses srt's rules: **reading** is allowed unless a path is in
`denyRead`, and `allowRead` reopens parts of it; **writing** is denied unless
a path is in `allowWrite`, and `denyWrite` wins over `allowWrite`. A pattern
starting with `/**/` matches anywhere on the disk; without the leading `/` it
would only match inside the project. Paths are listed whether or not they exist
on a given machine, so the policy fits everyone.

### `denyRead`: credentials

Reading is harmless for overreach, except where it hands the agent a login it
could use to act on other systems.

| Entry | Holds | Why closed |
| --- | --- | --- |
| `~/.ssh` | SSH keys | Push to git remotes and log in to servers. |
| `~/.aws` | AWS credentials | Act on AWS resources. |
| `~/.config/gcloud` | gcloud logins, application default credentials | Run `gcloud`, `bq`, `gsutil` against GCP projects, including deletes. |
| `~/.config/gh` | GitHub CLI config and logins | `gh` keeps its token here when it is not in the Keychain. Side effect: `gh` does not start inside at all. Use `gh` outside `claude-sb`. |
| `~/.gnupg` | GPG keys | Sign commits or decrypt files as you. |
| `~/.netrc` | Passwords for HTTP and FTP hosts | Read by curl, git and pip to log in. |
| `~/Library/Keychains` | macOS Keychain | With it readable, `security` inside reads any item, the `gh` token included. |
| `~/.zsh_history`, `~/.zsh_sessions`, `~/.bash_history`, `~/.python_history`, `~/.node_repl_history` | Shell and REPL histories (`~/.zsh_sessions` is the per-window history of macOS Terminal) | Tokens and passwords typed into commands (`export TOKEN=...`). |
| `~/.git-credentials`, `~/.config/git/credentials` | Passwords stored by git's `store` helper | Push to any git host. |
| `~/.npmrc`, `~/.pypirc`, `~/.cargo/credentials`, `~/.cargo/credentials.toml`, `~/.m2/settings.xml`, `~/.gradle/gradle.properties` | Package registry logins | Publish packages as you. Only the credential files: the rest of `~/.cargo`, `~/.m2` and `~/.gradle` holds caches the tools need. |
| `~/.terraform.d/credentials.tfrc.json`, `~/.azure`, `~/.config/op`, `~/.config/glab-cli`, `~/.databrickscfg`, `~/.cache/huggingface/token` | Terraform Cloud, Azure, 1Password CLI, GitLab CLI, Databricks and Hugging Face logins | Act on those services as you. |
| `~/.docker`, `~/.colima`, `~/.orbstack`, `~/.rd`, `~/.local/share/containers`, `~/.kube` | Container registry logins, the folders of Docker alternatives (Colima, OrbStack, Rancher Desktop, Podman), Kubernetes logins | Push images, act on clusters. Whether closing a folder also stops a connection to a socket inside it is not tested; the removed `DOCKER_HOST` is the main guard. |
| `~/Library/Application Support/Slack`, `~/Library/Application Support/Microsoft/Teams`, `~/Library/Containers/com.microsoft.teams2` | Chat app data | Session cookies: read and post messages as you. |
| `/**/.env`, `/**/.env.*` | Project secrets, in any project | API keys and passwords next to the code, `.env.local` and `.env.production` included. |

### `denyRead`: private folders

Not logins, but private data an agent has no work reason to read, and the
first thing a manipulated agent would send out.

| Entry | Holds |
| --- | --- |
| `~/Documents`, `~/Desktop`, `~/Downloads` | Personal files. Cost: copy a download or a screenshot into the project before the agent reads it. |
| `~/Pictures`, `~/Movies`, `~/Music` | Photos (the Photos library included), video, audio. |
| `~/Library/Mobile Documents`, `~/Library/CloudStorage` | iCloud Drive, and Dropbox, OneDrive and Google Drive folders. |
| `~/Library/Mail`, `~/Library/Messages`, `~/Library/Calendars` | Mail, iMessage history, calendars. |
| `~/Library/Application Support/AddressBook`, `~/Library/Group Containers/group.com.apple.notes` | Contacts, Notes. |
| `~/Library/Safari`, `~/Library/Containers/com.apple.Safari`, `~/Library/Cookies`, and the browser profiles under `~/Library/Application Support`: `Google/Chrome`, `Firefox`, `Microsoft Edge`, `BraveSoftware`, `Arc` | History, saved sessions and cookies. A session cookie is a login to its site. |

### `allowRead`: exceptions inside `denyRead`

| Entry | Why open |
| --- | --- |
| `/**/.env.example` | Lists variable names without values; the agent needs it to know what a project expects. |

### `allowWrite`: where the agent may change things

| Entry | Why open |
| --- | --- |
| `.` | The project folder `claude-sb` starts in: the work itself. |
| `/tmp`, `/private/tmp` | Temporary files; `/tmp` is a link to `/private/tmp` on macOS. |
| `~/.claude/projects`, `sessions`, `session-env`, `shell-snapshots`, `file-history`, `todos`, `plans`, `tasks`, `paste-cache`, `image-cache`, `cache`, `backups`, `statsig`, `telemetry`, `ide`, `plugins`, `history.jsonl`, `.credentials.json`, `.last-cleanup`, `mcp-needs-auth-cache.json`, `policy-limits.json*`, `remote-settings.json*` | What Claude Code writes during a session: transcripts and memory, history, plans, caches, backups of `~/.claude.json`, MCP logins, the plugin marketplace. Only these, not all of `~/.claude`: the rules, skills, agents, commands, `CLAUDE.md` and hooks there steer every later session, plain `claude` included. If a Claude Code update writes somewhere new, it shows up as a denied write; add the path here. |
| `~/.claude.json`, `~/.claude.json.*` | Claude Code's main state file and the temporary copies it writes before replacing it. |
| `~/.cache`, `~/.npm`, `~/Library/Caches` | Download and build caches of uv, pip, npm and others, and Claude Code's MCP logs. Tools outside the sandbox use them too (see Limitations), but every tool keeps its own cache and no narrower rule fits them all. |

### `denyWrite`: exceptions inside `allowWrite`

Both paths are outside the narrowed `allowWrite` already; they stay listed as a
guard in case it is widened again.

| Entry | Why closed |
| --- | --- |
| `~/.claude/settings.json` | The permission rules for every session. An agent changing its own rules is overreach, however well meant. |
| `~/.claude/scripts` | Hook code. An agent stopped by a hook could otherwise edit the hook instead, and the change would apply to plain `claude` too. |

### Other settings

| Entry | Why |
| --- | --- |
| no `network` block | Network open, for web search, docs and package downloads. See the launcher section below. |
| `allowPty: true` | Claude Code must put the terminal into raw mode; without it, the terminal's replies arrive as typed input. |
| `allowAppleEvents: false` | No scripting of other apps (Mail, Finder, Terminal) through AppleScript. |
| `enableWeakerNetworkIsolation: true` | Lets programs reach the macOS trust service `com.apple.trustd.agent`. Go programs (the GitHub MCP server, `gcloud`, `terraform`) check TLS certificates through it; without it every HTTPS call fails with `x509: OSStatus -26276`. srt warns that trustd can carry data past a network filter; the network here is open anyway. Revisit when the network is filtered. |

### Added by srt itself

Not in `policy.json`, and they cannot be switched off there:

- Always writable: `/tmp/claude`, `~/.npm/_logs`, `~/.claude/debug`, and the
  terminal's output devices.
- Never writable in the project: `.git/hooks`, `.git/config`, `.vscode`,
  `.idea`, `.claude/commands`, `.claude/agents`, `.mcp.json`, `.gitconfig`,
  `.gitmodules`, `.bashrc`, `.zshrc`, `.zprofile`, `.profile`, `.ripgreprc`.
  These run code later, outside the sandbox (git hooks, editor tasks, shell
  start-up).

## MCP servers

All configured servers run inside the sandbox with their usual tokens. The
wrapper sets two variables so they start:

| Variable | Why |
| --- | --- |
| `UV_TOOL_DIR=~/.cache/claude-sb/uv-tools` | `uvx` (for example the Atlassian server) takes a lock in its tool folder. The usual one, `~/.local/share/uv/tools`, stays closed so `uv tool install` cannot install globally. |
| `FASTMCP_ENV_FILE=/dev/null` | fastmcp-based servers read `.env` from the project folder and crash when the sandbox denies it. |

Servers that log in through the browser (OAuth, for example Miro) work too:
the login started from `/mcp` opens the browser, completes, and survives a
restart of `claude-sb`.

## git and GitHub

`~/.ssh` and the Keychain are closed, so git has no login of its own inside.
The wrapper gives it the GitHub MCP token (`GITHUB_PERSONAL_ACCESS_TOKEN`)
through `GIT_CONFIG_*` variables, which leave `~/.gitconfig` and plain `claude`
untouched:

| Setting | Why |
| --- | --- |
| `credential.https://github.com.helper` cleared, then set to a helper that prints the token | The token is read from the environment when git asks. The cleared entry drops `osxkeychain`, which cannot reach the Keychain. |
| `url.https://github.com/.insteadOf` = `git@github.com:`, `ssh://git@github.com/` | Remotes cloned over SSH fetch over HTTPS, without changing the clone. |

This is safe only if the token may **read code, not write it**: a fine-grained
token with Contents: read and no Workflows: write, limited to the repositories
you work in. `claude-sb` refuses to start with a classic token (`ghp_...`),
which cannot be limited that way. Fetch and
clone then work, private repos included, and GitHub refuses `git push` with
"Write access to repository not granted". Pull requests, issues and comments go
through the GitHub MCP server. If the token is ever given Contents: write,
pushing from inside works too: `tests/run.sh` checks both.

## Why a launcher instead of the `srt` command

The `srt` command always filters the network: its settings file requires a
domain list (`network.allowedDomains`), and that list does not accept `*`.
srt's library only filters when such a list is given. `claude-sb-run.mjs`
checks `policy.json` with srt's own schema and starts the sandbox through the
library without a domain list. Quoting, Ctrl+C and exit codes follow the `srt`
command.

## Check the policy

In a normal terminal:

```bash
make sandbox-test           # the files in sandbox/
sandbox/tests/run.sh        # the installed copies in ~/.config/claude-sb/
```

It runs each probe through the launcher from a throwaway project and exits
non-zero if anything that must be blocked is not, or normal work fails. Probes
that fail even outside the sandbox are reported as `skip`. The git fetch and
push probes run only with `CLAUDE_SB_TEST_REPO` set to the SSH URL of a private
repo the GitHub token can read; without it, the run ends with a warning that
push was not tested. `make test` checks, without macOS or srt, that every
policy entry is documented here and that the scripts parse. Hooks and MCP servers need a real session: in
`claude-sb`, `/mcp` lists the servers.

## Limitations

What the sandbox leaves open, mostly because closing it would block ordinary
work or is not possible from inside one sandbox:

- **Tokens are readable inside.** The MCP tokens are environment variables,
  OAuth logins of MCP servers are in `~/.claude/.credentials.json`, and
  `CLAUDE_CODE_OAUTH_TOKEN` is in the environment. Claude Code and the commands
  it runs share one sandbox, so anything Claude Code can read, they can.
- **Secrets in shell startup files are readable.** `~/.zshrc`, `~/.zprofile`
  and `~/.zshenv` stay open, because the shell inside reads them to set
  `PATH`. Keep tokens out of them in plain text, for example by reading them
  from the Keychain there: inside the sandbox that read fails, outside it works.
- **Credential locations nobody listed are readable.** The `denyRead` list
  covers known ones; a new tool's login file, or a project's own `.npmrc`,
  `.envrc` or `*.tfvars`, is not on it.
- **Local sockets are reachable.** With the network open, srt allows every
  connection, local sockets included. Removing `SSH_AUTH_SOCK` and
  `DOCKER_HOST` stops tools from finding the ssh-agent and Docker; a process
  that searches for the sockets (the ssh-agent's is under `/private/tmp`) can
  still connect.
- **Data can leave.** The network is open. Even with a domain allowlist,
  `api.anthropic.com` must stay reachable, and the MCP servers can write
  wherever their tokens allow.
- **Some writes run later, outside the sandbox.** `~/.claude.json` (holds
  `mcpServers`), `~/.claude/plugins` (plugin code), the shared caches, and a
  project's `.claude/settings.local.json` (hooks; gitignored, so invisible in
  `git status`) stay writable and are used by plain `claude` and other tools.
- **Other terminal windows.** `allowPty` opens every `/dev/ttys*`, not only the
  session's own terminal. Untested whether a process inside can use that.
- **Keychain item names** (not their secrets) are still listed by
  `security dump-keychain`.
