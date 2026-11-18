#!/usr/bin/env python3
"""PreToolUse gate «only after the owner's yes» (installed by neurootdel-install, #1920 b, g).

The channel agents run with --dangerously-skip-permissions, so no tool call ever asks anybody. This hook
holds the calls that change what belongs to the OWNER, or the agent's own rules, until the owner taps
«Allow» in Telegram:

  * other bots and services of the owner: Telegram Bot API settings calls (setWebhook, deleteWebhook,
    setMyCommands, logOut, ...), write calls to bot builders and CRMs (ChatPlace, Salebot, BotHelp, ...),
    MCP tools of other servers whose action is update/set/delete/disable/... ;
  * services: systemctl stop/disable/mask/restart/... (also --user), service X stop/restart,
    pm2 stop/delete/restart, docker stop/rm/restart/kill, docker compose down;
  * the schedule: crontab -r/-e/<file>/-, writes to /etc/cron*, /var/spool/cron;
  * the owner's files: rm/unlink/shred/rmdir/find -delete/mv-away outside the agent's work dirs
    (~/.claude-lab, /tmp, /var/tmp, ~/.cache, ~/work, ~/projects + OWNER_GATE_WORK_DIRS);
    edits of systemd units, /etc, prompt files of other bots;
  * the agent's own rules and switches: any CLAUDE.md under ~/.claude and ~/.claude-lab, settings*.json,
    ~/.claude/{hooks,rules,plugins,channels}/, ~/.claude.json, .mcp.json, azv/soul/, the plugin's .claude/,
    core/rules.md (appending a line stays free: that is how owner corrections are recorded);
  * root requests other than `restart` (allow-user, model, permissions, ...); typing into the agent's own
    tmux pane (tmux -L channel-* send-keys).

How the owner says yes: the hook POSTs the call to the dashi plugin's /hooks/permission/request
(127.0.0.1, port and bearer from the root-owned channel.env), the plugin sends the owner an Allow/Deny
card in Telegram and answers with his tap. Only the owner's own account can tap it
(TELEGRAM_PERMISSION_ALLOWED_USER_IDS); the agent cannot write a file, flag or message that counts as
a yes. allow = the call runs; deny, no tap in OWNER_GATE_TIMEOUT_SEC (default 170), plugin down, route
off, any error = blocked (exit 2) with an instruction to ask the owner in the chat and repeat.
Read, search and ordinary work (own workspace, /tmp, git, own bot through the plugin) never ask.

This is a seatbelt against the agent's own initiative, not a sandbox: obfuscated commands are out of scope.
Usage: owner-gate.py <agent>. Log: ~/.claude-lab/shared/state/<agent>/owner-gate/events.jsonl.
Stop (root only): touch <CONFIG_ROOT>/owner-gate.STOP, or remove the entry from the plugin settings.json.
guard.conf keys (optional): OWNER_GATE_TIMEOUT_SEC, OWNER_GATE_WORK_DIRS, OWNER_GATE_HOSTS (space-separated).
"""
from __future__ import annotations

import importlib.util
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

INIT_FAIL = ("BLOCKED by owner-gate: проверка не запустилась ({err}); пока её не починят, действия с ботами, "
             "сервисами и файлами владельца не выполняются. Спроси владельца и дождись его «да»; "
             "починка: переустановка или sudo neurootdel-verify.")
try:
    LIB = Path(__file__).resolve().parent.parent
    sys.path.insert(0, str(LIB))
    import guard_conf  # noqa: E402  (lives one level up, next to guard.conf)

    _spec = importlib.util.spec_from_file_location("block_dangerous",
                                                   Path(__file__).resolve().parent / "block-dangerous.py")
    if not _spec or not _spec.loader:
        raise ImportError("block-dangerous.py not found")
    bd = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(bd)

    CONF = guard_conf.load()
    RAW = guard_conf.read_raw()
    HOME = str(CONF.agent_home)
    LAB = f"{HOME}/.claude-lab"
except Exception as _e:  # noqa: BLE001 - fail closed: a hook that cannot start must not wave calls through
    if __name__ == "__main__":
        print(INIT_FAIL.format(err=f"{type(_e).__name__}: {_e}"[:200]), file=sys.stderr)
        sys.exit(2)
    raise
DEFAULT_WAIT_SEC = 170
MAX_WAIT_SEC = 185          # the installer registers the hook with timeout 200: we must answer first
HTTP_MARGIN_SEC = 5

# --- what is held ----------------------------------------------------------------------------
TG_METHODS = re.compile(
    r"/(setwebhook|deletewebhook|logout|close|setmy\w+|deletemy\w+|setchat\w+|deletechat\w+|"
    r"setmydefaultadministratorrights|promotechatmember|restrictchatmember|banchat\w+|unbanchat\w+|"
    r"leavechat|revokechatinvitelink|setbusiness\w+|deletebusiness\w+|setpassportdataerrors|"
    r"setgamescore|deletestickerset|unpinallchatmessages)\b", re.I)
