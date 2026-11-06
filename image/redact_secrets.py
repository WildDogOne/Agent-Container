"""Secret redaction for the proxy's --inspect flow log (imported by inspect-proxy.py).

The flow log is world-readable inside the container (and mirrored to the host with
--proxy-logs), so anything the sandboxed agent may not read - API keys, OAuth tokens,
cookies, passwords - has to be removed before a record is written. Layered, because no
single technique catches everything:

  1. Parse first: JSON bodies are walked and form bodies / query strings are split into
     fields, and a value is redacted wholesale when its *name* looks secret
     (is_secret_name). This catches tokens of any shape as long as they sit under a
     telling key (access_token, password, client_secret, x-api-key, ...).
  2. Value patterns (VALUE_RULES): prefix-anchored, high-confidence token shapes, applied
     to every remaining string (and to the raw text when a body can't be parsed). These
     catch secrets that appear outside a telling key - echoed in tool output, error
     messages, env dumps, URLs.
  3. Context patterns for unparsed text: `name: value` / `name=value` assignments whose
     name looks secret, and `Bearer` / `Basic` credentials.

Redaction happens before truncation (a token straddling the log cut would otherwise
survive as an unmatched prefix), and replaced values read `[redacted:<rule>]` so a
false positive can be traced to the rule that caused it. Over-redaction is the accepted
failure mode: a false positive costs a log value, a false negative leaks a credential.

Pattern sources: most VALUE_RULES are ported (simplified, and rewritten for Python's `re`)
from the gitleaks and betterleaks rule sets; the rule names keep the upstream rule ids
where one exists. Both projects are MIT licensed:

    gitleaks  - https://github.com/gitleaks/gitleaks   config/gitleaks.toml
    betterleaks - https://github.com/betterleaks/betterleaks   config/betterleaks.toml
    MIT License, Copyright (c) 2019 Zachary Rice

    Permission is hereby granted, free of charge, to any person obtaining a copy of this
    software and associated documentation files (the "Software"), to deal in the Software
    without restriction, including without limitation the rights to use, copy, modify,
    merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
    permit persons to whom the Software is furnished to do so, subject to the following
    conditions: The above copyright notice and this permission notice shall be included
    in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS
    IS", WITHOUT WARRANTY OF ANY KIND.

The key-name list starts from sentry-python's DEFAULT_DENYLIST (MIT) plus the OAuth / cloud
names it lacks; what must never be logged follows the OWASP Logging Cheat Sheet ("Data to
exclude"). Rules marked `heuristic` have no upstream rule (shape from the provider's known
prefix only) - they are deliberately loose.

Porting notes (Go RE2 -> Python re): everything is compiled with re.ASCII (RE2's \\w \\d \\b
are ASCII-only), inline flags are scoped `(?i:...)` (Python rejects a mid-pattern global
`(?i)`), and every repetition is bounded - Python's re backtracks where RE2 doesn't, so
unbounded `+` before a required terminator is a ReDoS risk on a 64 KB body.
"""
import json
import re
from urllib.parse import parse_qsl, urlencode

MAX_BODY_LOG = 64 * 1024        # logged characters of a text body, after redaction
SCAN_MARGIN = 32 * 1024         # extra text scanned past the cut, > the longest bounded pattern
MAX_PARSE = 4 * 1024 * 1024     # larger bodies skip JSON/form parsing and fall back to text patterns

_F = re.ASCII

# ---- 1. names ----------------------------------------------------------------------
# A field / header / parameter name is secret when one of its `_`-separated segments
# (after camelCase -> snake_case and `-`/`.` -> `_`) is in SECRET_SEGMENTS, or it contains
# one of SECRET_COMPOUNDS. Segment matching keeps `max_tokens` / `input_tokens` / `author`
# / `design` readable while still catching `x-api-key`, `accessToken`, `X-Amz-Signature`.
SECRET_SEGMENTS = {
    "password", "passwd", "passphrase", "pwd", "pass", "secret", "token", "auth",
    "authorization", "credential", "credentials", "cookie", "session", "sessionid",
    "csrftoken", "csrf", "xsrf", "jwt", "bearer", "signature", "assertion", "apikey",
    "privatekey", "otp", "sid",
}
SECRET_COMPOUNDS = (
    "api_key", "private_key", "access_key", "secret_key", "client_secret",
    "subscription_key", "connection_string", "conn_str", "set_cookie", "connect_sid",
    "phpsessid", "mysql_pwd",
)
# Only in URLs and form bodies: bare names that are credentials there (Google ?key=,
# Azure SAS sig=, OAuth authorization code=) but ordinary data keys in JSON payloads.
SECRET_PARAM_NAMES = {"key", "sig", "code", "pw"}

