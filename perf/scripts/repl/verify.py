#!/usr/bin/env python3
"""Planned changes and data checks for T17 (repl-1, issue #23).

  verify.py manifest-prepare            on the primary, before the PR cut: the
                                        objects the cut will change or remove
  verify.py manifest-apply              on the primary, during the PR cut: new,
                                        changed, and deleted objects of every
                                        kind; writes $RES/manifest.json
  verify.py manifest-check <cluster>    after catch-up: every manifest entry
                                        reads back on <cluster> as recorded
  verify.py writes-final <cluster> <writes.log>
                                        every key the KV load wrote has the
                                        last logged version on <cluster>
  verify.py writes-missing <cluster> <writes.log> <cut_ms> <promote_ms> [token cluster]
                                        a promoted DR replica: writes made
                                        before the cut are all there, and
                                        how many made after it are missing

Uses clusters.json and the root tokens repl/lib.sh caches in /opt/perf/.repl.
Each command prints a JSON result and writes it to $RES/<command>[-<cluster>].json.
"""
import base64
import concurrent.futures as cf
import hashlib
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request

CLUSTERS = json.load(open(os.environ.get("PERF_CLUSTERS", "/etc/perf/clusters.json")))
STATE = "/opt/perf/.repl"
RES = os.environ.get("RES") or f"/opt/perf/results/{os.environ.get('PLAN', 'repl-1')}-repl"
CTX = ssl.create_default_context(cafile=os.environ.get("VAULT_CACERT", "/etc/perf/ca.crt"))

# Sizes of the manifest: enough of each kind to show the sync handles it.
N_NEW = int(os.environ.get("MANIFEST_NEW", 200))
N_UPD = int(os.environ.get("MANIFEST_UPDATE", 100))
N_DEL = int(os.environ.get("MANIFEST_DELETE", 100))


def token(cluster):
    with open(f"{STATE}/token-{cluster}") as f:
        return f.read().strip()


def call(cluster, method, path, body=None, tok=None, timeout=15):
    """-> (status, parsed JSON or {})"""
    url = f"{CLUSTERS[cluster]['addr']}/v1/{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("X-Vault-Token", tok or token(cluster))
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=timeout) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, {"raw": raw[:300].decode(errors="replace")}
    except Exception as e:  # noqa: BLE001 - a probe result, not a crash
        return 0, {"error": str(e)}


def must(cluster, method, path, body=None):
    for attempt in range(5):
        code, out = call(cluster, method, path, body)
        if 200 <= code < 300:
            return out
        time.sleep(2 * (attempt + 1))
    raise SystemExit(f"{method} {path} on {cluster}: {code} {out}")


def sha(s):
    return hashlib.sha256(s.encode()).hexdigest()


def rand():
    return base64.b16encode(os.urandom(16)).decode()


def save(name, result):
    os.makedirs(RES, exist_ok=True)
    with open(f"{RES}/{name}.json", "w") as f:
        json.dump(result, f, indent=2)
    print(json.dumps(result if len(json.dumps(result)) < 4000 else result.get("summary", result), indent=2))


def kv_put(c, key, value):
    must(c, "POST", f"kv_perf/data/{key}", {"data": {"value": value}})


def policy_text(version):
    return f'path "kv_perf/data/manifest/*" {{ capabilities = ["read"] }}\n# manifest {version}\n'


def manifest_prepare():
    c = "primary"
    for i in range(N_UPD):
        kv_put(c, f"manifest/upd-{i}", "before")
    for i in range(N_DEL):
        kv_put(c, f"manifest/del-{i}", "before")
    mounts = must(c, "GET", "sys/mounts")
    if "manifest_old/" not in mounts.get("data", mounts):
        must(c, "POST", "sys/mounts/manifest_old", {"type": "kv", "options": {"version": "2"}})
        time.sleep(5)
    must(c, "POST", "manifest_old/data/keep", {"data": {"value": "old"}})
    must(c, "PUT", "sys/policies/acl/manifest-pol", {"policy": policy_text("v1")})
    must(c, "POST", "pki_perf/roles/manifest-role", {"allow_any_name": True, "ttl": "1h", "no_store": True})
    must(c, "POST", "auth/approle/role/manifest-role", {"token_ttl": "10m", "token_policies": "default"})
    must(c, "POST", "identity/entity", {"name": "manifest-entity-old"})
    save("manifest-prepare", {"ok": True, "updated": N_UPD, "deleted": N_DEL})


