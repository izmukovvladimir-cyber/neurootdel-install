#!/usr/bin/env python3
"""PreToolUse (Bash) guard of the agents (installed by neurootdel-install).

Exit 2 + stderr = the command is blocked and the reason goes back to the agent. Exit 0 = allowed.
A recursive rm is blocked only when a target can hit a system root, the
home dir, an agent's dir/memory/plugin/skills, the knowledge base or the backups, or is "$VAR/..."
without a ${VAR:?} guard. Scratch cleanup (rm -rf /tmp/..., rm -rf "$S") stays allowed: the
agents do it several times a day and a blanket block would stall them.
This is a seatbelt against mistakes, not a sandbox: obfuscated commands are out of scope.
Stop: delete the PreToolUse "Bash" entry pointing here from the agent's settings.json.
"""
import fnmatch
import json
import os
import re
import shlex
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import guard_conf  # noqa: E402  (lives one level up, next to guard.conf)

_CONF = guard_conf.load()
HOME = str(_CONF.agent_home)
LAB = f"{HOME}/.claude-lab"

# Whole-command patterns (rm and git are handled on tokens below).
PATTERNS = [
    r"drop\s+table",
    r"drop\s+database",
    r"truncate\s+table",
    r"\b(curl|wget)\b[^|]*\|\s*(sudo\s+(-\S+\s+)*)?(\S*/)?(ba|z|da|k)?sh\b",
    r"mkfs\.",
    r"\bdd\s+[^|;&]*of=/dev/",
    r">\s*/dev/sd[a-z]",
    r"(^|[\s;|&])[a-z][a-z0-9_-]*\s+auth\s+login",
]
FORK_BOMB = ":(){"

# A recursive rm whose target is this dir or an ANCESTOR of it is blocked.
ANCESTOR_PROTECTED = [
    "/", "/bin", "/boot", "/etc", "/lib", "/lib64", "/opt", "/root", "/sbin", "/srv", "/usr",
    "/var", "/var/lib", "/home", "/tmp", HOME, LAB, f"{HOME}/.claude", f"{HOME}/.claude/projects",
    f"{HOME}/knowledge", f"{HOME}/backups", f"{HOME}/.ssh", f"{HOME}/.bun", f"{LAB}/shared",
]
# A target equal to one of these is an ancestor of agent memory (LAB/<agent>, LAB/<agent>/.claude,
# ~/.claude/projects/<project>).
ANCESTOR_PROTECTED_RE = [
    re.compile(rf"^{re.escape(LAB)}/[^/]+(/\.claude)?$"),
    re.compile(rf"^{re.escape(HOME)}/\.claude/projects/[^/]+$"),
]
# A recursive rm whose target is this dir or anything INSIDE it is blocked.
INSIDE_PROTECTED_RE = [
    re.compile(rf"^{re.escape(LAB)}/[^/]+/\.claude/(core|memory|skills|dashi-plugin-claude-code)(/|$)"),
    re.compile(rf"^{re.escape(LAB)}/[^/]+/\.claude/CLAUDE\.md$"),
    re.compile(rf"^{re.escape(HOME)}/\.claude/projects/[^/]+/memory(/|$)"),
    re.compile(rf"^{re.escape(HOME)}/(knowledge|backups|\.ssh)(/|$)"),
    re.compile(r"^/(etc|opt|usr|boot|root|bin|sbin|lib|lib64)(/|$)"),
]
SEPARATORS = {";", "&&", "||", "|", "&", "(", ")", ";;", "|&"}
RM_NAMES = {"rm", "/bin/rm", "/usr/bin/rm"}
GIT_NAMES = {"git", "/usr/bin/git"}
SHELL_NAMES = {"bash", "sh", "zsh", "dash", "/bin/bash", "/bin/sh", "/usr/bin/bash", "/usr/bin/zsh"}
# Wrappers after which the next word is still in command position, with the options that take
# a separate argument (sudo -u root rm ..., nice -n 5 rm ..., xargs -I {} rm ...).
WRAPPER_OPTS_WITH_ARG = {
    "sudo": {"-u", "-g", "-C", "-h", "-p", "-r", "-t", "-U", "-D", "-T", "--user", "--group", "--host",
             "--prompt", "--role", "--type", "--other-user", "--chdir", "--close-from", "--command-timeout"},
    "doas": {"-u", "-C"},
    "env": {"-u", "-C", "-S", "--unset", "--chdir", "--split-string"},
    "nice": {"-n", "--adjustment"},
    "xargs": {"-I", "-L", "-P", "-d", "-a", "-n", "-s", "-E", "--arg-file", "--delimiter", "--max-args",
              "--max-procs", "--replace", "--max-lines", "--max-chars", "--eof"},
    "time": {"-f", "-o", "--format", "--output"},
    "exec": {"-a"},
    "nohup": set(), "command": set(),
}
CHDIR_OPTS = {"env": {"-C", "--chdir"}, "sudo": {"-D", "--chdir"}}
KEYWORDS = {"then", "do", "else", "elif", "if", "while", "until", "!", "{", "}", "time"}
GIT_OPTS_WITH_ARG = {"-C", "-c", "--git-dir", "--work-tree", "--namespace"}
ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
REDIR_RE = re.compile(r"(\d*(?:>>?|<<?<?|>&|<&|&>>?|>\|))(.*)")
GLOB_CHARS = set("*?[")
UNSAFE_VAR_RE = re.compile(r"^\$(\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*)/")
HOME_VAR_RE = re.compile(r"^(\$HOME|\$\{HOME\}|~)(?=/|$)")
RISKY_RELATIVE = {".", "..", "*", "./*", "../*", ".*"}
GLOB_PARENTS_ALL_PROTECTED = {LAB, f"{HOME}/.claude/projects"}  # every child holds agent memory