_CAMEL = re.compile(r"(?<=[a-z0-9])(?=[A-Z])", _F)
_SEP = re.compile(r"[-.\s]+", _F)


def is_secret_name(name, param=False):
    if not isinstance(name, str) or not name:
        return False
    n = _SEP.sub("_", _CAMEL.sub("_", name)).lower()
    if param and n in SECRET_PARAM_NAMES:
        return True
    if any(c in n for c in SECRET_COMPOUNDS):
        return True
    return any(seg in SECRET_SEGMENTS for seg in n.split("_"))


# ---- 2. value patterns ----------------------------------------------------------------
# (rule id, keywords, pattern). A rule only runs when one of its lowercase keywords occurs
# in the lowercased text (gitleaks-style prefilter; None = always run). A pattern with a
# group named `s` redacts only that group (e.g. the password in user:pass@host); otherwise
# the whole match is replaced.
_PEM = r"-----BEGIN[ A-Z0-9_-]{0,100}PRIVATE KEY(?: BLOCK)?-----"
VALUE_RULES = [
    # gitleaks private-key, plus an unterminated form (a key cut off by truncation or
    # streaming must not leak its first lines).
    ("private-key", ["private key"],
     _PEM + r"(?:[\s\S]{0,12288}?" + _PEM.replace("BEGIN", "END") + r"|[A-Za-z0-9+/=\s:.,\\-]{0,12288})"),
    # betterleaks generic-credential-uri (simplified): password in scheme://user:pass@host
    ("credential-uri", ["://"],
     r"\b[A-Za-z][A-Za-z0-9+.-]{1,20}://[^\s:/@'\"`]{0,128}:(?P<s>[^\s/@'\"`]{1,256})@"),
    # gitleaks anthropic-api-key / anthropic-admin-api-key generalised to every
    # sk-ant-<family><nn>- token (api03, admin01, OAuth oat01 / ort01 - heuristic for the
    # latter two, which no rule set defines) and without the exact length.
    ("anthropic", ["sk-ant-"], r"\bsk-ant-[a-z]{2,8}\d{2}-[A-Za-z0-9_-]{16,512}"),
    # gitleaks/betterleaks openai-api-key, loosened to every current prefix; T3BlbkFJ is
    # base64 "OpenAI", the legacy key marker.
    ("openai", ["sk-", "t3blbkfj"],
     r"\bsk-(?:proj|svcacct|admin)-[A-Za-z0-9_-]{20,512}|\bsk-[A-Za-z0-9]{20}T3BlbkFJ[A-Za-z0-9]{20}"),
    ("gcp-api-key", ["aiza"], r"\bAIza[\w-]{35}"),
    ("google-oauth-access-token", ["ya29."], r"\bya29\.[\w-]{10,2048}"),          # trufflehog shape (reference only)
    ("google-oauth-refresh-token", ["1//0"], r"(?<![\w/])1//0[\w-]{30,512}"),      # heuristic
    ("github-token", ["ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_"],
     r"\b(?:gh[pousr]_[0-9A-Za-z]{36}|github_pat_\w{82})\b"),
    ("gitlab-token", ["glpat-", "glptt-", "gldt-", "gr1348941", "glrt-", "glcbt-", "gloas-"],
     r"\b(?:gl(?:pat|rt|cbt|oas)-[\w-]{20,128}(?:\.[0-9a-z]{2}\.?[0-9a-z]{7,9})?|glptt-[0-9a-f]{40}|gldt-[\w-]{20,64}|GR1348941[\w-]{20})"),
    ("slack-token", ["xox", "xapp-"], r"\bxox[abeoprs]-[A-Za-z0-9-]{10,512}|\bxapp-\d-[A-Za-z0-9-]{10,512}"),
    ("slack-webhook-url", ["hooks.slack.com"],
     r"hooks\.slack\.com/(?:services|workflows|triggers)/[A-Za-z0-9+/]{43,56}"),
    ("discord-webhook-url", ["discord"],                                            # heuristic
     r"discord(?:app)?\.com/api/webhooks/\d{5,30}/[\w-]{20,128}"),
    ("telegram-bot-api-token", [":a"], r"(?<!\d)\d{5,16}:A[\w-]{34}(?![\w-])"),   # gitleaks shape, context-free
    ("aws-access-token", ["akia", "asia", "abia", "acca", "a3t"],
     r"\b(?:A3T[A-Z0-9]|AKIA|ASIA|ABIA|ACCA)[A-Z2-7]{16}\b"),
    ("aws-amazon-bedrock-api-key", ["absk"], r"\bABSK[A-Za-z0-9+/]{109,269}={0,2}"),
    ("azure-storage-account-key", ["accountkey"], r"(?i:AccountKey)=[A-Za-z0-9+/]{86}=="),
    ("azure-sas-signature", ["sig="], r"(?i:\bsig)=(?P<s>[A-Za-z0-9%+/=]{30,256})"),  # heuristic
    ("azure-ad-client-secret", ["q~"], r"(?<![\w~.-])[\w~.]{3}\dQ~[\w~.-]{31,34}(?![\w~.-])"),
    ("npm-access-token", ["npm_"], r"\bnpm_[A-Za-z0-9]{36}\b"),
    ("pypi-upload-token", ["pypi-ageichlwas5vcmc"], r"\bpypi-AgEIcHlwaS5vcmc[\w-]{50,1000}"),
    ("huggingface-token", ["hf_", "api_org_"], r"\b(?:hf_|api_org_)[A-Za-z]{34}\b"),
    ("stripe-access-token", ["sk_", "rk_"], r"\b(?:sk|rk)_(?:test|live|prod)_[A-Za-z0-9]{10,99}\b"),
    ("twilio-api-key", ["sk"], r"\bSK[0-9a-fA-F]{32}\b"),
    ("sendgrid-api-token", ["sg."], r"\bSG\.[\w-]{22}\.[\w-]{43}\b"),
    ("dockerhub-access-token", ["dckr_"], r"\bdckr_(?:pat_[\w-]{27}|oat_[\w-]{32})"),
    ("digitalocean-token", ["do_v1_", "dop_v1_", "dor_v1_"], r"\bdo[opr]_v1_[a-f0-9]{64}\b"),
    ("atlassian-api-token", ["atatt3", "atctt3"], r"\bAT(?:ATT|CTT)3[A-Za-z0-9_=+/-]{100,512}"),
    ("jwt", ["eyj"], r"\beyJ[\w-]{10,4096}\.eyJ[\w-]{10,8192}\.[\w-]{0,4096}"),
]

