#!/usr/bin/env python3
"""flowlog - analyze Agent-Container proxy session logs.

Reads the JSONL flow log written by image/inspect-proxy.py (mirrored to the host by
`run.sh --proxy-logs` as `flows.log`, or `/tmp/agentcontainer/flows.jsonl` in the
container). Stdlib only - run it on the host against a session directory, or inside a
container that mounted the log tree.

    flowlog                     # summary of the most recent session
    flowlog summary [LOG]       # same, explicit log
    flowlog hosts  [LOG]        # per-host breakdown (requests, denies, errors, bytes)
    flowlog flows  [LOG]        # one line per request/response pair
    flowlog show N   [LOG]      # full detail (headers, query, bodies) of flow #N
    flowlog grep PAT [LOG]      # regex over url/headers/bodies, prints matches
    flowlog errors [LOG]        # non-2xx responses and denials
    flowlog denies [LOG]        # every allowlist denial

    --sort COL on summary/hosts/flows/errors/denies orders the table by that column
    (numeric columns largest-first, text A-Z; --desc flips it).
    In tables: out = request bytes sent from the sandbox, in = response bytes received.

LOG is a flows.log/flows.jsonl file, a session directory (or just its name under
~/.local/state/agentcontainer/logs/), or omitted for the newest session there
(AGENTCONTAINER_LOG_DIR overrides that directory). With --all, every session in that
directory is merged instead (chronological, each line tagged with its session).

Requests and responses are paired by (method, url) in arrival order - good enough for
the sequential traffic a sandbox generates; unpaired ones are shown on their own.
"""
import argparse
import json
import os
import re
import sys
from collections import defaultdict
from datetime import datetime
from urllib.parse import urlsplit

LOG_DIR = os.environ.get(
    "AGENTCONTAINER_LOG_DIR",
    os.path.expanduser("~/.local/state/agentcontainer/logs"),
)
FLOW_FILES = ("flows.log", "flows.jsonl")

_COLOR = sys.stdout.isatty()


def _c(code, s):
    return "\033[%sm%s\033[0m" % (code, s) if _COLOR else s


_ANSI = re.compile(r"\033\[[0-9;]*m")


def table(headers, rows, aligns=None):
    """Print an aligned, bordered table. Cells are strings and may contain ANSI color
    codes (ignored when measuring). aligns: one of '<' '>' per column."""
    n = len(headers)
    aligns = aligns or "<" * n
    widths = [max([len(_ANSI.sub("", str(h)))]
                  + [len(_ANSI.sub("", str(r[i]))) for r in rows])
              for i, h in enumerate(headers)]

    def sep(l, m, r):
        return l + m.join("─" * (w + 2) for w in widths) + r

    def row(line):
        cells = []
        for i, v in enumerate(line):
            v = str(v)
            pad = widths[i] - len(_ANSI.sub("", v))
            cells.append((" " * pad + v) if aligns[i] == ">" else (v + " " * pad))
        return "│ " + " │ ".join(cells) + " │"

    print("\n".join([sep("┌", "┬", "┐"), row(headers), sep("├", "┼", "┤")]
                    + [row(r) for r in rows] + [sep("└", "┴", "┘")]))


def _flow_file(dirpath):
    for name in FLOW_FILES:
        f = os.path.join(dirpath, name)
        if os.path.isfile(f):
            return f
    return None


def short_session(name):
    """`2026-11-06-100746-claude` -> `100746-claude` (the date is in the timestamps)."""
    parts = name.split("-")
    return "-".join(parts[3:]) if len(parts) >= 5 else name


def all_sessions():
    if not os.path.isdir(LOG_DIR):
        sys.exit("error: no log directory %s" % LOG_DIR)
    out = []
    for d in sorted(os.listdir(LOG_DIR)):
        f = _flow_file(os.path.join(LOG_DIR, d))
        if f:
            out.append((d, f))
    if not out:
        sys.exit("error: no session logs in %s" % LOG_DIR)
    return out


