#!/usr/bin/env python3
"""Bump/check local release versions. Refresh origin tags before invoking."""

import argparse
import re
import subprocess
import sys
from pathlib import Path

VERSION_PATTERN = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
BUILD_PATTERN = re.compile(r"0|[1-9][0-9]*")


def git(repo, *args):
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True, text=True, encoding="utf-8", timeout=30,
    )
    if result.returncode:
        raise ValueError(result.stderr.strip() or "git command failed")
    return result.stdout.strip()


def release_history(repo):
    tags = git(repo, "for-each-ref", "--format=%(refname:short)", "refs/tags/v*").splitlines()
    maximum = 0
    for tag in tags:
        # Old upstream tags can predate this fork's BUILD_NUMBER file.
        if not git(repo, "ls-tree", "--name-only", tag, "--", "BUILD_NUMBER"):
            continue
        value = re.sub(r"\s", "", git(repo, "show", f"{tag}:BUILD_NUMBER"))
        if re.fullmatch(r"[0-9]+", value):
            maximum = max(maximum, int(value))
    return tags, maximum


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[4],
                        help="Repository root (defaults to this skill's project)")
    parser.add_argument("--part", type=int, choices=(1, 2, 3), default=3,
                        help="Component to increment; reset following components to zero")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="Preview without writing")
    mode.add_argument("--check", action="store_true", help="Check current files without incrementing")
    args = parser.parse_args()
    repo = args.repo.resolve()
    if Path(git(repo, "rev-parse", "--show-toplevel")).resolve() != repo:
        raise ValueError("--repo must point to the repository root")

    version_file, build_file = repo / "VERSION", repo / "BUILD_NUMBER"
    original_version = version_file.read_text(encoding="utf-8")
    original_build = build_file.read_text(encoding="utf-8")
    version, build = original_version.strip(), original_build.strip()
    if not VERSION_PATTERN.fullmatch(version):
        raise ValueError("VERSION must contain three nonnegative integers without leading zeros")
    if not BUILD_PATTERN.fullmatch(build):
        raise ValueError("BUILD_NUMBER must be a nonnegative integer without leading zeros")
    tags, maximum = release_history(repo)
    new_version, new_build = version, int(build)
    if not args.check:
        parts = [int(part) for part in version.split(".")]
        index = args.part - 1
        parts[index] += 1
        parts[index + 1:] = [0] * (2 - index)
        new_version = ".".join(str(part) for part in parts)
        new_build = max(int(build), maximum) + 1

    tag = f"v{new_version}"
    if tag in tags:
        raise ValueError(f"Release tag already exists: {tag}; do not move or reuse it")
    if new_build <= maximum:
        raise ValueError(f"BUILD_NUMBER {new_build} must exceed historical maximum {maximum}")
    if args.check:
        print(f"PASS: VERSION={version}, BUILD_NUMBER={build}, tag={tag} available")
    else:
        if not args.dry_run:
            # Recheck both snapshots before writing so an intervening edit is detected.
            if (version_file.read_text(encoding="utf-8") != original_version
                    or build_file.read_text(encoding="utf-8") != original_build):
                raise ValueError("Version files changed during preflight; inspect and retry")
            version_file.write_text(new_version + "\n", encoding="utf-8")
            build_file.write_text(str(new_build) + "\n", encoding="utf-8")
        label = "PREVIEW" if args.dry_run else "UPDATED"
        print(f"{label}: VERSION {version} -> {new_version}; BUILD_NUMBER {build} -> {new_build}")
    print(f"Historical maximum BUILD_NUMBER: {maximum} (local v* tags; fetch origin tags first)")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