# ---- 3. context patterns for unparsed text -------------------------------------------
# `<name><sep><value>` where the name ends in a secret word: env dumps, YAML/INI, headers
# echoed in text, JSON that couldn't be parsed (incl. escaped \" inside JSON strings). The
# name must END in the word, so `max_tokens` / `author` don't match. `pwd` is left out
# here: PWD=/path is the working directory in every env dump.
_ASSIGN_WORDS = (r"password|passwd|passphrase|secret|token|api[_-]?key|apikey|auth|authorization"
                 r"|credentials?|cookie|session[_-]?id|private[_-]?key|access[_-]?key|signature")
# The key must start at a non-name character (lookbehind) so the lazy prefix isn't retried
# at every position of a long word run; an optional auth scheme (`Authorization: Bearer x`)
# belongs to the key, so the credential after it is what gets redacted.
ASSIGN_RE = re.compile(
    r"(?i:(?P<k>(?<![\w.-])[\w.-]{0,64}?(?:" + _ASSIGN_WORDS + r")\\?[\"']?[ \t]{0,3}(?::|=|=>)[ \t]{0,3}\\?[\"']?"
    r"(?:(?:bearer|basic|token|digest)[ \t]{1,4})?))"
    r"(?!\[redacted:)(?P<s>[^\s\"'`,;&<>\\]{1,4096})", _F)
ASSIGN_KEYWORDS = ("pass", "secret", "token", "key", "auth", "credential", "cookie", "session", "signature")
# Authorization schemes in free text (curl -H lines, logged headers in tool output).
AUTH_SCHEME_RE = re.compile(r"(?i:\b(?:bearer|basic|token)[ \t]{1,4})(?!\[redacted:)(?P<s>[A-Za-z0-9._~+/=-]{16,4096})", _F)
AUTH_SCHEME_KEYWORDS = ("bearer", "basic", "token")