def resolve_log(arg):
    """LOG arg -> (session, path). arg may be a file, a directory, a bare session
    name under LOG_DIR, or None (= newest session in LOG_DIR)."""
    if arg:
        p = os.path.expanduser(arg)
        if os.path.isdir(p):
            f = _flow_file(p)
            if f:
                return os.path.basename(os.path.normpath(p)), f
            sys.exit("error: no %s in %s" % ("/".join(FLOW_FILES), p))
        if os.path.isfile(p):
            return os.path.basename(os.path.dirname(os.path.normpath(p))), p
        p2 = os.path.join(LOG_DIR, arg)
        if os.path.isdir(p2):
            return resolve_log(p2)
        sys.exit("error: no such log, directory or session: %s" % arg)
    return all_sessions()[-1]


def load(path, session=None):
    events, bad = [], 0
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except ValueError:
                bad += 1  # tail -F can cut a line mid-write
                continue
            if session:
                ev["_session"] = session
            events.append(ev)
    return events, bad


def body_size(body):
    if isinstance(body, dict):
        return body.get("bytes") or len(body.get("text", ""))
    return 0


def build(events):
    """Pair requests with responses -> (flows, connects, denies), all sorted by time."""
    flows, connects, denies = [], [], []
    pending = defaultdict(list)
    for ev in events:
        kind = ev.get("ev")
        if kind == "request":
            f = {
                "t": ev.get("t"), "method": ev.get("method", "?"),
                "url": ev.get("url", ""), "host": ev.get("host", ""),
                "port": ev.get("port"), "req_headers": ev.get("headers") or {},
                "query": ev.get("query") or {}, "req_body": ev.get("body"),
                "status": None, "resp_headers": None, "resp_body": None,
                "session": ev.get("_session"),
            }
            flows.append(f)
            pending[(f["method"], f["url"])].append(f)
        elif kind == "response":
            queue = pending.get((ev.get("method"), ev.get("url")))
            if queue:
                f = queue.pop(0)
            else:  # response with no logged request (tunnel-mode session, mid-file gap)
                f = {"t": None, "method": ev.get("method", "?"), "url": ev.get("url", ""),
                     "host": (urlsplit(ev.get("url", "")).hostname or ""), "port": None,
                     "req_headers": {}, "query": {}, "req_body": None,
                     "status": None, "resp_headers": None, "resp_body": None,
                     "session": ev.get("_session")}
                flows.append(f)
            f["status"] = ev.get("status")
            f["resp_headers"] = ev.get("headers") or {}
            f["resp_body"] = ev.get("body")
        elif kind == "connect":
            connects.append(ev)
        elif kind == "deny":
            denies.append(ev)
    flows.sort(key=lambda f: f["t"] or 0)
    return flows, connects, denies


def ts(t, fmt="%H:%M:%S"):
    return datetime.fromtimestamp(t).strftime(fmt) if t else "-"


def short_target(flow):
    return urlsplit(flow["url"]).path or "/"


def _human(n):
    if not n:
        return "-"
    for unit in ("B", "K", "M", "G"):
        if n < 1024 or unit == "G":
            return ("%d%s" if unit == "B" else "%.1f%s") % (n, unit)
        n /= 1024.0


def sort_rows(rows, cols, col, desc):
    """Sort rows in place by a named column. cols: name -> (keyfn, is_numeric).
    Numeric columns default to largest-first, text to A-Z; --desc flips both."""
    if col is None:
        return rows
    if col not in cols:
        sys.exit("error: no such sort column %r (choose: %s)"
                 % (col, ", ".join(cols)))
    keyfn, numeric = cols[col]
    rows.sort(key=keyfn, reverse=(numeric != desc))
    return rows


