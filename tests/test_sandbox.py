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


def policy() -> dict:
    return json.loads((SANDBOX / "policy.json").read_text())


def test_policy_has_no_network_block():
    # The launcher runs with the network open and refuses a policy that has one.
    assert "network" not in policy()


@pytest.mark.parametrize("key", ["denyRead", "allowRead", "allowWrite", "denyWrite"])
def test_every_policy_entry_is_documented_in_the_readme(key):
    # Arrange
    readme = (SANDBOX / "README.md").read_text()
    entries = policy()["filesystem"][key]

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