SERVICE_HOSTS = [
    "chatplace.io", "salebot.pro", "bothelp.io", "smartsender", "puzzlebot", "leadteh.ru", "manychat.com",
    "sendpulse.com", "senler.ru", "aimylogic.com", "botmother", "amocrm.ru", "kommo.com", "bitrix24",
    "getcourse.ru", "unisender.com", "textback.ru", "wazzup24", "chatapp.online",
]
MUTATING_HTTP = re.compile(
    r"(-X\s*|--request[\s=]+)['\"]?(POST|PUT|PATCH|DELETE)\b|(^|\s)(-d|--data[\w-]*|-F|--form|--json|-T|--upload-file)(\s|=|$)"
    r"|\b(requests|httpx|session|client|axios)\.(post|put|patch|delete)\b|method\s*[:=]\s*['\"]?(POST|PUT|PATCH|DELETE)\b"
    r"|\bhttps?\s+(POST|PUT|PATCH|DELETE)\b", re.I)
ROOT_REQ = re.compile(r"-requests/requests/")
ROOT_REQ_GATED = re.compile(r"\b(allow-user|allow-chat|revoke-user|permissions|model|model-revert|cron-restore)\b")
TMUX_SEG = re.compile(r"\btmux\b[^\n;&|]*")
INTERPRETERS = {"python", "python3", "node", "bun", "perl", "ruby", "php", "deno"}
INLINE_WRITE = re.compile(
    r"write_text|write_bytes|\.write\(|open\([^)]*,\s*['\"][wax+]|unlink|os\.remove|rmtree|\.rename|os\.replace|"
    r"shutil\.(copy|move)|json\.dump\(|writeFile|appendFile|rmSync|fs\.rm|unlinkSync|renameSync|copyFile|"
    r"rmdirSync|fs\.rename|fs\.unlink|truncateSync", re.I)
INLINE_DELETE = re.compile(r"unlink|remove|rmtree|rmSync|rmdirSync|fs\.rm|renameSync|fs\.rename|os\.rename", re.I)
# copy/move calls with two literal paths: the SOURCE is only read (a move also removes it), the DEST is written
INLINE_COPY = re.compile(
    r"""(?:shutil\.(copy\w*|move)|\b(copyFileSync|copyFile|renameSync|cpSync|fs\.rename|fs\.cp|fs\.promises\.rename)"""
    r"""|os\.(rename|replace))"""
    r"""\(\s*[rfb]?(['"])([^'"\n]+)\4\s*,\s*[rfb]?(['"])([^'"\n]+)\6""")
INLINE_PATH = re.compile(
    r"CLAUDE(\.local)?\.md|settings(\.local)?\.json|\.claude/(hooks|rules|plugins|channels)/|core/rules\.md|"
    r"\.mcp\.json|\.claude\.json|azv/soul/|/etc/cron|/var/spool/cron|channel\.env|owner-gate")

SYSTEMCTL_GATED = {"stop", "disable", "mask", "restart", "try-restart", "reload-or-restart", "try-reload-or-restart",
                   "condrestart", "force-reload", "kill", "reload", "edit", "revert", "set-property", "isolate",
                   "poweroff", "reboot", "halt", "kexec", "link", "preset", "clean", "freeze", "enable",
                   "reenable", "unmask", "start"}
SYSTEMCTL_OPTS_WITH_ARG = {"-H", "-M", "--host", "--machine", "-p", "--property", "-t", "--type", "-s", "--signal",
                           "--state", "-n", "--lines", "-o", "--output", "--root", "--kill-whom", "--what", "--job-mode"}
SERVICE_GATED = {"stop", "restart", "reload", "force-reload", "try-restart", "condrestart"}
PM2_GATED = {"stop", "delete", "del", "restart", "reload", "kill", "flush", "reset", "start", "scale", "resurrect"}
DOCKER_GATED = {"stop", "rm", "restart", "kill", "down", "update", "pause", "rmi", "prune", "up", "run", "create",
                "start", "unpause"}
DELETE_CMDS = {"rm", "unlink", "shred", "rmdir", "srm", "trash", "trash-put", "gio"}
MCP_OWN_SERVERS = re.compile(r"^(dashi-channel|gbrain-[\w-]+|agent-jobs)$")
MCP_GATED_VERBS = {"update", "set", "delete", "remove", "disable", "enable", "configure", "edit", "patch", "toggle",
                   "trash", "archive", "unpublish", "deactivate", "activate", "reset", "revoke", "ban", "kick",
                   "rename", "replace", "overwrite", "destroy", "drop", "purge", "clear", "unsubscribe", "stop",
                   "pause", "restart"}


# a tool named get_*/list_*/search_* only reads, even when a later word looks like a verb (list_stop_words)
MCP_READ_VERBS = {"get", "list", "search", "read", "fetch", "find", "query", "describe", "show", "count", "check",
                  "download", "export", "view", "lookup", "preview", "validate", "status", "health"}


def _words(conf_key: str) -> list[str]:
    return [w for w in RAW.get(conf_key, "").split() if w]


# ~/.claude holds the agent's own auto-memory and plans; its rules/settings/hooks are caught before this list.
# CLAUDE_CONFIG_DIR (when the service sets one) is the agent's ~/.claude under another name.
CLAUDE_DIRS = list(dict.fromkeys([f"{HOME}/.claude"] + [os.path.normpath(d) for d in
                                                       [os.environ.get("CLAUDE_CONFIG_DIR", "")] if d.startswith("/")]))
HOME_WORK_ROOTS = [LAB, *CLAUDE_DIRS, f"{HOME}/.cache", f"{HOME}/work", f"{HOME}/projects", f"{HOME}/knowledge",
                   f"{HOME}/var"]
