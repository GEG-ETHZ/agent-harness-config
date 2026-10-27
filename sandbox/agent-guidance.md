# Working inside the claude-sb sandbox

This session runs inside a sandbox (sandbox-runtime). It is set up for
supervised work: a person is watching, and the sandbox stops changes outside
this project and the use of credentials. The policy and the reason for each
rule are in `~/.config/claude-sb/README.md`.

This is not Claude Code's own Bash sandbox. That one is switched off for this
session, so `dangerouslyDisableSandbox` and similar settings change nothing.
The whole Claude Code process, every tool and every child process, runs inside
an operating-system sandbox (macOS Seatbelt) that was set when the session
started. Nothing inside the session can switch it off or loosen it; only the
user can, by leaving `claude-sb` and starting plain `claude`.

What it blocks:

- Writes outside the project, `/tmp`, Claude Code's own session state and the
  download caches. Other projects are readable, not writable. Global installs
  (`brew`, `npm -g`, `pip --user`, `uv tool install`) fail.
- Writes to `~/.claude/settings.json`, hooks, rules, skills, agents, commands
  and `CLAUDE.md` in `~/.claude`, and to `.git/hooks`, `.git/config` and
  `.vscode` in the project.
- Reading credentials: `~/.ssh`, `~/.aws`, `~/.config/gcloud`, `~/.config/gh`,
  `~/.gnupg`, `~/.netrc`, the Keychain, `.env` files, shell histories, and the
  logins of git, package registries, containers and other tools. `gh` does not
  start, and the ssh-agent and Docker are not available.
- Reading private folders: Documents, Desktop, Downloads, photos, mail,
  messages, browser profiles. Ask the user to copy a file into the project.
- In the strict profile (the start line names it), everything in `~` outside
  the project and Claude Code's own files is closed, and so is every host but
  Anthropic's. A tool, cache or host that fails there needs an exception the
  user adds to their own policy; say which path or host, do not look for
  another way.
- Pushing code. `git fetch` and `git clone` from GitHub work, private repos
  included, with a token that may read code only; GitHub refuses `git push`.

The network is open unless the user's own policy filters it (the start line
says which), and MCP servers have their usual tokens. For pull
requests, issues and comments, use the GitHub MCP tools.

## When something is blocked

An `Operation not permitted` error on one of these paths, or a missing
credential, is the sandbox doing its job.

1. **Stop, do not work around it.** No other path, copy, tool, environment
   variable or retry, no `dangerouslyDisableSandbox`, and do not suggest
   switching the sandbox off.
2. **Hand it to the user.** In two or three lines: what was blocked and why the
   task needs it. If the step is reasonable, give the exact command for them to
   run in a separate terminal; commands started with `!` in this session run
   inside the sandbox too. Then continue with what you can do, or wait.
3. **Report a policy problem.** If the block stops ordinary work the sandbox
   should allow (a normal tool's cache, a common workflow, not a one-off),
   draft a report and show it to the user: the path or host and the exact
   error, the command, why ordinary work needs it, the narrowest rule that
   would allow it, and what else that rule would open. The user decides where
   it goes; do not file it yourself unless they ask.

Never change the sandbox policy yourself. A person reviews each report and
changes the policy.
