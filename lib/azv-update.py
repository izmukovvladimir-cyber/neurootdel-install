#!/usr/bin/env python3
"""Backup, protected-file check and rollback for `install.sh --update` («Агент за вечер»).

install.sh copies this file into the update's backup dir, so the rollback works later
without the installer repo. Subcommands (all paths absolute):

  manifest <out.json> <list.nul> <root>...
      every directory, regular file and symlink under the roots: kind, sha256 (or link
      target), size, mode, uid, gid. Claude's session transcripts (~/.claude/projects/*.jsonl)
      and files over 50 MB are listed as skipped (kind S: no hash, not in the copy), so a
      skipped path is never mistaken for a missing one. <list.nul> = what tar copies.
  verify <manifest.json> <files.tgz>
      every file and link of the manifest is in the copy with the same bytes / target
      (the manifest and tar are two passes: a file changed in between = no update).
  check <config.json>
      compares the manifest taken before the update with the files now (the agent is still
      stopped). Writes manifest-after.json, changes.json (changed / removed / added) and
      report.txt into the backup dir and prints one line:
      checked=N changed=N added=N removed=N problems=N soul_edits=N.
      A problem is: a strict file (memory, journals, login) that changed or went away, a file
      that changed its kind, a protected channel.env key whose value changed, or a line of the
      owner's text the update removed outside the installer's own marker blocks (a removed line
      is the installer's own only when it is in the installer sources, a {{PLACEHOLDER}} line
      with enough fixed text matches it, or it was in the previous payload).
  rollback <backup dir>
      puts back every file the update changed or removed (from files.tgz) and deletes every
      file it added, both only while the file is still as the update left it
      (manifest-after.json): a file changed again since stays, named as a conflict. Files the
      update did not touch stay as they are now; a path outside the roots or under a symlinked
      directory is skipped (checked again right before each write). Without the after record
      (the update was killed) nothing is touched. The current copies of the files it replaces
      go to rolled-back-<ts>.tgz first.

Secrets: the report names paths, env keys and line numbers, never the text of a line.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import stat
import sys
import tarfile
import time
from collections import Counter
from pathlib import Path

SKIP_DIRS = {"node_modules", ".git", "shell-snapshots", "todos", "statsig", "debug", "telemetry",
             "cache", ".cache", "session-env", "file-history", "__pycache__"}
MAX_BYTES = 50 * 1024 * 1024
TEXT_LIMIT = 2 * 1024 * 1024
PROTECTED_ENV_KEYS = ("TELEGRAM_BOT_TOKEN", "TELEGRAM_ALLOWED_USER_IDS", "TELEGRAM_ALLOWED_CHAT_IDS",
                      "TELEGRAM_PERMISSION_ALLOWED_USER_IDS", "TELEGRAM_COMMAND_OWNER_IDS",
                      "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY")
PLACEHOLDER_RE = re.compile(r"\\\{\\\{[A-Z0-9_]+\\\}\\\}")
VAR_RE = re.compile(r"\$\{?[A-Za-z_][A-Za-z0-9_]*(:-[^}]*)?\}?")
MIN_LITERAL = 12
# crontab(1) rewrites its own header line with the install time on every write: never owner text
CRON_STAMP_RE = re.compile(r"^# \(.* installed on .*\)$")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def walk(root: Path):
    """Yields (path, lstat) for dirs, regular files and symlinks under root (root may be a file)."""
    try:
        st = root.lstat()
    except FileNotFoundError:
        return
    if stat.S_ISLNK(st.st_mode) or stat.S_ISREG(st.st_mode):
        yield root, st
        return
    if not stat.S_ISDIR(st.st_mode):
        return
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        try:
            yield Path(dirpath), Path(dirpath).lstat()
        except FileNotFoundError:
            continue
        keep = []
        for d in sorted(dirnames):
            p = Path(dirpath) / d
            if p.is_symlink():
                try:
                    yield p, p.lstat()   # a symlinked dir is a link, never followed
                except FileNotFoundError:
                    pass
            elif d not in SKIP_DIRS and not d.endswith(".staging"):
                keep.append(d)
        dirnames[:] = keep
        for name in sorted(filenames):
            p = Path(dirpath) / name
            try:
                st = p.lstat()
            except FileNotFoundError:
                continue
            # a fifo or socket is never opened (a fifo without a writer would hang the copy)
            if stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode):
                yield p, st


def _skipped(key: str, st: os.stat_result) -> bool:
    return (key.endswith(".jsonl") and "/.claude/projects/" in key) or st.st_size > MAX_BYTES


def take_manifest(roots: list[str]) -> dict[str, list]:
    """path -> [kind, sha256 | link target | "", size, mode, uid, gid]; kinds F, L, D, S (skipped)."""
    out: dict[str, list] = {}
    for r in roots:
        for p, st in walk(Path(r)):
            key = str(p)
            meta = [stat.S_IMODE(st.st_mode), st.st_uid, st.st_gid]
            if stat.S_ISDIR(st.st_mode):
                out[key] = ["D", "", 0, *meta]
            elif stat.S_ISLNK(st.st_mode):
                out[key] = ["L", os.readlink(p), 0, *meta]
            elif _skipped(key, st):
                out[key] = ["S", "", st.st_size, *meta]
            else:
                try:
                    out[key] = ["F", sha256_file(p), st.st_size, *meta]
                except (PermissionError, FileNotFoundError):
                    continue
    return out


def cmd_manifest(out_json: str, list_nul: str, roots: list[str]) -> int:
    m = take_manifest(roots)
    Path(out_json).write_text(json.dumps(m, ensure_ascii=False, indent=0), encoding="utf-8")
    with open(list_nul, "wb") as fh:
        for k in sorted(m):
            if m[k][0] != "S":
                fh.write(k.encode("utf-8", "surrogateescape") + b"\0")
    print(len(m))
    return 0


def cmd_verify(manifest_json: str, tgz: str) -> int:
    m = json.loads(Path(manifest_json).read_text(encoding="utf-8"))
    bad = 0
    with tarfile.open(tgz, "r:gz") as tar:
        members = {"/" + x.name: x for x in tar.getmembers()}
        for path, entry in m.items():
            if entry[0] in ("D", "S"):
                continue
            mem = members.get(path)
            if mem is None:
                bad += 1
            elif [mem.uid, mem.gid] != [entry[4], entry[5]] or (entry[0] == "F" and mem.mode & 0o7777 != entry[3]):
                bad += 1   # the rollback applies these as root: they must be what the manifest saw
            elif entry[0] == "L":
                bad += 0 if mem.issym() and mem.linkname == entry[1] else 1
            elif not mem.isfile():
                bad += 1
            else:
                fh = tar.extractfile(mem)
                h = hashlib.sha256()
                for chunk in iter(lambda: fh.read(1 << 20), b""):
                    h.update(chunk)
                bad += 0 if h.hexdigest() == entry[1] else 1
    print(f"mismatch={bad}")
    return 0 if bad == 0 else 1


def _lines(data: bytes) -> list[str] | None:
    if b"\0" in data[:8192]:
        return None
    try:
        return data.decode("utf-8").splitlines()
    except UnicodeDecodeError:
        return None


def _read_regular(path: str) -> bytes | None:
    """The file's bytes when it is a regular file of at most TEXT_LIMIT, never through a link."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return None
    with os.fdopen(fd, "rb") as fh:
        st = os.fstat(fh.fileno())
        if not stat.S_ISREG(st.st_mode) or st.st_size > TEXT_LIMIT:
            return None
        return fh.read(TEXT_LIMIT + 1)