WORK_ROOTS = ["/tmp", "/var/tmp", "/dev/shm"] + _words("OWNER_GATE_WORK_DIRS")
ROOT_REQ_DIR = re.compile(r"^/var/lib/[\w.-]+-requests/requests(/|$)")
SERVICE_HOSTS += _words("OWNER_GATE_HOSTS")


def under(path: str, root: str) -> bool:
    root = root.rstrip("/") or "/"
    return path == root or path.startswith(root + "/")


def norm(path: str, cwd: str | None) -> str | None:
    """Absolute normalized path; None when a variable or substitution makes it unknown."""
    p = bd.HOME_VAR_RE.sub(HOME, path)
    if "$" in p or "`" in p or p.startswith("~") or not p:
        return None
    if not p.startswith("/"):
        if not cwd:
            return None
        p = os.path.join(cwd, p)
    return re.sub(r"/+", "/", os.path.normpath(p)) or "/"


def own_config_reason(p: str) -> str | None:
    """The agent's own rules, settings, hooks, prompts and channel config."""
    name = os.path.basename(p)
    if name in {"CLAUDE.md", "CLAUDE.local.md"} and (any(under(p, d) for d in CLAUDE_DIRS) or under(p, LAB)):
        return f"свои правила агента ({name})"
    if (re.search(r"/\.claude/settings(\.[\w-]+)?\.json$", p) and under(p, HOME)) \
            or any(re.fullmatch(rf"{re.escape(d)}/settings(\.[\w-]+)?\.json", p) for d in CLAUDE_DIRS):
        return "свои настройки и хуки агента (settings.json)"
    for d in CLAUDE_DIRS:
        for sub in ("hooks", "rules", "plugins", "channels"):
            if under(p, f"{d}/{sub}"):
                return f"свои {sub} агента (~/.claude/{sub})"
    if p == f"{HOME}/.claude.json" or any(p == f"{d}/.claude.json" for d in CLAUDE_DIRS) \
            or (name == ".mcp.json" and under(p, HOME)):
        return "подключения агента (MCP)"
    if re.match(rf"^{re.escape(LAB)}/[^/]+/\.claude/azv/soul(/|$)", p):
        return "промпт агента (azv/soul)"
    m = re.match(rf"^{re.escape(LAB)}/[^/]+/\.claude/(rules|hooks|\.claude)(/|$)", p)
    if m:
        return f"свои {m.group(1).lstrip('.')} агента (workspace)"
    if re.match(rf"^{re.escape(LAB)}/[^/]+/\.claude/core/rules\.md$", p):
        return "свои правила агента (core/rules.md)"
    if re.match(rf"^{re.escape(LAB)}/[^/]+/\.claude/dashi-plugin-claude-code/plugin/\.claude(/|$)", p):
        return "настройки своего канала (plugin/.claude)"
    if under(p, str(CONF.config_root)) or under(p, str(CONF.lib_dir)):
        return "конфиг канала и предохранителей"
    return None


def owner_config_reason(p: str) -> str | None:
    """Schedule, services and other bots' configs of the owner."""
    if p == "/etc/crontab" or re.match(r"^/etc/cron\.[\w]+(/|$)", p) or under(p, "/var/spool/cron"):
        return "расписание (cron)"
    if re.search(r"\.(service|timer|socket|path|mount)$", p) or under(p, "/etc/systemd") \
            or under(p, f"{HOME}/.config/systemd") or under(p, "/lib/systemd") or under(p, "/usr/lib/systemd"):
        return "службы (systemd)"
    if under(p, "/etc"):
        return "системные настройки (/etc)"
    if not in_work_dir(p) and \
            re.search(r"(^|[/_.-])(system[_-]?)?prompts?([_.-][^/]*)?\.(txt|md|ya?ml|json|j2)$", p, re.I):
        return "промпт другого бота"
    return None


def file_reason(p: str) -> str | None:
    return own_config_reason(p) or owner_config_reason(p)


def write_reason(p: str) -> str | None:
    """A write to p (or to what p links to): protected config, or an existing file of the owner outside the
    agent's work dirs. Creating a new file there stays free; /dev and /proc are not files."""
    try:
        real = os.path.realpath(p)
    except (OSError, ValueError):
        real = p
    for cand in dict.fromkeys((p, real)):
        r = file_reason(cand)
        if r:
            return r
    if any(under(x, d) for x in (p, real) for d in ("/dev", "/proc")) or in_work_dir(real) and in_work_dir(p):
        return None
    if os.path.lexists(p) and not os.path.isdir(real):
        return f"файлы владельца вне рабочей папки ({p})"
    return None


def protected_paths() -> list[str]:
    """Existing protected files/dirs, so removing or moving a PARENT of one is caught too."""
    out = [f"{HOME}/.claude.json", str(CONF.config_root), str(CONF.lib_dir)]
    for d in CLAUDE_DIRS:
        out += [f"{d}/{x}" for x in ("CLAUDE.md", "settings.json", "settings.local.json", "hooks", "rules",
                                     "plugins", "channels", ".claude.json")]
    try:
        agents = [e.path for e in os.scandir(LAB) if e.is_dir()]
    except OSError:
        agents = []
    for a in agents:
        out += [f"{a}/.claude/{x}" for x in ("CLAUDE.md", "core/rules.md", "azv/soul", "rules", "hooks", ".claude",
                                            "dashi-plugin-claude-code/plugin/.claude")]
    return [x for x in out if os.path.lexists(x)]


