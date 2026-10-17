"""Fleet graph model for the factory dashboard (python3 stdlib only).

FleetGraph JSON shape (schema sf-dashboard.v1):
  nodes[]: {id, kind, parent, label, project, state, busy, task_title,
            current, pr, branch, since}
  edges[]: {seq, ts, from, to, kind, text}

Inputs, all optional and read-only:
  snapshot   fm-fleet-snapshot.v1 JSON (tasks[], secondmate_current)
  state_dir  fleet-ledger.jsonl, <id>.meta, <id>.inbox/*.msg and handled/
  config_dir fleet-ledger presence flag
"""

import calendar
import json
import os
import re
import subprocess
import time

SCHEMA = "sf-dashboard.v1"
FIRSTMATE = "firstmate"
NODE_KINDS = ("firstmate", "secondmate", "ship", "scout")
STATES = ("working", "parked", "done", "blocked", "paused", "failed", "unknown")
EDGE_KINDS = ("dispatch", "steer", "status", "pr_ready", "merged", "cleaned_up")

# ledger event -> (edge kind, True when the edge runs worker -> firstmate)
LEDGER_EDGES = {
    "task.dispatched": ("dispatch", False),
    "task.status": ("status", True),
    "task.pr_ready": ("pr_ready", True),
    "task.merged": ("merged", False),
    "task.cleaned_up": ("cleaned_up", False),
}
TEXT_MAX = 300


def _state(value):
    return value if value in STATES else "unknown"


def _read_meta(path):
    meta = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                key, sep, value = line.rstrip("\n").partition("=")
                if sep:
                    meta[key] = value
    except OSError:
        pass
    return meta


def _short(text):
    text = " ".join(str(text or "").split())
    return text if len(text) <= TEXT_MAX else text[: TEXT_MAX - 1] + "…"


def ledger_enabled(config_dir):
    return bool(config_dir) and os.path.exists(os.path.join(config_dir, "fleet-ledger"))


