"""Turns SwiftLint's JSON into a short to-do for the terminal, and the full list as Markdown for an agent.
Grouped by problem, most worth acting on first. Usage: audit-report.py <root> <markdown out> <json>..."""
import json
import sys
from collections import Counter
from pathlib import Path

root = Path(sys.argv[1])
out = Path(sys.argv[2])
findings = []
for path in sys.argv[3:]:
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


def place(f):
    if f["rule_id"] == "file_length":
        return short(f["file"]), f"{len(Path(f['file']).read_text().splitlines())} lines"
    return f"{short(f['file'])}:{f['line']}", code(f["file"], f["line"])


markdown = ["# Code audit", "", "Each line is a file and line in Sources, then the code there. Fix what's worth it, leave the rest.", ""]
if not findings:
    print("Nothing found.")
    markdown.append("Nothing found.")
for rule, title, why in groups:
    hits = sorted((f for f in findings if f["rule_id"] == rule), key=lambda f: (f["file"], f["line"]))
    if not hits:
        continue
    print(f"\n{title} ({len(hits)}): {why}")
    markdown += [f"## {title} ({len(hits)})", "", f"{why[0].upper()}{why[1:]}. SwiftLint rule `{rule}`.", ""]
    markdown += [f"- `{where}` `{text}`" for where, text in map(place, hits)] + [""]
    if len(hits) > noisy:
        counts = Counter(short(f["file"]) for f in hits).most_common()
        for file, count in counts[:top]:
            print(f"  {count:3}  {file}")
        if len(counts) > top:
            print(f"       and {len(counts) - top} more files")
        continue
    for where, text in map(place, hits):
        print(f"  {where:44} {text}")

out.write_text("\n".join(markdown))
print(f"\nThe full list, to hand to an agent: {out}")