def norm(path: str, cwd: str | None) -> str | None:
    """Absolute normalized path, or None when it cannot be known statically."""
    path = HOME_VAR_RE.sub(HOME, path)
    if "$" in path or "`" in path or path.startswith("~"):
        return None
    if not path.startswith("/"):
        if not cwd:
            return None
        path = os.path.join(cwd, path)
    return re.sub(r"/+", "/", os.path.normpath(path)) or "/"


def via_links(path: str) -> str:
    """Same path with symlinks in its PARENT resolved (removing a link itself stays the link)."""
    parent, name = os.path.split(path)
    try:
        real_parent = os.path.realpath(parent or "/")
    except (OSError, ValueError):
        return path
    return re.sub(r"/+", "/", os.path.join(real_parent, name)) if name else real_parent


def is_ancestor_or_equal(target: str, protected: str) -> bool:
    if target == "/":
        return True
    return protected == target or protected.startswith(target + "/")


def plain_path_reason(raw: str, path: str) -> str | None:
    for p in ANCESTOR_PROTECTED:
        if is_ancestor_or_equal(path, p):
            return f"'{raw}' covers protected '{p}'"
    for rx in ANCESTOR_PROTECTED_RE:
        if rx.match(path):
            return f"'{raw}' holds agent memory"
    for rx in INSIDE_PROTECTED_RE:
        if rx.match(path):
            return f"'{raw}' is inside agent memory / system files"
    return None


def glob_reason(raw: str, path: str) -> str | None:
    """A glob removes CHILDREN of its parent dir that match the first wildcard component."""
    head = re.split(r"[*?\[]", path, maxsplit=1)[0]
    parent = head.rstrip("/") if head.endswith("/") else os.path.dirname(head)
    parent = parent or "/"
    rest = path[len(parent):].lstrip("/") if parent != "/" else path.lstrip("/")
    comp = rest.split("/", 1)[0] or "*"
    if parent in GLOB_PARENTS_ALL_PROTECTED:
        return f"'{raw}' matches agent dirs in '{parent}'"
    for rx in INSIDE_PROTECTED_RE + ANCESTOR_PROTECTED_RE:
        if rx.match(parent):
            return f"'{raw}' is inside agent memory / system files"
    candidates = list(ANCESTOR_PROTECTED)
    if re.fullmatch(rf"{re.escape(LAB)}/[^/]+", parent):
        candidates.append(f"{parent}/.claude")
    if re.fullmatch(rf"{re.escape(LAB)}/[^/]+/\.claude", parent):
        candidates += [f"{parent}/{d}" for d in ("core", "memory", "skills", "dashi-plugin-claude-code", "CLAUDE.md")]
    prefix = "/" if parent == "/" else parent + "/"
    for p in candidates:
        if p.startswith(prefix) and p != parent:
            child = p[len(prefix):].split("/", 1)[0]
            if fnmatch.fnmatchcase(child, comp):
                return f"'{raw}' matches protected '{p}'"
    return None


