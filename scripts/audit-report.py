"""Turns SwiftLint's JSON into a short to-do for make audit: grouped by problem, most useful first, one line per finding."""
import json
import sys
from collections import Counter
from pathlib import Path

root = Path(sys.argv[1])
findings = []
for path in sys.argv[2:]:
    text = Path(path).read_text().strip()
    if text:
        findings += json.loads(text)

# Most worth acting on first. A noisy group shows a count per file instead of every line.
groups = [
    ("unused_declaration", "Unused code", "nothing calls it, so it can likely go"),
    ("unused_import", "Unused imports", "the file builds without them"),
    ("cyclomatic_complexity", "Tangled functions", "too many branches to follow, worth splitting"),
    ("function_body_length", "Long functions", "worth splitting"),
    ("type_body_length", "Long types", "worth splitting into smaller ones"),
    ("file_length", "Long files", "worth splitting"),
    ("force_try", "try!", "crashes instead of handling the error"),
    ("force_unwrapping", "Force unwraps", "crash if the value is ever nil"),
]
noisy = 15
top = 10
lines_cache = {}


def code(file, line):
    if file not in lines_cache:
        lines_cache[file] = Path(file).read_text().splitlines()
    text = lines_cache[file][line - 1].strip() if 0 < line <= len(lines_cache[file]) else ""
    return text if len(text) <= 70 else text[:67] + "..."


def short(file):
    return str(Path(file).relative_to(root / "Sources")) if (root / "Sources") in Path(file).parents else str(Path(file).relative_to(root))


if not findings:
    print("Nothing found.")
for rule, title, why in groups:
    hits = sorted((f for f in findings if f["rule_id"] == rule), key=lambda f: (f["file"], f["line"]))
    if not hits:
        continue
    print(f"\n{title} ({len(hits)}): {why}")
    if len(hits) > noisy:
        counts = Counter(short(f["file"]) for f in hits).most_common()
        for file, count in counts[:top]:
            print(f"  {count:3}  {file}")
        if len(counts) > top:
            print(f"       and {len(counts) - top} more files")
        continue
    for f in hits:
        if rule == "file_length":
            print(f"  {short(f['file']):44} {len(Path(f['file']).read_text().splitlines())} lines")
            continue
        place = f"{short(f['file'])}:{f['line']}"
        print(f"  {place:44} {code(f['file'], f['line'])}")