def flows_table(flows, host_filter=None, last=None, multi=False,
                sort_col=None, desc=False):
    rows = [(i, f) for i, f in enumerate(flows, 1)
            if not host_filter or f["host"] == host_filter]
    if last:
        rows = rows[-last:]
    sort_rows(rows, {
        "time": (lambda r: r[1]["t"] or 0, True),
        "session": (lambda r: r[1]["session"] or "", False),
        "host": (lambda r: r[1]["host"], False),
        "method": (lambda r: r[1]["method"], False),
        "path": (lambda r: short_target(r[1]), False),
        "status": (lambda r: r[1]["status"] or 0, True),
        "req": (lambda r: body_size(r[1]["req_body"]), True),
        "resp": (lambda r: body_size(r[1]["resp_body"]), True),
    }, sort_col, desc)
    headers = ["#", "time"] + (["session"] if multi else []) \
        + ["host", "method", "path", "status", "req", "resp"]
    aligns = ">" + "<" * (4 + (1 if multi else 0)) + ">" * 3
    out = []
    for i, f in rows:
        status = f["status"]
        mark = _c("31", str(status)) if status and status >= 400 else str(status or "-")
        path = short_target(f)
        if len(path) > 60:
            path = path[:57] + "..."
        out.append([str(i), ts(f["t"])]
                   + ([short_session(f["session"] or "?")] if multi else [])
                   + [f["host"][:45], f["method"], path, mark,
                      _human(body_size(f["req_body"])),
                      _human(body_size(f["resp_body"]))])
    table(headers, out, aligns)


def _host_stats(flows, connects, denies):
    hosts = defaultdict(lambda: {"req": 0, "conn": 0, "deny": 0, "err": 0,
                                 "out": 0, "in": 0})
    for f in flows:
        h = hosts[f["host"]]
        h["req"] += 1
        h["out"] += body_size(f["req_body"])
        h["in"] += body_size(f["resp_body"])
        if f["status"] and f["status"] >= 400:
            h["err"] += 1
    for e in connects:
        hosts[e["host"]]["conn"] += 1
    for e in denies:
        hosts[e["host"]]["deny"] += 1
    return hosts


def _host_cols(with_times=True):
    cols = {
        "host": (lambda kv: kv[0], False),
        "reqs": (lambda kv: kv[1]["req"], True),
        "conns": (lambda kv: kv[1]["conn"], True),
        "errs": (lambda kv: kv[1]["err"], True),
        "deny": (lambda kv: kv[1]["deny"], True),
        "out": (lambda kv: kv[1]["out"], True),
        "in": (lambda kv: kv[1]["in"], True),
    }
    if with_times:
        cols["first"] = (lambda kv: kv[1].get("first") or 0, True)
        cols["last"] = (lambda kv: kv[1].get("last") or 0, True)
    return cols