TREE_SCAN_LIMIT = 50000
# never hold rules or settings the agent loads; skipped so a big build tree does not exhaust the scan
TREE_SKIP_DIRS = {"node_modules", ".git", ".venv", "venv", "__pycache__", ".cache", "dist", "build", ".next"}


def scan_tree(root: str, writing: bool) -> str | None:
    """Walk an existing dir that a recursive copy/remove/move touches. Held: a protected file anywhere below
    (also a nested CLAUDE.md); for a write also a link whose real target is protected or outside the work
    dirs. An incomplete walk (too big, unreadable) is held too: unchecked is not allowed."""
    errors: list[OSError] = []
    seen = 0
    for cur, dirs, files in os.walk(root, onerror=errors.append):
        dirs[:] = [d for d in dirs if d not in TREE_SKIP_DIRS]
        for name in dirs + files:
            seen += 1
            path = os.path.join(cur, name)
            r = file_reason(path)
            if r:
                return f"каталог, в котором {r}"
            if writing and os.path.islink(path):
                real = os.path.realpath(path)
                r = file_reason(real)
                if r:
                    return f"каталог со ссылкой на {r}"
                if not in_work_dir(real) and os.path.exists(real):
                    return f"каталог со ссылкой на папку владельца вне рабочей папки ({real})"
        if seen > TREE_SCAN_LIMIT:
            return f"каталог слишком большой для проверки ({root})"
    if errors:
        return f"каталог не удалось проверить целиком ({root})"
    return None


def tree_write_reason(land: str) -> str | None:
    """A tree copied into `land` may overwrite anything inside it: protected files anywhere below
    (also a nested CLAUDE.md), or, outside the agent's work dirs, the owner's existing files."""
    for prot in protected_paths():
        if under(prot, land):
            return f"запись поверх каталога, в котором {file_reason(prot) or 'свои настройки'}"
    real = os.path.realpath(land)
    r = file_reason(land) or file_reason(real)
    if r:
        return f"запись в {r}"
    if not os.path.isdir(real):
        return write_reason(land)
    if not in_work_dir(land) or not in_work_dir(real):
        return f"запись поверх папки владельца вне рабочей папки ({real})"
    r = scan_tree(real, writing=True)
    return f"запись поверх: {r}" if r else None


def delete_reason(p: str) -> str | None:
    r = file_reason(p) or file_reason(bd.via_links(p))
    if r:
        return f"удаление: {r}"
    for prot in protected_paths():
        if under(prot, p) or under(prot, bd.via_links(p)):
            r = file_reason(prot) or "свои правила и настройки агента"
            return f"удаление каталога, в котором {r}"
    if not in_work_dir(p):
        return f"удаление файлов владельца вне рабочей папки ({p})"
    # a nested CLAUDE.md / settings in a dir of HOME (the only place the agent loads them from)
    if under(p, HOME) and os.path.isdir(p) and not os.path.islink(p):
        r = scan_tree(p, writing=False)
        if r:
            return f"удаление: {r}"
    return None


def in_work_dir(p: str) -> bool:
    """The agent's own work area. Inside HOME only its own dirs count (HOME may itself sit under /tmp)."""
    if ROOT_REQ_DIR.match(p):
        return True
    extra = _words("OWNER_GATE_WORK_DIRS")
    if under(p, HOME):
        return any(under(p, r) for r in HOME_WORK_ROOTS + extra)
    return any(under(p, r) for r in WORK_ROOTS)


def rules_append_only(p: str) -> bool:
    return bool(re.match(rf"^{re.escape(LAB)}/[^/]+/\.claude/core/rules\.md$", p))


# --- Bash -------------------------------------------------------------------------------------
def split_redirs(words: list[str]) -> tuple[list[str], list[tuple[str, str]]]:
    """Words without redirections, and the (operator, target) pairs of output redirections."""
    out: list[str] = []
    redirs: list[tuple[str, str]] = []
    k = 0
    while k < len(words):
        w = words[k]
        if any(ch.isspace() for ch in w):
            out.append(w)
            k += 1
            continue
        cut = min((w.find(c) for c in "<>" if c in w), default=-1)
        if cut > 0 and not re.fullmatch(r"\d+|&", w[:cut]):
            out.append(w[:cut])
            w = w[cut:]
        m = bd.REDIR_RE.fullmatch(w)
        if m:
            op, target = m.group(1), m.group(2)
            if not target and k + 1 < len(words):
                target = words[k + 1]
                k += 1
            if ">" in op and "&" not in op.replace("&>", ""):
                redirs.append((op, target))
            elif op.startswith("&>"):
                redirs.append((op, target))
            k += 1
            continue
        out.append(w)
        k += 1
    return out, redirs


def first_verb(args: list[str], with_arg: set[str]) -> tuple[str, list[str]]:
    k = 0
    while k < len(args):
        a = args[k]
        if a == "--":
            k += 1
            break
        if a.startswith("-") and a != "-":
            k += 2 if a in with_arg else 1
            continue
        break
    return (args[k], args[k + 1:]) if k < len(args) else ("", [])


def non_options(args: list[str]) -> list[str]:
    out, done = [], False
    for a in args:
        if not done and a == "--":
            done = True
        elif not done and a.startswith("-") and a != "-":
            continue
        else:
            out.append(a)
    return out


