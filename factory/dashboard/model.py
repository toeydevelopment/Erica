"""Fleet graph model for the factory dashboard (python3 stdlib only).

FleetGraph JSON shape (schema sf-dashboard.v1):
  nodes[]: {id, kind, parent, label, project, state, busy, task_title,
            current, pr, branch, since}
  edges[]: {seq, ts, from, to, kind, text}  (the newest FLEET_EDGES only)
  snapshot: {age, error}

Inputs, all optional and read-only:
  snapshot   fm-fleet-snapshot.v1 JSON (tasks[], secondmate_current)
  state_dir  fleet-ledger.jsonl, <id>.meta, <id>.status, <id>.inbox/*.msg and handled/
  config_dir fleet-ledger presence flag
  each second mate's own home (meta home=): its state/ and data/backlog.md,
  which give the workers under that second mate and their messages.
"""

import calendar
import json
import os
import re
import signal
import subprocess
import threading
import time

SCHEMA = "sf-dashboard.v1"
FIRSTMATE = "firstmate"
NODE_KINDS = ("firstmate", "secondmate", "ship", "scout")
STATES = ("working", "parked", "done", "blocked", "paused", "failed", "unknown")
EDGE_KINDS = ("dispatch", "steer", "status", "pr_ready", "merged", "cleaned_up")

# ledger event -> (edge kind, True when the edge runs worker -> lead)
LEDGER_EDGES = {
    "task.dispatched": ("dispatch", False),
    "task.status": ("status", True),
    "task.pr_ready": ("pr_ready", True),
    "task.merged": ("merged", False),
    "task.cleaned_up": ("cleaned_up", False),
}
# status-line verbs that are not dashboard states
VERB_STATES = {"needs-decision": "blocked", "captain-held": "blocked", "resolved": "working", "in-progress": "working"}
STATUS_RE = re.compile(r"^([A-Za-z-]+):?((?:\s*\[[^\]]*\])*):?\s*(.*)$")
TEXT_MAX = 300
FLEET_EDGES = 200
# the state/, config/ and data/ folder names inside a home; fixtures use recorded-*
LIVE_DIRS = ("state", "config", "data")
FIXTURE_DIRS = ("recorded-state", "recorded-config", "recorded-data")
SNAPSHOT_EVERY = 30
SNAPSHOT_TIMEOUT = 300


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


def _listdir(path):
    try:
        return sorted(os.listdir(path))
    except OSError:
        return []


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


def _parse_status(line):
    """'paused [key=k] [at=123]: note' -> (state or None, ts, note)."""
    m = STATUS_RE.match(line.strip())
    if not m:
        return None, 0, ""
    verb = m.group(1).lower()
    state = VERB_STATES.get(verb, verb)
    at = re.search(r"\[at=(\d+)\]", m.group(2))
    return (state if state in STATES else None), (int(at.group(1)) if at else 0), m.group(3)


def _status_lines(state_dir, tid):
    try:
        with open(os.path.join(state_dir, tid + ".status"), encoding="utf-8", errors="replace") as f:
            return [line for line in f.read().splitlines() if line.strip()]
    except OSError:
        return []


def _status_tail(state_dir, tid):
    """The newest status line that names a state: (state, note) or (None, None)."""
    for line in reversed(_status_lines(state_dir, tid)):
        state, _, note = _parse_status(line)
        if state:
            return state, note
    return None, None


def _backlog_titles(home, dirs=LIVE_DIRS):
    titles = {}
    try:
        with open(os.path.join(home, dirs[2], "backlog.md"), encoding="utf-8", errors="replace") as f:
            for line in f:
                m = re.match(r"\s*- \[.\] (\S+) - (.*)", line)
                if m:
                    titles.setdefault(m.group(1), re.split(r"\s+blocked-by:", m.group(2))[0].strip())
    except OSError:
        pass
    return titles