def cmd_summary(sessions, flows, connects, denies, bad, sort_col=None, desc=False):
    multi = len(sessions) > 1
    if multi:
        print("sessions (%d, oldest first):" % len(sessions))
        by_sess = defaultdict(lambda: {"flows": [], "connects": [], "denies": [], "times": []})
        for f in flows:
            s = by_sess[f["session"]]
            s["flows"].append(f)
            if f["t"]:
                s["times"].append(f["t"])
        for e in connects:
            s = by_sess[e.get("_session")]
            s["connects"].append(e)
            if e.get("t"):
                s["times"].append(e["t"])
        for e in denies:
            s = by_sess[e.get("_session")]
            s["denies"].append(e)
            if e.get("t"):
                s["times"].append(e["t"])
        rows = []
        for name, path in sessions:
            s = by_sess.get(name, {"flows": [], "connects": [], "denies": [], "times": []})
            times = s["times"]
            rows.append([
                short_session(name),
                ts(min(times), "%m-%d %H:%M") if times else "-",
                ts(max(times), "%m-%d %H:%M") if times else "-",
                str(len(s["flows"])), str(len(s["connects"])), str(len(s["denies"])),
                _human(sum(body_size(f["req_body"]) for f in s["flows"])),
                _human(sum(body_size(f["resp_body"]) for f in s["flows"]))])
        table(["session", "start", "end", "reqs", "conns", "deny", "out", "in"],
              rows, "<<<" + ">>>>>")
        times = [f["t"] for f in flows if f["t"]] + [e["t"] for e in connects if e.get("t")]
        print("time:     %s .. %s" % (ts(min(times), "%Y-%m-%d %H:%M:%S"),
                                      ts(max(times), "%Y-%m-%d %H:%M:%S")) if times else "time:     -")
    else:
        name, path = sessions[0]
        print("session:  %s" % name)
        print("log:      %s" % path)
        times = [f["t"] for f in flows if f["t"]] + [e["t"] for e in connects if e.get("t")]
        if times:
            dur = (max(times) - min(times)) / 60.0
            print("time:     %s .. %s (%.1f min)" % (ts(min(times), "%Y-%m-%d %H:%M:%S"),
                                                     ts(max(times)), dur))
    print("events:   %d requests, %d responses, %d connects, %d denials%s" % (
        len(flows), sum(1 for f in flows if f["status"] is not None),
        len(connects), len(denies),
        "  (%d unparseable lines skipped)" % bad if bad else ""))

    hosts = _host_stats(flows, connects, denies)
    print("\nhosts (%d):" % len(hosts))
    hitems = list(hosts.items())
    if sort_col:
        sort_rows(hitems, _host_cols(with_times=False), sort_col, desc)
    else:
        hitems.sort(key=lambda kv: -kv[1]["req"])
    hrows = []
    for host, h in hitems:
        errs = _c("31", str(h["err"])) if h["err"] else "0"
        deny = _c("33", str(h["deny"])) if h["deny"] else "0"
        hrows.append([host[:45], str(h["req"]), str(h["conn"]), errs, deny,
                      _human(h["out"]), _human(h["in"])])
    table(["host", "reqs", "conns", "errs", "deny", "out", "in"], hrows, "<" + ">" * 6)

    codes = defaultdict(int)
    for f in flows:
        if f["status"]:
            codes[f["status"]] += 1
    if codes:
        print("\nstatus codes: " + "  ".join(
            "%s:%d" % (c, n) for c, n in sorted(codes.items())))
    if denies:
        print("\ndenied hosts: " + ", ".join(sorted({e["host"] for e in denies})))


def cmd_hosts(flows, connects, denies, sort_col=None, desc=False):
    hosts = defaultdict(lambda: {"first": None, "last": None, "req": 0, "conn": 0,
                                 "deny": 0, "err": 0, "out": 0, "in": 0, "ports": set()})
    def touch(h, t):
        if t:
            h["first"] = t if h["first"] is None else min(h["first"], t)
            h["last"] = t if h["last"] is None else max(h["last"], t)
    for f in flows:
        h = hosts[f["host"]]
        h["req"] += 1
        h["ports"].add(f["port"])
        h["out"] += body_size(f["req_body"])
        h["in"] += body_size(f["resp_body"])
        touch(h, f["t"])
        if f["status"] and f["status"] >= 400:
            h["err"] += 1
    for e in connects:
        h = hosts[e["host"]]
        h["conn"] += 1
        h["ports"].add(e.get("port"))
        touch(h, e.get("t"))
    for e in denies:
        h = hosts[e["host"]]
        h["deny"] += 1
        h["ports"].add(e.get("port"))
        touch(h, e.get("t"))
    hitems = list(hosts.items())
    if sort_col:
        sort_rows(hitems, _host_cols(), sort_col, desc)
    else:
        hitems.sort(key=lambda kv: -kv[1]["req"])
    hrows = []
    for host, h in hitems:
        hrows.append([host[:45], str(h["req"]), str(h["conn"]), str(h["err"]),
                      str(h["deny"]), _human(h["out"]), _human(h["in"]),
                      ts(h["first"], "%m-%d %H:%M"), ts(h["last"], "%m-%d %H:%M"),
                      ",".join(str(p) for p in sorted(h["ports"]))])
    table(["host", "reqs", "conns", "errs", "deny", "out", "in",
           "first", "last", "ports"], hrows, "<" + ">" * 6 + "<<<")


