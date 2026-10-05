#!/usr/bin/env python3
"""Leadership timeline for one T11 failover repeat, from each voter's Vault log.

Reads <dir>/<node>.log (journalctl -o short-iso-precise, one file per voter),
writes <dir>/timeline.log (leadership lines from every node, merged by time)
and prints JSON with the time of each failover stage, in seconds after the
freeze (null when the log has no matching line):

  detected_s       first follower gives up on the leader (heartbeat timeout / pre-vote)
  elected_s        a node wins the election (election won / entering leader state)
  active_s         that node finishes taking over as Vault active (post-unseal setup complete)
  old_stepdown_s   the frozen node steps down after SIGCONT

Usage: failover-logs.py <dir> <freeze_ms> <old active node>
"""
import glob
import json
import os
import re
import sys
from datetime import datetime

# hashicorp/raft and Vault core messages around a leader change.
RELEVANT = re.compile(
    r"heartbeat timeout|pre-?vote|candidate state|election|leader state|follower state|lost leadership"
    r"|failed to contact|rejecting (vote|pre-vote)|acquired lock|active operation|post-unseal|pre-seal"
    r"|stepping down|step.?down|entering standby|leadership|leader",
    re.I,
)
STAGES = {
    "detected": re.compile(r"heartbeat timeout reached|entering pre-?vote|starting pre-?vote|entering candidate state", re.I),
    "elected": re.compile(r"election won|entering leader state", re.I),
    "active": re.compile(r"post-unseal setup complete", re.I),
    "stepdown": re.compile(r"entering follower state|stepping down|lost leadership|entering standby", re.I),
}
TS = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?([+-]\d{2}:?\d{2}|Z)?")


def parse_ts(line):
    m = TS.match(line)
    if not m:
        return None
    frac = (m.group(2) or ".0")[:7]  # microseconds at most
    tz = (m.group(3) or "+00:00").replace("Z", "+00:00")
    if re.fullmatch(r"[+-]\d{4}", tz):
        tz = tz[:3] + ":" + tz[3:]
    return datetime.fromisoformat(m.group(1) + frac + tz).timestamp() * 1000


def main():
    d, freeze_ms, old = sys.argv[1], float(sys.argv[2]), sys.argv[3]
    events = []  # (ms, node, line)
    for path in sorted(glob.glob(os.path.join(d, "*.log"))):
        node = os.path.basename(path)[:-4]
        if node == "timeline":
            continue
        for line in open(path, errors="replace"):
            t = parse_ts(line)
            if t is not None and RELEVANT.search(line):
                events.append((t, node, line.rstrip()))
    events.sort()
    with open(os.path.join(d, "timeline.log"), "w") as f:
        for t, node, line in events:
            f.write(f"{(t - freeze_ms) / 1000:+8.3f}s  {node:<10} {line}\n")

    def first(stage, nodes=None, exclude=None):
        for t, node, line in events:
            if t >= freeze_ms and STAGES[stage].search(line) and (nodes is None or node in nodes) and node != exclude:
                return round((t - freeze_ms) / 1000, 3), node
        return None, None

    out = {}
    out["detected_s"], out["detected_by"] = first("detected", exclude=old)
    out["elected_s"], out["elected_node"] = first("elected", exclude=old)
    winner = [out["elected_node"]] if out["elected_node"] else None
    out["active_s"], _ = first("active", nodes=winner, exclude=old)
    out["old_stepdown_s"], _ = first("stepdown", nodes=[old])
    out["timeline_lines"] = len(events)
    print(json.dumps(out))


if __name__ == "__main__":
    main()
