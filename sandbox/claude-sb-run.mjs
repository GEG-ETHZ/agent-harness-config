// Run a command under sandbox-runtime with claude-sb's policy.
//
// Usage: node claude-sb-run.mjs SRT_DIST POLICY [--local LOCAL] -c 'command string'
//        node claude-sb-run.mjs SRT_DIST POLICY [--local LOCAL] -- command [args...]
//        node claude-sb-run.mjs --print POLICY [--local LOCAL]
//
// POLICY is the shared, supervised policy; policy.strict.json next to it is
// the strict one. LOCAL, if given, is your personal file: its "extends" picks
// the profile ("supervised", the default, or "strict"), and everything else in
// it is merged over that profile (see mergePolicy). {project} in a path
// stands for the current project's folder in ~/.claude/projects. --print
// shows the result and needs no srt.
//
// The srt CLI always filters the network: its settings file requires
// network.allowedDomains, and that list accepts no bare "*". The library only
// filters when allowedDomains is set, so this launcher starts the sandbox
// through the library: with the network open when the merged policy has no
// "network" block, and filtered to its allowedDomains when it has one. Either
// way the policy is validated with srt's own schema first. Everything else
// follows srt's cli.js: signal forwarding, exit codes.

import { existsSync, readFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { dirname, join } from 'node:path';
import { pathToFileURL } from 'node:url';

// The one place the srt version is pinned. The Makefile installs it, and the
// launcher refuses any other: it relies on how this version builds the
// sandbox and handles a policy without a network block.
const SRT_VERSION = '0.0.79';
const USAGE = [
  "usage: claude-sb-run.mjs SRT_DIST POLICY [--local LOCAL] (-c 'command' | -- command [args...])",
  '       claude-sb-run.mjs --print POLICY [--local LOCAL]',
].join('\n');

function fail(message) {
  console.error(`claude-sb-run: ${message}`);
  process.exit(2);
}

function takeLocal(rest) {
  if (rest[0] !== '--local') return { localPath: undefined, rest };
  if (!rest[1]) fail(USAGE);
  return { localPath: rest[1], rest: rest.slice(2) };
}

function parseArgs(argv) {
  if (argv[0] === '--print') {
    const [, policyPath, ...more] = argv;
    if (!policyPath) fail(USAGE);
    const { localPath, rest } = takeLocal(more);
    if (rest.length > 0) fail(USAGE);
    return { print: true, policyPath, localPath };
  }
  const [srtDist, policyPath, ...more] = argv;
  if (!srtDist || !policyPath) fail(USAGE);
  const { localPath, rest } = takeLocal(more);
  const [mode, ...command] = rest;
  if (mode === '-c' && command.length === 1) return { srtDist, policyPath, localPath, commandString: command[0] };
  if (mode === '--' && command.length > 0) return { srtDist, policyPath, localPath, commandArgs: command };
  return fail(USAGE);
}

function checkSrtVersion(srtDist) {
  let version;
  try {
    version = JSON.parse(readFileSync(join(srtDist, '..', 'package.json'), 'utf8')).version;
  } catch (error) {
    return fail(`cannot read srt's version next to ${srtDist}: ${error.message}`);
  }
  if (version !== SRT_VERSION) {
    fail(`srt ${version} is installed, claude-sb needs ${SRT_VERSION}. In agent-harness-config, run: make sandbox-install`);
  }
}

// POSIX shell quoting: plain words stay as they are, anything else goes in
// single quotes, with each ' written as '\''.
function shellQuote(args) {
  return args
    .map((arg) => (/^[A-Za-z0-9_\/.,:=@%+-]+$/.test(arg) ? arg : `'${arg.replace(/'/g, "'\\''")}'`))
    .join(' ');
}

function readJson(path, what) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch (error) {
    return fail(`cannot read the ${what} ${path}: ${error.message}`);
  }
}

const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);

