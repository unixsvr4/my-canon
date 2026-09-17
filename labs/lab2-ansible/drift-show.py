#!/usr/bin/env python3
"""Read the Ansible drift archive - the Lab 2 twin of lab1's drift-show.py.

    ./drift-show.py                  list every archived drift event
    ./drift-show.py latest           per-host, per-task diffs of the newest event
    ./drift-show.py 2                detail of event #2 from the list
    ./drift-show.py drift-history/<stamp>   detail of a specific record

Used by drift-check.sh as well, so the console output, drift.txt and this
viewer can never disagree about what a run found:
    ./drift-show.py --render <drift.json>
    ./drift-show.py --index-row <drift.json> <stamp> <scope> <exit> <record>
"""
import csv
import difflib
import json
import os
import sys

LAB = os.path.dirname(os.path.abspath(__file__))
HISTORY = os.path.join(LAB, "drift-history")
INDEX_HEADER = ["detected_utc", "scope", "exit_code", "drifted_hosts", "changed_tasks",
                "not_checked", "hosts", "record"]


def color(text, code, tty):
    return f"\033[{code}m{text}\033[0m" if tty else text


def load(path):
    with open(path) as fh:
        return json.load(fh)


def summarise(run):
    """(drifted {host: n}, not_checked [host], {host: [(task, [diff, ...])]})"""
    stats = run.get("stats", {})
    drifted = {h: s["changed"] for h, s in sorted(stats.items()) if s.get("changed")}
    # A host that failed or was unreachable was NOT checked. Reporting it as
    # "no drift" is how a dead box hides in a green dashboard.
    not_checked = sorted(h for h, s in stats.items() if s.get("unreachable") or s.get("failures"))
    detail = {}
    for play in run.get("plays", []):
        for task in play.get("tasks", []):
            for host, res in task.get("hosts", {}).items():
                if res.get("changed"):
                    diffs = res.get("diff") or []
                    detail.setdefault(host, []).append(
                        (task["task"]["name"], diffs if isinstance(diffs, list) else [diffs]))
    return drifted, not_checked, detail


def as_lines(value):
    if value is None:
        return []
    if isinstance(value, dict):
        return [f"{k}: {v}\n" for k, v in sorted(value.items())]
    return str(value).splitlines(True)


def render(run, tty=False):
    drifted, not_checked, detail = summarise(run)
    out = []
    if drifted:
        out.append(f"{len(drifted)} host(s) drifted from baseline: "
                   + ", ".join(f"{h} ({n} task{'s' if n != 1 else ''})" for h, n in drifted.items()))
    elif not_checked:
        out.append("no drift on the hosts that were checked - the run is INCOMPLETE")
    else:
        out.append("no drift")
    if not_checked:
        out.append(color(f"NOT CHECKED (failed/unreachable): {', '.join(not_checked)}", "31", tty))
    out.append("")

    for host in sorted(detail):
        out.append(color(f"== {host}", "1", tty))
        for task, diffs in detail[host]:
            out.append(f"   TASK [{task}]")
            shown = False
            for d in diffs:
                if "prepared" in d:
                    out.extend("      " + l for l in str(d["prepared"]).splitlines())
                    shown = True
                b, a = as_lines(d.get("before")), as_lines(d.get("after"))
                if not b and not a:
                    continue
                before_hdr = d.get("before_header", "")
                after_hdr = d.get("after_header", "")
                # For template tasks Ansible reports the controller's temporary
                # render path as the "after" header - which leaks a local home
                # directory into records and screen shares. Show the destination
                # file and the template name instead.
                if "ansible-local-" in after_hdr:
                    after_hdr = f"{before_hdr} (rendered from {os.path.basename(after_hdr)})"
                for line in difflib.unified_diff(
                        b, a, fromfile=f"before: {before_hdr}",
                        tofile=f"after:  {after_hdr}", n=1):
                    line = line.rstrip("\n")
                    if line.startswith("+") and not line.startswith("+++"):
                        line = color(line, "32", tty)
                    elif line.startswith("-") and not line.startswith("---"):
                        line = color(line, "31", tty)
                    out.append("      " + line)
                    shown = True
            if not shown:
                out.append("      (changed, but the module returned no diff)")
        out.append("")
    return "\n".join(out).rstrip() + "\n"


def index_row(run, stamp, scope, rc, record):
    drifted, not_checked, detail = summarise(run)
    tasks = sum(len(v) for v in detail.values())
    w = csv.writer(sys.stdout, lineterminator="\n")   # proper quoting, not hand-rolled
    w.writerow([stamp, scope, rc, len(drifted), tasks, ";".join(not_checked),
                ";".join(f"{h}={n}" for h, n in drifted.items()), record])


def records():
    if not os.path.isdir(HISTORY):
        return []
    return [os.path.join(HISTORY, d) for d in sorted(os.listdir(HISTORY))
            if os.path.isfile(os.path.join(HISTORY, d, "drift.json"))]


def when(stamp):
    s = stamp.split("-")[0]
    return f"{s[0:4]}-{s[4:6]}-{s[6:8]} {s[9:11]}:{s[11:13]}:{s[13:15]}Z"


def do_list():
    recs = records()
    if not recs:
        print("no drift recorded (drift-history/ is empty)")
        print("create one:  ./tamper.sh && ./drift-check.sh")
        return 0
    tty = sys.stdout.isatty()
    print(f"{len(recs)} drift event(s) recorded\n")
    print(f"{'#':>3}  {'detected (UTC)':<21} {'hosts':>5} {'tasks':>5}  drifted")
    for i, rec in enumerate(recs, 1):
        drifted, not_checked, detail = summarise(load(os.path.join(rec, "drift.json")))
        names = ", ".join(f"{h}={n}" for h, n in drifted.items())
        if not_checked:
            names += color(f"  NOT CHECKED: {','.join(not_checked)}", "31", tty)
        tasks = sum(len(v) for v in detail.values())
        print(f"{i:>3}  {when(os.path.basename(rec)):<21} {len(drifted):>5} {tasks:>5}  {names}")
    print("\ndetail:  ./drift-show.py latest   |   ./drift-show.py <#>")
    return 0


def do_detail(target):
    recs = records()
    if target == "latest" and recs:
        rec = recs[-1]
    elif target.isdigit() and 1 <= int(target) <= len(recs):
        rec = recs[int(target) - 1]
    else:
        rec = target if os.path.isabs(target) else os.path.join(LAB, target)
    path = os.path.join(rec, "drift.json")
    if not os.path.isfile(path):
        print(f"no such drift record: {target} (have {len(recs)})", file=sys.stderr)
        return 1
    head = f"drift detected {when(os.path.basename(rec))}"
    print(head)
    print("-" * len(head))
    sys.stdout.write(render(load(path), tty=sys.stdout.isatty()))
    print(f"\nrecord: {os.path.relpath(rec, LAB)}/  (drift.txt, drift.json)")
    return 0


if __name__ == "__main__":
    a = sys.argv[1:]
    if not a:
        sys.exit(do_list())
    if a[0] == "--render" and len(a) == 2:
        sys.stdout.write(render(load(a[1])))
        sys.exit(0)
    if a[0] == "--index-row" and len(a) == 6:
        index_row(load(a[1]), *a[2:])
        sys.exit(0)
    sys.exit(do_detail(a[0]))