def target_reason(raw: str, cwd: str | None) -> str | None:
    if UNSAFE_VAR_RE.match(raw):
        return f"'{raw}': an empty variable turns this into '/...'; use \"${{VAR:?}}/...\""
    path = norm(raw, cwd)
    if path is None:
        if not raw.startswith(("/", "~", "$")) and (raw in RISKY_RELATIVE or raw.startswith("..")):
            return f"'{raw}' in an unknown directory"
        return None
    is_glob = any(c in GLOB_CHARS for c in path)
    for candidate in dict.fromkeys((path, via_links(path))):
        reason = glob_reason(raw, candidate) if is_glob else plain_path_reason(raw, candidate)
        if reason:
            return reason
    return None


def rm_reason(args: list[str], cwd: str | None) -> str | None:
    recursive = False
    targets: list[str] = []
    opts_done = False
    for t in args:
        if not opts_done and t == "--":
            opts_done = True
        elif not opts_done and t.startswith("--"):
            recursive = recursive or t == "--recursive"
        elif not opts_done and t.startswith("-") and len(t) > 1:
            recursive = recursive or "r" in t or "R" in t
        else:
            targets.append(t)
    if not recursive:
        return None
    for t in targets:
        reason = target_reason(t, cwd)
        if reason:
            return f"recursive rm: {reason}"
    return None


def git_reason(args: list[str]) -> str | None:
    i = 0
    while i < len(args) and args[i].startswith("-"):
        i += 2 if args[i] in GIT_OPTS_WITH_ARG else 1
    if i >= len(args):
        return None
    sub, rest = args[i], args[i + 1:]
    if sub == "reset" and "--hard" in rest:
        return "git reset --hard"
    if sub == "push":
        for a in rest:
            if a in {"--mirror", "--delete", "--prune"} or a.startswith("--force"):
                return f"git push {a}"
            if re.fullmatch(r"-[a-zA-Z]*[fd][a-zA-Z]*", a):
                return f"git push {a}"
            if len(a) > 1 and a[0] in "+:":
                return f"git push {a} (force / remote delete refspec)"
    return None


def drop_redirections(words: list[str]) -> list[str]:
    """Remove redirections (2>/x, > /x, &>>log, <in) and their operands from a simple command."""
    out: list[str] = []
    k = 0
    while k < len(words):
        w = words[k]
        if any(ch.isspace() for ch in w):  # came from quotes: an argument, never a redirection
            out.append(w)
            k += 1
            continue
        m = REDIR_RE.fullmatch(w)
        if m:
            k += 1 if m.group(2) else 2
            continue
        cut = min((w.find(c) for c in "<>" if c in w), default=-1)
        if cut > 0:  # word glued to a redirection: path>/tmp/log keeps "path"
            out.append(w[:cut])
            rest = REDIR_RE.fullmatch(w[cut:])
            k += 1 if rest is None or rest.group(2) else 2
            continue
        out.append(w)
        k += 1
    return out