def simple_reason(words: list[str], cwd: str | None) -> str | None:
    words, redirs = split_redirs(words)
    for op, target in redirs:
        p = norm(target, cwd)
        if p is None:
            continue
        if ">>" in op and rules_append_only(p):
            continue
        r = write_reason(p)
        if r:
            return f"запись в {r}"
    cmd, args, chdir = bd.command_words(words)
    if chdir:
        cwd = norm(chdir, cwd) or cwd
    base = os.path.basename(cmd)
    if base == "systemctl":
        verb, units = first_verb(args, SYSTEMCTL_OPTS_WITH_ARG)
        if verb in SYSTEMCTL_GATED:
            return f"systemctl {verb} {' '.join(non_options(units))}".strip()
    elif base == "service":
        rest = non_options(args)
        if len(rest) >= 2 and rest[1] in SERVICE_GATED:
            return f"service {rest[0]} {rest[1]}"
    elif base == "pm2":
        verb, _ = first_verb(args, set())
        if verb in PM2_GATED:
            return f"pm2 {verb}"
    elif base in {"docker", "docker-compose", "podman"}:
        rest = non_options(args)
        verbs = [v for v in rest[:3] if v in DOCKER_GATED]
        if verbs:
            return f"{base} {verbs[0]}"
    elif base == "crontab":
        verb_args = [a for a in args]
        skip_next = False
        files: list[str] = []
        flags: set[str] = set()
        for a in verb_args:
            if skip_next:
                skip_next = False
                continue
            if a == "-u":
                skip_next = True
            elif a.startswith("-") and a != "-":
                flags.update(a[1:])
            else:
                files.append(a)
        if flags & {"r", "e"} or files:
            return "изменение расписания (crontab)"
    elif base in DELETE_CMDS or (base == "find" and "-delete" in args):
        targets = non_options(args)
        if base == "find":
            targets = []
            for a in args:
                if a.startswith("-") or a in {"(", ")", "!"}:
                    break
                targets.append(a)
        if base == "gio":
            if not args or args[0] not in {"trash", "remove"}:
                return None
            targets = non_options(args[1:])
        for t in targets:
            for cand in bd.expand_braces(t):
                p = norm(cand, cwd)
                if p is None:
                    continue
                if any(c in bd.GLOB_CHARS for c in p):
                    p = os.path.dirname(re.split(r"[*?\[]", p, maxsplit=1)[0] + "x")
                r = delete_reason(p)
                if r:
                    return r
    elif base in {"curl", "wget"}:
        outs = {"curl": ("-o", "--output"), "wget": ("-O", "--output-document")}[base]
        for k, a in enumerate(args):
            t = None
            if a in outs and k + 1 < len(args):
                t = args[k + 1]
            elif a.startswith(outs[1] + "="):
                t = a.split("=", 1)[1]
            elif a.startswith(outs[0]) and len(a) > 2 and not a.startswith("--"):
                t = a[2:]
            p = norm(t, cwd) if t and t != "-" else None
            r = write_reason(p) if p else None
            if r:
                return f"загрузка в {r}"
    elif base in {"mv", "cp", "install", "ln", "rsync", "tee", "sed", "perl", "truncate", "chmod", "chown",
                  "chattr", "touch", "dd", "patch"}:
        ops = non_options(args)
        targets: list[tuple[str, bool]] = []   # (path, append?)
        if base == "tee":
            append = any(a in {"-a", "--append"} for a in args)
            targets = [(t, append) for t in ops]
        elif base in {"sed", "perl"}:
            if not any(a.startswith("-i") or a.startswith("--in-place") or re.fullmatch(r"-[a-zA-Z]*i[a-zA-Z]*", a)
                       for a in args):
                return None
            has_script_opt = any(a in {"-e", "--expression", "-f", "--file"} for a in args)
            targets = [(t, False) for t in (ops if has_script_opt else ops[1:])]
        elif base == "dd":
            targets = [(a[3:], False) for a in args if a.startswith("of=")]
        elif base in {"mv", "cp", "install", "ln", "rsync"}:
            tdir = None
            for k, a in enumerate(args):
                if a in {"-t", "--target-directory"} and k + 1 < len(args):
                    tdir = args[k + 1]
                elif a.startswith("--target-directory="):
                    tdir = a.split("=", 1)[1]
                elif re.fullmatch(r"-[a-zA-Z]*t.+", a) and base != "rsync":
                    tdir = a[a.index("t") + 1:]
            if tdir is not None:
                ops = [o for o in ops if o != tdir] + [tdir.rstrip("/") + "/"]
            if ops:
                dest = ops[-1]
                targets.append((dest, False))
                pd = norm(dest, cwd)
                no_target_dir = any(a in {"-T", "--no-target-directory"} or re.fullmatch(r"-[a-zA-Z]*T[a-zA-Z]*", a)
                                    for a in args) and base != "rsync"
                into_dir = pd is not None and not no_target_dir and (dest.endswith("/") or os.path.isdir(pd))
                if into_dir:
                    for src in ops[:-1]:
                        targets.append((os.path.join(pd, os.path.basename(src.rstrip("/"))), False))
                recursive = base in {"rsync", "mv"} or any(
                    a in {"--recursive", "--archive"} or re.fullmatch(r"-[a-zA-Z]*[rRa][a-zA-Z]*", a) for a in args)
                if recursive and pd is not None:
                    # a tree copied into dest overwrites whatever protected files lie inside the landing dir
                    lands = [pd] if not into_dir else [
                        pd if base == "rsync" or src.endswith(("/", "/.")) else
                        os.path.join(pd, os.path.basename(src.rstrip("/"))) for src in ops[:-1]]
                    for land in lands:
                        r = tree_write_reason(land)
                        if r:
                            return r
                if base == "mv":
                    for src in ops[:-1]:
                        p = norm(src, cwd)
                        if p is not None:
                            r = delete_reason(p)
                            if r:
                                return r.replace("удаление", "перенос")
        elif base in {"chmod", "chown", "chattr"}:
            targets = [(t, False) for t in ops[1:]]
        else:
            targets = [(t, False) for t in ops]
        for t, append in targets:
            p = norm(t, cwd)
            if p is None:
                continue
            if append and rules_append_only(p):
                continue
            r = write_reason(p)
            if r:
                return f"запись в {r}"
    elif (base in bd.SHELL_NAMES or base == "su"):
        idx = next((k for k, a in enumerate(args) if re.fullmatch(r"-[a-zA-Z]*c[a-zA-Z]*", a)), None)
        if idx is not None and idx + 1 < len(args):
            return bash_reason(args[idx + 1], cwd, depth=1)
    return None


