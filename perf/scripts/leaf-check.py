#!/usr/bin/env python3
"""Check the leafs consul-leaf.js sampled (issue #7): leaf-check.py <run dir>.

consul-leaf.js logs 1 in LEAF_SAMPLE issued leafs to <run dir>/k6.log as
"LEAFSAMPLE <service> <base64 CertPEM>". For each one:
  - san:   the SPIFFE URI SAN ends in /svc/<service>;
  - ttl:   NotAfter - NotBefore is within TTL_SLACK_S (120) of Consul's
           LeafCertTTL (Vault backdates NotBefore by 30 s). LEAF_TTL overrides
           it (e.g. 72h) if the token can't read the CA configuration;
  - chain: `openssl verify` against Consul's CA roots, read from the agent
           after the run (every root and intermediate, so leafs from before and
           after T13's rotation both verify). Consul's root is a Vault
           intermediate, so this uses -partial_chain. MESH_ROOT_FILE (the
           offline mesh root: terraform output -raw mesh_root_ca_pem) also
           checks the full chain to it.
Writes <run dir>/leaf-check.json: {sampled, invalid, by_check, failures (up to 20)}.
Exits 0 unless it can't run at all; invalid leafs are a result, not an error.
"""
import base64
import json
import os
import re
import ssl
import subprocess
import sys
import tempfile
import urllib.request
from datetime import datetime

RUN = sys.argv[1]
ADDR = os.environ.get("CONSUL_HTTP_ADDR", "http://127.0.0.1:8500")
if not ADDR.startswith("http"):
    ADDR = "http://" + ADDR
TOKEN = os.environ.get("CONSUL_HTTP_TOKEN", "")
SLACK = int(os.environ.get("TTL_SLACK_S", "120"))
PEM_RE = re.compile(r"-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----", re.S)
SAMPLE_RE = re.compile(r"LEAFSAMPLE (\S+) ([A-Za-z0-9+/=]+)")


def consul(path):
    ctx = None
    if ADDR.startswith("https"):
        ca = os.environ.get("CONSUL_CACERT")
        ctx = ssl.create_default_context(cafile=ca) if ca else ssl._create_unverified_context()
    req = urllib.request.Request(ADDR + path, headers={"X-Consul-Token": TOKEN})
    with urllib.request.urlopen(req, timeout=10, context=ctx) as r:
        return json.load(r)


def to_secs(s):
    m = re.fullmatch(r"(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?", s.strip())
    if not m or not any(m.groups()):
        return None
    h, mi, se = (int(x or 0) for x in m.groups())
    return h * 3600 + mi * 60 + se


def openssl(*args, data=None):
    return subprocess.run(["openssl", *args], input=data, capture_output=True, text=True)


def main():
    log = os.path.join(RUN, "k6.log")
    samples = []
    with open(log, errors="replace") as f:
        for line in f:
            m = SAMPLE_RE.search(line)
            if m:
                samples.append((m.group(1), base64.b64decode(m.group(2)).decode()))
    if not samples:
        return

    roots = consul("/v1/agent/connect/ca/roots").get("Roots") or []
    trusted, untrusted = [], []
    for r in roots:
        pems = PEM_RE.findall(r.get("RootCert", ""))
        trusted += pems[:1]
        untrusted += pems[1:]
        for i in r.get("IntermediateCerts") or []:
            untrusted += PEM_RE.findall(i)
    ttl = to_secs(os.environ["LEAF_TTL"]) if os.environ.get("LEAF_TTL") else None
    if ttl is None:
        try:
            ttl = to_secs(consul("/v1/connect/ca/configuration")["Config"].get("LeafCertTTL", ""))
        except Exception:
            ttl = None
    mesh_root = os.environ.get("MESH_ROOT_FILE")

    failures, invalid, by_check = [], 0, {"san": 0, "ttl": 0, "chain": 0, "chain_to_mesh_root": 0}
    with tempfile.TemporaryDirectory() as tmp:
        ca_file = os.path.join(tmp, "roots.pem")
        un_file = os.path.join(tmp, "untrusted.pem")
        full_file = os.path.join(tmp, "untrusted-full.pem")
        with open(ca_file, "w") as f:
            f.write("\n".join(trusted) + "\n")
        for svc, pem in samples:
            certs = PEM_RE.findall(pem)
            leaf = certs[0] if certs else ""
            with open(un_file, "w") as f:
                f.write("\n".join(untrusted + certs[1:]) + "\n")
            # To the mesh root, Consul's roots are intermediates too.
            with open(full_file, "w") as f:
                f.write("\n".join(trusted + untrusted + certs[1:]) + "\n")
            bad = []
            info = openssl("x509", "-noout", "-ext", "subjectAltName", "-startdate", "-enddate", data=leaf).stdout
            if not re.search(r"URI:spiffe://\S+/svc/" + re.escape(svc) + r"(\s|,|$)", info):
                bad.append("san")
            nb = re.search(r"notBefore=(.+)", info)
            na = re.search(r"notAfter=(.+)", info)
            got = None
            if nb and na:
                fmt = "%b %d %H:%M:%S %Y %Z"
                got = (datetime.strptime(" ".join(na.group(1).split()), fmt)
                       - datetime.strptime(" ".join(nb.group(1).split()), fmt)).total_seconds()
            if got is None or (ttl is not None and abs(got - ttl) > SLACK):
                bad.append("ttl")
            v = openssl("verify", "-partial_chain", "-CAfile", ca_file, "-untrusted", un_file, data=leaf)
            if v.returncode != 0:
                bad.append("chain")
            if mesh_root:
                v2 = openssl("verify", "-CAfile", mesh_root, "-untrusted", full_file, data=leaf)
                if v2.returncode != 0:
                    bad.append("chain_to_mesh_root")
            for b in bad:
                by_check[b] += 1
            invalid += 1 if bad else 0
            if bad and len(failures) < 20:
                failures.append({"service": svc, "failed": bad, "ttl_s": got,
                                 "verify": (v.stdout + v.stderr).strip()[-300:] if "chain" in bad else None})

    out = {"sampled": len(samples), "invalid": invalid, "by_check": by_check, "expected_ttl_s": ttl,
           "roots": len(trusted), "mesh_root_checked": bool(mesh_root), "failures": failures}
    with open(os.path.join(RUN, "leaf-check.json"), "w") as f:
        json.dump(out, f, indent=1)
    print(f"leaf check: {invalid} of {len(samples)} sampled leafs invalid {json.dumps(by_check)}")


if __name__ == "__main__":
    main()
