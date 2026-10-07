#!/usr/bin/env python3
"""Keeps Farol's comments and docs short and plain.

Usage:
  python3 scripts/check-style.py            check the whole repo
  python3 scripts/check-style.py FILE...    check some files
  python3 scripts/check-style.py --hook     Claude Code hook, reads the edited file from stdin JSON
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHECKED = {".swift", ".sh", ".md", ".py"}
MAX_COMMENT_LINES = 3
EM_DASH = chr(0x2014)

SLOP = re.compile(
    r"\b(leverag(e|es|ed|ing)|utiliz(e|es|ed|ing)|seamless(ly)?|robust|comprehensive|"
    r"streamlin(e|es|ed|ing)|delv(e|es|ing)|empower(s|ed|ing)?|effortless(ly)?|"
    r"cutting[- ]edge|game[- ]changer|blazing(ly)?|supercharg(e|es|ed|ing)|"
    r"it'?s worth noting|in today'?s|moreover|furthermore)\b",
    re.IGNORECASE,
)


def comment_text(line: str, suffix: str) -> str | None:
    """The comment part of a code line, or None if the line is not a comment."""
    stripped = line.strip()
    if suffix == ".swift" and stripped.startswith("//"):
        return stripped.lstrip("/")
    if suffix in {".sh", ".py"} and stripped.startswith("#") and not stripped.startswith("#!"):
        return stripped.lstrip("#")
    return None


def check(path: Path) -> list[str]:
    problems = []
    suffix = path.suffix
    in_fence = False
    in_docstring = False
    comment_run = 0
    open_sentence = False

    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        where = f"{path.relative_to(ROOT) if ROOT in path.parents else path}:{number}"

        if EM_DASH in line:
            problems.append(f"{where}: em dash. Use a period, comma or colon.")

        if suffix == ".md":
            if line.strip().startswith("```"):
                in_fence = not in_fence
                continue
            prose = None if in_fence else re.sub(r"`[^`]*`", "", line)
        elif suffix == ".py" and line.strip().startswith('"""'):
            # Docstrings count as prose. A one-line docstring opens and closes itself.
            if line.strip().count('"""') == 1:
                in_docstring = not in_docstring
            prose = line
        else:
            prose = line if in_docstring else comment_text(line, suffix)

        is_comment = suffix != ".md" and prose is not None and not in_docstring
        comment_run = comment_run + 1 if is_comment else 0
        if is_comment and open_sentence:
            problems.append(f"{where}: sentence wrapped across comment lines. Put it on one line.")
        # Xcode's MARK lines are section headers, not sentences.
        open_sentence = is_comment and not prose.strip().startswith("MARK:") and not re.search(r"[.:?!)]$", prose.strip())
        if comment_run == MAX_COMMENT_LINES + 1:
            problems.append(f"{where}: comment block over {MAX_COMMENT_LINES} lines. Keep only the non-obvious why.")

        # Interface text in Swift strings is prose too, and reads as badly as a doc with the same slip.
        if suffix == ".swift" and prose is None:
            for literal in re.findall(r'"((?:[^"\\]|\\.)*)"', line):
                if "; " in literal:
                    problems.append(f"{where}: semicolon in interface text. Split it into two sentences.")
                if match := SLOP.search(literal):
                    problems.append(f'{where}: "{match.group(0)}" in interface text reads as filler. Say it plainly.')

        if prose is None:
            continue
        if ";" in prose:
            problems.append(f"{where}: semicolon in prose. Split it into two sentences.")
        if match := SLOP.search(prose):
            problems.append(f'{where}: "{match.group(0)}" reads as filler. Say it plainly.')

    return problems


def git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True)


def repo_files() -> list[Path]:
    # What git tracks or would add, so anything git ignores is left alone.
    listed = git("ls-files", "-z", "--cached", "--others", "--exclude-standard").stdout.split("\0")
    return [p for p in (ROOT / name for name in listed if name) if p.is_file() and p.suffix in CHECKED]


def main() -> int:
    args = sys.argv[1:]
    if args == ["--hook"]:
        payload = json.load(sys.stdin)
        target = payload.get("tool_input", {}).get("file_path", "")
        path = Path(target).resolve()
        if path.suffix not in CHECKED or ROOT not in path.parents or git("check-ignore", "-q", str(path)).returncode == 0:
            return 0
        files = [path]
    else:
        files = [Path(a).resolve() for a in args] or repo_files()

    problems = [p for f in files for p in check(f)]
    if not problems:
        return 0
    print("Style check failed (see scripts/check-style.py):", file=sys.stderr)
    print("\n".join(problems), file=sys.stderr)
    # Exit code 2 makes Claude Code feed this back to the model so it fixes the file.
    return 2 if args == ["--hook"] else 1


if __name__ == "__main__":
    sys.exit(main())