def manifest_apply():
    c = "primary"
    m = {"kv": {}, "kv_deleted": [], "policies": {}, "pki_roles": {}, "approle_roles": {},
         "mounts_present": {}, "mounts_absent": [], "entities_present": [], "entities_absent": [],
         "groups": {}, "started": time.time()}
    for i in range(N_NEW):
        val = rand()
        kv_put(c, f"manifest/new-{i}", val)
        m["kv"][f"manifest/new-{i}"] = sha(val)
    for i in range(N_UPD):
        val = rand()
        kv_put(c, f"manifest/upd-{i}", val)
        m["kv"][f"manifest/upd-{i}"] = sha(val)
    for i in range(N_DEL):
        must(c, "DELETE", f"kv_perf/metadata/manifest/del-{i}")
        m["kv_deleted"].append(f"manifest/del-{i}")
    for name, ver in (("manifest-pol", "v2"), ("manifest-new", "v1")):
        must(c, "PUT", f"sys/policies/acl/{name}", {"policy": policy_text(ver)})
        m["policies"][name] = sha(policy_text(ver))
    for name, ttl in (("manifest-role", "2h"), ("manifest-new-role", "3h")):
        must(c, "POST", f"pki_perf/roles/{name}", {"allow_any_name": True, "ttl": ttl, "no_store": True})
        m["pki_roles"][name] = {"ttl": int(ttl[0]) * 3600}
    for name, ttl in (("manifest-role", 1200), ("manifest-new-role", 1800)):
        must(c, "POST", f"auth/approle/role/{name}", {"token_ttl": ttl, "token_policies": "default"})
        m["approle_roles"][name] = {"token_ttl": ttl}
    must(c, "POST", "auth/approle/role/manifest-new-role/secret-id", {})
    must(c, "DELETE", "sys/mounts/manifest_old")
    m["mounts_absent"].append("manifest_old/")
    must(c, "POST", "sys/mounts/manifest_new", {"type": "kv", "options": {"version": "2"}})
    time.sleep(5)
    val = rand()
    must(c, "POST", "manifest_new/data/k", {"data": {"value": val}})
    m["mounts_present"]["manifest_new/"] = {"key": "manifest_new/data/k", "sha": sha(val)}
    ent = must(c, "POST", "identity/entity", {"name": "manifest-entity-new", "metadata": {"manifest": "1"}})
    eid = ent["data"]["id"]
    must(c, "POST", "identity/group", {"name": "manifest-group", "member_entity_ids": [eid]})
    must(c, "DELETE", "identity/entity/name/manifest-entity-old")
    m["entities_present"].append("manifest-entity-new")
    m["entities_absent"].append("manifest-entity-old")
    m["groups"]["manifest-group"] = [eid]
    m["finished"] = time.time()
    save("manifest", m)


def manifest_check(cluster):
    m = json.load(open(f"{RES}/manifest.json"))
    fails = []
    checked = 0

    def kv(key):
        code, out = call(cluster, "GET", f"kv_perf/data/{key}")
        return key, code, (out.get("data") or {}).get("data", {}).get("value")

    with cf.ThreadPoolExecutor(32) as ex:
        for key, code, val in ex.map(kv, m["kv"]):
            checked += 1
            if code != 200 or sha(val or "") != m["kv"][key]:
                fails.append({"kind": "kv", "key": key, "code": code})
        for key in m["kv_deleted"]:
            checked += 1
            code, _ = call(cluster, "GET", f"kv_perf/metadata/{key}")
            if code != 404:
                fails.append({"kind": "kv_deleted", "key": key, "code": code})
    for name, want in m["policies"].items():
        checked += 1
        code, out = call(cluster, "GET", f"sys/policies/acl/{name}")
        if code != 200 or sha((out.get("data") or {}).get("policy", "")) != want:
            fails.append({"kind": "policy", "name": name, "code": code})
    for name, want in m["pki_roles"].items():
        checked += 1
        code, out = call(cluster, "GET", f"pki_perf/roles/{name}")
        if code != 200 or (out.get("data") or {}).get("ttl") != want["ttl"]:
            fails.append({"kind": "pki_role", "name": name, "code": code, "got": (out.get("data") or {}).get("ttl")})
    for name, want in m["approle_roles"].items():
        checked += 1
        code, out = call(cluster, "GET", f"auth/approle/role/{name}")
        if code != 200 or (out.get("data") or {}).get("token_ttl") != want["token_ttl"]:
            fails.append({"kind": "approle_role", "name": name, "code": code})
    checked += 1
    code, out = call(cluster, "LIST", "auth/approle/role/manifest-new-role/secret-id")
    if code != 200 or not (out.get("data") or {}).get("keys"):
        fails.append({"kind": "approle_secret_id", "code": code})
    code, mounts = call(cluster, "GET", "sys/mounts")
    mounts = mounts.get("data", mounts)
    for path in m["mounts_absent"]:
        checked += 1
        if path in mounts:
            fails.append({"kind": "mount_absent", "path": path})
    for path, want in m["mounts_present"].items():
        checked += 1
        code, out = call(cluster, "GET", want["key"])
        val = ((out.get("data") or {}).get("data") or {}).get("value", "")
        if path not in mounts or sha(val) != want["sha"]:
            fails.append({"kind": "mount_present", "path": path, "code": code})
    for name in m["entities_present"] + m["entities_absent"]:
        checked += 1
        code, out = call(cluster, "POST", "identity/lookup/entity", {"name": name})
        present = code == 200 and bool(out.get("data"))
        if present != (name in m["entities_present"]):
            fails.append({"kind": "entity", "name": name, "present": present})
    for name, members in m["groups"].items():
        checked += 1
        code, out = call(cluster, "GET", f"identity/group/name/{name}")
        got = (out.get("data") or {}).get("member_entity_ids") or []
        if code != 200 or sorted(got) != sorted(members):
            fails.append({"kind": "group", "name": name, "code": code})
    save(f"manifest-check-{cluster}", {"cluster": cluster, "checked": checked, "failed": len(fails),
                                       "ok": not fails, "failures": fails[:50]})