def _steers(state_dir):
    """Every steer record, unhandled and handled, as (ts, task, text)."""
    out = []
    for name in _listdir(state_dir):
        if not name.endswith(".inbox"):
            continue
        task = name[: -len(".inbox")]
        inbox = os.path.join(state_dir, name)
        for sub in (inbox, os.path.join(inbox, "handled")):
            for msg in (m for m in _listdir(sub) if re.fullmatch(r"\d+\.msg", m)):
                try:
                    with open(os.path.join(sub, msg), encoding="utf-8", errors="replace") as f:
                        raw = f.read()
                except OSError:
                    continue
                head, _, body = raw.partition("\n--\n")
                at = re.search(r"^at=(\S+)", head, re.M)
                out.append((_iso_epoch(at.group(1) if at else None), task, body))
    return out


def _home_raw_edges(state_dir, config_dir, lead, prefix):
    """One home's messages as sortable tuples (ts, i, src, dst, kind, text).

    The ledger when the home turned it on; otherwise every timestamped
    <id>.status line, which is what the ledger's task.status mirrors.
    """
    raw = []
    if ledger_enabled(config_dir):
        for i, rec in enumerate(_ledger_records(state_dir)):
            kind, upward = LEDGER_EDGES[rec["event"]]
            task = prefix + str(rec["task"])
            if kind == "status":
                text = ((rec.get("state") or "") + ":" + (rec.get("text") or "")).strip(": ")
            elif kind == "dispatch":
                text = " ".join(str(rec.get(k)) for k in ("kind", "project") if rec.get(k))
            else:
                text = rec.get("pr") or ""
            ts = rec.get("ts") if isinstance(rec.get("ts"), int) else 0
            src, dst = (task, lead) if upward else (lead, task)
            raw.append((ts, i, src, dst, kind, text))
    else:
        i = 0
        for name in _listdir(state_dir):
            if not name.endswith(".status"):
                continue
            tid = name[: -len(".status")]
            for line in _status_lines(state_dir, tid):
                _, ts, note = _parse_status(line)
                if ts:
                    raw.append((ts, i, prefix + tid, lead, "status", line.split(":", 1)[0].split(" [")[0] + ": " + note))
                    i += 1
    base = len(raw)
    for i, (ts, task, body) in enumerate(_steers(state_dir)):
        raw.append((ts, base + i, lead, prefix + task, "steer", body))
    return raw


def _child_homes(state_dir, base, snapshot_tasks, dirs=LIVE_DIRS):
    """(secondmate id, home dir) for each second mate whose home is on this disk."""
    out = []
    for tid in sorted(set(snapshot_tasks) | {n[: -len(".meta")] for n in _listdir(state_dir) if n.endswith(".meta")}):
        meta = _read_meta(os.path.join(state_dir, tid + ".meta"))
        task = snapshot_tasks.get(tid) or {}
        if (task.get("kind") or meta.get("kind")) != "secondmate":
            continue
        home = meta.get("home") or ((task.get("paths") or {}).get("home") or {}).get("path")
        if home:
            home = os.path.join(base, home)
            if os.path.isdir(os.path.join(home, dirs[0])):
                out.append((tid, home))
    return out


def build_edges(state_dir, config_dir=None, base=None, snapshot_tasks=None, dirs=LIVE_DIRS):
    """Messages of this home and of every local second-mate home, numbered in time order.

    ponytail: seq is a position in this ordering, not a stored id; a message
    recorded with a ts older than the newest one shifts later seqs.
    Add a real sequence when the ledger grows one.
    """
    raw = [(r[0], 0) + r[1:] for r in _home_raw_edges(state_dir, config_dir, FIRSTMATE, "")]
    for n, (sm, home) in enumerate(_child_homes(state_dir, base or state_dir, snapshot_tasks or {}, dirs), 1):
        sub = _home_raw_edges(os.path.join(home, dirs[0]), os.path.join(home, dirs[1]), sm, sm + "/")
        raw.extend((r[0], n) + r[1:] for r in sub)
    raw.sort(key=lambda r: r[:3])
    return [
        {"seq": i, "ts": r[0], "from": r[3], "to": r[4], "kind": r[5], "text": _short(r[6])}
        for i, r in enumerate(raw, 1)
    ]


