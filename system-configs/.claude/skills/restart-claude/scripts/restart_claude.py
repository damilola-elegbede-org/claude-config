#!/usr/bin/env python3
"""Update the Claude Code CLI, then restart every running claude process so it
picks up the new binary and the current settings.json.

A claude process pins whatever binary it exec'd, so `claude update` alone changes
nothing for sessions that are already running -- they keep serving from the old
version directory until the process is replaced. Same for settings.json, which is
read at startup. Restarting is the only way to move a live session forward.

Modes:
  --plan      inventory + intended actions, changes nothing (no update either)
  --execute   update, then restart everything stale, forcefully

The invoking session is always handled last, by a detached helper, because
killing it would otherwise kill the script mid-run.
"""

import argparse
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
LAUNCHER = os.path.join(HOME, ".local/bin/claude")
VERSIONS_DIR = os.path.join(HOME, ".local/share/claude/versions")
STATE_DIR = os.path.join(HOME, ".claude/restart-claude")
REPORT = os.path.join(STATE_DIR, "last-run.md")

# Flags worth carrying over when relaunching a session. Anything not listed is
# dropped on purpose: daemon-internal wiring (--bg-pty-host, --bg-spare) points
# at sockets the old supervisor owned, so re-passing it would leave the new
# process waiting on something nobody is serving. --reply-on-resume is added
# back deliberately in relaunch_cmd().
VALUE_FLAGS = {
    "--model", "--permission-mode", "--effort", "--agent", "--output-style",
    "--settings", "--setting-sources", "--append-system-prompt", "--system-prompt-file",
}
REPEATABLE_FLAGS = {"--allowed-tools", "--allowedTools", "--add-dir", "--mcp-config", "--disallowed-tools"}
BOOL_FLAGS = {
    "--dangerously-skip-permissions", "--allow-dangerously-skip-permissions",
    "--brief", "--chrome", "--forward-subagent-text", "--verbose",
}


ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def strip_ansi(text):
    return ANSI_RE.sub("", text)


def sh(cmd, timeout=120, cwd=None):
    """Run a command, return (rc, stdout+stderr). Never raises on non-zero."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=cwd)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired:
        return 124, "timed out"
    except FileNotFoundError:
        return 127, "not found"


VERSION_NAME_RE = re.compile(r"^[0-9]+(\.[0-9]+)*$")


def _version_key(name):
    return tuple(int(p) for p in name.split("."))


def installed_versions():
    """Every build present, newest last."""
    try:
        names = [n for n in os.listdir(VERSIONS_DIR)
                 if VERSION_NAME_RE.match(n) and os.path.isfile(os.path.join(VERSIONS_DIR, n))]
    except OSError:
        return []
    return sorted(names, key=_version_key)


def latest_version():
    """Newest build in versions/.

    Deliberately not `realpath(launcher)`: the launcher here is a shell script
    that picks the newest build and execs it through ClaudeCode.app, so the
    launcher path resolves to itself and says nothing about versions.
    """
    versions = installed_versions()
    return versions[-1] if versions else None


def inode_to_version():
    """Map inode -> version name.

    The launcher hard-links the newest build into the app bundle so macOS
    privacy grants attach to a stable bundle id. Hard links mean the running
    binary's *path* can be .../ClaudeCode.app/Contents/MacOS/claude with no
    version in it at all, so paths can't identify a build -- inodes can, because
    the link and versions/<ver> are the same file.
    """
    m = {}
    for name in installed_versions():
        try:
            m[os.stat(os.path.join(VERSIONS_DIR, name)).st_ino] = name
        except OSError:
            continue
    return m


def exe_version(pid, ino_map=None):
    """Version a live pid is actually executing, or None if unidentifiable.

    argv can't answer this -- a process started as `claude` carries no version.
    lsof reports the executable it's running; the inode of that file is what
    ties it back to a build.
    """
    ino_map = inode_to_version() if ino_map is None else ino_map
    rc, out = sh(["lsof", "-p", str(pid)], timeout=20)
    paths = []
    for line in out.splitlines():
        if " txt " not in f" {line} ":
            continue
        path = line.split(None, 8)[-1] if len(line.split(None, 8)) > 8 else line.split()[-1]
        if "claude" in path.lower():
            paths.append(path)
    for path in paths:
        try:
            ver = ino_map.get(os.stat(path).st_ino)
        except OSError:
            ver = None
        if ver:
            return ver
    for path in paths + [out]:
        m = re.search(r"versions/([0-9][0-9.]*)", path)
        if m:
            return m.group(1)
    return None


def ps_table():
    rc, out = sh(["ps", "-eo", "pid=,ppid=,command="])
    rows = []
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 3:
            continue
        try:
            rows.append({"pid": int(parts[0]), "ppid": int(parts[1]), "cmd": parts[2]})
        except ValueError:
            continue
    return rows


def is_claude_proc(cmd):
    """Claude Code CLI processes only, judged by argv[0].

    Matching the whole command line looks tempting but catches anything that
    merely *mentions* claude -- a wrapper shell like `zsh -lc 'claude agents'`,
    an editor, a grep. Those aren't claude and can't be version-checked, so they
    surface as unknown-version processes and pollute the restart list. argv[0]
    is the executable actually running.

    /Applications/Claude.app is the separate desktop app -- restarting the CLI
    has nothing to do with it, and killing its helpers would close windows the
    user never asked us to touch.
    """
    try:
        exe = shlex.split(cmd)[0] if cmd.strip() else ""
    except ValueError:
        exe = cmd.split()[0] if cmd.split() else ""
    if not exe or "/Applications/Claude.app" in exe:
        return False
    return (
        ".local/share/claude/versions/" in exe
        or "ClaudeCode.app/Contents/MacOS/claude" in exe
        or exe == "claude"
        or exe.endswith("/claude")
    )


def replay_flags(cmd):
    """Pull the reusable flags out of a running process's command line."""
    try:
        toks = shlex.split(cmd)
    except ValueError:
        toks = cmd.split()
    out, i = [], 0
    while i < len(toks):
        t = toks[i]
        if t in BOOL_FLAGS:
            out.append(t)
            i += 1
        elif t in VALUE_FLAGS and i + 1 < len(toks):
            out += [t, toks[i + 1]]
            i += 2
        elif t in REPEATABLE_FLAGS and i + 1 < len(toks):
            out.append(t)
            i += 1
            while i < len(toks) and not toks[i].startswith("-"):
                out.append(toks[i])
                i += 1
        else:
            i += 1
    return out