// The personal policy only adds: lists are extended (entries already there
// are not repeated), objects are merged key by key, and a single value
// (true/false, a number) replaces the shared one. Nothing in the shared
// policy can be removed this way, so stricter means adding entries.
export function mergePolicy(shared, local) {
  if (Array.isArray(shared) && Array.isArray(local)) {
    return [...shared, ...local.filter((entry) => !shared.includes(entry))];
  }
  if (isObject(shared) && isObject(local)) {
    const merged = { ...shared };
    for (const [key, value] of Object.entries(local)) {
      merged[key] = key in shared ? mergePolicy(shared[key], value) : value;
    }
    return merged;
  }
  return local === undefined ? shared : local;
}

// Claude Code keeps a project's transcripts and memory in
// ~/.claude/projects/<key>, the key being the project's path with every
// character other than a letter or digit replaced by "-". A policy names that
// folder as {project}, so it can open the current project's and no other.
export const projectKey = (dir) => dir.replace(/[^A-Za-z0-9]/g, '-');

function withProject(value, key) {
  if (typeof value === 'string') return value.replaceAll('{project}', key);
  if (Array.isArray(value)) return value.map((entry) => withProject(entry, key));
  if (isObject(value)) {
    return Object.fromEntries(Object.entries(value).map(([name, entry]) => [name, withProject(entry, key)]));
  }
  return value;
}

// Profiles a personal file can extend. supervised: open network, reads closed
// only where listed. strict: everything in ~ closed, network filtered, and the
// personal file adds the exceptions.
const PROFILES = { supervised: (policyPath) => policyPath, strict: (policyPath) => join(dirname(policyPath), 'policy.strict.json') };

function effectivePolicy(policyPath, localPath) {
  const personal = localPath && existsSync(localPath) ? readJson(localPath, 'personal policy') : {};
  const { extends: profile = 'supervised', ...additions } = personal;
  if (!(profile in PROFILES)) {
    fail(`"extends": "${profile}" in ${localPath}: use one of ${Object.keys(PROFILES).join(', ')}`);
  }
  const merged = mergePolicy(readJson(PROFILES[profile](policyPath), `${profile} policy`), additions);
  return withProject(merged, projectKey(process.cwd()));
}

function validate(policy, SandboxRuntimeConfigSchema) {
  // srt's schema requires a network block with both lists. Without one the
  // network stays open: an empty block is enough to check the rest, and no
  // allowedDomains means srt starts no proxy and adds no network rule.
  const filtered = policy.network !== undefined;
  const network = filtered
    ? { deniedDomains: [], ...policy.network }
    : { allowedDomains: [], deniedDomains: [] };
  const result = SandboxRuntimeConfigSchema.safeParse({ ...policy, network });
  if (!result.success) fail(`the policy is not valid for srt: ${result.error.message}`);
  return filtered ? result.data : { ...result.data, network: { deniedDomains: [] } };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const policy = effectivePolicy(args.policyPath, args.localPath);
  if (args.print) {
    console.log(JSON.stringify(policy, null, 2));
    return;
  }

  checkSrtVersion(args.srtDist);
  // index.js is the package's entry point ("main"), not an internal file.
  const { SandboxManager, SandboxRuntimeConfigSchema } = await import(
    pathToFileURL(join(args.srtDist, 'index.js')).href
  );

  // Registered before anything slow, so Ctrl+C while the sandbox is being
  // prepared stops the launch instead of being lost.
  let child;
  const forward = (signal) => (child ? child.kill(signal) : process.exit(130));
  process.on('SIGINT', () => forward('SIGINT'));
  process.on('SIGTERM', () => forward('SIGTERM'));

  await SandboxManager.initialize(validate(policy, SandboxRuntimeConfigSchema));

  const command = args.commandString ?? shellQuote(args.commandArgs);
  const sandboxed = await SandboxManager.wrapWithSandbox(command);
  child = spawn(sandboxed, { shell: true, stdio: 'inherit' });

  child.on('exit', (code, signal) => {
    SandboxManager.cleanupAfterCommand();
    if (signal === 'SIGINT' || signal === 'SIGTERM') process.exit(0);
    if (signal) {
      console.error(`claude-sb-run: process killed by signal ${signal}`);
      process.exit(1);
    }
    process.exit(code ?? 0);
  });
  child.on('error', (error) => fail(`cannot start the command: ${error.message}`));
}

// Run only as a program; importing the module (for mergePolicy) starts nothing.
if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => fail(error instanceof Error ? error.message : String(error)));
}
