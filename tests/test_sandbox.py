"""sandbox/: the claude-sb policy, its docs and its scripts stay consistent.

sandbox/tests/run.sh probes the policy for real, but needs macOS and srt. These
checks run anywhere, CI included, and catch the drift that run.sh cannot: an
entry nobody documented, a version pinned in two places, a script that no
longer parses.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest
from conftest import load_tool

REPO = Path(__file__).resolve().parent.parent
SANDBOX = REPO / "sandbox"


def policy(name: str = "policy.json") -> dict:
    return json.loads((SANDBOX / name).read_text())


def test_policy_has_no_network_block():
    # The launcher runs with the network open and refuses a policy that has one.
    assert "network" not in policy()


@pytest.mark.parametrize("name", ["policy.json", "policy.strict.json"])
@pytest.mark.parametrize("key", ["denyRead", "allowRead", "allowWrite", "denyWrite"])
def test_every_policy_entry_is_documented_in_the_readme(name, key):
    # Arrange
    readme = (SANDBOX / "README.md").read_text()
    entries = policy(name)["filesystem"][key]

    # Act: the README names an entry in full, or by its trailing part in a row
    # that groups several (`~/.claude/projects`, `sessions`, ...; `Google/Chrome`).
    def named(entry: str) -> bool:
        parts = entry.rstrip("*").split("/")
        return any(f"`{'/'.join(parts[i:])}" in readme for i in range(len(parts)))

    undocumented = [entry for entry in entries if not named(entry)]

    # Assert
    assert undocumented == []


def test_srt_version_is_pinned_only_in_the_launcher():
    # Arrange
    launcher = (SANDBOX / "claude-sb-run.mjs").read_text()
    others = [
        path for path in SANDBOX.rglob("*") if path.is_file() and path.name != "claude-sb-run.mjs"
    ]
    others.append(REPO / "Makefile")

    # Act
    pinned_elsewhere = [
        str(path.relative_to(REPO))
        for path in others
        if re.search(r"sandbox-runtime@\d", path.read_text())
    ]

    # Assert
    assert re.search(r"^const SRT_VERSION = '\d+\.\d+\.\d+';$", launcher, re.MULTILINE)
    assert pinned_elsewhere == []


def test_makefile_installs_the_files_doctor_compares():
    # Arrange
    doctor = load_tool("doctor.py")
    makefile = (REPO / "Makefile").read_text()

    # Act
    listed = re.search(r"^SANDBOX_FILES\s*:=\s*(.+)$", makefile, re.MULTILINE)

    # Assert
    assert listed is not None
    assert tuple(listed.group(1).split()) == doctor.SANDBOX_FILES
    assert all((SANDBOX / name).is_file() for name in doctor.SANDBOX_FILES)


@pytest.mark.parametrize(
    ("tool", "args", "script"),
    [
        ("bash", ["-n"], "tests/run.sh"),
        ("zsh", ["-n"], "claude-sb.zsh"),
        ("zsh", ["-n"], "claude-sb-vscode"),
        ("node", ["--check"], "claude-sb-run.mjs"),
    ],
)
def test_scripts_parse(tool, args, script):
    if shutil.which(tool) is None:
        pytest.skip(f"{tool} not installed")

    result = subprocess.run([tool, *args, str(SANDBOX / script)], capture_output=True, text=True)

    assert result.returncode == 0, result.stderr


def test_vscode_wrapper_is_executable():
    # VS Code runs claudeCode.claudeProcessWrapper directly; make sandbox-install copies the mode.
    assert os.access(SANDBOX / "claude-sb-vscode", os.X_OK)


def effective_policy(local: Path | None, cwd: Path | None = None) -> dict:
    if shutil.which("node") is None:
        pytest.skip("node not installed")
    args = ["node", str(SANDBOX / "claude-sb-run.mjs"), "--print", str(SANDBOX / "policy.json")]
    if local is not None:
        args += ["--local", str(local)]
    result = subprocess.run(args, capture_output=True, text=True, check=True, cwd=cwd)
    return json.loads(result.stdout)


def test_personal_policy_only_adds_to_the_shared_one(tmp_path):
    # Arrange
    shared = policy()
    already_denied = shared["filesystem"]["denyRead"][0]
    local = tmp_path / "policy.local.json"
    local.write_text(
        json.dumps(
            {
                "filesystem": {"denyRead": [already_denied, "~/extra"]},
                "network": {"allowedDomains": ["api.anthropic.com"]},
                "allowPty": False,
            }
        )
    )

    # Act
    merged = effective_policy(local)

    # Assert
    deny_read = merged["filesystem"]["denyRead"]
    assert deny_read[: len(shared["filesystem"]["denyRead"])] == shared["filesystem"]["denyRead"]
    assert deny_read[-1] == "~/extra"
    assert deny_read.count(already_denied) == 1
    assert merged["filesystem"]["allowWrite"] == shared["filesystem"]["allowWrite"]
    assert merged["network"] == {"allowedDomains": ["api.anthropic.com"]}
    assert merged["allowPty"] is False


def test_no_personal_policy_means_the_shared_one(tmp_path):
    assert effective_policy(tmp_path / "missing.json") == policy()


def test_strict_example_filters_the_network_and_keeps_claude_reachable():
    merged = effective_policy(SANDBOX / "examples" / "policy.local.strict.json")

    assert merged["network"]["strictAllowlist"] is True
    assert "api.anthropic.com" in merged["network"]["allowedDomains"]


def test_strict_example_can_read_what_it_may_write():
    # ~ is closed for reading in strict, and changing a file that exists (uv's
    # lock file) means opening it: a write path in ~ needs a read exception.
    filesystem = effective_policy(SANDBOX / "examples" / "policy.local.strict.json")["filesystem"]

    def readable(entry: str) -> bool:
        return any(
            entry == path or entry.startswith(f"{path}/") or entry.startswith(f"{path}.")
            for path in filesystem["allowRead"]
        )

    unreadable = [
        entry for entry in filesystem["allowWrite"] if entry.startswith("~") and not readable(entry)
    ]

    assert unreadable == []


def test_strict_closes_only_what_it_reopens_too_broadly():
    # ~ and /Volumes, plus what sits inside a folder strict itself opens (the
    # project's .env, other projects' Claude state, Claude's login file). The
    # rest is the personal policy's to close.
    supervised, strict = policy()["filesystem"], policy("policy.strict.json")["filesystem"]

    assert strict["denyRead"] == [
        "~",
        "/Volumes",
        "~/.claude/projects/*",
        "~/.claude/.credentials.json",
        "/**/.env",
        "/**/.env.*",
    ]
    assert strict["denyWrite"] == supervised["denyWrite"]


def test_strict_opens_no_credential_location_of_the_supervised_profile():
    # Nothing in strict keeps a credential closed inside a folder it opens, so
    # an exception that is a parent of one (~/.config/git) would open it.
    supervised, strict = policy()["filesystem"], policy("policy.strict.json")["filesystem"]

    opened = [
        (exception, closed)
        for exception in strict["allowRead"]
        for closed in supervised["denyRead"]
        if closed == exception or closed.startswith(f"{exception}/")
    ]

    assert opened == []


def test_strict_writes_are_a_subset_without_the_shared_caches():
    supervised, strict = policy()["filesystem"], policy("policy.strict.json")["filesystem"]

    def covered(entry: str) -> bool:
        return any(
            entry == path or entry.startswith(f"{path}/") for path in supervised["allowWrite"]
        )

    assert all(covered(entry) for entry in strict["allowWrite"])
    assert not {"~/.cache", "~/.npm", "~/Library/Caches"} & set(strict["allowWrite"])


def test_strict_filters_the_network_to_anthropic():
    network = policy("policy.strict.json")["network"]

    assert network["strictAllowlist"] is True
    assert all(host.endswith(("anthropic.com", "claude.ai")) for host in network["allowedDomains"])
    assert network["allowLocalBinding"] is False


def test_personal_file_extends_the_strict_profile(tmp_path):
    # Arrange
    local = tmp_path / "policy.local.json"
    local.write_text(
        json.dumps({"extends": "strict", "filesystem": {"allowWrite": ["~/.cache/uv"]}})
    )

    # Act
    merged = effective_policy(local)

    # Assert
    assert "extends" not in merged
    assert merged["filesystem"]["denyRead"][0] == "~"
    assert merged["filesystem"]["allowWrite"][-1] == "~/.cache/uv"


def test_strict_opens_only_the_current_projects_claude_folder(tmp_path):
    # Arrange: a project path with characters Claude Code replaces by "-".
    project = tmp_path / "my_project.v2"
    project.mkdir()
    key = re.sub(r"[^A-Za-z0-9]", "-", str(project.resolve()))
    local = tmp_path / "policy.local.json"
    local.write_text(json.dumps({"extends": "strict"}))

    # Act
    filesystem = effective_policy(local, cwd=project)["filesystem"]

    # Assert
    assert f"~/.claude/projects/{key}" in filesystem["allowRead"]
    assert f"~/.claude/projects/{key}" in filesystem["allowWrite"]
    assert "~/.claude/projects" not in filesystem["allowWrite"]
    assert not any("{project}" in entry for entry in filesystem["allowWrite"])
