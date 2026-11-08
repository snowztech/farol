"""Reads a make profile recording and says whether anything stands out: freezes, where the CPU went, and the commands Farol ran.
Prints a short verdict, and writes the details as Markdown for an agent. Usage: profile-report.py <trace> <pid> <markdown out>"""
import subprocess
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path

trace, pid, out = sys.argv[1], sys.argv[2], Path(sys.argv[3])


def table(schema):
    """The rows of one table, each a dict of column to element. xctrace writes a value once and points back to it by id after."""
    xml = subprocess.run(
        ["xcrun", "xctrace", "export", "--input", trace, "--xpath", f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'],
        capture_output=True, text=True).stdout
    node = ET.fromstring(xml).find("node") if xml.strip() else None
    if node is None:
        return []
    columns = [col.findtext("mnemonic") for col in node.find("schema").findall("col")]
    seen = {}

    def value(element):
        for inner in element.iter():
            if "id" in inner.attrib:
                seen[inner.attrib["id"]] = inner
        return seen.get(element.attrib.get("ref"), element)

    def stack(element):
        # Frames and their binaries point back by id too, and only within this table.
        result = []
        for frame in element:
            frame = value(frame)
            binary = frame.find("binary")
            binary = value(binary) if binary is not None else None
            result.append((frame.get("name") or "?", "Farol.app" in (binary.get("path", "") if binary is not None else "")))
        return result

    rows = []
    for row in node.findall("row"):
        values = dict(zip(columns, map(value, row)))
        if "stack" in values:
            values["stack"] = stack(values["stack"])
        rows.append(values)
    return rows


def number(element):
    try:
        return int(element.text)
    except (AttributeError, TypeError, ValueError):
        return 0


def ours(element):
    """The process recorded, not the others sampled beside it."""
    return element is not None and pid in (element.get("fmt") or "")


def on_main(row):
    return "Main Thread" in (row.get("thread").get("fmt") or "")


def frames(row):
    return row.get("stack") or []


def ms(nanoseconds):
    return f"{nanoseconds / 1e6:,.0f} ms"


samples = [row for row in table("time-profile") if ours(row.get("process"))]
cpu = sum(number(row.get("weight")) for row in samples)
start = min((number(row.get("time")) for row in samples), default=0)
end = max((number(row.get("time")) for row in samples), default=0)
seconds = max((end - start) / 1e9, 1)

# Time in a function and everything it called, counted once per sample.
total = defaultdict(int)
alone = defaultdict(int)
for row in samples:
    weight = number(row.get("weight"))
    stack = frames(row)
    if stack:
        alone[stack[0][0]] += weight
    for name in {name for name, farol in stack if farol}:
        total[name] += weight

hangs = [row for row in table("potential-hangs") if ours(row.get("process"))]


def busy_during(hang):
    """The function of Farol's own that the main thread spent the freeze in, the most."""
    begin = number(hang.get("start"))
    finish = begin + number(hang.get("duration"))
    spent = defaultdict(int)
    for row in samples:
        if on_main(row) and begin <= number(row.get("time")) <= finish:
            farol = [name for name, mine in frames(row) if mine]
            if farol:
                spent[farol[0]] += number(row.get("weight"))
    return max(spent, key=spent.get) if spent else "nothing of Farol's own, so likely the system"


# Perf marks every process it starts as a "Command" interval, named after the command.
opened = {}
commands = defaultdict(lambda: {"runs": 0, "time": 0, "longest": 0, "main": 0})
for row in table("os-signpost"):
    if not ours(row.get("process")) or (row.get("name").text if row.get("name") is not None else "") != "Command":
        continue
    kind = (row.get("event-type").text or "").lower()
    key = row.get("identifier").text
    if kind == "begin":
        message = row.get("message")
        opened[key] = (number(row.get("time")), message.text if message is not None else "?", on_main(row))
    elif kind == "end" and key in opened:
        began, command, main = opened.pop(key)
        took = number(row.get("time")) - began
        stats = commands[" ".join(command.split()[:2])]
        stats["runs"] += 1
        stats["time"] += took
        stats["longest"] = max(stats["longest"], took)
        stats["main"] += main

# What counts as worth a look, like the Inspector's readings.
issues = []
if hangs:
    issues.append(f"{len(hangs)} {'freeze' if len(hangs) == 1 else 'freezes'} of the window")
blocking = sum(stats["main"] for stats in commands.values())
if blocking:
    issues.append(f"{blocking} {'command' if blocking == 1 else 'commands'} run on the main thread")
if cpu / 1e9 / seconds > 0.5:
    issues.append(f"busy CPU: {cpu / 1e9 / seconds:.0%} of one core on average")
runs = sum(stats["runs"] for stats in commands.values())
if runs / seconds > 4:
    issues.append(f"{runs / seconds:.1f} commands a second, which looks like a loop")
verdict = "Nothing stands out." if issues else ""

md = ["# Farol profile", "", f"Recording: `{trace}`, open it in Instruments for the full picture.", ""]
print()
if issues:
    print("Worth a look:")
    md += ["## Worth a look", ""]
    for issue in issues:
        print(f"  - {issue}")
        md.append(f"- {issue}")
else:
    print(verdict)
    md.append(verdict)
md.append("")

md += ["## Freezes", ""]
if hangs:
    print("\nFreezes:")
    for hang in hangs:
        at = (number(hang.get("start")) - start) / 1e9
        line = f"{at:5.1f} s in, {ms(number(hang.get('duration')))}, in {busy_during(hang)}"
        print(f"  {line}")
        md.append(f"- {line}")
else:
    md.append("None.")
md.append("")

md += ["## Where the CPU went", "", f"Farol used {cpu / 1e9:.1f} s of CPU in {seconds:.0f} s.", "",
       "Farol's own functions, with what they called:", ""]
heaviest = sorted(total.items(), key=lambda item: -item[1])[:15]
md += [f"- {ms(weight)} `{name}`" for name, weight in heaviest] or ["None sampled."]
md += ["", "Where the time was spent itself, Farol's or the system's:", ""]
md += [f"- {ms(weight)} `{name}`" for name, weight in sorted(alone.items(), key=lambda item: -item[1])[:10]] or ["None sampled."]
if heaviest:
    print("\nHeaviest of Farol's own:")
for name, weight in heaviest[:5]:
    print(f"  {ms(weight):>9}  {name[:90]}")
md.append("")

md += ["## Commands", ""]
if commands:
    md += ["| Command | Runs | Total | Longest | On the main thread |", "|---|---|---|---|---|"]
    for command, stats in sorted(commands.items(), key=lambda item: -item[1]["time"]):
        md.append(f"| `{command}` | {stats['runs']} | {ms(stats['time'])} | {ms(stats['longest'])} | {stats['main']} |")
else:
    md.append("None ran.")

out.write_text("\n".join(md) + "\n")
print(f"\nThe details, to hand to an agent: {out}")
