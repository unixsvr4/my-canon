#!/usr/bin/env python3
"""Verify a LIVE environment: test what was built, not the code that built it.

    ./verify-env.py envs/dev                # after apply: exit 0 = verified, 1 = failed
    ./verify-env.py envs/prod
    ./verify-env.py --destroyed envs/prod   # after destroy: nothing left behind

`terraform apply` exiting 0 means the provider accepted every API call. It does
not mean the environment works: a resource can be created and then deleted out
of band, hand-edited, wired to the wrong target, or quietly violate a policy
that the module's validations only enforce on INPUT. This script is the
post-apply smoke test. It reads the state and the outputs, then goes and looks
at every real object and asks five questions:

  1. exists       every resource in state has a real object
  2. integrity    each object still matches what Terraform last wrote
  3. unmanaged    nothing exists that Terraform doesn't know about
  4. wiring       references between objects resolve (listener -> service,
                  endpoint -> listeners, runbook -> definition, deploy ids)
  5. policy       the BUILT objects meet environment policy (tags, TLS on
                  public listeners, prod replicas >= 2, deletion protection)
  +  outputs      what the root publishes to its consumers matches reality

The same shape on AWS: `aws ecs describe-services` for exists/policy, the
target group's health for wiring, `aws resourcegroupstaggingapi` for
unmanaged resources, and a curl through each public endpoint.
"""
import hashlib
import json
import os
import re
import stat
import subprocess
import sys

LAB_DIR = os.path.dirname(os.path.abspath(__file__))
MANDATORY_TAGS = ("Environment", "ManagedBy", "Module", "Owner", "CostCenter")
ADDRESS_RE = re.compile(r'^module\.app_stack\.(\w+)\.(\w+)(?:\["([^"]+)"\])?$')

results = []  # (ok, check, detail)


def record(check, failures, ok_detail):
    if failures:
        results.append((False, check, failures))
    else:
        results.append((True, check, [ok_detail]))


def tf_json(root, *args):
    out = subprocess.run(["terraform", *args, "-json"], cwd=root, capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"[ERROR] terraform {' '.join(args)} failed in {root}:\n{out.stderr}")
    return json.loads(out.stdout or "{}")


def load(path):
    with open(path, "rb") as fh:
        return fh.read()