def read_writes(path, until_ms=None):
    """-> {key: [(ts_ms, version), ...]} from 'W <ms> <key> <version>' lines."""
    out = {}
    with open(path, errors="replace") as f:
        for line in f:
            p = line.split()
            if len(p) != 4 or p[0] != "W" or not p[3].isdigit():
                continue
            ts = int(p[1])
            if until_ms is not None and ts > until_ms:
                continue
            out.setdefault(p[2], []).append((ts, int(p[3])))
    return out


def versions(cluster, keys, tok=None):
    def one(k):
        # Retry timeouts and 5xx: just after a promotion some reads fail.
        for attempt in range(4):
            code, out = call(cluster, "GET", f"kv_perf/metadata/{k}", tok=tok)
            if code == 200:
                return k, (out.get("data") or {}).get("current_version", 0)
            if code == 404:
                return k, 0
            time.sleep(1 + attempt)
        return k, -1

    with cf.ThreadPoolExecutor(32) as ex:
        return dict(ex.map(one, keys))


def writes_final(cluster, path):
    w = read_writes(path)
    want = {k: max(v for _, v in vs) for k, vs in w.items()}
    got = versions(cluster, list(want))
    behind = {k: (want[k], got[k]) for k in want if got[k] < want[k]}
    errors = sum(1 for v in got.values() if v < 0)
    save(f"writes-final-{cluster}", {"cluster": cluster, "keys": len(want), "writes": sum(len(v) for v in w.values()),
                                     "behind": len(behind), "read_errors": errors, "ok": not behind and not errors,
                                     "examples": dict(list(behind.items())[:20])})


def writes_missing(cluster, path, cut_ms, promote_ms, tok_cluster=None):
    cut_ms, promote_ms = int(cut_ms), int(promote_ms)
    slack = 2000  # writes in flight when the cut started
    w = read_writes(path, until_ms=promote_ms)
    tok = token(tok_cluster) if tok_cluster else None
    got = versions(cluster, list(w), tok=tok)
    before_missing = after_writes = after_missing = errors = 0
    examples = []
    for k, vs in w.items():
        r = got[k]
        if r < 0:
            errors += 1
            continue
        before = max((v for ts, v in vs if ts < cut_ms - slack), default=0)
        total = max(v for _, v in vs)
        after_writes += sum(1 for ts, _ in vs if ts > cut_ms)
        if r < before:
            before_missing += 1
            if len(examples) < 20:
                examples.append({"key": k, "replica": r, "before_cut": before})
        after_missing += max(0, total - max(r, before))
    save(f"writes-missing-{cluster}", {
        "cluster": cluster, "cut_ms": cut_ms, "promote_ms": promote_ms, "keys": len(w),
        "writes_after_cut": after_writes, "missing_after_cut": after_missing,
        "keys_missing_writes_from_before_cut": before_missing, "read_errors": errors,
        "ok": before_missing == 0 and errors == 0,
        "examples": examples,
    })


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    cmd, args = sys.argv[1], sys.argv[2:]
    {
        "manifest-prepare": manifest_prepare,
        "manifest-apply": manifest_apply,
        "manifest-check": manifest_check,
        "writes-final": writes_final,
        "writes-missing": writes_missing,
    }[cmd](*args)


if __name__ == "__main__":
    main()
