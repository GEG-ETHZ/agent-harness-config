# claude-sb: Claude Code in a sandbox

`claude-sb` starts Claude Code inside Anthropic's
[`sandbox-runtime`](https://github.com/anthropics/sandbox-runtime) (`srt`), a
sandbox built into macOS. Everything Claude Code starts runs inside it too:
every command, hook and MCP server. The sandbox decides which files they may
read and change and which hosts they may reach, and nothing inside can switch
it off. It is made for **supervised use**: you watch the session, and the
sandbox stops the agent from changing things outside the project or using your
logins. macOS only.

Plain `claude` stays as it is, without any of this protection. If you use it,
use it deliberately: everything the sandbox blocks is open there, your logins
and the rest of your machine included.

This README has two parts. **Part 1** is what you need to set it up and use
it. **Part 2** explains how it works and why it is built this way.

## Part 1: Set up and use

### Choose a profile

There are two profiles. They differ in their starting point:

- **supervised** (the default) starts **open** and closes what is known to be
  dangerous: SSH keys, cloud and GitHub logins, the Keychain, `.env` files,
  shell histories, your private folders. This rarely gets in the way of your
  work. The catch: it only closes what is on its list. A login file of a tool
  the list does not know about stays readable.
- **strict** starts **closed** and opens only what Claude Code needs to run.
  Everything else your work needs, such as uv, npm or GitHub, you open
  yourself, one exception at a time. More setup, but a login file nobody
  listed is closed too.

| | supervised | strict |
| --- | --- | --- |
| Reading in your home folder | open, except credentials and private folders | closed, except the project, Claude Code and your exceptions |
| Writing | the project, `/tmp`, Claude Code's state, download caches | the project, `/tmp`, Claude Code's state for this project |
| Network | open | Anthropic, plus the hosts you add |
| Setup | none | a list of exceptions for your tools |
| Choose it when | you want protection without noticing it | you want to decide exactly what the agent can reach |

Both profiles block changes outside the project (including global installs
and your Claude Code settings), credentials, the ssh-agent, and `git push`.

### Set up

Run every step in a normal terminal, not inside `claude-sb`, from the root of
this repository. You need macOS and `node`.

1. **Install it.**

   ```bash
   make sandbox-install
   ```

   This installs the sandbox runtime, copies `claude-sb` to
   `~/.config/claude-sb/`, and adds a line to `~/.zshrc` that loads the
   `claude-sb` command.

2. **Give it a login for Claude Code.** The sandbox cannot open the Keychain,
   where Claude Code normally keeps your login, so `claude-sb` uses a separate
   token. Create it, then store it; the second command asks for the token, so
   it never lands in your shell history:

   ```bash
   claude setup-token
   security add-generic-password -U -s claude-sb-oauth -a "$USER" -w
   ```

   If Claude Code inside `claude-sb` ever reports that it is not logged in,
   the token has expired: repeat this step.

3. **Optional: let git fetch from GitHub.** Inside the sandbox, git cannot use
   your SSH key or saved login. To make `git fetch`, `git pull` and
   `git clone` work there, give `claude-sb` a GitHub token that can **read**
   code but not change it; you then push yourself, from a normal terminal.

   1. On GitHub, create a **fine-grained** token (Settings, Developer
      settings, Personal access tokens, Fine-grained tokens): only the
      repositories you work in, Contents: **Read-only**, no access to
      Workflows. For the GitHub MCP server, the same token can also get
      Issues and Pull requests: Read and write. `claude-sb` refuses a classic
      token (`ghp_...`).
   2. Store it in the Keychain, and export it from `~/.zprofile` (VS Code
      reads that file, not `~/.zshrc`):

      ```bash
      security add-generic-password -U -s github-token -a "$USER" -w

      # in ~/.zprofile
      export GITHUB_PERSONAL_ACCESS_TOKEN=$(security find-generic-password -s github-token -a "$USER" -w 2>/dev/null)
      ```

4. **For strict: create your policy.** Skip this step for supervised. Start
   from the example, which opens uv, PyPI and GitHub:

   ```bash
   cp sandbox/examples/policy.local.strict.json ~/.config/claude-sb/policy.local.json
   ```

   Add what else you need later (Add exceptions, below).

5. **Open a new terminal**, so the `claude-sb` command is loaded.

6. **Test it.**

   ```bash
   make sandbox-test
   ```

   It tries what the sandbox must block and the work it must allow. It works
   when the last line shows `holes: 0` and `core broken: 0`. In strict, work
   you have not opened shows as `info`. To test git too, put the SSH URL of a
   private repository your token can read in front:
   `CLAUDE_SB_TEST_REPO=git@github.com:<owner>/<repo>.git make sandbox-test`.

7. **Start it** in a project folder:

   ```bash
   cd ~/projects/my-project
   claude-sb
   ```

   The first line shows the profile, where it may write and whether the
   network is filtered.

After pulling changes to `sandbox/`, run `make sandbox-install` again;
`make doctor` tells you when the installed copy is out of date.

### Use

Start `claude-sb` instead of `claude`, from the project folder you want to
work in. It takes the same options (`claude-sb --resume`) and starts in `auto`
permission mode. It refuses to start in folders that hold more than one
project, such as `~` or `~/projects`, because the agent may change everything
in the folder it starts in.

What the sandbox blocks, such as a push, a global install or a change to your
Claude Code settings, you do yourself in a normal terminal, after checking it,
rather than handing it to an agent without the sandbox. Commands started with
`!` inside `claude-sb` run inside the sandbox too.

### Use in VS Code

1. Open VS Code's settings file: Cmd+Shift+P, "Preferences: Open User
   Settings (JSON)".
2. Add this line, with the full path; `~` does not work there:

   ```json
   "claudeCode.claudeProcessWrapper": "/Users/<you>/.config/claude-sb/claude-sb-vscode"
   ```

3. Reload the window: Cmd+Shift+P, "Developer: Reload Window".

Every chat in the Claude Code panel now runs in the sandbox, with the same
profile as `claude-sb`. Pick the permission mode in the panel as usual. To go
back, remove the line and reload. In strict, `/ide` from `claude-sb` in VS
Code's terminal needs an exception (Add exceptions); the panel does not.

### When something is blocked

A block shows as `Operation not permitted` for a file, or as a `403` from the
sandbox's proxy for a host strict does not reach. Claude is told to hand a
block to you rather than work around it, and to say which path or host it
needs.

To see exactly what was blocked, watch the sandbox log while you repeat the
step:

```bash
/usr/bin/log stream --style compact --predicate 'sender == "Sandbox"'
```

If it is something your work needs, add an exception.

### Add exceptions

Your profile and your exceptions live in one file,
`~/.config/claude-sb/policy.local.json`. Without it, you get supervised.
`claude-sb` reads it on every start, so a change applies when you restart
`claude-sb`. The agent inside cannot change it.

```json
{
  "extends": "strict",
  "filesystem": {
    "allowRead": ["~/.local/share/uv", "~/.cache/uv"],
    "allowWrite": ["~/.cache/uv"]
  },
  "network": { "allowedDomains": ["pypi.org", "files.pythonhosted.org"] }
}
```

- `extends`: `strict`, or `supervised` (the default).
- `allowRead` and `allowWrite` open paths; `denyRead` and `denyWrite` close
  them.
- `allowedDomains` lists the hosts that may be reached; `*.example.com`
  covers the subdomains.

Three rules:

1. **Open narrow paths.** `allowRead: ~/.config` opens every login stored
   under it. Open the one folder your tool needs.
2. **What a tool writes, it must also read.** Put every `allowWrite` path in
   `allowRead` too, or the tool fails with `Operation not permitted`.
3. **The file only adds.** It cannot remove anything from the profile.

`make sandbox-policy` shows the policy `claude-sb` will run with. To go back
to supervised, delete the file.

| For | Add |
| --- | --- |
| uv (`uv run`, `uvx`) | `allowRead`: `~/.local/bin`, `~/.local/share/uv`; `allowRead` and `allowWrite`: `~/.cache/uv`, `~/.cache/claude-sb` (uvx); hosts: `pypi.org`, `files.pythonhosted.org` |
| npm, npx (and the Context7 server) | `allowRead` and `allowWrite`: `~/.npm`; hosts: `registry.npmjs.org`, plus the server's own host |
| git and GitHub, the GitHub MCP server | hosts: `github.com`, `api.github.com`, `*.githubusercontent.com`; `"enableWeakerNetworkIsolation": true` for Go programs |
| pre-commit | `allowRead` and `allowWrite`: `~/.cache/pre-commit` |
| nvm, pyenv, Rust | `allowRead`: `~/.nvm`, `~/.pyenv`, `~/.cargo` and `~/.rustup` |
| reading other projects | `allowRead`: `~/projects` (their `.env` files stay closed) |
| `/ide` from a terminal in VS Code | `"network": { "allowLocalBinding": true }` (opens every local port) |
| an MCP server that logs in through the browser (OAuth) | `allowRead` and `allowWrite`: `~/.claude/.credentials.json`, plus the server's host |
| aliases and functions from your shell | `allowRead`: `~/.zshrc` (keep tokens out of it) |
| any other MCP server or website | its host in `allowedDomains` |

## Part 2: How it works

### What it protects against, and what not

The agent is assumed to be well-meaning but able to **overreach**: delete or
change things outside the project, install globally, use your credentials to
act on other systems. The sandbox stops that, in both profiles.

A **manipulated** agent (prompt injection) is a different matter. Such an
attack needs three things: **private data** it can read, **untrusted text**
that carries the instructions (web pages, docs, issues, cloned repositories,
all part of normal work), and **a way out** (a host to send data to, or an MCP
server that can write, for example on GitHub).

In supervised, all three are present: the person watching is the control, not
the sandbox. strict takes away most of the private data and most of the ways
out. Neither removes the way out entirely: `api.anthropic.com` stays
reachable, and MCP servers can write wherever their tokens allow. Limitations,
at the end, lists what stays open.

### How the policy is put together

`claude-sb-run.mjs`, the launcher, loads the profile your `policy.local.json`
names in `extends` (`policy.json` for supervised, `policy.strict.json` for
strict) and merges your file over it: lists are extended, objects merged key
by key, and single settings replaced. Nothing in the profile can be removed,
so you keep every later fix to it.

`{project}` in a path stands for the current project's folder in
`~/.claude/projects`, where Claude Code keeps transcripts and memory: the
project's path with every character other than a letter or digit replaced by
`-`.

srt's rules decide the rest. **Reading** is allowed unless a path is in
`denyRead`; `allowRead` reopens parts of it, and a more specific entry wins
over a broader one. **Writing** is denied unless a path is in `allowWrite`,
and `denyWrite` wins over `allowWrite`. A pattern starting with `/**/` matches
anywhere on the disk. Paths are listed whether or not they exist on a given
machine. srt's documentation lists every setting:
<https://github.com/anthropics/sandbox-runtime>.

The installed files are copied, not linked, so an agent working in this
repository cannot change its own live policy or the code every new shell runs.

### The strict profile

**Closed for reading** (`denyRead`): `~` and `/Volumes` (external disks and
network shares; a project on one stays open, because the more specific entry
wins). Also closed, because they sit inside folders strict opens:

- the `.env` files in the project (`/**/.env`, `/**/.env.*`);
- other projects' transcripts and memory (`~/.claude/projects/*`); their
  folder names, which are the projects' paths, stay visible;
- the browser logins of MCP servers (`~/.claude/.credentials.json`).

The rest of the system (`/usr`, `/opt/homebrew`, `/Applications`, ...) stays
readable: programs need it to start, and it holds no credentials.

**Open for reading** (`allowRead`):

| Entry | Why |
| --- | --- |
| `.`, `/**/.env.example` | The project, and env templates. |
| `~/.claude`, `~/.claude.json`, `~/.claude.json.*`, `~/Library/Caches/claude-cli-nodejs` | Claude Code's settings, state and MCP logs. |
| `~/.claude/projects/{project}` | This project's transcripts and memory. Other projects are closed with a pattern, `~/.claude/projects/*`, not the folder: srt cannot reopen a folder inside a closed folder that is itself inside an open one (`~/.claude`), but a pattern leaves out the exceptions it covers. |
| `~/.config/claude-sb` | The agent guidance and this README. |
| `~/.local/bin/claude`, `~/.local/share/claude`, `~/.vscode/extensions/anthropic.claude-code-*` | Claude Code itself, installed natively or bundled with the VS Code extension. A Homebrew install is outside `~` and needs nothing. |
| `~/.gitconfig`, `~/.config/git/config`, `~/.config/git/ignore`, `~/.config/git/attributes` | git's settings; single files, so `~/.config/git/credentials` stays closed. |
| `~/Library/Preferences/.GlobalPreferences.plist`, `~/Library/Preferences/.GlobalPreferences_m.plist`, `~/Library/Preferences/ByHost/.GlobalPreferences.*.plist` | Locale and system defaults Node reads on start-up. |

The shell startup files (`~/.zshrc`, `~/.zprofile`, `~/.zshenv`) are closed:
they often hold tokens. Commands get `PATH` from the environment `claude-sb`
starts with; aliases and functions are missing inside.

**Open for writing** (`allowWrite`): the project (`.`), `/tmp` and
`/private/tmp`, `~/Library/Caches/claude-cli-nodejs`, `~/.claude.json` and
`~/.claude.json.*`, and Claude Code's working state as in supervised, except:

- of `~/.claude/projects`, only `~/.claude/projects/{project}`;
- not `~/.claude/plugins`: a plugin brings code that runs in later sessions,
  so install and update plugins outside;
- not `~/.claude/.credentials.json`, `~/.claude/statsig` or
  `~/.claude/telemetry`.

No download caches.

**Network:** `api.anthropic.com`, `statsig.anthropic.com`, `claude.ai` and
`console.anthropic.com` only (`strictAllowlist`), no addresses in private
networks (`deniedResolvedAddresses`), no local ports
(`allowLocalBinding: false`), and `enableWeakerNetworkIsolation` off.

### The supervised profile

#### `denyRead`: credentials

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

#### `denyRead`: private folders

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

#### `allowRead`, `allowWrite`, `denyWrite`

| Entry | Why |
| --- | --- |
| `/**/.env.example` (`allowRead`) | Lists variable names without values; the agent needs it to know what a project expects. |
| `.` | The project folder `claude-sb` starts in: the work itself. |
| `/tmp`, `/private/tmp` | Temporary files; `/tmp` is a link to `/private/tmp` on macOS. |
| `~/.claude/projects`, `sessions`, `session-env`, `shell-snapshots`, `file-history`, `todos`, `plans`, `tasks`, `paste-cache`, `image-cache`, `cache`, `backups`, `statsig`, `telemetry`, `plugins`, `history.jsonl`, `.credentials.json`, `.last-cleanup`, `mcp-needs-auth-cache.json`, `policy-limits.json*`, `remote-settings.json*` | What Claude Code writes during a session. Only these, not all of `~/.claude`: the rules, skills, agents, commands, `CLAUDE.md` and hooks there steer every later session, plain `claude` included. If a Claude Code update writes somewhere new, it shows up as a denied write; add the path here. Not `~/.claude/ide`, where VS Code keeps its lock files (VS Code, below). |
| `~/.claude.json`, `~/.claude.json.*` | Claude Code's main state file and the temporary copies it writes before replacing it. |
| `~/.cache`, `~/.npm`, `~/Library/Caches` | Download and build caches of uv, pip, npm and others. Tools outside the sandbox use them too (see Limitations), but every tool keeps its own and no narrower rule fits them all. |
| `~/.claude/settings.json` (`denyWrite`) | The permission rules for every session. An agent changing its own rules is overreach, however well meant. |
| `~/.claude/scripts` (`denyWrite`) | Hook code. An agent stopped by a hook could otherwise edit the hook instead. |

The two `denyWrite` entries are outside `allowWrite` already; they stay listed
as a guard in case it is widened again. strict lists them too.

#### Other settings

| Entry | Why |
| --- | --- |
| no `network` block | Network open, for web search, docs and package downloads. |
| `allowPty: true` | Claude Code must put the terminal into raw mode; without it, the terminal's replies arrive as typed input. |
| `allowAppleEvents: false` | No scripting of other apps (Mail, Finder, Terminal) through AppleScript. |
| `enableWeakerNetworkIsolation: true` | Lets Go programs (the GitHub MCP server, `gcloud`, `terraform`) check TLS certificates through the macOS service `com.apple.trustd.agent`; without it every HTTPS call fails with `x509: OSStatus -26276`. srt warns that the service can carry data past a network filter, which matters only in strict, where it is off unless you turn it on. |

### Added by srt itself

Not in either policy, and they cannot be switched off there:

- Always writable: `/tmp/claude`, `~/.npm/_logs`, `~/.claude/debug`, and the
  terminal's output devices.
- Never writable in the project: `.git/hooks`, `.git/config`, `.vscode`,
  `.idea`, `.claude/commands`, `.claude/agents`, `.mcp.json`, `.gitconfig`,
  `.gitmodules`, `.bashrc`, `.zshrc`, `.zprofile`, `.profile`, `.ripgreprc`.
  These run code later, outside the sandbox.

### Start folders

`claude-sb` refuses to start where the agent could change more than one
project: `~` and folders directly under it (`~/projects`), hidden folders,
`~/Library`, the private folders (`~/Documents`, ...), and, outside `~`,
anything not under `/Volumes` or `/private/tmp` (`/opt/homebrew/bin` or
`/usr/local` hold programs that run later, outside the sandbox).

### Tokens, git and GitHub

The sandbox closes the Keychain, so nothing inside can read your stored
logins. `claude-sb` reads the two it needs before the sandbox starts and
passes them in as environment variables: the Claude Code login
(`CLAUDE_CODE_OAUTH_TOKEN`, from the Keychain item `claude-sb-oauth`) and,
if set, `GITHUB_PERSONAL_ACCESS_TOKEN`.

git gets the GitHub token through `GIT_CONFIG_*` variables, for this session
only, so `~/.gitconfig` and plain `claude` are untouched:

| Setting | Why |
| --- | --- |
| `credential.https://github.com.helper` cleared, then set to a helper that prints the token | The token is read from the environment when git asks. The cleared entry drops `osxkeychain`, which cannot reach the Keychain. |
| `url.https://github.com/.insteadOf` = `git@github.com:`, `ssh://git@github.com/` | Remotes cloned over SSH fetch over HTTPS, without changing the clone. |

This is safe only while the token cannot write code: with Contents: Read-only,
GitHub refuses `git push` ("Write access to repository not granted"). That is
why `claude-sb` refuses a classic token, which cannot be limited, and why
`make sandbox-test` checks that a push fails when `CLAUDE_SB_TEST_REPO` is
set. Pull requests, issues and comments go through the GitHub MCP server.

### MCP servers

All configured servers run inside the sandbox with their usual tokens; in
strict, each also needs its host and its tool's exceptions. The wrapper sets
two variables so they start:

| Variable | Why |
| --- | --- |
| `UV_TOOL_DIR=~/.cache/claude-sb/uv-tools` | `uvx` takes a lock in its tool folder. The usual one, `~/.local/share/uv/tools`, stays closed so `uv tool install` cannot install globally. |
| `FASTMCP_ENV_FILE=/dev/null` | fastmcp-based servers read `.env` from the project folder and crash when the sandbox denies it. |

Servers that log in through the browser (OAuth, for example Miro) work: the
login from `/mcp` completes and survives a restart. Claude Code keeps these
logins in `~/.claude/.credentials.json`, which strict closes unless you open
it.

### VS Code

The extension starts the wrapper `claude-sb-vscode` with the path of the
Claude Code it bundles as the first argument, then its own options, including
the permission mode; it also runs `auth status`, which runs in the sandbox
without the session flags. This is not documented and was checked with
extension 2.1.310, so a later version may change it. The wrapper runs as a
login shell (`zsh -l`), because VS Code started from the Dock does not have
your terminal's `PATH`; `node`, `srt` and your tokens must come from
`~/.zprofile`. The extension notes two side effects of any wrapper: plan mode
is not restored when a conversation is resumed, and the "conversation still
open" check is skipped.

The chat panel talks to Claude through the process it starts, so diffs and
the current selection need nothing more. `/ide` from a terminal is different:
it finds VS Code through a lock file in `~/.claude/ide` and connects on a local
port. The sandbox does not let Claude check whether the VS Code process is
running, so Claude takes the lock file for stale and deletes it, which also
hides VS Code from plain `claude` until the window is reloaded. Both profiles
keep `~/.claude/ide` read-only for that reason. In supervised, `/ide` then
connects; strict also needs `allowLocalBinding` for the connection, which
opens every local port.

If the panel does not start, set `CLAUDE_SB_DEBUG` for the Claude process in
VS Code's settings and read `$TMPDIR/claude-sb-vscode.log`, one line per start:

```json
"claudeCode.environmentVariables": [{ "name": "CLAUDE_SB_DEBUG", "value": "1" }]
```

### Why a launcher instead of the `srt` command

The `srt` command always filters the network: its settings file requires a
host list, and that list does not accept `*`. srt's library only filters when
such a list is given. So `claude-sb-run.mjs` merges the policy, checks it with
srt's own schema, and starts the sandbox through the library: with the network
open when the policy has no `network` block, filtered when it has one. It also
pins the `srt` version (`SRT_VERSION`) and refuses any other.

### When Claude is blocked

`claude-sb` adds `agent-guidance.md` to Claude's system prompt: what the
sandbox blocks, and that a block is handed to you, not worked around. When a
block looks like a gap in the policy, Claude drafts a report with the path,
the error, the narrowest rule that would allow it and what else that rule
would open; filing it is up to you. A change for everyone goes into
`sandbox/policy.json` or `sandbox/policy.strict.json`, with its entry
documented here.

### Tests

`make sandbox-test` (the files in `sandbox/`) and `sandbox/tests/run.sh` (the
installed copies) run each probe through the launcher, with your
`policy.local.json`, from a throwaway project, and exit non-zero if anything
that must be blocked is not, or normal work fails. Probes that fail even
outside the sandbox (a missing folder, macOS privacy protection) are reported
as `skip`. `make test` checks, without macOS or srt, that every policy entry is
documented here and that the scripts parse.

### Limitations

What stays open, mostly because closing it would block ordinary work or is
not possible from inside one sandbox:

- **Tokens are readable inside.** The MCP tokens and `CLAUDE_CODE_OAUTH_TOKEN`
  are environment variables, and in supervised the browser logins of MCP
  servers are readable in `~/.claude/.credentials.json`. Claude Code and the
  commands it runs share one sandbox, so anything Claude Code can read, they
  can.
- **Shell startup files are readable** in supervised, because the shell inside
  reads them to set `PATH`. Keep tokens out of them in plain text, for example
  by reading them from the Keychain there: inside the sandbox that read fails.
- **Credential locations nobody listed are readable** in supervised. In both
  profiles, the project's own files are readable, its `.npmrc`, `.envrc` or
  `*.tfvars` included; only `.env` files are closed.
- **Local sockets are reachable** in supervised. Removing `SSH_AUTH_SOCK` and
  `DOCKER_HOST` stops tools from finding the ssh-agent and Docker; a process
  that searches for the sockets can still connect.
- **Data can leave.** In supervised, the network is open. In strict,
  `api.anthropic.com` and the hosts you add stay reachable. In both, MCP
  servers can write wherever their tokens allow.
- **Some writes run later, outside the sandbox.** `~/.claude.json` (holds
  `mcpServers`), a project's `.claude/settings.local.json` (hooks; gitignored,
  so invisible in `git status`), and in supervised also `~/.claude/plugins`,
  the shared caches and other projects' memory. Plain `claude` and other tools
  use them later. `~/.claude.json` cannot be closed: Claude Code writes it all
  the time.
- **Other terminal windows.** `allowPty` opens every `/dev/ttys*`, not only the
  session's own terminal. Untested whether a process inside can use that.
- **Keychain item names** (not their secrets) are still listed by
  `security dump-keychain`.