def _block_re(tags: list[str]) -> re.Pattern[str]:
    """Begin markers the installer itself writes: <!-- BEGIN <install tag>: name --> and <!-- <tag>:begin ... -->."""
    long_tags = "|".join(re.escape(t) for t in tags if not t.startswith(":"))
    short_tags = "|".join(re.escape(t[1:]) for t in tags if t.startswith(":"))
    parts = []
    if long_tags:
        parts.append(rf"BEGIN\s+(?P<tag>{long_tags}):\s*(?P<name>[^>]*?)")
    if short_tags:
        parts.append(rf"(?P<short>{short_tags}):begin\b[^>]*?")
    return re.compile(r"^\s*<!--\s*(?:" + "|".join(parts or ["(?!x)x"]) + r")\s*-->\s*$")


def _outside_blocks(lines: list[str], begin_re: re.Pattern[str]) -> list[str]:
    """The lines outside the installer's marker blocks: what is between them is the installer's own."""
    out: list[str] = []
    end: str | None = None
    for ln in lines:
        if end is None:
            m = begin_re.match(ln)
            if m:
                end = (f"<!-- END {m.group('tag')}: {m.group('name').strip()} -->" if m.group("tag")
                       else f"<!-- {m.group('short')}:end")
                continue
            out.append(ln)
        elif ln.strip().startswith(end):
            end = None
    return out if end is None else lines   # an unclosed block: judge every line


