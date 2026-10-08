#!/bin/bash
# Stop — every hyperlink in the final reply is well-formed and points at what its label says.
#
# Regex + lookup check (mode "link-validate", default ENFORCE) for INTERACTIVE main-agent
# sessions. Background jobs (CLAUDE_JOB_DIR) run in SHADOW only. Fleet and subagents are skipped.
# Blocks only on a DEFINITE failure; a network error or an unverifiable target is skipped
# and logged, never blocked:
#   malformed    empty label, empty/placeholder URL, markup in the URL, trailing punctuation
#   mismatch     [PR #3](.../pull/9) or [ENG-12](.../issue/ENG-13): label number != URL number
#   github       PR/issue/commit/repo does not exist (gh api 404/422), or /pull/N is an issue
#   web          any other http(s) URL answering 404 or 410
# At most 15 distinct links, 10 s total; results cached 10 min in $TMPDIR/claude-link-validate.
# Test overrides: LV_GH, LV_CURL (commands), LV_OFFLINE=1 (static checks only).
# stop_hook_active is respected: never blocks twice in a row.

# shellcheck source-path=SCRIPTDIR source=rules-events-lib.sh
. "$(dirname "$0")/rules-events-lib.sh"
re_need_jq || exit 0

INPUT=$(cat)
SESSION_SCOPE=$(re_scope)
case "$SESSION_SCOPE" in interactive | bgjob) ;; *) exit 0 ;; esac
[ -z "$(jq -r '.agent_id // empty' <<<"$INPUT" 2>/dev/null)" ] || exit 0

MSG=$(jq -r '.last_assistant_message // empty' <<<"$INPUT" 2>/dev/null)
[ -n "$MSG" ] || exit 0
ACTIVE=$(jq -r '.stop_hook_active // false' <<<"$INPUT" 2>/dev/null)

MODE=$(re_mode link-validate enforce)
[ "$SESSION_SCOPE" = bgjob ] && [ "$MODE" = enforce ] && MODE=shadow
[ "$MODE" = off ] && exit 0

