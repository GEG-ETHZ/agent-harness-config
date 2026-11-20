"""gitleaks runs in the hooks at commit and at push; the full-history scan is the organisation's.

An organisation ruleset requires one shared gitleaks workflow on every pull request, so a
workflow here that downloads gitleaks would pin the version a second time.
"""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PRE_COMMIT = ROOT / ".pre-commit-config.yaml"


def test_no_workflow_downloads_gitleaks():
    # Arrange
    workflows = sorted((ROOT / ".github" / "workflows").glob("*.yml"))

    # Act
    own = [w.name for w in workflows if "gitleaks/gitleaks/releases" in w.read_text()]

    # Assert
    assert workflows
    assert own == []


def test_gitleaks_hook_runs_at_commit_and_at_push():
    # Arrange
    config = PRE_COMMIT.read_text()
    block = re.search(
        r"- repo: https://github\.com/gitleaks/gitleaks\n(.*?)\n  - repo:", config, re.S
    ).group(1)

    # Act
    stages = set(re.findall(r"stages: \[([a-z-]+)\]", block))
    installed = re.search(r"^default_install_hook_types: \[(.*)\]$", config, re.M).group(1)

    # Assert
    assert stages == {"pre-commit", "pre-push"}
    assert "pre-push" in installed