# a path literal: absolute, ~/..., or relative with a dir or an extension (config.py, bots/x); not 'utf-8'
_PATH_BODY = r"(?:/|~/)[^'\"\n]*|[\w.-]*/[\w./-]+|[\w-][\w.-]*\.[A-Za-z0-9]{1,8}"
PATH_LIT = re.compile(r"""[rfb]?(['"])(""" + _PATH_BODY + r""")\1""")
PATH_ASSIGN = re.compile(r"""\b(\w+)\s*=\s*(?:Path\()?\s*[rfb]?(['"])(""" + _PATH_BODY + r""")\2""")


def _var_written(v: str, code: str) -> bool:
    v = re.escape(v)
    return bool(re.search(
        rf"\b{v}\s*\.\s*(write_text|write_bytes|unlink|rename|replace|rmdir|open\([^)]*['\"][wax+])"
        rf"|open\(\s*{v}\s*,\s*['\"][wax+]|os\.(remove|replace|rename|unlink)\([^)]*\b{v}\b"
        # copy: only the destination (2nd arg) is written; move/rmtree: either side changes
        rf"|shutil\.(copy\w*)\([^,)]*,\s*{v}\b|shutil\.(move|rmtree)\([^)]*\b{v}\b"
        rf"|(copyFileSync|copyFile|cpSync)\([^,)]*,\s*{v}\b"
        rf"|(writeFileSync|writeFile|appendFileSync|rmSync|unlinkSync|renameSync|truncateSync)\(\s*{v}\b", code))


def inline_reason(code: str, cwd: str | None) -> str | None:
    """Inline code (python -c, heredoc, node -e) writes a protected path or an existing file of the owner:
    the path literal on the same line as the write, or in a variable that is written."""
    for line in code.splitlines():
        for m in INLINE_COPY.finditer(line):
            moving = bool(re.search(r"move|rename|replace", m.group(0)))
            dst, src = norm(m.group(7), cwd), norm(m.group(5), cwd)
            if dst and re.search(r"copytree|cpSync|fs\.cp", m.group(0)):
                r = tree_write_reason(dst)     # a tree lands INTO dst (dirs_exist_ok / recursive)
                if r:
                    return f"скрипт: {r}"
            r = write_reason(dst) if dst else None
            if not r and dst and os.path.isdir(dst) and src:
                r = write_reason(os.path.join(dst, os.path.basename(src)))
            if not r and moving and src:
                r = delete_reason(src)
            if r:
                return f"скрипт: {r}"
        line = INLINE_COPY.sub("", line)
        if INLINE_PATH.search(line) and INLINE_WRITE.search(line):
            return "скрипт пишет в правила/настройки/расписание агента"
        if INLINE_WRITE.search(line):
            for m in PATH_LIT.finditer(line):
                p = norm(m.group(2), cwd)
                r = (write_reason(p) or (delete_reason(p) if INLINE_DELETE.search(line) else None)) if p else None
                if r:
                    return f"скрипт: {r}"
    for m in PATH_ASSIGN.finditer(code):
        if not _var_written(m.group(1), code):
            continue
        p = norm(m.group(3), cwd)
        # a dir held in a variable that is written to: whatever lands inside it is unknown, check the tree
        r = (tree_write_reason(p) if os.path.isdir(p) else write_reason(p)) if p else None
        if r or (INLINE_PATH.search(m.group(3))):
            return f"скрипт: {r or 'пишет в правила/настройки агента'}"
    return None