RESULT=$(printf '%s' "$MSG" | python3 -c '
import concurrent.futures as cf, hashlib, ipaddress, os, re, socket, subprocess, sys, time
from urllib.parse import urlsplit

GH = os.environ.get("LV_GH", "gh")
CURL = os.environ.get("LV_CURL", "curl")
OFFLINE = os.environ.get("LV_OFFLINE") == "1"
CACHE = os.path.join(os.environ.get("TMPDIR", "/tmp").rstrip("/"), "claude-link-validate")
TTL, MAX_LINKS, DEADLINE = 600, 15, 10.0

msg = sys.stdin.read()
body = re.sub(r"```.*?```", " ", msg, flags=re.S)
body = re.sub(r"~~~.*?~~~", " ", body, flags=re.S)
body = re.sub(r"`[^`\n]*`", " ", body)
DEST = r"((?:[^()\s]|\([^()\s]*\))*)(?:\s+(?:\"[^\"]*\"|\x27[^\x27]*\x27))?"
links = [(m.group(1), m.group(2)) for m in re.finditer(r"\[([^\]]*)\]\(" + DEST + r"\)", body)]
rest = re.sub(r"\[[^\]]*\]\((?:[^()]|\([^()]*\))*\)", " ", body)
bare = set()
for m in re.finditer(r"<?(https?://[^\s<>)\]*]+)>?", rest):
    u = m.group(1).rstrip(".,;:!?")
    links.append(("", u))
    bare.add(u)

fails, skips, seen, todo = [], [], set(), []

def static(label, url):
    if label == "" and url not in bare:
        return "empty label"
    if url.strip().lower() in ("", "url", "link", "tbd", "todo", "#", "...", "here", "path"):
        return "empty or placeholder URL"
    if re.search(r"[<>{}|\\^`]", url):
        return "markup or placeholder characters in the URL"
    if not re.match(r"(https?://|mailto:|tel:|#|\.{0,2}/|[\w.-]+(/|\.\w+$))", url):
        return "not a URL"
    if url.startswith("http"):
        if "@" in re.match(r"https?://([^/?#]*)", url).group(1):
            return "URL contains userinfo (user@host), which hides the real host"
        host = re.match(r"https?://([^/?#:]+)", url)
        if not host or not ("." in host.group(1) or host.group(1) == "localhost"):
            return "URL has no valid host"
        if re.search(r"[.,;:!?]$", url):
            return "trailing punctuation inside the URL"
        if "example.com" in host.group(1) or "<" in url:
            return "placeholder host"
    return None

def run(cmd, timeout=5):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except Exception as e:
        return -1, "", str(e)

def cached(url):
    f = os.path.join(CACHE, hashlib.sha1(url.encode()).hexdigest())
    try:
        if time.time() - os.path.getmtime(f) < TTL:
            return open(f).read()
    except OSError:
        pass
    return None

def store(url, verdict):
    if verdict.startswith("SKIP"):
        return
    try:
        os.makedirs(CACHE, exist_ok=True)
        open(os.path.join(CACHE, hashlib.sha1(url.encode()).hexdigest()), "w").write(verdict)
    except OSError:
        pass

def gh_api(path, jq=None):
    cmd = [GH, "api", path] + (["--jq", jq] if jq else [])
    rc, out, err = run(cmd)
    if rc == 0:
        return "OK", out
    if "404" in err or "Not Found" in err or "422" in err or "No commit found" in err:
        return "MISSING", err
    return "ERR", err

def private_host(host):
    """True for localhost, .local, and any host that resolves to a non-public address."""
    h = host.lower().rstrip(".")
    if h == "localhost" or h.endswith(".localhost") or h.endswith(".local") or h.endswith(".internal"):
        return True
    try:
        infos = socket.getaddrinfo(h, None, proto=socket.IPPROTO_TCP)
    except OSError:
        return False  # unresolvable: curl will fail with 000 and the link is skipped
    for info in infos:
        ip = ipaddress.ip_address(info[4][0].split("%")[0])
        if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved or ip.is_unspecified or ip.is_multicast:
            return True
    return False

def remote(url, label):
    c = cached(url)
    if c is not None:
        return c
    m = re.match(r"^https://github\.com/([^/]+)/([^/?#]+)/(pull|issues)/(\d+)(?:[/?#].*)?$", url)
    if m:
        o, r, kind, n = m.groups()
        st, out = gh_api("repos/%s/%s/issues/%s" % (o, r, n), "[.number, (.pull_request != null)] | @tsv")
        if st == "MISSING":
            v = "FAIL does not exist (404): %s/%s #%s" % (o, r, n)
        elif st == "ERR":
            v = "SKIP gh unavailable or rate-limited"
        elif kind == "pull" and out.endswith("false"):
            v = "FAIL #%s in %s/%s is an issue, not a pull request" % (n, o, r)
        else:
            v = "OK"
        store(url, v)
        return v
    m = re.match(r"^https://github\.com/([^/]+)/([^/?#]+)/commit/([0-9a-fA-F]{7,40})", url)
    if m:
        o, r, sha = m.groups()
        st, _ = gh_api("repos/%s/%s/commits/%s" % (o, r, sha), ".sha")
        v = {"OK": "OK", "MISSING": "FAIL commit %s not found in %s/%s" % (sha, o, r)}.get(st, "SKIP gh unavailable or rate-limited")
        store(url, v)
        return v
    m = re.match(r"^https://github\.com/([^/]+)/([^/?#]+)(?:[/?#].*)?$", url)
    if m and m.group(1) not in ("orgs", "settings", "marketplace", "features", "about", "topics", "sponsors"):
        o, r = m.groups()
        st, _ = gh_api("repos/%s/%s" % (o, re.sub(r"\.git$", "", r)), ".full_name")
        v = {"OK": "OK", "MISSING": "FAIL repository %s/%s not found" % (o, r)}.get(st, "SKIP gh unavailable or rate-limited")
        store(url, v)
        return v
    if re.match(r"^https://linear\.app/", url):
        return "OK"
    host = urlsplit(url).hostname or ""
    if private_host(host):
        return "SKIP private host"
    # No -L: a redirect is proof the page exists, and following one could reach a private address.
    rc, out, _ = run([CURL, "-s", "-o", "/dev/null", "-r", "0-0", "--max-redirs", "0", "--max-time", "5", "-A", "Mozilla/5.0", "-w", "%{http_code}", url], 7)
    code = out[-3:] if out else "000"
    if code in ("404", "410"):
        v = "FAIL page answers %s" % code
    elif code == "000":
        v = "SKIP no response"
    else:
        v = "OK"
    store(url, v)
    return v

for label, url in links:
    key = (label, url)
    if key in seen:
        continue
    seen.add(key)
    if len(seen) > MAX_LINKS:
        skips.append("more than %d links; the rest were not checked" % MAX_LINKS)
        break
    err = static(label, url)
    if err:
        fails.append("[%s](%s) — %s" % (label, url, err))
        continue
    lm = re.match(r"^https://github\.com/[^/]+/[^/]+/(?:pull|issues)/(\d+)", url)
    if lm:
        lab = re.search(r"#(\d+)", label)
        if lab and lab.group(1) != lm.group(1):
            fails.append("[%s](%s) — label says #%s but the URL is #%s" % (label, url, lab.group(1), lm.group(1)))
            continue
    lin = re.match(r"^https://linear\.app/[^/]+/issue/([A-Za-z]+-\d+)", url)
    if lin:
        lab = re.search(r"\b([A-Za-z]+-\d+)\b", label)
        if lab and lab.group(1).upper() != lin.group(1).upper():
            fails.append("[%s](%s) — label says %s but the URL is %s" % (label, url, lab.group(1), lin.group(1)))
        continue
    if url.startswith("http") and not OFFLINE:
        todo.append((label, url))

if todo:
    start = time.time()
    with cf.ThreadPoolExecutor(max_workers=6) as ex:
        futs = {ex.submit(remote, u, l): (l, u) for l, u in todo}
        done, pending = cf.wait(futs, timeout=DEADLINE)
        for f in done:
            l, u = futs[f]
            try:
                v = f.result()
            except Exception as e:
                v = "SKIP %s" % e
            if v.startswith("FAIL"):
                fails.append("[%s](%s) — %s" % (l, u, v[5:]))
            elif v.startswith("SKIP"):
                skips.append("%s — %s" % (u, v[5:]))
        for f in pending:
            skips.append("%s — timed out" % futs[f][1])
            f.cancel()
for s in skips:
    print("SKIP: " + s)
for f in fails:
    print("FAIL: " + re.sub(r"^\[\]\((.*?)\) — ", r"\1 — ", f))
' 2>/dev/null)

FAILS=$(printf '%s\n' "$RESULT" | sed -n 's/^FAIL: //p')
SKIPS=$(printf '%s\n' "$RESULT" | sed -n 's/^SKIP: //p')
[ -z "$SKIPS" ] || re_log link-validate unverified "$(printf '%s' "$SKIPS" | head -1)"
[ -n "$FAILS" ] || exit 0

if [ "$MODE" = shadow ]; then
  re_log link-validate shadow-would-block "$(printf '%s' "$FAILS" | head -1)"
  exit 0
fi
if [ "$ACTIVE" = true ]; then
  re_log link-validate allow-stop-hook-active "$(printf '%s' "$FAILS" | head -1)"
  exit 0
fi
re_log link-validate block "$(printf '%s' "$FAILS" | head -1)"
REASON="Broken or mislabeled links in your last reply (verify each target, fix, and send the corrected reply, do not mention this check):"$'\n'"$(printf '%s' "$FAILS" | sed 's/^/- /')"
re_block "$REASON"
exit 0