def sessions():
    """Live sessions per the CLI itself -- authoritative, unlike ps guessing.

    Gives sessionId, cwd, name and busy/idle status for interactive and
    background sessions alike.
    """
    rc, out = sh([LAUNCHER, "agents", "--json"], timeout=60)
    if rc != 0:
        return []
    try:
        start = out.index("[")
        data = json.loads(out[start:])
    except (ValueError, json.JSONDecodeError):
        return []
    # Interactive entries come back in a slimmer shape than background ones --
    # no short `id`, no `state`. Normalising here keeps every caller from having
    # to know that, and stops a single open interactive session from blowing up
    # the whole run with a KeyError.
    for s in data:
        s.setdefault("id", (s.get("sessionId") or "")[:8])
        s.setdefault("state", "")
        s.setdefault("name", s.get("id", ""))
    return data


def tmux_claude_panes(procs):
    """Panes whose foreground process tree contains a claude CLI."""
    rc, out = sh(["tmux", "list-panes", "-a", "-F",
                  "#{pane_id}\t#{pane_pid}\t#{pane_current_path}\t#{session_name}"])
    if rc != 0:
        return []
    by_ppid, by_pid = {}, {}
    for p in procs:
        by_ppid.setdefault(p["ppid"], []).append(p)
        by_pid[p["pid"]] = p

    def descend(pid, depth=0):
        # The pane process itself can be claude: `tmux new-session claude` execs
        # it directly with no shell in between. Panes started from a prompt have
        # a shell parent instead, so both shapes have to be checked or one of
        # them is silently skipped.
        if depth == 0 and pid in by_pid:
            return by_pid[pid]
        if depth > 4:
            return None
        for child in by_ppid.get(pid, []):
            if is_claude_proc(child["cmd"]):
                return child
            found = descend(child["pid"], depth + 1)
            if found:
                return found
        return None

    panes, seen = [], set()
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) < 4:
            continue
        pane_id, pane_pid, path, sess = parts[0], parts[1], parts[2], parts[3]
        # tmux grouped sessions expose the same pane twice; respawning it twice
        # would kill the process we just started.
        if pane_id in seen:
            continue
        seen.add(pane_id)
        try:
            proc = descend(int(pane_pid))
        except ValueError:
            continue
        if proc:
            panes.append({"pane": pane_id, "tmux_session": sess, "cwd": path, "proc": proc})
    return panes