def bash_reason(cmd: str, cwd: str | None, depth: int = 0) -> str | None:
    if depth > 3:
        return None
    low = cmd.lower()
    if "api.telegram.org" in low and TG_METHODS.search(cmd):
        m = TG_METHODS.search(cmd)
        return f"настройки Telegram-бота через Bot API ({m.group(1) if m else ''})"
    if MUTATING_HTTP.search(cmd):
        host = next((h for h in SERVICE_HOSTS if re.search(r"(://|\.)" + re.escape(h.lower()), low)), None)
        if host:
            return f"изменение в сервисе владельца ({host})"
    if ROOT_REQ.search(cmd) and ROOT_REQ_GATED.search(cmd):
        return f"заявка root «{ROOT_REQ_GATED.search(cmd).group(1)}»"
    if any("send-keys" in m.group(0) and "channel-" in m.group(0) for m in TMUX_SEG.finditer(cmd)):
        return "ввод в собственную сессию агента (tmux send-keys)"
    tokens = bd.split_tokens(cmd)
    if tokens is None:
        tokens = cmd.split()
    names = {os.path.basename(t) for t in tokens}
    i, n = 0, len(tokens)
    cur = cwd
    while i < n:
        j = i
        while j < n and tokens[j] not in bd.SEPARATORS:
            j += 1
        seg = tokens[i:j]
        if seg:
            c, a, _ = bd.command_words(bd.drop_redirections(seg))
            if os.path.basename(c) == "cd":
                dest = next((x for x in a if not x.startswith("-")), HOME)
                cur = norm(dest, cur) or cur
            elif os.path.basename(c) in INTERPRETERS:
                # each interpreter run is checked in the directory reached by the cd's before it
                r = inline_reason(cmd, cur)
                if r:
                    return r
                r = simple_reason(seg, cur)
                if r:
                    return r
            else:
                r = simple_reason(seg, cur)
                if r:
                    return r
        i = j + 1
    return None


# --- Edit / Write / MCP -----------------------------------------------------------------------
def file_tool_reason(tool: str, ti: dict, cwd: str | None) -> str | None:
    raw = ti.get("file_path") or ti.get("notebook_path") or ti.get("path") or ""
    if not isinstance(raw, str) or not raw:
        return None
    p = norm(raw, cwd)
    if p is None:
        return None
    r = write_reason(p)
    if not r:
        return None
    try:
        real = os.path.realpath(p)
    except (OSError, ValueError):
        real = p
    if rules_append_only(real) and appends_only(tool, ti, real):
        return None
    return f"правка: {r}"


def appends_only(tool: str, ti: dict, p: str) -> bool:
    """The change only adds text at the END of the file (how an owner correction is recorded)."""
    try:
        existing = Path(p).read_text(encoding="utf-8")
    except FileNotFoundError:
        existing = ""
    except (OSError, UnicodeDecodeError):
        return False
    if tool == "Write":
        after = ti.get("content")
        if not isinstance(after, str):
            return False
    elif tool in {"Edit", "MultiEdit"}:
        edits = [ti] if tool == "Edit" else ti.get("edits")
        if not isinstance(edits, list) or not edits:
            return False
        after = existing
        for e in edits:
            if not isinstance(e, dict):
                return False
            old, new = e.get("old_string"), e.get("new_string")
            if not isinstance(old, str) or not isinstance(new, str) or not old or e.get("replace_all") \
                    or after.count(old) != 1:
                return False
            after = after.replace(old, new, 1)
    else:
        return False
    # the old text stays a prefix and the addition starts on a new line (no tail glued to the last rule)
    return after.startswith(existing) and (existing == "" or existing.endswith("\n")
                                           or after[len(existing):].startswith("\n") or after == existing)


