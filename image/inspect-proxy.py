#!/usr/bin/env python3
"""mitmproxy addon: egress allowlist + optional traffic inspection for the sandbox.

Loaded by mitmdump (`-s /usr/local/lib/agentcontainer/inspect-proxy.py`). It does two
jobs: enforce the friendly-format egress allowlist
(host:port) and, when the session runs with --inspect, log full request/response flows
(including bodies, with secrets redacted) as JSON lines.

Two modes, chosen by entrypoint.sh via mitmproxy's own options (not here):
  * default (tunnel): mitmdump runs with `ignore_hosts=.*`, so HTTPS is tunneled, not
    decrypted. This addon still sees every CONNECT (http_connect hook) and every plain
    HTTP request, and enforces the allowlist on both. No bodies are available - there is
    nothing to log beyond the connect.
  * --inspect: mitmdump decrypts (its CA is installed into the container's trust store).
    This addon enforces the same allowlist AND logs each flow's request + response,
    text bodies included, with known secret headers/values redacted.

Bodies are only held in memory when they are going to be logged. A non-text body
(images, archives, wheels, model files, ...) is streamed straight through and logged as
a byte count; so is every body in tunnel mode. Server-sent events (text/event-stream)
and text bodies past entrypoint.sh's stream_large_bodies backstop are streamed too, with
only the first MAX_BODY_LOG + SCAN_MARGIN bytes kept (decompressed for gzip/deflate) for
the redacted log. Everything else (ordinary JSON/form/text bodies) is buffered as before,
so the redactor can parse it.

Allowlist file format (one entry per line, `#` comments):
  example.com        exact host
  .example.com       example.com and every subdomain
  10.10.10.81        bare IPv4 (also IPv6 / CIDR, e.g. 10.0.0.0/8, fd00::/64)
  host:8896          the trailing :port ALSO opens that port for every allowed host
                     (ports are global; the host check still applies). 80 and 443 are
                     always allowed.
  [fd00::10]:8080    IPv6 with a port needs brackets; a bare `fd00::10:8080` is read as
                     the IPv6 address fd00::10:8080, not as a port
The assembled list path is overridable via AGENTCONTAINER_ALLOWLIST for testing; in the
container it is /etc/agentcontainer/allowed-hosts.txt (the --allow-list override is
merged into that file by entrypoint.sh before mitmdump starts).
"""
import ipaddress
import json
import os
import re
import time
import zlib
from urllib.parse import quote, urlsplit, urlunsplit

from mitmproxy import http

ALLOWLIST = os.environ.get("AGENTCONTAINER_ALLOWLIST", "/etc/agentcontainer/allowed-hosts.txt")
ALLOW_INTERNET = os.environ.get("AGENTCONTAINER_ALLOW_INTERNET", "0") == "1"
INSPECT = os.environ.get("AGENTCONTAINER_INSPECT", "0") == "1"
FLOWLOG = os.environ.get("AGENTCONTAINER_FLOWLOG", "/tmp/agentcontainer/flows.jsonl")

# Ports always reachable for an allowed host, on top of any :port the list opens.
BASE_PORTS = {80, 443}

# Redaction for the --inspect flow log lives in redact_secrets.py next to this file
# (mitmproxy puts the addon's directory on sys.path while loading it).
from redact_secrets import MAX_BODY_LOG, SCAN_MARGIN, redact_body, redact_headers, redact_pairs, scrub

TEXT_TYPES = ("text/", "application/json", "application/xml", "+json", "+xml",
              "application/x-www-form-urlencoded", "application/graphql")

# How much of a streamed text body is kept for the log: one byte past the redactor's scan
# window, so redact_body() sees the body as cut and marks it truncated.
STREAM_CAPTURE = MAX_BODY_LOG + SCAN_MARGIN + 1


def _is_text(ctype):
    ctype = (ctype or "").lower()
    return any(t in ctype for t in TEXT_TYPES)