def _parse_env(lines: list[str]) -> dict[str, str]:
    env: dict[str, str] = {}
    for ln in lines:
        s = ln.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        k, v = s.split("=", 1)
        env[k.strip().removeprefix("export ").strip()] = v.strip().strip('"').strip("'")
    return env


def _is_env_file(path: str) -> bool:
    n = os.path.basename(path)
    return n.endswith(".env") or n.startswith("channel.env") or n == "guard.conf"


class InstallerText:
    """Every line the installer could have written: sources, templates, previous payload."""

    def __init__(self) -> None:
        self.exact: set[str] = set()
        self.patterns: list[re.Pattern[str]] = []

    def add_text(self, text: str) -> None:
        for ln in text.splitlines():
            s = ln.strip()
            if not s:
                continue
            self.exact.add(s)
            # a line that is mostly a placeholder (`{{BRIEF_LINE}}`) would match any owner line: no pattern
            if "{{" in s and len(re.sub(r"\{\{[A-Z0-9_]+\}\}", "", s).strip()) >= MIN_LITERAL:
                try:
                    self.patterns.append(re.compile(PLACEHOLDER_RE.sub(".*", re.escape(s)) + r"\Z"))
                except re.error:
                    pass
            # an installer heredoc line with ${VARS}: the same rule
            if "$" in s and len(VAR_RE.sub("", s).strip()) >= MIN_LITERAL:
                rx = re.sub(r"\\\$\\\{?[A-Za-z_][A-Za-z0-9_]*(\\:\\-[^}]*)?\\\}?", ".*", re.escape(s))
                try:
                    self.patterns.append(re.compile(rx + r"\Z"))
                except re.error:
                    pass

    def add_tree(self, root: str) -> None:
        for p, st in walk(Path(root)):
            if not stat.S_ISREG(st.st_mode) or st.st_size > TEXT_LIMIT:
                continue
            data = _read_regular(str(p))
            lines = _lines(data) if data is not None else None
            if lines is not None:
                self.add_text("\n".join(lines))

    def knows(self, line: str) -> bool:
        s = line.strip()
        return s in self.exact or any(p.match(s) for p in self.patterns)


def _member(tar: tarfile.TarFile, path: str) -> bytes | None:
    try:
        m = tar.getmember(path.lstrip("/"))
    except KeyError:
        return None
    if not m.isfile():
        return None
    f = tar.extractfile(m)
    return f.read() if f else None


def _under(path: str, prefixes: list[str]) -> bool:
    return any(path == p or path.startswith(p.rstrip("/") + "/") for p in prefixes)