def _task_node(task, meta, since, tail, title):
    kind = task.get("kind") or meta.get("kind")
    last = ((task.get("paths") or {}).get("status_log") or {}).get("last_event") or {}
    state = (task.get("current_state") or {}).get("state")
    if state not in STATES or state == "unknown":
        state = tail[0] or state
    project = task.get("project") or meta.get("project") or ""
    if kind == "secondmate":
        project = meta.get("projects") or ""
    return {
        "id": task["id"],
        "kind": kind if kind in NODE_KINDS[1:] else "ship",
        "parent": FIRSTMATE,
        "label": task["id"],
        "project": os.path.basename(project.rstrip("/")) or None,
        "state": _state(state),
        "busy": state == "working",
        "task_title": (task.get("backlog") or {}).get("title") or title,
        "current": _short(tail[1] or last.get("note") or last.get("raw")) or None,
        "pr": (task.get("pr") or {}).get("url") or meta.get("pr") or None,
        "branch": task.get("branch") or meta.get("branch") or None,
        "since": since,
    }


def _home_children(sm, home, last_ts, dirs):
    state_dir = os.path.join(home, dirs[0])
    titles = _backlog_titles(home, dirs)
    out = []
    for tid in (n[: -len(".meta")] for n in _listdir(state_dir) if n.endswith(".meta")):
        meta = _read_meta(os.path.join(state_dir, tid + ".meta"))
        state, note = _status_tail(state_dir, tid)
        nid = sm + "/" + tid
        out.append({
            "id": nid,
            "kind": meta.get("kind") if meta.get("kind") in ("ship", "scout") else "ship",
            "parent": sm,
            "label": tid,
            "project": os.path.basename((meta.get("project") or "").rstrip("/")) or None,
            "state": _state(state),
            "busy": state == "working",
            "task_title": titles.get(tid),
            "current": _short(note) or None,
            "pr": meta.get("pr") or None,
            "branch": meta.get("branch") or None,
            "since": last_ts.get(nid),
        })
    return out


def build(snapshot, state_dir, config_dir, label="firstmate", generated=None, base=None, edge_limit=None, dirs=LIVE_DIRS):
    snapshot = snapshot if isinstance(snapshot, dict) else {}
    base = base or os.path.dirname(state_dir.rstrip("/"))
    tasks = {t["id"]: t for t in snapshot.get("tasks") or [] if isinstance(t, dict) and t.get("id")}
    edges = build_edges(state_dir, config_dir, base, tasks, dirs)
    last_ts = {}
    for e in edges:
        for end in (e["from"], e["to"]):
            last_ts[end] = max(last_ts.get(end, 0), e["ts"])

    for tid in (n[: -len(".meta")] for n in _listdir(state_dir) if n.endswith(".meta")):
        tasks.setdefault(tid, {"id": tid})

    titles = _backlog_titles(base, dirs)
    nodes = []
    for tid in sorted(tasks):
        meta = _read_meta(os.path.join(state_dir, tid + ".meta"))
        nodes.append(_task_node(tasks[tid], meta, last_ts.get(tid), _status_tail(state_dir, tid), titles.get(tid)))
    # The snapshot reports no state for the firstmate itself; show it working while any report is.
    busy = any(n["busy"] for n in nodes)
    nodes.insert(0, {
        "id": FIRSTMATE, "kind": "firstmate", "parent": None, "label": label,
        "project": None, "state": "working" if busy else "parked", "busy": busy,
        "task_title": None, "current": None, "pr": None, "branch": None,
        "since": last_ts.get(FIRSTMATE),
    })

    # Workers under a second mate: read from its home when it is on this disk,
    # else from the snapshot's summary of it.
    secondmates = {n["id"] for n in nodes if n["kind"] == "secondmate"}
    homes = dict(_child_homes(state_dir, base, tasks, dirs))
    for sm, home in sorted(homes.items()):
        nodes.extend(_home_children(sm, home, last_ts, dirs))
    for rec in (snapshot.get("secondmate_current") or {}).get("records") or []:
        if not isinstance(rec, dict) or rec.get("id") not in secondmates or rec.get("id") in homes:
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
        "edges": edges[-edge_limit:] if edge_limit else edges,
    }