def build_inventory():
    latest = latest_version()
    procs = [p for p in ps_table() if is_claude_proc(p["cmd"])]
    self_pid = int(os.environ.get("CLAUDE_PID") or 0)
    self_sid = os.environ.get("CLAUDE_CODE_SESSION_ID") or ""

    inv = {"latest": latest, "self_session": self_sid, "self_pid": self_pid,
           "sessions": [], "panes": [], "spares": [], "daemon": None}
    ino_map = inode_to_version()

    def version_of(pid):
        return exe_version(pid, ino_map)

    def is_stale(ver):
        # An unidentifiable build means the binary it's running is no longer in
        # versions/ -- i.e. an old build that was cleaned up. Treating unknown as
        # current would silently skip exactly the processes worth restarting.
        return bool(latest) and ver != latest

    live = {s["pid"]: s for s in sessions()}
    # A spare that gets claimed *becomes* the session process, and its pty host is
    # the session's parent -- so both look like spares in argv while actually
    # serving live work. Killing either would take a session down with no
    # relaunch, so anything holding a live session is never treated as a spare.
    children = {}
    for p in procs:
        children.setdefault(p["ppid"], []).append(p["pid"])

    def holds_live_session(pid):
        return pid in live or any(c in live for c in children.get(pid, []))

    for p in procs:
        cmd = p["cmd"]
        ver = version_of(p["pid"])
        stale = is_stale(ver)
        if "daemon run" in cmd:
            inv["daemon"] = {"pid": p["pid"], "version": ver, "stale": stale}
        elif ("--bg-spare" in cmd or "bg-pty-host" in cmd) and not holds_live_session(p["pid"]):
            inv["spares"].append({"pid": p["pid"], "version": ver, "stale": stale})
        elif p["pid"] in live:
            s = dict(live[p["pid"]])
            s.update({"version": ver, "stale": stale, "flags": replay_flags(cmd),
                      "is_self": p["pid"] == self_pid or s.get("sessionId") == self_sid})
            inv["sessions"].append(s)

    # Sessions the CLI knows about but whose pid we didn't classify above.
    classified = {s["pid"] for s in inv["sessions"]}
    for pid, s in live.items():
        if pid not in classified:
            ver = version_of(pid)
            inv["sessions"].append({**s, "version": ver,
                                    "stale": is_stale(ver),
                                    "flags": [],
                                    "is_self": pid == self_pid or s.get("sessionId") == self_sid})

    by_pid_session = {s["pid"]: s for s in inv["sessions"]}
    for pane in tmux_claude_panes(procs):
        pid = pane["proc"]["pid"]
        ver = version_of(pid)
        hosted = by_pid_session.get(pid)
        pane.update({"version": ver, "stale": is_stale(ver),
                     # A pane that hosts a real session is still restarted as a
                     # pane -- relaunching it as a background job would empty the
                     # user's terminal and move their conversation elsewhere. The
                     # session id just tells us what to resume in place.
                     "hosts_session": bool(hosted),
                     "session_id": hosted.get("sessionId") if hosted else None})
        inv["panes"].append(pane)

    # Sessions living in a pane are handled by the pane path, so they must not
    # also be picked up as background sessions.
    pane_pids = {p["proc"]["pid"] for p in inv["panes"]}
    for s in inv["sessions"]:
        s["in_pane"] = s["pid"] in pane_pids
    return inv


def relaunch_cmd(sess):
    """Command that brings a background session back on the current binary.

    --reply-on-resume is what makes the restart stick: a session resumed into
    --bg without it sits unattached and gets reaped within a couple of minutes,
    so the "restart" silently loses the session. With it, the session comes back
    idle-and-attachable with its history intact and no extra turn generated.
    """
    if not transcript_exists(sess.get("sessionId")):
        # Nothing written yet, so --resume would fail; bring it back as a fresh
        # background session under the same name rather than losing it.
        cmd = [LAUNCHER, "--bg"]
        name = (sess.get("name") or "").strip()
        return (cmd + (["--name", name] if name else []) + sess.get("flags", []))
    cmd = [LAUNCHER, "--resume", sess["sessionId"], "--bg", "--reply-on-resume"]
    name = (sess.get("name") or "").strip()
    # Resuming into --bg mints a fresh session id and loses the label, so pass
    # the name back explicitly -- that's how the session stays findable in
    # `claude agents` after the restart.
    if name and "--name" not in sess.get("flags", []):
        cmd += ["--name", name]
    return cmd + sess.get("flags", [])