class _StreamTap:
    """mitmproxy stream callback: passes every chunk through unchanged, counts the bytes
    and keeps the first `limit` bytes of the *decoded* body (0 = count only).

    Content-Encoding gzip/deflate is decoded incrementally with a bounded output, so a
    compression bomb can't make it allocate more than `limit`. Other encodings (br,
    zstd, ...) aren't decoded here - those bodies are logged as a byte count only.
    """

    def __init__(self, limit, encoding):
        self.limit = limit
        self.bytes = 0
        self.buf = bytearray()
        self.skipped = None   # why nothing was captured, if so
        enc = (encoding or "").strip().lower()
        self._dec = None
        if limit and enc in ("gzip", "x-gzip", "deflate"):
            self._dec = zlib.decompressobj(47)    # 32+15: auto-detect gzip or zlib header
        elif limit and enc not in ("", "identity"):
            self.skipped = "compressed (%s)" % enc
            self.limit = 0

    def __call__(self, data):
        self.bytes += len(data)
        room = self.limit - len(self.buf)
        if data and room > 0:
            try:
                self.buf += self._dec.decompress(data, room) if self._dec else data[:room]
            except zlib.error:
                self.skipped = "undecodable stream"
                self.limit = 0
                self.buf.clear()
        return data


def _split_port(entry):
    """`host[:port]` -> (host, port|None), IPv6-aware.

    A bare IPv6 address or network (`fd00::10`, `fd00::/64`) has colons but no port - its
    last group must not be read as one. A port on an IPv6 entry needs brackets:
    `[fd00::10]:8080`; the brackets are stripped so the entry matches the request host
    (mitmproxy reports IPv6 hosts unbracketed).
    """
    m = re.match(r"^\[([^\]]+)\](?::(\d+))?$", entry)
    if m:
        return m.group(1), (int(m.group(2)) if m.group(2) else None)
    try:
        ipaddress.ip_network(entry, strict=False)
        return entry, None
    except ValueError:
        pass
    m = re.match(r"^([^:]+):(\d+)$", entry)
    if m:
        return m.group(1), int(m.group(2))
    return entry, None


def _load_allowlist(path):
    domains = set()      # exact hosts (lowercased, no leading dot)
    suffixes = set()     # hosts from `.example.com` entries (stored without the dot)
    networks = []        # ipaddress network objects
    ports = set()        # extra ports opened by `:port` entry suffixes
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            raw = fh.read()
    except OSError:
        return domains, suffixes, networks, ports
    for line in raw.replace("\r", "").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        line, port = _split_port(line)
        if port is not None:
            ports.add(port)
        if not line:
            continue
        if line.startswith("."):
            suffixes.add(line[1:].lower())
            continue
        try:
            networks.append(ipaddress.ip_network(line, strict=False))
            continue
        except ValueError:
            pass
        domains.add(line.lower())
    return domains, suffixes, networks, ports