def diff_manifests(before: dict, after: dict) -> dict:
    """Files and links only (directories are recreated with their parents on a rollback)."""
    b = {k: v for k, v in before.items() if v[0] != "D"}
    a = {k: v for k, v in after.items() if v[0] != "D"}
    changed = sorted(k for k in b if k in a and b[k] != a[k])
    removed = sorted(k for k in b if k not in a)
    added = {k: a[k] for k in sorted(a) if k not in b}
    return {"changed": changed, "removed": removed, "added": added}


def cmd_check(config_path: str) -> int:
    cfg = json.loads(Path(config_path).read_text(encoding="utf-8"))
    bdir = Path(cfg["backup_dir"])
    before = json.loads((bdir / "manifest-before.json").read_text(encoding="utf-8"))
    after = take_manifest(cfg["roots"])
    d = diff_manifests(before, after)
    # the state the update left: a rollback puts back only paths still in this state (no conflict)
    (bdir / "manifest-after.json").write_text(json.dumps(after, ensure_ascii=False, indent=0), encoding="utf-8")
    (bdir / "changes.json").write_text(json.dumps(d, ensure_ascii=False, indent=0), encoding="utf-8")
    strict = [re.compile(x) for x in cfg.get("strict", [])]
    managed = cfg.get("managed", [])
    begin_re = _block_re(cfg.get("block_tags", []))
    stage_old, stage_dir = cfg.get("azv_stage", ""), cfg.get("azv_agent_dir", "")

    known = InstallerText()
    for src in cfg.get("sources", []):
        known.add_tree(src)
    problems: list[str] = []
    soul_edits: list[str] = []
    report: list[str] = []
    with tarfile.open(bdir / "files.tgz", "r:gz") as tar:
        for m in tar.getmembers():   # the previous payload: its lines are the installer's own too
            if stage_old and ("/" + m.name).startswith(stage_old.rstrip("/") + "/") and m.isfile():
                lines = _lines(_member(tar, "/" + m.name) or b"")
                if lines is not None:
                    known.add_text("\n".join(lines))
        for path in d["changed"] + d["removed"]:
            gone = path in d["removed"]
            what = "removed" if gone else "changed"
            old_kind = before[path][0]
            new_kind = after[path][0] if not gone else ""
            if any(rx.search(path) for rx in strict):
                problems.append(f"STRICT {what}: {path}")
                continue
            if new_kind and new_kind != old_kind:
                problems.append(f"TYPE {path}: {old_kind} -> {new_kind}")
                continue
            if stage_dir and _under(path, [stage_dir]):
                # payload file: replaced by the new payload; an owner's edit of it is kept in the backup
                old = _member(tar, path)
                ref = _member(tar, os.path.join(stage_old, os.path.relpath(path, stage_dir))) if stage_old else None
                if old is not None and ref is not None and old != ref:
                    soul_edits.append(path)
                continue
            if _under(path, managed):
                report.append(f"managed: {path}")
                continue
            if old_kind == "S":
                problems.append(f"UNCHECKED {what} (not in the copy, over 50 MB or a transcript): {path}")
                continue
            if old_kind != "F":
                report.append(f"{what} ({'link' if old_kind == 'L' else 'not in copy'}): {path}")
                continue
            old = _member(tar, path)
            if old is not None and len(old) > TEXT_LIMIT:
                problems.append(f"UNCHECKED {what} (over {TEXT_LIMIT // 1024 // 1024} MB, lines not compared): {path}")
                continue
            old_lines = _lines(old) if old is not None else None
            if old_lines is None:
                report.append(f"{what} (binary): {path}")
                continue
            new_lines: list[str] = []
            if not gone:
                data = _read_regular(path)
                new_lines = (_lines(data) if data is not None else None) or []
            if _is_env_file(path):
                o, n = _parse_env(old_lines), _parse_env(new_lines)
                for k in PROTECTED_ENV_KEYS:
                    if o.get(k, "") and o.get(k) != n.get(k):
                        problems.append(f"ENV {path}: {k} changed")
            outside_old = _outside_blocks(old_lines, begin_re)
            lost = Counter(outside_old) - Counter(_outside_blocks(new_lines, begin_re))
            for text in lost:
                if not text.strip() or known.knows(text) or CRON_STAMP_RE.match(text):
                    continue
                # where, never what: a removed line may hold anything the owner wrote
                num = next((i for i, x in enumerate(old_lines, 1) if x == text), 0)
                problems.append(f"OWNER_TEXT {path}: line {num} of the copy")
            report.append(f"{what}: {path}")
    for p in d["added"]:
        report.append(f"added: {p}")
    n_skipped = sum(1 for v in before.values() if v[0] == "S")
    with (bdir / "report.txt").open("w", encoding="utf-8") as fh:
        fh.write(f"# update check {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
        for ln in problems:
            fh.write(f"PROBLEM {ln}\n")
        for ln in soul_edits:
            fh.write(f"SOUL_EDIT {ln} (owner's copy in files.tgz)\n")
        if n_skipped:
            fh.write(f"NOT_IN_COPY {n_skipped} files (session transcripts, files over 50 MB), kind S in manifest-before.json\n")
        for ln in report:
            fh.write(ln + "\n")
    print(f"checked={len(before)} changed={len(d['changed'])} added={len(d['added'])} "
          f"removed={len(d['removed'])} problems={len(problems)} soul_edits={len(soul_edits)}")
    return 0


def _safe_target(path: str, roots: list[str]) -> bool:
    """Inside a root, and no directory on the way is a symlink (a planted link must not redirect root)."""
    if not _under(path, roots):
        return False
    parent = os.path.dirname(path)
    while parent and not os.path.lexists(parent):
        parent = os.path.dirname(parent)
    return os.path.realpath(parent) == os.path.normpath(parent)


def _fresh_name(dirname: str, create) -> str:
    """A short new name in dirname, made by create(path) (which fails on an existing one); never reuses."""
    for _ in range(50):
        t = os.path.join(dirname, f".azvrb-{os.urandom(6).hex()}")
        try:
            create(t)
            return t
        except FileExistsError:
            continue
    raise FileExistsError(f"no free temporary name in {dirname}")


def _make_parents(path: str, tar: tarfile.TarFile, before: dict) -> None:
    """Missing parent dirs back with the mode and owner the copy recorded (else the nearest parent's)."""
    missing = []
    parent = os.path.dirname(path)
    while parent and not os.path.lexists(parent):
        missing.append(parent)
        parent = os.path.dirname(parent)
    for d in reversed(missing):
        os.mkdir(d)
        rec = before.get(d)
        if rec and rec[0] == "D":
            mode, uid, gid = rec[3], rec[4], rec[5]
        else:
            st = os.stat(os.path.dirname(d))
            mode, uid, gid = stat.S_IMODE(st.st_mode), st.st_uid, st.st_gid
        os.chmod(d, mode)
        if os.geteuid() == 0:
            os.chown(d, uid, gid)


def cmd_rollback(bdir_s: str) -> int:
    bdir = Path(bdir_s)
    before = json.loads((bdir / "manifest-before.json").read_text(encoding="utf-8"))
    roots = json.loads((bdir / "roots.json").read_text(encoding="utf-8"))
    ch_path, after_path = bdir / "changes.json", bdir / "manifest-after.json"
    if not (ch_path.exists() and after_path.exists()):
        print("no_after_record: the update left no record of its changes; nothing touched", file=sys.stderr)
        return 3
    d = json.loads(ch_path.read_text(encoding="utf-8"))
    after = json.loads(after_path.read_text(encoding="utf-8"))
    now = take_manifest(roots)
    restore, conflicts, unsafe = [], [], []
    for p in d["changed"] + d["removed"]:
        if not _safe_target(p, roots):
            unsafe.append(p)
        elif now.get(p) != after.get(p):
            conflicts.append(p)   # changed again after the update: the newer copy stays
        elif before[p][0] not in ("F", "L") or (now.get(p) or ["F"])[0] == "S":
            conflicts.append(p)   # not in the copy, or no hash to prove it is as the update left it
        else:
            restore.append(p)
    # only a file or link with a hash or target proving it is still the update's own is removed
    drop = [p for p, entry in d["added"].items()
            if entry[0] in ("F", "L") and now.get(p) == entry and _safe_target(p, roots)]
    kept_new = [p for p in d["added"] if p in now and p not in drop]
    ts = time.strftime("%Y%m%d-%H%M%S")
    with tarfile.open(bdir / f"rolled-back-{ts}.tgz", "w:gz") as out:
        for p in restore + drop:
            if os.path.lexists(p):
                out.add(p, arcname=p.lstrip("/"), recursive=False)
    done_drop = []
    for p in drop:
        if not _safe_target(p, roots):   # checked again right before the write
            unsafe.append(p)
            continue
        try:
            os.unlink(p)
            done_drop.append(p)
        except FileNotFoundError:
            pass
    done_restore = []
    with tarfile.open(bdir / "files.tgz", "r:gz") as tar:
        for p in restore:
            try:
                m = tar.getmember(p.lstrip("/"))
            except KeyError:
                continue
            if not _safe_target(p, roots):
                unsafe.append(p)
                continue
            _make_parents(p, tar, before)
            if os.path.isdir(p) and not os.path.islink(p):
                conflicts.append(p)   # a directory stands there now: left as it is
                continue
            # the old version is built next to the target, then renamed over it in one step:
            # a full disk or a kill leaves the current file whole, and a retry sees it unchanged
            tmp = ""
            try:
                if m.issym():
                    tmp = _fresh_name(os.path.dirname(p), lambda t: os.symlink(m.linkname, t))
                    if os.geteuid() == 0:
                        os.lchown(tmp, m.uid, m.gid)
                else:
                    src = tar.extractfile(m)
                    fds: list[int] = []
                    tmp = _fresh_name(os.path.dirname(p), lambda t: fds.append(
                        os.open(t, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)))
                    fd = fds[0]
                    with os.fdopen(fd, "wb") as dst:
                        shutil.copyfileobj(src, dst)
                        dst.flush()
                        os.fsync(dst.fileno())
                        if os.geteuid() == 0:
                            os.fchown(dst.fileno(), m.uid, m.gid)
                        os.fchmod(dst.fileno(), m.mode & 0o7777)
                    os.utime(tmp, (m.mtime, m.mtime), follow_symlinks=False)
                os.replace(tmp, p)
            except OSError:
                if tmp and os.path.lexists(tmp):
                    os.unlink(tmp)
                raise
            done_restore.append(p)
    with (bdir / f"rollback-{ts}.txt").open("w", encoding="utf-8") as fh:
        for tag, items in (("restored", done_restore), ("removed_added", done_drop), ("conflict_kept_newer", conflicts),
                           ("unsafe_path_skipped", unsafe), ("added_changed_since_kept", kept_new)):
            for p in items:
                fh.write(f"{tag} {p}\n")
    print(f"restored={len(done_restore)} removed_added={len(done_drop)} conflicts_kept={len(conflicts)} "
          f"unsafe_skipped={len(unsafe)} kept_changed_since={len(kept_new)} list=rollback-{ts}.txt")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) >= 4 and argv[1] == "manifest":
        return cmd_manifest(argv[2], argv[3], argv[4:])
    if len(argv) == 4 and argv[1] == "verify":
        return cmd_verify(argv[2], argv[3])
    if len(argv) == 3 and argv[1] == "check":
        return cmd_check(argv[2])
    if len(argv) == 3 and argv[1] == "rollback":
        return cmd_rollback(argv[2])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