def cmd_show(idx, flows):
    if not 1 <= idx <= len(flows):
        sys.exit("error: flow # must be 1..%d" % len(flows))
    f = flows[idx - 1]
    sess = "  [%s]" % f["session"] if f["session"] and len({x["session"] for x in flows}) > 1 else ""
    print("#%d  %s  %s %s%s" % (idx, ts(f["t"], "%Y-%m-%d %H:%M:%S"), f["method"], f["url"], sess))
    print("-- request " + "-" * 60)
    _print_headers(f["req_headers"])
    if f["query"]:
        print("query:   " + json.dumps(f["query"], ensure_ascii=False))
    _print_body(f["req_body"])
    print("-- response " + "-" * 59)
    if f["status"] is None:
        print("(no logged response)")
    else:
        print("status:  %d" % f["status"])
        _print_headers(f["resp_headers"])
        _print_body(f["resp_body"])


def _print_headers(headers):
    for name, value in (headers or {}).items():
        print("  %s: %s" % (name, value))


def _print_body(body):
    if body is None:
        print("body:    (none)")
        return
    if isinstance(body, dict) and "omitted" in body:
        print("body:    (%s, %s bytes%s)" % (
            body["omitted"], body.get("bytes", "?"),
            ", streamed" if body.get("streamed") else ""))
        return
    text = body.get("text", "")
    if body.get("parsed") == "json":
        try:
            text = json.dumps(json.loads(text), indent=2, ensure_ascii=False)
        except ValueError:
            pass
    print("body:    %d chars%s" % (len(text), " [truncated]" if body.get("truncated") else ""))
    print(text)


def _flow_text(f):
    parts = [f["method"], f["url"], json.dumps(f["query"], ensure_ascii=False),
             json.dumps(f["req_headers"], ensure_ascii=False),
             json.dumps(f["resp_headers"] or {}, ensure_ascii=False)]
    for b in (f["req_body"], f["resp_body"]):
        if isinstance(b, dict) and "text" in b:
            parts.append(b["text"])
    return "\n".join(parts)


def cmd_grep(pattern, flows, host_filter, max_hits, multi=False):
    rx = re.compile(pattern, re.IGNORECASE)
    hits = 0
    for i, f in enumerate(flows, 1):
        if host_filter and f["host"] != host_filter:
            continue
        m = rx.search(_flow_text(f))
        if not m:
            continue
        hits += 1
        text = _flow_text(f)
        lo, hi = max(0, m.start() - 60), min(len(text), m.end() + 60)
        snippet = (text[lo:m.start()] + _c("36", text[m.start():m.end()]) + text[m.end():hi])
        snippet = snippet.replace("\n", " ")
        sess = " [%s]" % short_session(f["session"]) if multi else ""
        print("#%-4d %s %-6s %s%s" % (i, ts(f["t"]), f["status"] or "-", f["url"], sess))
        print("       ..." + snippet + "...")
        if hits >= max_hits:
            print("(%d-hit cap reached; raise with --hits)" % max_hits)
            break
    if not hits:
        print("no matches")


def cmd_errors(flows, denies, multi=False, sort_col=None, desc=False):
    # raw rows: [i, t, session, status, method, url, is_deny]
    raw = []
    for i, f in enumerate(flows, 1):
        if f["status"] and f["status"] >= 400:
            raw.append([i, f["t"] or 0, f["session"] or "", f["status"],
                        f["method"], f["url"], False])
    for e in denies:
        raw.append([0, e.get("t") or 0, e.get("_session") or "", 0,
                    e.get("method", "CONNECT"), "%s:%s" % (e["host"], e["port"]), True])
    if not raw:
        print("(no errors)")
        return
    sort_rows(raw, {
        "time": (lambda r: r[1], True),
        "session": (lambda r: r[2], False),
        "status": (lambda r: r[3], True),
        "method": (lambda r: r[4], False),
        "url": (lambda r: r[5], False),
    }, sort_col, desc)
    rows = []
    for i, t, sess, status, method, url, is_deny in raw:
        mark = _c("33", "DENY") if is_deny else _c("31", str(status))
        rows.append([str(i) if i else "-", ts(t)]
                    + ([short_session(sess or "?")] if multi else [])
                    + [mark, method, url[:80]])
    headers = ["#", "time"] + (["session"] if multi else []) + ["status", "method", "url"]
    # columns: # >  time <  [session <]  status >  method <  url <
    aligns = ">" + "<" * (1 + (1 if multi else 0)) + ">" + "<<"
    table(headers, rows, aligns)