def mcp_reason(tool: str) -> str | None:
    parts = tool.split("__")
    if len(parts) < 3:
        return None
    server, action = parts[1], parts[-1]
    if MCP_OWN_SERVERS.match(server) or server in _words("OWNER_GATE_MCP_ALLOW"):
        return None
    words = [w for w in re.split(r"[_\W]+", re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", action).lower()) if w]
    if not words or words[0] in MCP_READ_VERBS:
        return None
    if any(w in MCP_GATED_VERBS for w in words):
        return f"изменение в сервисе владельца ({server}: {action})"
    return None


def classify(payload: dict) -> str | None:
    tool = payload.get("tool_name")
    ti = payload.get("tool_input")
    if not isinstance(tool, str) or not isinstance(ti, dict):
        return None
    cwd = payload.get("cwd")
    cwd = cwd if isinstance(cwd, str) and cwd.startswith("/") else None
    if tool == "Bash":
        cmd = ti.get("command")
        return bash_reason(cmd, cwd) if isinstance(cmd, str) and cmd else None
    if tool in {"Edit", "Write", "MultiEdit", "NotebookEdit"}:
        return file_tool_reason(tool, ti, cwd)
    if tool.startswith("mcp__"):
        return mcp_reason(tool)
    return None


# --- asking the owner -------------------------------------------------------------------------
SECRET_RES = [
    (re.compile(r"(?<!\d)(\d{5,}):[A-Za-z0-9_-]{20,}"), r"\1:***"),
    (re.compile(r"(?i)(bearer\s+|basic\s+)[^\s'\"]+"), r"\1***"),
    (re.compile(r"(?i)((?:^|\s)(?:-u|--user|--proxy-user)(?:\s+|=)['\"]?)[^\s'\"]+"), r"\1***"),
    (re.compile(r"((?:^|\s)['\"]?-u)(?![\s='\"])[^\s'\"]+"), r"\1***"),
    (re.compile(r"(?i)(://[^/\s:@'\"]+:)[^@\s/'\"]+@"), r"\1***@"),
    (re.compile(r"(?i)((?:api[_-]?key|token|secret|password|passwd|authorization)[\"']?\s*[:=]\s*[\"']?)[^\s\"'&]+"), r"\1***"),
    (re.compile(r"\b(sk|pk|rk|ghp|gho|xox[bp])[-_][A-Za-z0-9_-]{12,}"), r"\1-***"),
]


def redact(text: str) -> str:
    for rx, rep in SECRET_RES:
        text = rx.sub(rep, text)
    return text


def preview(tool: str, ti: dict) -> str:
    if tool == "Bash":
        s = str(ti.get("command") or "")
    elif tool.startswith("mcp__"):
        s = json.dumps(ti, ensure_ascii=False)
    else:
        s = str(ti.get("file_path") or ti.get("notebook_path") or "")
        change = ti.get("new_string") if tool == "Edit" else ti.get("content")
        if isinstance(change, str) and change:
            s += "\n---\n" + change
    return redact(s)[:1500]


def channel_env(agent: str) -> dict[str, str]:
    out: dict[str, str] = {}
    with CONF.channel_env(agent).open(encoding="utf-8") as fh:
        for line in fh:
            m = re.match(r"^([A-Z_][A-Z0-9_]*)=\"?([^\"\n]*)\"?\s*$", line)
            if m:
                out[m.group(1)] = m.group(2)
    return out


def wait_sec() -> int:
    try:
        v = int(RAW.get("OWNER_GATE_TIMEOUT_SEC", "") or DEFAULT_WAIT_SEC)
    except ValueError:
        v = DEFAULT_WAIT_SEC
    return max(1, min(v, MAX_WAIT_SEC))


def ask_owner(agent: str, payload: dict, reason: str) -> tuple[str, str]:
    """Returns (status, detail): status allow | deny | timeout | unavailable."""
    try:
        env = channel_env(agent)
    except OSError:
        return "unavailable", "нет channel.env"
    port, token = env.get("TELEGRAM_WEBHOOK_PORT", ""), env.get("TELEGRAM_WEBHOOK_TOKEN", "")
    if not re.fullmatch(r"\d{2,5}", port) or not token:
        return "unavailable", "в channel.env нет порта или ключа вебхука"
    wait = wait_sec()
    tool = str(payload.get("tool_name") or "")
    ti = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
    body = json.dumps({
        "session_id": str(payload.get("session_id") or "")[:256],
        "tool_use_id": str(payload.get("tool_use_id") or "")[:256],
        "tool_name": tool[:256] or "tool",
        "preview": preview(tool, ti),
        "reason": f"Агент просит разрешения: {reason}"[:1000],
        "timeout_ms": wait * 1000,
    }, ensure_ascii=False).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{port}/hooks/permission/request", data=body, method="POST",
                                 headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=wait + HTTP_MARGIN_SEC) as resp:
            data = json.loads(resp.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as e:
        return "unavailable", f"плагин ответил HTTP {e.code}"
    except (urllib.error.URLError, OSError, TimeoutError):
        return "unavailable", "плагин канала не ответил"
    except ValueError:
        return "unavailable", "непонятный ответ плагина"
    status = data.get("status") if isinstance(data, dict) else None
    if status == "allow":
        return "allow", ""
    if status == "timeout":
        return "timeout", f"владелец не ответил за {wait // 60 or 1} мин"
    if status == "deny":
        return "deny", "владелец нажал «Deny»"
    return "unavailable", "непонятный ответ плагина"


def log_event(agent: str, event: dict) -> None:
    try:
        d = CONF.lab / "shared" / "state" / agent / "owner-gate"
        d.mkdir(parents=True, exist_ok=True)
        with (d / "events.jsonl").open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), **event},
                                ensure_ascii=False) + "\n")
    except OSError:
        pass


def block(text: str) -> int:
    print(text, file=sys.stderr)
    return 2


def main() -> int:
    agent = sys.argv[1] if len(sys.argv) > 1 and re.fullmatch(r"[a-z0-9-]+", sys.argv[1]) else CONF.main_agent
    if (CONF.config_root / "owner-gate.STOP").exists():
        return 0
    try:
        payload = json.loads(sys.stdin.read())
    except (ValueError, UnicodeDecodeError):
        return block("BLOCKED by owner-gate: не удалось прочитать вызов инструмента.")
    if not isinstance(payload, dict):
        return block("BLOCKED by owner-gate: не удалось прочитать вызов инструмента.")
    reason = classify(payload)
    if not reason:
        return 0
    status, detail = ask_owner(agent, payload, reason)
    tool = str(payload.get("tool_name") or "")
    log_event(agent, {"tool": tool, "reason": redact(reason), "status": status, "detail": detail})
    if status == "allow":
        return 0
    if status == "unavailable":
        how = (f"Кнопку владельцу отправить не удалось ({detail}). Опиши ему в чате, что и зачем хочешь "
               "изменить (было -> станет), и предложи сделать это ему самому или включить кнопку подтверждения.")
    else:
        how = (f"Кнопка подтверждения ушла владельцу, {detail}. Напиши ему в чате, что и зачем хочешь изменить "
               "(было -> станет), дождись его «да» и повтори ту же команду: придёт новая кнопка «Allow».")
    return block(
        f"BLOCKED by owner-gate: {reason}.\n"
        "Это меняет ботов, сервисы, расписание, файлы владельца или твои собственные правила и настройки: "
        "только после его явного «да». Остановись и спроси владельца, дождись его «да».\n"
        f"{how}\n"
        "Разрешение даёт только нажатие владельца в Telegram; не обходи проверку другой командой или файлом.")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception:  # noqa: BLE001 - fail closed: an unreadable call must not run unasked
        print("BLOCKED by owner-gate: внутренняя ошибка проверки; спроси владельца и дождись его «да».",
              file=sys.stderr)
        sys.exit(2)