def command_words(words: list[str]) -> tuple[str, list[str], str | None]:
    """Skip keywords, VAR=val and wrappers with their options.
    Returns (command, args, chdir) where chdir is a directory a wrapper switches to (env -C, sudo -D)."""
    words = drop_redirections(words)
    k = 0
    chdir: str | None = None
    while k < len(words):
        w = words[k]
        if w in KEYWORDS or ASSIGN_RE.match(w):
            k += 1
            continue
        name = os.path.basename(w)
        if name in WRAPPER_OPTS_WITH_ARG:
            with_arg = WRAPPER_OPTS_WITH_ARG[name]
            cd_opts = CHDIR_OPTS.get(name, set())
            k += 1
            while k < len(words) and words[k].startswith("-") and words[k] != "-":
                opt = words[k]
                if opt == "--":
                    k += 1
                    break
                if "=" in opt and opt.startswith("--"):
                    key, val = opt.split("=", 1)
                    if key in cd_opts:
                        chdir = val
                    k += 1
                elif opt in with_arg:
                    if opt in cd_opts and k + 1 < len(words):
                        chdir = words[k + 1]
                    k += 2
                elif not opt.startswith("--") and len(opt) > 2 and opt[:2] in with_arg:
                    if opt[:2] in cd_opts:  # glued short option: env -C/dir, sudo -D/dir
                        chdir = opt[2:]
                    k += 1
                else:
                    k += 1
            if name == "env":
                while k < len(words) and ASSIGN_RE.match(words[k]):
                    k += 1
            continue
        return w, words[k + 1:], chdir
    return "", [], chdir


def expand_braces(word: str, limit: int = 64) -> list[str]:
    """Bash brace expansion for comma lists ({a,b}); ranges and odd forms stay literal."""
    m = re.search(r"\{([^{}]*,[^{}]*)\}", word)
    if not m:
        return [word]
    out: list[str] = []
    for alt in m.group(1).split(","):
        out.extend(expand_braces(word[:m.start()] + alt + word[m.end():], limit))
        if len(out) >= limit:
            break
    return out[:limit]


def run_simple(words: list[str], cwd: str | None, piped: bool, depth: int) -> tuple[str | None, set]:
    """Check one simple command run in `cwd`. Returns (block reason, possible (cwd, status) after)."""
    cmd, args, chdir = command_words(words)
    run_cwd = norm(chdir, cwd) if chdir is not None else cwd
    base = os.path.basename(cmd)
    if base == "cd" and not piped:
        dest = next((a for a in args if not a.startswith("-") or a == "-"), HOME)
        new = norm(dest, cwd) if dest != "-" else None
        # Any cd may fail (missing dir, no permission): only `cd X && ...` is sure to be in X.
        return None, {(new, True), (cwd, False)}
    reason = None
    if cmd in RM_NAMES:
        reason = rm_reason([a for t in args for a in expand_braces(t)], run_cwd)
    elif cmd in GIT_NAMES:
        reason = git_reason(args)
    elif (cmd in SHELL_NAMES or base == "su") and depth < 3:
        idx = next((k for k, a in enumerate(args) if re.fullmatch(r"-[a-zA-Z]*c[a-zA-Z]*", a)), None)
        if idx is not None and idx + 1 < len(args):
            reason = walk(split_tokens(args[idx + 1]) or args[idx + 1].split(), run_cwd, depth + 1)
    return reason, {(cwd, True), (cwd, False)}


