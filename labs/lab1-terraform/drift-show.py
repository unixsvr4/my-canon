#!/usr/bin/env python3
"""Read the drift archive without reading raw JSON.

    ./drift-show.py                  list every archived drift event
    ./drift-show.py latest           attribute-level detail of the newest event
    ./drift-show.py 2                detail of event #2 from the list
    ./drift-show.py envs-dev/2026... detail of a specific record
    ./drift-show.py envs/dev/drift.plan.json   detail of a live KEEP_PLAN=1 plan

plan.txt in each record is Terraform's own human-readable diff. This exists for
the other question - "what has drifted here over time, and which attribute" -
which is the one a ticket or a handover actually asks.
"""
import json
import os
import sys

LAB = os.path.dirname(os.path.abspath(__file__))
HISTORY = os.path.join(LAB, "drift-history")
TTY = sys.stdout.isatty()

# Terraform's own plan symbols.
SYM = {"create": "+", "update": chr(0x7E), "delete": "-", "replace": "-/+",
       "read": "<=", "no-op": " "}
COLOR = {"create": "32", "update": "33", "delete": "31", "replace": "31"}


def paint(text, action):
    code = COLOR.get(action)
    return f"\033[{code}m{text}\033[0m" if (TTY and code) else text


def action_of(change):
    acts = change["actions"]
    if acts in (["create", "delete"], ["delete", "create"]):
        return "replace"
    return "+".join(acts)


def short(value, width=68):
    """One-line rendering of any attribute value."""
    if value is None:
        return "null"
    if isinstance(value, (dict, list)):
        value = json.dumps(value, sort_keys=True, separators=(",", ":"))
    else:
        value = str(value)
    value = " ".join(value.split())
    return value if len(value) <= width else value[: width - 1] + "…"


def flatten(value, prefix=""):
    """dict (or a JSON string holding one) -> {"a.b": leaf}.

    Without this, a changed attribute that happens to be a JSON document renders
    as two truncated blobs that look identical - which is the opposite of useful.
    """
    if isinstance(value, str):
        stripped = value.strip()
        if stripped[:1] in ("{", "[") :
            try:
                value = json.loads(stripped)
            except ValueError:
                pass
    if isinstance(value, dict):
        out = {}
        for k, v in value.items():
            out.update(flatten(v, f"{prefix}.{k}" if prefix else k))
        return out
    return {prefix: value}


def attr_delta(key, before, after):
    """Lines describing how one attribute changed, drilled into JSON if needed."""
    fb, fa = flatten(before, key), flatten(after, key)
    keys = [k for k in sorted(set(fb) | set(fa)) if fb.get(k) != fa.get(k)]
    lines = []
    for k in keys:
        b, a = short(fb.get(k), 34), short(fa.get(k), 34)
        if len(b) + len(a) <= 62:
            lines.append(f"      {k}: {b} -> {a}")
        else:
            lines.append(f"      {k}:")
            lines.append(f"        - {short(fb.get(k))}")
            lines.append(f"        + {short(fa.get(k))}")
    return lines


def records():
    """Every archived record, oldest first: (root, stamp, dir)."""
    out = []
    if not os.path.isdir(HISTORY):
        return out
    for slug in sorted(os.listdir(HISTORY)):
        d = os.path.join(HISTORY, slug)
        if not os.path.isdir(d):
            continue
        for stamp in sorted(os.listdir(d)):
            rec = os.path.join(d, stamp)
            if os.path.isfile(os.path.join(rec, "plan.json")):
                out.append((slug.replace("-", "/", 1), stamp, rec))
    return out


def when(stamp):
    return f"{stamp[0:4]}-{stamp[4:6]}-{stamp[6:8]} {stamp[9:11]}:{stamp[11:13]}:{stamp[13:15]}Z"


def changes(plan_json):
    with open(plan_json) as fh:
        plan = json.load(fh)
    return [rc for rc in plan.get("resource_changes", [])
            if rc["change"]["actions"] != ["no-op"]]


