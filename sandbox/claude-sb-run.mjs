// Run a command under sandbox-runtime's file rules with the network open.
//
// Usage: node claude-sb-run.mjs SRT_DIST POLICY -c 'command string'
//        node claude-sb-run.mjs SRT_DIST POLICY -- command [args...]
//
// The srt CLI always filters the network: its settings file requires
// network.allowedDomains, and that list accepts no bare "*". The library only
// filters when allowedDomains is set, so this launcher validates the policy
// with srt's own schema and then starts the sandbox without that list.
// Everything else follows srt's cli.js: quoting, signal forwarding, exit codes.

import { readFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

// The one place the srt version is pinned. The Makefile installs it, and the
// launcher refuses any other: it relies on how this version builds the
// sandbox and handles a policy without a network block.
const SRT_VERSION = '0.0.79';
const USAGE = "usage: claude-sb-run.mjs SRT_DIST POLICY (-c 'command' | -- command [args...])";

function fail(message) {
  console.error(`claude-sb-run: ${message}`);
  process.exit(2);
}

function parseArgs(argv) {
  const [srtDist, policyPath, mode, ...rest] = argv;
  if (!srtDist || !policyPath) fail(USAGE);
  if (mode === '-c' && rest.length === 1) return { srtDist, policyPath, commandString: rest[0] };
  if (mode === '--' && rest.length > 0) return { srtDist, policyPath, commandArgs: rest };
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

function loadPolicy(policyPath, SandboxRuntimeConfigSchema) {
  let raw;
  try {
    raw = JSON.parse(readFileSync(policyPath, 'utf8'));
  } catch (error) {
    return fail(`cannot read the policy ${policyPath}: ${error.message}`);
  }
  if (raw.network !== undefined) {
    fail(`${policyPath} has a "network" block; this launcher runs with the network open. Remove it.`);
  }
  // srt's schema requires a network block; an empty one is enough to check
  // the rest of the file, and is dropped again below.
  const result = SandboxRuntimeConfigSchema.safeParse({
    ...raw,
    network: { allowedDomains: [], deniedDomains: [] },
  });
  if (!result.success) {
    fail(`${policyPath} is not a valid srt policy: ${result.error.message}`);
  }
  // No allowedDomains: srt starts no proxy and adds no network rule.
  return { ...result.data, network: { deniedDomains: [] } };
}

async function main() {
  const { srtDist, policyPath, commandString, commandArgs } = parseArgs(process.argv.slice(2));
  checkSrtVersion(srtDist);
  // index.js is the package's entry point ("main"), not an internal file.
  const { SandboxManager, SandboxRuntimeConfigSchema } = await import(
    pathToFileURL(join(srtDist, 'index.js')).href
  );

  // Registered before anything slow, so Ctrl+C while the sandbox is being
  // prepared stops the launch instead of being lost.
  let child;
  const forward = (signal) => (child ? child.kill(signal) : process.exit(130));
  process.on('SIGINT', () => forward('SIGINT'));
  process.on('SIGTERM', () => forward('SIGTERM'));

  const policy = loadPolicy(policyPath, SandboxRuntimeConfigSchema);
  await SandboxManager.initialize(policy);

  const command = commandString ?? shellQuote(commandArgs);
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

main().catch((error) => fail(error instanceof Error ? error.message : String(error)));