def walk(tokens: list[str], cwd: str | None, depth: int = 0) -> str | None:
    """Abstract run of the command list. State = set of (possible cwd, last exit ok?).
    `a && b` runs b only on ok states, `a || b` only on failed ones; `;` joins every path;
    a pipeline member, a `( ... )` subshell or a `&` background list never moves the parent cwd.
    if/while bodies are not modelled as branches: a cd inside them is just "may or may not happen",
    which the may-fail outcome of every cd already covers."""
    states: set = {(cwd, True)}
    list_start: set = set(states)
    stack: list[tuple[set, set]] = []
    op: str | None = None  # operator before the next simple command
    i, n = 0, len(tokens)
    while i < n:
        tok = tokens[i]
        if tok == "(":
            stack.append((set(states), set(list_start)))
            list_start = set(states)
            op = None
            i += 1
            continue
        if tok == ")":
            if stack:
                outer, list_start = stack.pop()
                states = {(c, s) for c, _ in outer for s in (True, False)}
            op = None
            i += 1
            continue
        if tok in {"&&", "||"}:
            op = tok
            i += 1
            continue
        if tok in {";", ";;"}:
            states = {(c, True) for c, _ in states}
            list_start = set(states)
            op = None
            i += 1
            continue
        if tok == "&":
            states = set(list_start)
            op = None
            i += 1
            continue
        if tok in {"|", "|&"}:
            i += 1
            continue
        j = i
        while j < n and tokens[j] not in SEPARATORS:
            j += 1
        piped = (j < n and tokens[j] in {"|", "|&"}) or (i > 0 and tokens[i - 1] in {"|", "|&"})
        runs = {st for st in states if op is None or (op == "&&") == st[1]}
        skipped = states - runs
        after: set = set(skipped)
        for c, _ in runs:
            reason, outcome = run_simple(tokens[i:j], c, piped, depth)
            if reason:
                return reason
            after |= outcome
        states = after
        op = None
        i = j
    return None


def split_tokens(cmd: str) -> list[str] | None:
    try:
        # A backslash-newline is a line continuation, not a command separator.
        lex = shlex.shlex(re.sub(r"\\\r?\n", " ", cmd).replace("\n", " ; "), posix=True,
                          punctuation_chars=";&|()")
        lex.whitespace_split = True
        lex.commenters = ""
        raw = list(lex)
    except ValueError:
        return None
    # shlex glues adjacent operators (");", "&&(") into one token: split them back.
    out: list[str] = []
    for t in raw:
        if t and set(t) <= set(";&|()"):
            k = 0
            while k < len(t):
                two = t[k:k + 2]
                if two in {"&&", "||", ";;", "|&"}:
                    out.append(two)
                    k += 2
                else:
                    out.append(t[k])
                    k += 1
        else:
            out.append(t)
    # Glue fd-duplicating redirections back: "2>" "&" "1" -> "2>&1", "&" ">log" -> "&>log",
    # so their "&" is not read as the background operator.
    glued: list[str] = []
    k = 0
    while k < len(out):
        t = out[k]
        if (re.fullmatch(r"\d*[<>]", t) and k + 2 < len(out) and out[k + 1] == "&"
                and re.fullmatch(r"\d+-?|-", out[k + 2])):
            glued.append(t + "&" + out[k + 2])
            k += 3
            continue
        if t == "&" and k + 1 < len(out) and out[k + 1].startswith(">"):
            glued.append("&" + out[k + 1])
            k += 2
            continue
        glued.append(t)
        k += 1
    return glued


def decide(cmd: str, cwd: str | None) -> str | None:
    low = cmd.lower()
    if FORK_BOMB in cmd:
        return "fork bomb"
    for pat in PATTERNS:
        if re.search(pat, low):
            return f"matches dangerous pattern '{pat}'"
    tokens = split_tokens(cmd)
    if tokens is None:
        # Unparsable (unbalanced quotes): be conservative for the token-checked classes.
        if re.search(r"\brm\s+(-\S*[rR]|--recursive)", cmd) or re.search(r"\bgit\b.*\b(reset|push)\b", low):
            return "recursive rm / git reset / git push in a command that cannot be parsed"
        return None
    return walk(tokens, cwd)


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError, UnicodeDecodeError):
        return 0
    if not isinstance(payload, dict):
        return 0
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return 0
    cmd = tool_input.get("command")
    if not isinstance(cmd, str) or not cmd:
        return 0
    cwd = payload.get("cwd")
    reason = decide(cmd, cwd if isinstance(cwd, str) and cwd.startswith("/") else None)
    if reason:
        print(f"BLOCKED by block-dangerous: {reason}.", file=sys.stderr)
        print("Scratch cleanup under /tmp is allowed: give rm an absolute /tmp/... path or write "
              "`cd DIR && rm ...`. Intentional removal of protected data: ask the owner.", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception:  # a guard bug must not wedge the agent
        sys.exit(0)