def main():
    args = sys.argv[1:]
    destroyed = "--destroyed" in args
    args = [a for a in args if a != "--destroyed"]
    if len(args) != 1:
        sys.exit(__doc__)
    rel_root = args[0].rstrip("/")
    root = os.path.join(LAB_DIR, rel_root)
    artifact_dir = os.path.join(root, ".artifacts")

    if not os.path.isdir(os.path.join(root, ".terraform")):
        subprocess.run(["terraform", "init", "-input=false"], cwd=root, capture_output=True, check=True)

    state = tf_json(root, "show")
    resources = []
    for module in state.get("values", {}).get("root_module", {}).get("child_modules", []):
        resources.extend(module.get("resources", []))

    on_disk = set()
    if os.path.isdir(artifact_dir):
        for dirpath, _, files in os.walk(artifact_dir):
            on_disk.update(os.path.relpath(os.path.join(dirpath, f), root) for f in files)

    print(f"== verify {rel_root} ({'after destroy' if destroyed else 'after apply'})")

    if destroyed:
        record("state", [f"still in state: {r['address']}" for r in resources], "state is empty")
        record("objects", [f"left behind: {p}" for p in sorted(on_disk)], "no objects left on disk")
        return report()

    if not resources:
        print(f"[FAIL] nothing is deployed in {rel_root}: run terraform apply first")
        return 1

    # Index state by resource type and key.
    files = {}   # type name -> {key: values}
    deploy = {}  # key -> hex
    for r in resources:
        m = ADDRESS_RE.match(r["address"])
        if not m:
            continue
        rtype, name, key = m.groups()
        if rtype == "local_file":
            files.setdefault(name, {})[key] = r["values"]
        elif rtype == "random_id":
            deploy[key] = r["values"]["hex"]

    # --- 1. exists ------------------------------------------------------------
    managed = {}  # relative path -> state values
    for group in files.values():
        for values in group.values():
            managed[os.path.normpath(values["filename"])] = values
    missing = [f"missing: {p}" for p in sorted(managed) if not os.path.isfile(os.path.join(root, p))]
    record("exists", missing, f"{len(managed)} managed object(s) present, {len(deploy)} deploy id(s) in state")

    # --- 2. integrity ---------------------------------------------------------
    # local_file's id IS the SHA-1 of its content, so comparing the hash of the
    # real object with the id in state detects any out-of-band edit.
    drifted = []
    for p, values in sorted(managed.items()):
        full = os.path.join(root, p)
        if not os.path.isfile(full):
            continue
        if hashlib.sha1(load(full)).hexdigest() != values["id"]:
            drifted.append(f"content differs from state: {p}")
        mode = oct(stat.S_IMODE(os.stat(full).st_mode))[2:].zfill(4)
        if mode != values["file_permission"]:
            drifted.append(f"permission {mode}, expected {values['file_permission']}: {p}")
    record("integrity", drifted, "every object matches what Terraform last wrote")

    # --- 3. unmanaged ---------------------------------------------------------
    unmanaged = [f"not in state: {p}" for p in sorted(on_disk - set(managed))]
    record("unmanaged", unmanaged, "no objects outside Terraform's control")

    # Read the REAL objects for the functional checks (skip ones already missing).
    def read_json(values):
        full = os.path.join(root, values["filename"])
        try:
            return json.loads(load(full))
        except (OSError, ValueError):
            return None

    services = {k: read_json(v) for k, v in files.get("service", {}).items()}
    listeners = {k: read_json(v) for k, v in files.get("listener", {}).items()}
    endpoints = {k: read_json(v) for k, v in files.get("public_endpoint", {}).items()}
    datastore = read_json(files.get("stateful_store", {}).get(None, {"filename": "/nonexistent"}))
    unreadable = [f"unreadable or invalid JSON: {k}" for k, v in {**services, **listeners, **endpoints}.items() if v is None]
    if datastore is None:
        unreadable.append("unreadable or invalid JSON: datastore")

    # --- 4. wiring ------------------------------------------------------------
    wiring = list(unreadable)
    service_files = {os.path.normpath(v["filename"]): k for k, v in files.get("service", {}).items()}
    for key, svc in services.items():
        if svc and svc.get("deploy_id") != deploy.get(key):
            wiring.append(f"service {key}: deploy_id {svc.get('deploy_id')} != random_id {deploy.get(key)}")
    for key, lst in listeners.items():
        if not lst:
            continue
        target = os.path.normpath(lst["target"])
        if not os.path.isfile(os.path.join(root, target)):
            wiring.append(f"listener {key}: target {target} does not exist")
        elif service_files.get(target) != lst["service"]:
            wiring.append(f"listener {key}: target {target} is not service {lst['service']}")
    for key, ep in endpoints.items():
        if not ep:
            continue
        ports = sorted(l["port"] for l in listeners.values() if l and l["service"] == key)
        if not ports:
            wiring.append(f"endpoint {key}: no listener serves it")
        elif ports != sorted(ep["ports"]):
            wiring.append(f"endpoint {key}: exposes {sorted(ep['ports'])}, listeners serve {ports}")
    for key, values in files.get("runbook", {}).items():
        full = os.path.join(root, values["filename"])
        if not os.path.isfile(full):
            continue
        text = load(full).decode()
        definition = re.search(r"^- Definition: (.+)$", text, re.M)
        if not definition or not os.path.isfile(os.path.join(root, definition.group(1))):
            wiring.append(f"runbook {key}: its Definition does not point at a real service")
    record("wiring", wiring, f"{len(listeners)} listener(s), {len(endpoints)} endpoint(s) and "
                             f"{len(files.get('runbook', {}))} runbook(s) resolve")

    # --- 5. policy ------------------------------------------------------------
    policy = []
    # The environment the objects claim to belong to: the datastore's, or the
    # services' if the datastore itself is what's broken.
    claimed = [o.get("environment") for o in [datastore, *services.values()] if o and o.get("environment")]
    env = claimed[0] if claimed else None
    objects = {f"service {k}": v for k, v in services.items()}
    objects.update({f"listener {k}": v for k, v in listeners.items()})
    objects.update({f"endpoint {k}": v for k, v in endpoints.items()})
    objects["datastore"] = datastore
    for label, obj in objects.items():
        if not obj:
            continue
        tags = obj.get("tags", {})
        absent = [t for t in MANDATORY_TAGS if not tags.get(t)]
        if absent:
            policy.append(f"{label}: missing tag(s) {', '.join(absent)}")
        if tags.get("Environment") and tags["Environment"] != env:
            policy.append(f"{label}: tagged Environment={tags['Environment']} in a {env} environment")
    for key, svc in services.items():
        if not svc:
            continue
        if svc["image"].endswith(":latest") or ":" not in svc["image"]:
            policy.append(f"service {key}: mutable image {svc['image']}")
        if env == "prod" and svc["desired_count"] < 2:
            policy.append(f"service {key}: desired_count {svc['desired_count']} in prod (minimum 2)")
    for key, lst in listeners.items():
        if lst and lst["scheme"] == "internet-facing" and lst["protocol"] != "HTTPS":
            policy.append(f"listener {key}: internet-facing over {lst['protocol']}")
    if env == "prod" and datastore and datastore.get("deletion_protection") is not True:
        policy.append("datastore: deletion protection is off in prod")
    record("policy", policy, f"tags, TLS, image tags{', replicas and deletion protection' if env == 'prod' else ''} OK ({env})")

    # --- + outputs --------------------------------------------------------------
    outputs = {k: v["value"] for k, v in tf_json(root, "output").items()}
    published = []
    real_names = {k: v["name"] for k, v in services.items() if v}
    if outputs.get("service_names") != real_names:
        published.append(f"service_names output {outputs.get('service_names')} != real {real_names}")
    real_ports = {k: v["port"] for k, v in listeners.items() if v}
    if outputs.get("listeners") != real_ports:
        published.append(f"listeners output {outputs.get('listeners')} != real {real_ports}")
    real_fqdns = {k: v["fqdn"] for k, v in endpoints.items() if v}
    if outputs.get("public_endpoints") != real_fqdns:
        published.append(f"public_endpoints output {outputs.get('public_endpoints')} != real {real_fqdns}")
    record("outputs", published, "outputs match the real objects")

    return report()


def report():
    for ok, check, details in results:
        print(f"   {'PASS' if ok else 'FAIL'}  {check:<10} {details[0]}")
        for d in details[1:]:
            print(f"   {'':<4}  {'':<10} {d}")
    failed = [c for ok, c, _ in results if not ok]
    if failed:
        print(f"[FAIL] {len(failed)} of {len(results)} check(s) failed: {', '.join(failed)}")
        return 1
    print(f"[VERIFIED] {len(results)} of {len(results)} checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