def live_snapshot(fm_root, fm_home, timeout=SNAPSHOT_TIMEOUT):
    """Run fm-fleet-snapshot.sh --json; return (snapshot or None, error or None).

    It runs in its own process group so a timeout kills every process it started.
    """
    env = dict(os.environ, FM_HOME=fm_home)
    try:
        proc = subprocess.Popen(
            [os.path.join(fm_root, "bin", "fm-fleet-snapshot.sh"), "--json"],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True,
        )
    except OSError as exc:
        return None, "fleet snapshot failed: %s" % exc
    try:
        stdout, stderr = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        proc.communicate()
        return None, "fleet snapshot timed out after %d seconds" % timeout
    if proc.returncode != 0:
        return None, "fleet snapshot exited %d: %s" % (proc.returncode, stderr.strip()[-300:])
    try:
        return json.loads(stdout), None
    except ValueError:
        return None, "fleet snapshot printed invalid JSON"


class Source:
    """Where the graph comes from: the live home, or a recorded fixture dir.

    Live mode refreshes the snapshot in one background thread, so a request
    never waits for it and at most one snapshot runs at a time.
    """

    def __init__(self, fm_root, fm_home=None, fixture=None):
        self.fm_root = fm_root
        self.fixture = fixture
        self.snapshot = None
        self.snapshot_at = None
        self.snapshot_error = None
        self._lock = threading.Lock()
        self._thread = None
        self.dirs = FIXTURE_DIRS if fixture else LIVE_DIRS
        if fixture:
            self.base = fixture
            self.state_dir = os.path.join(fixture, "recorded-state")
            self.config_dir = os.path.join(fixture, "recorded-config")
            self.label = "firstmate (fixture)"
            try:
                with open(os.path.join(fixture, "fleet-snapshot.json"), encoding="utf-8") as f:
                    self.snapshot = json.load(f)
            except (OSError, ValueError):
                pass
        else:
            self.fm_home = fm_home
            self.base = fm_home
            self.state_dir = os.path.join(fm_home, "state")
            self.config_dir = os.path.join(fm_home, "config")
            self.label = "firstmate " + os.path.basename(fm_home.rstrip("/"))

    def _refresh(self):
        snap, err = live_snapshot(self.fm_root, self.fm_home)
        with self._lock:
            if snap is not None:
                self.snapshot, self.snapshot_at = snap, time.time()
            self.snapshot_error = err

    def _loop(self):
        while True:
            self._refresh()
            time.sleep(SNAPSHOT_EVERY)

    def graph(self, wait=False, edge_limit=FLEET_EDGES):
        if not self.fixture:
            if wait:
                self._refresh()
            elif self._thread is None:
                self._thread = threading.Thread(target=self._loop, daemon=True)
                self._thread.start()
        with self._lock:
            snapshot, at, error = self.snapshot, self.snapshot_at, self.snapshot_error
        g = build(snapshot, self.state_dir, self.config_dir, self.label, base=self.base, edge_limit=edge_limit, dirs=self.dirs)
        g["snapshot"] = {"age": int(time.time() - at) if at else None, "error": error, "live": not self.fixture}
        if error:
            g["errors"].append(error + ("; showing the last good snapshot" if snapshot else "; states come from status lines"))
        return g

    def events(self, after):
        with self._lock:
            tasks = {t["id"]: t for t in (self.snapshot or {}).get("tasks") or [] if isinstance(t, dict) and t.get("id")}
        return [e for e in build_edges(self.state_dir, self.config_dir, self.base, tasks, self.dirs) if e["seq"] > after]