_COMPILED = [(rid, kws, re.compile(p, _F)) for rid, kws, p in VALUE_RULES]


def _sub_rule(rule_id, rx, text):
    def repl(m):
        if "s" in rx.groupindex and m.group("s") is not None:
            return text[m.start():m.start("s")] + "[redacted:%s]" % rule_id + text[m.end("s"):m.end()]
        return "[redacted:%s]" % rule_id
    return rx.sub(repl, text)


def scrub(text, context=True):
    """Redact value-shaped secrets in free text. context=False skips the `name=value` /
    Bearer rules (used on strings whose name was already checked, e.g. parsed JSON)."""
    if not text or not isinstance(text, str):
        return text
    low = text.lower()
    for rule_id, kws, rx in _COMPILED:
        if kws is None or any(k in low for k in kws):
            text = _sub_rule(rule_id, rx, text)
    if context:
        if any(k in low for k in AUTH_SCHEME_KEYWORDS):
            text = _sub_rule("auth-scheme", AUTH_SCHEME_RE, text)
        if any(k in low for k in ASSIGN_KEYWORDS):
            text = _sub_rule("assignment", ASSIGN_RE, text)
    return text


# ---- structured redaction ------------------------------------------------------------
REDACTED_NAME = "[redacted:name]"


def redact_json(obj, _depth=0):
    """Walk parsed JSON: values under a secret key go wholesale (containers too), every
    other string is scrubbed - including JSON-in-a-string, via the text patterns."""
    if _depth > 64:
        return "[redacted:depth]"
    if isinstance(obj, dict):
        return {k: (REDACTED_NAME if is_secret_name(k) and obj[k] not in (None, "", True, False)
                    else redact_json(v, _depth + 1)) for k, v in obj.items()}
    if isinstance(obj, list):
        return [redact_json(v, _depth + 1) for v in obj]
    if isinstance(obj, str):
        return scrub(obj)
    return obj


def redact_pairs(pairs):
    """Query-string / form fields: [(name, value)] -> {name: [values]} with secrets masked.
    Values arrive percent-decoded, so encoded tokens are matched too."""
    out = {}
    for name, value in pairs:
        out.setdefault(name, []).append(REDACTED_NAME if is_secret_name(name, param=True) else scrub(value))
    return out


def redact_headers(items):
    out = {}
    for name, value in items:
        out[name] = REDACTED_NAME if is_secret_name(name) else scrub(value)
    return out


def _cut(text):
    return (text[:MAX_BODY_LOG], True) if len(text) > MAX_BODY_LOG else (text, False)


def redact_body(data, ctype):
    """bytes + Content-Type -> loggable dict. Redact first, truncate second."""
    if not data:
        return None
    ctype = (ctype or "").lower()
    text = data.decode("utf-8", "replace")
    if len(text) <= MAX_PARSE:
        stripped = text.lstrip()
        if "json" in ctype or stripped[:1] in ("{", "["):
            try:
                parsed = json.loads(text)
            except ValueError:
                parsed = None
            else:
                out, truncated = _cut(json.dumps(redact_json(parsed), ensure_ascii=False))
                return {"text": out, "truncated": truncated, "parsed": "json"}
        if "x-www-form-urlencoded" in ctype:
            try:
                pairs = parse_qsl(text, keep_blank_values=True, strict_parsing=True)
            except ValueError:
                pairs = None
            if pairs is not None:
                flat = [(k, v) for k, vs in redact_pairs(pairs).items() for v in vs]
                out, truncated = _cut(urlencode(flat, safe="[]:"))
                return {"text": out, "truncated": truncated, "parsed": "form"}
    # Scan MAX + margin, so a token straddling the cut is matched whole. When the body is
    # longer than that window, a token may straddle the window's own end and stay
    # unmatched; replacements shrink the text, so drop the scrubbed window's last
    # SCAN_MARGIN chars (they cover at least the window's original tail) before cutting.
    window = text[:MAX_BODY_LOG + SCAN_MARGIN]
    out = scrub(window)
    if len(text) > len(window):
        out = out[:max(0, len(out) - SCAN_MARGIN)]
    return {"text": out[:MAX_BODY_LOG], "truncated": len(text) > MAX_BODY_LOG}