def transcript_exists(session_id):
    """Whether a session has anything on disk to resume.

    A session that never exchanged a message has no transcript, and `--resume`
    on it fails outright ("No conversation found with session ID"). Checking
    first is the difference between the user getting their session back and
    getting an error message where their session used to be.
    """
    if not session_id:
        return False
    import glob
    pattern = os.path.join(HOME, ".claude/projects", "*", f"{session_id}.jsonl")
    return bool(glob.glob(pattern))


SUBCOMMANDS = {"agents", "daemon", "mcp", "plugin", "plugins", "install", "update",
               "upgrade", "doctor", "auth", "project", "setup-token", "gateway",
               "ultrareview", "attach", "logs", "stop", "config"}


def pane_relaunch_cmd(pane):
    """What to run in a respawned pane.

    A pane is someone's terminal, so it has to come back as the same kind of
    thing it was. A `claude agents` TUI just replays; a live conversation has to
    resume, or the restart quietly throws the user's thread away and hands them
    a blank prompt.
    """
    argv = shlex.split(pane["proc"]["cmd"])
    args = argv[1:]
    flags = replay_flags(pane["proc"]["cmd"])
    if pane.get("session_id") and transcript_exists(pane["session_id"]):
        return [LAUNCHER, "--resume", pane["session_id"]] + flags
    # No --continue guessing for an untracked pane: `--continue` picks the most
    # recent conversation in that directory, which can easily be a *live*
    # background session's transcript, and two processes on one session is worse
    # than a fresh prompt. Live sessions register with the CLI, so the branch
    # above already covers anything genuinely resumable.
    return [LAUNCHER] + args