def do_list():
    recs = records()
    if not recs:
        print("no drift recorded (drift-history/ is empty)")
        print("create one:  echo '{\"tampered\":true}' > envs/dev/.artifacts/canon-dev-api.json"
              " && ./drift-check.sh envs/dev")
        return 0

    print(f"{len(recs)} drift event(s) recorded\n")
    print(f"{'#':>3}  {'detected (UTC)':<21} {'root':<10} {'res':>3}  resources")
    for i, (root, stamp, rec) in enumerate(recs, 1):
        rcs = changes(os.path.join(rec, "plan.json"))
        names = ", ".join(
            paint(rc["address"].replace("module.app_stack.", ""), action_of(rc["change"]))
            for rc in rcs)
        print(f"{i:>3}  {when(stamp):<21} {root:<10} {len(rcs):>3}  {short(names, 90)}")
    print(f"\ndetail:  ./drift-show.py latest   |   ./drift-show.py <#>")
    print(f"full terraform diff:  cat {os.path.relpath(recs[-1][2], LAB)}/plan.txt")
    return 0


def do_detail(target):
    recs = records()
    if target == "latest":
        if not recs:
            print("no drift recorded", file=sys.stderr)
            return 1
        root, stamp, plan_json = recs[-1][0], recs[-1][1], os.path.join(recs[-1][2], "plan.json")
    elif target.isdigit():
        i = int(target)
        if not 1 <= i <= len(recs):
            print(f"no event #{i} (have {len(recs)})", file=sys.stderr)
            return 1
        root, stamp, plan_json = recs[i - 1][0], recs[i - 1][1], os.path.join(recs[i - 1][2], "plan.json")
    else:
        p = target if os.path.isabs(target) else os.path.join(LAB, target)
        plan_json = p if p.endswith(".json") else os.path.join(p, "plan.json")
        if not os.path.isfile(plan_json):
            print(f"not a drift record: {target}", file=sys.stderr)
            return 1
        root, stamp = "-", ""

    rcs = changes(plan_json)
    head = (f"{root}  detected {when(stamp)}" if stamp
            else f"plan: {plan_json}")
    print(head)
    print("-" * len(head))
    print(f"{len(rcs)} resource(s) differ from code\n")

    for rc in rcs:
        action = action_of(rc["change"])
        print(paint(f"{SYM.get(action, action):>3} {rc['address']}", action),
              paint(f"[{action}]", action))

        before = rc["change"]["before"] or {}
        after = rc["change"]["after"] or {}
        unknown = rc["change"].get("after_unknown") or {}

        keys = [k for k in sorted(set(before) | set(after))
                if before.get(k) != after.get(k) and not unknown.get(k)]
        # A create has no "before", so every attribute would be listed - the
        # useful ones are the identity of the thing, not its 9 checksum fields.
        if not before:
            keys = [k for k in keys if after.get(k) not in (None, "")]

        lines = []
        for k in keys:
            if before:
                lines.extend(attr_delta(k, before.get(k), after.get(k)))
            else:
                for fk, fv in sorted(flatten(after.get(k), k).items()):
                    lines.append(f"      {fk} = {short(fv)}")

        if not lines:
            lines = ["      (no readable attribute delta - see plan.txt)"]
        cap = 14
        for line in lines[:cap]:
            print(line)
        if len(lines) > cap:
            print(f"      ... {len(lines) - cap} more attribute(s) - see plan.txt")
        print()

    # Only point at plan.txt when there is one: an ad-hoc plan.json passed on
    # the command line has no archived sibling.
    txt = os.path.join(os.path.dirname(plan_json), "plan.txt")
    if os.path.isfile(txt):
        rel = os.path.relpath(txt, LAB)
        print(f"terraform's own diff:  cat {rel if not rel.startswith('..') else txt}")
    return 0


if __name__ == "__main__":
    sys.exit(do_list() if len(sys.argv) == 1 else do_detail(sys.argv[1]))