def cmd_denies(denies, multi=False, sort_col=None, desc=False):
    if not denies:
        print("(no denials - every request passed the allowlist)")
        return
    sort_rows(denies, {
        "time": (lambda e: e.get("t") or 0, True),
        "session": (lambda e: e.get("_session") or "", False),
        "method": (lambda e: e.get("method", "CONNECT"), False),
        "host": (lambda e: e["host"], False),
        "port": (lambda e: e.get("port") or 0, True),
    }, sort_col, desc)
    rows = [[ts(e.get("t"))]
            + ([short_session(e.get("_session") or "?")] if multi else [])
            + [e.get("method", "CONNECT"), e["host"], str(e["port"])]
            for e in denies]
    headers = ["time"] + (["session"] if multi else []) + ["method", "host", "port"]
    table(headers, rows, "<" * (3 + (1 if multi else 0)) + ">")
    print("\nto allow any of these: add it to the allowlist, or run the session with "
          "run.sh --allow-list <file>")


def main():
    ap = argparse.ArgumentParser(
        prog="flowlog", description=__doc__.splitlines()[0],
        epilog=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", nargs="?", default="summary",
                    choices=["summary", "hosts", "flows", "show", "grep", "errors", "denies"])
    ap.add_argument("arg", nargs="?", help="pattern for grep, flow # for show, else LOG")
    ap.add_argument("log", nargs="?", help="log file / session dir / session name")
    ap.add_argument("--host", help="filter by exact host")
    ap.add_argument("--last", type=int, help="flows: show only the last N")
    ap.add_argument("--hits", type=int, default=20, help="grep: max matches (default 20)")
    ap.add_argument("--all", action="store_true",
                    help="merge every session in the log directory (ignores LOG)")
    ap.add_argument("--sort", metavar="COL",
                    help="sort by column (numeric columns: largest first, text: A-Z; "
                         "columns per command: summary/hosts host,reqs,conns,errs,deny,"
                         "out,in[,first,last] - flows time,session,host,method,path,"
                         "status,req,resp - errors time,session,status,method,url - "
                         "denies time,session,method,host,port)")
    ap.add_argument("--desc", action="store_true", help="flip the --sort direction")
    ns = ap.parse_args()

    # `flowlog show 3 <LOG>` / `flowlog grep pat <LOG>`: arg=pattern/idx, log=LOG.
    # `flowlog flows <LOG>`: a bare arg that is not a number for show is the LOG.
    log_arg = ns.log
    if ns.command == "show":
        if ns.arg is None:
            ap.error("show needs a flow number")
        idx = int(ns.arg)
    elif ns.command == "grep":
        if ns.arg is None:
            ap.error("grep needs a pattern")
        pattern = ns.arg
    else:
        log_arg = ns.arg if ns.arg is not None and ns.log is None else ns.log
        idx = pattern = None

    sessions = all_sessions() if ns.all else [resolve_log(log_arg)]
    multi = len(sessions) > 1
    events, bad = [], 0
    for name, path in sessions:
        evs, b = load(path, name)
        events.extend(evs)
        bad += b
    flows, connects, denies = build(events)

    if ns.command == "summary":
        cmd_summary(sessions, flows, connects, denies, bad, ns.sort, ns.desc)
    elif ns.command == "hosts":
        cmd_hosts(flows, connects, denies, ns.sort, ns.desc)
    elif ns.command == "flows":
        flows_table(flows, ns.host, ns.last, multi, ns.sort, ns.desc)
    elif ns.command == "show":
        cmd_show(idx, flows)
    elif ns.command == "grep":
        cmd_grep(pattern, flows, ns.host, ns.hits, multi)
    elif ns.command == "errors":
        cmd_errors(flows, denies, multi, ns.sort, ns.desc)
    elif ns.command == "denies":
        cmd_denies(denies, multi, ns.sort, ns.desc)


if __name__ == "__main__":
    main()