def _ledger_records(state_dir):
    try:
        with open(os.path.join(state_dir, "fleet-ledger.jsonl"), encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except OSError:
        return []
    records = []
    for line in lines:
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if isinstance(rec, dict) and rec.get("event") in LEDGER_EDGES and rec.get("task"):
            records.append(rec)
    return records


def _iso_epoch(value):
    try:
        return calendar.timegm(time.strptime(value, "%Y-%m-%dT%H:%M:%SZ"))
    except (TypeError, ValueError):
        return 0


def _steers(state_dir):
    """Every steer record, unhandled and handled, as (ts, task, text)."""
    out = []
    try:
        names = sorted(os.listdir(state_dir))
    except OSError:
        return out
    for name in names:
        if not name.endswith(".inbox"):
            continue
        task = name[: -len(".inbox")]
        inbox = os.path.join(state_dir, name)
        for sub in (inbox, os.path.join(inbox, "handled")):
            try:
                msgs = sorted(m for m in os.listdir(sub) if re.fullmatch(r"\d+\.msg", m))
            except OSError:
                continue
            for msg in msgs:
                try:
                    with open(os.path.join(sub, msg), encoding="utf-8", errors="replace") as f:
                        raw = f.read()
                except OSError:
                    continue
                head, _, body = raw.partition("\n--\n")
                at = re.search(r"^at=(\S+)", head, re.M)
                out.append((_iso_epoch(at.group(1) if at else None), task, body))
    return out


def build_edges(state_dir):
    """Ledger and steer edges, numbered by (ts, ledger line, steer order).

    ponytail: seq is a position in this ordering, not a stored id; a steer
    recorded with a ts older than the newest ledger line shifts later seqs.
    Add a real sequence when the ledger grows one.
    """
    raw = []
    for i, rec in enumerate(_ledger_records(state_dir)):
        kind, upward = LEDGER_EDGES[rec["event"]]
        task = str(rec["task"])
        if kind == "status":
            text = ((rec.get("state") or "") + ":" + (rec.get("text") or "")).strip(": ")
        elif kind == "dispatch":
            text = " ".join(str(rec.get(k)) for k in ("kind", "project") if rec.get(k))
        else:
            text = rec.get("pr") or ""
        ts = rec.get("ts") if isinstance(rec.get("ts"), int) else 0
        src, dst = (task, FIRSTMATE) if upward else (FIRSTMATE, task)
        raw.append((ts, 0, i, src, dst, kind, text))
    for i, (ts, task, body) in enumerate(_steers(state_dir)):
        raw.append((ts, 1, i, FIRSTMATE, task, "steer", body))
    raw.sort(key=lambda r: r[:3])
    return [
        {"seq": n, "ts": r[0], "from": r[3], "to": r[4], "kind": r[5], "text": _short(r[6])}
        for n, r in enumerate(raw, 1)
    ]


def _task_node(task, meta, since):
    kind = task.get("kind") or meta.get("kind")
    last = ((task.get("paths") or {}).get("status_log") or {}).get("last_event") or {}
    state = (task.get("current_state") or {}).get("state")
    project = task.get("project") or meta.get("project") or ""
    return {
        "id": task["id"],
        "kind": kind if kind in NODE_KINDS[1:] else "ship",
        "parent": FIRSTMATE,
        "label": task["id"],
        "project": os.path.basename(project.rstrip("/")) or None,
        "state": _state(state),
        "busy": state == "working",
        "task_title": (task.get("backlog") or {}).get("title"),
        "current": _short(last.get("note") or last.get("raw")) or None,
        "pr": (task.get("pr") or {}).get("url") or meta.get("pr") or None,
        "branch": task.get("branch") or meta.get("branch") or None,
        "since": since,
    }


def build(snapshot, state_dir, config_dir, label="firstmate", generated=None):
    snapshot = snapshot if isinstance(snapshot, dict) else {}
    edges = build_edges(state_dir)
    last_ts = {}
    for e in edges:
        for end in (e["from"], e["to"]):
            last_ts[end] = max(last_ts.get(end, 0), e["ts"])

    tasks = {t["id"]: t for t in snapshot.get("tasks") or [] if isinstance(t, dict) and t.get("id")}
    try:
        metas = sorted(n[: -len(".meta")] for n in os.listdir(state_dir) if n.endswith(".meta"))
    except OSError:
        metas = []
    for tid in metas:
        tasks.setdefault(tid, {"id": tid})

    nodes = []
    for tid in sorted(tasks):
        meta = _read_meta(os.path.join(state_dir, tid + ".meta"))
        nodes.append(_task_node(tasks[tid], meta, last_ts.get(tid)))
    # The snapshot reports no state for the firstmate itself; show it working while any report is.
    busy = any(n["busy"] for n in nodes)
    nodes.insert(0, {
        "id": FIRSTMATE, "kind": "firstmate", "parent": None, "label": label,
        "project": None, "state": "working" if busy else "parked", "busy": busy,
        "task_title": None, "current": None, "pr": None, "branch": None,
        "since": last_ts.get(FIRSTMATE),
    })

    secondmates = {n["id"] for n in nodes if n["kind"] == "secondmate"}
    for rec in (snapshot.get("secondmate_current") or {}).get("records") or []:
        if not isinstance(rec, dict) or rec.get("id") not in secondmates:
            continue
        for child in rec.get("active_children") or []:
            if not isinstance(child, dict) or not child.get("id"):
                continue
            state = child.get("state")
            nodes.append({
                "id": rec["id"] + "/" + child["id"],
                "kind": child.get("kind") if child.get("kind") in ("ship", "scout") else "ship",
                "parent": rec["id"],
                "label": child["id"],
                "project": child.get("repo"),
                "state": _state(state),
                "busy": state == "working",
                "task_title": child.get("name"),
                "current": _short(child.get("doing")) or None,
                "pr": None,
                "branch": None,
                "since": None,
            })

    return {
        "schema": SCHEMA,
        "generated": generated or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "ledger": {"enabled": ledger_enabled(config_dir)},
        "errors": [],
        "nodes": nodes,
        "edges": edges,
    }


def live_snapshot(fm_root, fm_home):
    """Run fm-fleet-snapshot.sh --json; return (snapshot or None, error or None)."""
    env = dict(os.environ, FM_HOME=fm_home)
    try:
        out = subprocess.run(
            [os.path.join(fm_root, "bin", "fm-fleet-snapshot.sh"), "--json"],
            env=env, capture_output=True, text=True, timeout=30, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return None, "fleet snapshot failed: %s" % exc
    if out.returncode != 0:
        return None, "fleet snapshot exited %d: %s" % (out.returncode, out.stderr.strip()[-300:])
    try:
        return json.loads(out.stdout), None
    except ValueError:
        return None, "fleet snapshot printed invalid JSON"


class Source:
    """Where the graph comes from: the live home, or a recorded fixture dir."""

    def __init__(self, fm_root, fm_home=None, fixture=None):
        self.fm_root = fm_root
        self.fixture = fixture
        if fixture:
            self.state_dir = os.path.join(fixture, "recorded-state")
            self.config_dir = os.path.join(fixture, "recorded-config")
            self.label = "firstmate (fixture)"
        else:
            self.fm_home = fm_home
            self.state_dir = os.path.join(fm_home, "state")
            self.config_dir = os.path.join(fm_home, "config")
            self.label = "firstmate " + os.path.basename(fm_home.rstrip("/"))

    def graph(self):
        error = None
        if self.fixture:
            try:
                with open(os.path.join(self.fixture, "fleet-snapshot.json"), encoding="utf-8") as f:
                    snapshot = json.load(f)
            except (OSError, ValueError):
                snapshot = None
        else:
            snapshot, error = live_snapshot(self.fm_root, self.fm_home)
        g = build(snapshot, self.state_dir, self.config_dir, self.label)
        if error:
            g["errors"].append(error)
        return g

    def events(self, after):
        return [e for e in build_edges(self.state_dir) if e["seq"] > after]