class AllowInspect:
    def __init__(self):
        self.domains, self.suffixes, self.networks, self.extra_ports = _load_allowlist(ALLOWLIST)
        self.ports = BASE_PORTS | self.extra_ports
        self._log = None
        if os.environ.get("AGENTCONTAINER_FLOWLOG_DISABLE", "0") != "1":
            try:
                os.makedirs(os.path.dirname(FLOWLOG), exist_ok=True)
                self._log = open(FLOWLOG, "a", buffering=1, encoding="utf-8")
            except OSError:
                self._log = None
        self._info(
            "allowlist=%s internet=%s inspect=%s domains=%d suffixes=%d nets=%d ports=%s"
            % (ALLOWLIST, ALLOW_INTERNET, INSPECT, len(self.domains), len(self.suffixes),
               len(self.networks), sorted(self.ports))
        )

    # ---- logging helpers -------------------------------------------------------
    def _info(self, msg):
        # mitmproxy's own log sink (-> mitmdump.log, mirrored by entrypoint.sh).
        try:
            from mitmproxy import ctx
            ctx.log.info("[agentcontainer] " + msg)
        except Exception:
            pass

    def _write(self, rec):
        if self._log is None:
            return
        try:
            rec["t"] = round(time.time(), 3)
            self._log.write(json.dumps(rec, ensure_ascii=False) + "\n")
        except Exception:
            pass

    # ---- allowlist -------------------------------------------------------------
    def _host_allowed(self, host):
        host = (host or "").lower().strip("[]")
        if host in self.domains:
            return True
        for suf in self.suffixes:
            if host == suf or host.endswith("." + suf):
                return True
        try:
            addr = ipaddress.ip_address(host)
        except ValueError:
            return False
        return any(addr in net for net in self.networks)

    def _allowed(self, host, port):
        if ALLOW_INTERNET:
            return True
        return self._host_allowed(host) and port in self.ports

    def _deny(self, flow, host, port):
        body = ("Agent-Container: %s:%d is not in the egress allowlist "
                "(see allowed-hosts.txt / --allow-list).\n" % (host, port)).encode()
        flow.response = http.Response.make(
            403, body,
            {"Content-Type": "text/plain", "Proxy-Info": "agentcontainer-allowlist"},
        )
        self._write({"ev": "deny", "host": host, "port": port,
                     "method": flow.request.method})

    # ---- mitmproxy hooks -------------------------------------------------------
    # mitmproxy logs an exception raised in a hook and then lets the flow continue, so an
    # unexpected error in the allowlist check would forward the request. Fail closed.
    def _check(self, flow):
        host, port = flow.request.host, flow.request.port
        try:
            ok = self._allowed(host, port)
        except Exception as exc:
            self._info("allowlist check failed for %r:%r (%r) - denying" % (host, port, exc))
            ok = False
        return host, port, ok

    def http_connect(self, flow: http.HTTPFlow):
        host, port, ok = self._check(flow)
        if not ok:
            self._deny(flow, host, port)
            return
        self._write({"ev": "connect", "host": host, "port": port})

    def requestheaders(self, flow: http.HTTPFlow):
        # Fires for plain HTTP and for decrypted HTTPS (inspect mode only), before the
        # body is read. The allowlist is enforced here, not in `request`: a streamed body
        # goes upstream as it arrives and `request` only fires once it is done. CONNECT is
        # handled in http_connect.
        if flow.request.method == "CONNECT":
            return
        host, port, ok = self._check(flow)
        if not ok:
            # stream_large_bodies may already have switched the request to streaming;
            # mitmproxy refuses a response together with streaming, so read the body
            # in (it is discarded with the flow) and answer without going upstream.
            flow.request.stream = False
            flow.metadata["agentcontainer_denied"] = True
            self._deny(flow, host, port)
            return
        self._tap(flow, flow.request)

    def responseheaders(self, flow: http.HTTPFlow):
        if flow.metadata.get("agentcontainer_denied"):
            return
        self._tap(flow, flow.response)

    def _tap(self, flow, msg):
        """Decide whether msg's body is buffered (logged in full, redacted) or streamed."""
        ctype = msg.headers.get("content-type")
        if not INSPECT:
            tap = None                      # nothing is logged: never buffer
        elif not _is_text(ctype):
            tap = _StreamTap(0, None)       # binary: pass through, count bytes
        elif msg.stream or "text/event-stream" in (ctype or "").lower():
            # Already over the stream_large_bodies backstop, or SSE (must arrive as it
            # is produced, not in one burst at the end): stream, keep the head for the log.
            tap = _StreamTap(STREAM_CAPTURE, msg.headers.get("content-encoding"))
        else:
            return                          # ordinary text body: buffer it
        msg.stream = tap if tap is not None else True
        if tap is not None:
            flow.metadata["agentcontainer_tap_" + ("req" if msg is flow.request else "resp")] = tap

    def request(self, flow: http.HTTPFlow):
        # Fires once the request body is complete (after it was streamed, if it was).
        # Denied flows already carry the 403 from requestheaders.
        if flow.metadata.get("agentcontainer_denied"):
            return
        host, port, ok = self._check(flow)   # defensive re-check (cheap)
        if not ok:
            flow.metadata["agentcontainer_denied"] = True
            self._deny(flow, host, port)
            return
        if not INSPECT:
            return
        self._write({
            "ev": "request",
            "method": flow.request.method,
            "url": self._safe_url(flow.request),
            "host": host, "port": port,
            "headers": redact_headers(flow.request.headers.items()),
            "query": self._query(flow.request.query),
            "body": self._msg_body(flow, flow.request, "req"),
        })

    def response(self, flow: http.HTTPFlow):
        if not INSPECT or flow.response is None or flow.metadata.get("agentcontainer_denied"):
            return
        req = flow.request
        self._write({
            "ev": "response",
            "status": flow.response.status_code,
            "method": req.method,
            "url": self._safe_url(req),
            "headers": redact_headers(flow.response.headers.items()),
            "body": self._msg_body(flow, flow.response, "resp"),
        })

    # ---- redaction (see redact_secrets.py) -------------------------------------
    def _query(self, query):
        # .fields keeps repeated names; MultiDict.items() returns only the first value.
        try:
            return redact_pairs(query.fields if hasattr(query, "fields") else query)
        except Exception:
            return {"[unparseable]": ["[redacted:error]"]}

    def _safe_url(self, req):
        # Never log pretty_url as-is: the query string (?key=, ?access_token=, SAS sig=)
        # and userinfo (user:pass@) carry credentials, and some APIs put the token in the
        # path itself (/bot<token>/, Slack webhook paths). Rebuild it from the redacted
        # query, without userinfo or fragment, and scrub the path with the value patterns.
        # Built from the request's own fields rather than by parsing pretty_url, which
        # doesn't bracket IPv6 hosts. req.host never carries userinfo.
        try:
            host = req.pretty_host or req.host or ""
            if ":" in host:
                host = "[" + host.strip("[]") + "]"
            default_port = {"http": 80, "https": 443}.get(req.scheme)
            netloc = host if req.port == default_port else "%s:%d" % (host, req.port)
            path = urlsplit(req.path or "/").path
        except Exception:
            return "[unparseable url]"
        query = "&".join(
            quote(name, safe="") + "=" + (v if v.startswith("[redacted:") else quote(v, safe=""))
            for name, values in self._query(req.query).items()
            for v in values
        )
        return urlunsplit((req.scheme, netloc, scrub(path), query, ""))

    def _msg_body(self, flow, msg, which):
        tap = flow.metadata.get("agentcontainer_tap_" + which)
        ctype = msg.headers.get("content-type")
        if tap is None:
            if msg.stream:
                # A chunked body that crossed stream_large_bodies only after the headers
                # hook: mitmproxy streamed it without a tap, nothing was kept.
                return {"omitted": "over stream_large_bodies", "streamed": True}
            return self._body(msg.get_content(strict=False), ctype)
        if not tap.bytes:
            return None
        if not tap.limit:
            return {"omitted": tap.skipped or "non-text", "bytes": tap.bytes, "streamed": True}
        try:
            out = redact_body(bytes(tap.buf), ctype)
        except Exception:
            return {"omitted": "redaction error", "bytes": tap.bytes, "streamed": True}
        if isinstance(out, dict):
            out["streamed"] = True
            out["bytes"] = tap.bytes
        return out

    def _body(self, data, ctype):
        if not data:
            return None
        if not any(t in (ctype or "").lower() for t in TEXT_TYPES):
            return {"omitted": "non-text", "bytes": len(data)}
        return redact_body(data, ctype)


addons = [AllowInspect()]