def wait_gone(pid, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            os.kill(pid, 0)
        except OSError:
            return True
        time.sleep(0.5)
    return False


def stop_session(sess, log):
    """Clean stop, escalating only if the session ignores it."""
    sid, pid = sess["id"], sess["pid"]
    sh([LAUNCHER, "stop", sid], timeout=60)
    if wait_gone(pid, 20):
        return True
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.kill(pid, sig)
        except OSError:
            return True
        if wait_gone(pid, 10):
            log(f"  {sid}: exited after {sig.name}")
            return True
    log(f"  {sid}: pid {pid} would not die")
    return False


def restart_session(sess, log):
    sid = sess["id"]
    log(f"restarting session {sid} ({sess.get('name','')[:40]}) {sess.get('version')} -> latest")
    if not stop_session(sess, log):
        return {"id": sid, "action": "FAILED to stop", "new_id": None}
    cmd = relaunch_cmd(sess)
    # Launch from the session's own directory: project CLAUDE.md, local settings
    # and relative --add-dir paths all resolve against cwd.
    cwd = sess.get("cwd") if os.path.isdir(sess.get("cwd") or "") else HOME
    rc, out = sh(cmd, timeout=120, cwd=cwd)
    # The CLI colourises its confirmation line, and the escape codes contain
    # digits -- match against the stripped text or the id never parses and a
    # successful relaunch gets reported as a failure.
    m = re.search(r"backgrounded[^0-9a-f]*([0-9a-f]{8})\b", strip_ansi(out))
    new_id = m.group(1) if m else None
    if rc != 0 or not new_id:
        log(f"  relaunch failed rc={rc}: {out.strip()[:300]}")
        log(f"  recover by hand: cd {shlex.quote(sess.get('cwd','~'))} && {' '.join(shlex.quote(c) for c in cmd)}")
        return {"id": sid, "action": f"FAILED to relaunch (rc={rc})", "new_id": None, "new_pid": None}
    new_pid = next((s["pid"] for s in sessions() if s["id"] == new_id), None)
    log(f"  back as {new_id}")
    return {"id": sid, "action": "restarted", "new_id": new_id, "new_pid": new_pid}


def write_helper(inv, daemon_restart, targets):
    """Detached script for the steps that would kill this script mid-run.

    The invoking session -- and the daemon that supervises it -- can't be
    restarted from inside the session itself, so the work is handed to a process
    that outlives it and writes its outcome to the report.
    """
    os.makedirs(STATE_DIR, exist_ok=True)
    helper = os.path.join(STATE_DIR, "finish-restart.sh")
    log = os.path.join(STATE_DIR, "finish-restart.log")
    lines = ["#!/bin/bash", "# generated by the restart-claude skill", "set -u",
             f'exec >> {shlex.quote(log)} 2>&1', 'echo "--- finish $(date) ---"',
             "sleep 3"]
    if daemon_restart:
        d = inv["daemon"]
        lines += [f'echo "killing stale daemon {d["pid"]} (version {d["version"]})"',
                  f'kill {d["pid"]} 2>/dev/null || true', "sleep 3"]
    for t in targets:
        cmd = " ".join(shlex.quote(c) for c in relaunch_cmd(t))
        cwd = shlex.quote(t.get("cwd") or HOME)
        lines += [f'echo "relaunching {t["id"]} ({(t.get("name") or "")[:40]})"',
                  f'{LAUNCHER} stop {t["id"]} >/dev/null 2>&1 || true',
                  "sleep 2",
                  f'cd {cwd} && {cmd}']
    lines += [f'echo "done" >> {shlex.quote(log)}',
              f'printf "\\n_Finished by detached helper; see %s_\\n" {shlex.quote(log)} >> {shlex.quote(REPORT)}']
    with open(helper, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(helper, 0o755)
    subprocess.Popen(["nohup", "bash", helper], stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL,
                     start_new_session=True)
    return helper, log


def render(inv, actions, notes, latest):
    out = [f"# restart-claude ({time.strftime('%Y-%m-%d %H:%M:%S')})", "",
           f"Installed CLI: **{latest}**", "", "| what | id / pane | name | was | action |",
           "|---|---|---|---|---|"]
    for a in actions:
        out.append("| {kind} | {id} | {name} | {was} | {action} |".format(
            kind=a["kind"], id=a["id"], name=(a.get("name") or "")[:38].replace("|", "/"),
            was=a.get("was") or "?", action=a["action"]))
    if notes:
        out += ["", "## Notes"] + [f"- {n}" for n in notes]
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description="Restart all claude sessions on the latest CLI")
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--plan", action="store_true", help="report only, change nothing")
    mode.add_argument("--execute", action="store_true", help="update and restart")
    ap.add_argument("--no-update", action="store_true", help="skip `claude update`")
    ap.add_argument("--include-fresh", action="store_true",
                    help="also restart processes already on the latest version (picks up settings.json changes)")
    args = ap.parse_args()

    logs = []

    def log(msg):
        print(msg, flush=True)
        logs.append(msg)

    if args.execute and not args.no_update:
        log("updating CLI...")
        rc, out = sh([LAUNCHER, "update"], timeout=600)
        log("  " + " / ".join(l.strip() for l in strip_ansi(out).strip().splitlines()[-2:]))

    inv = build_inventory()
    latest = inv["latest"]
    if not latest:
        print("cannot resolve installed version from launcher symlink", file=sys.stderr)
        return 1

    def needs(item):
        return bool(item.get("stale")) or args.include_fresh

    actions, notes = [], []
    # Pane-hosted sessions are restarted through the pane path, in place.
    sess_targets = [s for s in inv["sessions"] if needs(s) and not s.get("in_pane")]
    self_sess = next((s for s in inv["sessions"] if s.get("is_self")), None)
    others = [s for s in sess_targets if not s.get("is_self")]
    panes = [p for p in inv["panes"] if needs(p)]
    spares = [s for s in inv["spares"] if needs(s)]
    daemon_restart = bool(inv["daemon"] and needs(inv["daemon"]))

    # A stale daemon has to go, and taking it down takes every background session
    # with it -- so restarting those sessions inline first would just be work the
    # daemon kill undoes. Hand the whole set to the helper instead.
    inline_sessions = [] if daemon_restart else others

    if args.plan:
        for s in sess_targets:
            actions.append({"kind": "session" + (" (self)" if s.get("is_self") else ""),
                            "id": s["id"], "name": s.get("name"), "was": s.get("version"),
                            "action": "would restart" + (" last, detached" if s.get("is_self") else "")})
        for p in panes:
            actions.append({"kind": "tmux pane", "id": f'{p["tmux_session"]}:{p["pane"]}',
                            "name": p["proc"]["cmd"][:38], "was": p.get("version"),
                            "action": "would respawn"})
        for s in spares:
            actions.append({"kind": "bg spare", "id": str(s["pid"]), "name": "pre-warmed",
                            "was": s.get("version"), "action": "would kill"})
        if daemon_restart:
            actions.append({"kind": "daemon", "id": str(inv["daemon"]["pid"]), "name": "supervisor",
                            "was": inv["daemon"]["version"],
                            "action": "would restart last (kills all bg sessions, helper relaunches them)"})
        if not actions:
            notes.append(f"Everything already on {latest}. Use --include-fresh to restart anyway "
                         f"(e.g. after editing settings.json).")
    else:
        # Spares go first, before any session is relaunched. A restarting session
        # is handed whichever pre-warmed spare is waiting, so a stale spare left
        # in the pool would put the "restarted" session straight back on the old
        # binary -- the exact thing this is meant to fix.
        for s in spares:
            # Unclaimed pre-warmed processes; the daemon makes new ones on demand,
            # so killing a stale one only stops it handing out an old binary.
            try:
                os.kill(s["pid"], signal.SIGTERM)
                act = "killed"
            except OSError as e:
                act = f"FAILED: {e}"
            actions.append({"kind": "bg spare", "id": str(s["pid"]), "name": "pre-warmed",
                            "was": s.get("version"), "action": act})
        if spares:
            time.sleep(2)  # let the daemon re-warm from the current binary

        for s in inline_sessions:
            r = restart_session(s, log)
            new_ver = exe_version(r["new_pid"]) if r.get("new_pid") else None
            detail = r["action"] + (f' -> {r["new_id"]}' if r["new_id"] else "")
            # Report the version the session actually came back on rather than
            # assuming the restart moved it: if the daemon is handing out an old
            # binary, this is where it shows up.
            if new_ver:
                detail += f" (on {new_ver})" + ("" if new_ver == latest else " -- STILL STALE")
            actions.append({"kind": "session", "id": s["id"], "name": s.get("name"),
                            "was": s.get("version"), "action": detail})
        for p in panes:
            cmd = pane_relaunch_cmd(p)
            log(f'respawning pane {p["tmux_session"]}:{p["pane"]} ({p.get("version")} -> {latest}): {" ".join(cmd[1:]) or "interactive"}')
            # Wrap in a login shell that survives claude exiting. Respawning the
            # bare command would make the pane close the moment the user quits
            # claude, losing a tmux window that previously fell back to a prompt.
            shell = os.environ.get("SHELL", "/bin/zsh")
            inner = " ".join(shlex.quote(c) for c in cmd)
            wrapped = [shell, "-l", "-c", f"{inner}; exec {shlex.quote(shell)} -l"]
            rc, out = sh(["tmux", "respawn-pane", "-k", "-t", p["pane"], "-c", p["cwd"], "--"] + wrapped)
            actions.append({"kind": "tmux pane", "id": f'{p["tmux_session"]}:{p["pane"]}',
                            "name": p["proc"]["cmd"][:38], "was": p.get("version"),
                            "action": "respawned" if rc == 0 else f"FAILED: {out.strip()[:80]}"})
        helper_targets = ([t for t in others] if daemon_restart else [])
        if self_sess and needs(self_sess):
            helper_targets.append(self_sess)
        if daemon_restart or helper_targets:
            helper, hlog = write_helper(inv, daemon_restart, helper_targets)
            if daemon_restart:
                actions.append({"kind": "daemon", "id": str(inv["daemon"]["pid"]), "name": "supervisor",
                                "was": inv["daemon"]["version"], "action": "restart handed to helper"})
            for t in helper_targets:
                actions.append({"kind": "session" + (" (self)" if t.get("is_self") else ""),
                                "id": t["id"], "name": t.get("name"), "was": t.get("version"),
                                "action": "restarting via detached helper"})
            notes.append(f"Detached helper running: `{helper}` (log: `{hlog}`). "
                         f"This session is restarted by it, so this session's own output stops here.")
        if not actions:
            notes.append(f"Nothing stale -- everything already on {latest}. "
                         f"Use --include-fresh to restart anyway (e.g. after editing settings.json).")

    # Interactive sessions outside tmux can't be respawned: killing one leaves a
    # dead terminal with no way to bring it back, which is worse than leaving it.
    for s in inv["sessions"]:
        if s.get("kind") == "interactive" and needs(s) and not s.get("is_self"):
            in_tmux = any(p["proc"]["pid"] == s["pid"] for p in inv["panes"])
            if not in_tmux:
                notes.append(f'Interactive session {s["id"]} (pid {s["pid"]}, {s.get("version")}) is not in '
                             f'tmux -- left running. In that terminal: `/exit`, then '
                             f'`claude --resume {s["sessionId"]}`.')

    report = render(inv, actions, notes, latest)
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(REPORT, "w") as f:
        f.write(report)
    print("\n" + report)
    print(f"report: {REPORT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
