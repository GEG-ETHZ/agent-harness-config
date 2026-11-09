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

- Writes anywhere except the project, `/tmp`, Claude Code's own session state
  and the download caches. Other projects are readable, not writable. Global installs
  (`brew`, `npm -g`, `pip --user`, `uv tool install`) fail.
- Writes to `~/.claude/settings.json`, hooks, rules, skills, agents, commands,
  plugins and `CLAUDE.md` in `~/.claude`, and to `.git/hooks`, `.git/config`,
  `.vscode`, `.env`, `.env.local` and `.env.*.local` in the project.
- Reading credentials: `~/.ssh`, `~/.aws`, `~/.config/gcloud`, `~/.config/gh`,
  `~/.gnupg`, `~/.netrc`, the Keychain, `.env` files, shell histories, and the
  logins of git, package registries, containers and other tools. `gh` does not
  start, the ssh-agent and Docker are not available, and tokens such as
  `GH_TOKEN` are removed from the environment.
- Reading private folders: Documents, Desktop, Downloads, photos, mail,
  messages, browser profiles. Ask the user to copy a file into the project.
- In the strict profile (the start line names it), everything in `~` outside
  the project and Claude Code's own files is closed, and so is every host but
  Anthropic's. A tool, cache or host that fails there needs an exception the
  user adds to their own policy; say which path or host, do not look for
  another way.
- Pushing code. In this project, `git fetch` from GitHub works, private repos
  included, with a token that may read code only; GitHub refuses `git push`.

The network is open unless the user's own policy filters it (the start line
says which), and MCP servers have their usual tokens. For pull
requests, issues and comments, use the GitHub MCP tools.

## When something is blocked

The sandbox's limits are the limits of your task. If the work needs to write
outside this project, read a closed path or use a credential, the work is
blocked, not just the path or command you tried.

1. **Stop at the first block.** Do not reach the same result another way: no
   clone or copy into `/tmp`, the scratchpad or another folder, no worktree, no
   other tool, environment variable or retry, no MCP write that makes the same
   change, no `dangerouslyDisableSandbox`, and no preparing something for the
   user to push or run that you could not do here yourself. Do not suggest
   switching the sandbox off.
2. **Say so, in this form, and wait:**

       Blocked: <what> (<exact error>).
       Needed for: <why the task needs it>.
       You can: <exact command for a separate terminal> or <start claude-sb in the right folder>.

   Commands started with `!` in this session run inside the sandbox too.
3. **Work in another repository only from a session started there**
   (`cd ~/projects/<repo> && claude-sb`). If a task belongs in another
   repository, say so before starting it, not after a write fails.
4. **Report a policy problem.** If the block stops ordinary work the sandbox
   should allow (a normal tool's cache, a common workflow, not a one-off),
   draft a report and show it to the user: the path or host and the exact
   error, the command, why ordinary work needs it, the narrowest rule that
   would allow it, and what else that rule would open. The user decides where
   it goes; do not file it yourself unless they ask.

Not this: a write to `~/projects/other-repo` is blocked, so the agent clones
`other-repo` into `/tmp`, commits the change there and asks the user to push it.
That is the same change by another route. Stop and report instead.

Never change the sandbox policy yourself. A person reviews each report and
changes the policy.
