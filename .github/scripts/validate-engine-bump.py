#!/usr/bin/env python3

"""Validate that an engine bump changes only the canonical pinned version."""

from pathlib import Path
import re
import sys


VERSION_PATTERN = re.compile(
    r'(?ms)^inputs:\n(?:(?!^\S).)*?^  version:\n'
    r'(?:    [^\n]*\n)*?^    default: "('
    r'(?:0|[1-9][0-9]*)\.'
    r'(?:0|[1-9][0-9]*)\.'
    r'(?:0|[1-9][0-9]*)'
    r')"$'
)


def read(path: str) -> str:
    return Path(path).read_text(encoding="utf-8")


def version(content: str, label: str) -> str:
    match = VERSION_PATTERN.search(content)
    if not match:
        raise SystemExit(f"could not find a canonical stable version default in {label}")
    return match.group(1)


def main() -> None:
    if len(sys.argv) != 5:
        raise SystemExit(
            "usage: validate-engine-bump.py OLD_ACTION OLD_README NEW_ACTION NEW_README"
        )

    old_action = read(sys.argv[1])
    old_readme = read(sys.argv[2])
    new_action = read(sys.argv[3])
    new_readme = read(sys.argv[4])

    old = version(old_action, "the previous action.yml")
    new = version(new_action, "action.yml")
    if old == new:
        raise SystemExit("the pinprick default version did not change")
    if tuple(map(int, new.split("."))) <= tuple(map(int, old.split("."))):
        raise SystemExit("the pinprick default version must increase")
    if old_action.count(old) != 3 or old_readme.count(old) != 2:
        raise SystemExit("the previous version-reference contract has drifted")
    if new_action != old_action.replace(old, new):
        raise SystemExit("action.yml contains changes beyond the version replacement")
    if new_readme != old_readme.replace(old, new):
        raise SystemExit("README.md contains changes beyond the version replacement")

    print(new)


if __name__ == "__main__":
    main()
