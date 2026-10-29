#!/usr/bin/env python3
"""Tests for templates/fact-number-gate.py (hard numbers gate). Run: python3 tests/test_fact_number_gate.py"""
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent / "templates"
spec = importlib.util.spec_from_file_location("fg", str(HERE / "fact-number-gate.py"))
fg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fg)
OWNER = "42"


def p(text: str, chat: str = OWNER, tool: str = "mcp__dashi-channel__reply", tp: str | None = None) -> dict:
    d = {"tool_name": tool, "tool_input": {"chat_id": chat, "text": text}, "session_id": "s1"}
    if tp:
        d["transcript_path"] = tp
    return d


def prompt(pid: str, text: str = "<channel source=\"telegram\">сколько ошибок?</channel>", ts: str = "") -> dict:
    return {"type": "user", "promptId": pid, "timestamp": ts, "message": {"role": "user", "content": text}}


def use(uid: str, name: str, inp: dict) -> dict:
    return {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": uid, "name": name, "input": inp}]}}


def res(uid: str, pid: str, out: str = "51 errors in log", err: bool = False) -> dict:
    return {"type": "user", "promptId": pid, "message": {"content": [
        {"type": "tool_result", "tool_use_id": uid, "is_error": err, "content": out}]}}


DENY_RESULT = "Hook PreToolUse:mcp__dashi-channel__reply denied this tool call: " + fg.REASON
TEXT = "Маркус нашёл 51 ошибку, лимит 30."


def run() -> int:
    cases: list[tuple[str, bool]] = []

    def dec(text: str, entries: list[dict] | None, **kw) -> str | None:
        return fg.decide(p(text, **{k: v for k, v in kw.items() if k in ("chat", "tool")}), owner=OWNER,
                         groups=kw.get("groups", False), entries=entries)[0]

    # (а) number without a check in the turn -> deny
    turn_a = [prompt("A"), use("r1", "mcp__dashi-channel__reply", {"chat_id": OWNER, "text": "Смотрю"}),
              res("r1", "A", "sent")]
    cases.append(("а) цифра без проверки -> блок", dec(TEXT, turn_a) is not None))
    # (б) the same text again 10 min later (deny result already in the turn) -> still deny
    turn_b = turn_a + [use("r2", "mcp__dashi-channel__reply", {"chat_id": OWNER, "text": TEXT}),
                       res("r2", "A", DENY_RESULT, err=True)]
    cases.append(("б) повтор того же текста через 10 мин -> снова блок", dec(TEXT, turn_b) is not None))
    cases.append(("б) повтор через CLI два раза подряд -> оба блок",
                  all(fg.decide(p(TEXT), entries=turn_b)[0] for _ in range(2))))
    # (в) a check in the turn -> pass
    turn_c = turn_b + [use("b1", "Bash", {"command": "grep -c ERROR /srv/var/log/x.log"}),
                       res("b1", "A", "51")]
    cases.append(("в) проверка Bash в ходе -> проходит", dec(TEXT, turn_c) is None))
    turn_c2 = [prompt("A"), use("rd", "Read", {"file_path": "/srv/x.txt"}), res("rd", "A", "limit=30")]
    cases.append(("в) проверка Read в ходе -> проходит", dec(TEXT, turn_c2) is None))
    turn_c3 = [prompt("A"), use("m1", "mcp__gbrain-tasks__task_get", {"task_id": 1}), res("m1", "A", "{...}")]
    cases.append(("в) MCP-чтение в ходе -> проходит", dec(TEXT, turn_c3) is None))
    # (г) plain text without numbers -> pass, even with no transcript at all
    cases.append(("г) текст без цифр -> проходит", fg.decide(p("Привет, смотрю."))[0] is None))
    cases.append(("г) время и дата не цифра: «в 14:05 МСК 29.10» -> проходит",
                  fg.decide(p("Сделаю к 14:05 МСК, 29.10 в 15:00, потом 2026-10-30, 31.10.2026 и 30 октября 2026 г."))[0]
                  is None))
    cases.append(("г) список «100.», путь v2/report.txt не цифра -> проходит",
                  fg.decide(p("100. Готово\nОткрой v2/report.txt"))[0] is None))
    # Codex r1: decimals are numbers, not dates
    for t in ("Средний балл 3.05", "Цена 3.05 USD", "Версия 3.10", "29.10 кг", "30/40 готово"):
        cases.append((f"r1: «{t}» это число -> блок", fg.decide(p(t))[0] is not None))
    # Codex r1: a Bash call must really return something
    for nm, cmd, out in (("false && cat; echo ok", "false && cat /etc/hosts; echo ok", "ok"),
                         ("cat /missing; echo ok", "cat /missing; echo ok", "cat: /missing: No such file or directory\nok"),
                         ('echo "|" cat', 'echo "|" cat', "| cat"),
                         ("swa\"\"rm", 'cat /tmp/swa""rm/inbox.json', "51 ошибка")):
        t = [prompt("A"), use("e", "Bash", {"command": cmd}), res("e", "A", out)]
        cases.append((f"r1: Bash «{nm}» не проверка -> блок", dec(TEXT, t) is not None))
    t = [prompt("A"), use("e", "Bash", {"command": "journalctl -u swarm.service -n 5"}), res("e", "A", "51 restarts")]
    cases.append(("r1: журнал docker/swarm.service это источник -> проходит", dec(TEXT, t) is None))
    # Codex r2
    for t in ("Вес до 29.10 кг", "Цена от 29.10 USD", "Коэффициент вырос до 12.05."):
        cases.append((f"r2: «{t}» это число -> блок", fg.decide(p(t))[0] is not None))
    for nm, cmd, out in (("printf %d", 'false && cat /etc/hosts; printf "%d\\n" 0x33', "51"),
                         ("/bin/echo 51", "false && cat /etc/hosts; /bin/echo 51", "51"),
                         ("echo $((50+1))", "true; echo $((50+1))", "51"),
                         ("кавычки в swarm-пути", 'cat "/var/lib/neurootdel-"swarm/delivered/x.json', "51 ошибка")):
        t = [prompt("A"), use("e", "Bash", {"command": cmd}), res("e", "A", out)]
        cases.append((f"r2: Bash «{nm}» не проверка -> блок", dec(TEXT, t) is not None))
    for nm, cmd, out in (("лог со словом ERROR", "cat /var/log/app.log", "ERROR: failed requests=51"),
                         ("echo --- + grep -c", "echo ---; grep -c ERR /x.log", "---\n51")):
        t = [prompt("A"), use("e", "Bash", {"command": cmd}), res("e", "A", out)]
        cases.append((f"r2: ложный блок «{nm}» -> проходит", dec(TEXT, t) is None))
    # Codex r3
    for t in ("Соотношение компонентов 1:10.", "Матч закончился со счётом 2:15."):
        cases.append((f"r3: «{t}» это число, не время -> блок", fg.decide(p(t))[0] is not None))
    for nm, cmd, out in (("cat fail; /bin/echo '51 errors'", "cat /proc/does-not-exist; /bin/echo '51 errors'",
                          "cat: /proc/does-not-exist: No such file or directory\n51 errors"),
                         ("false && true && cat", 'false && true && cat /etc/hosts; echo "$PWD"', "/home/x")):
        t = [prompt("A"), use("e", "Bash", {"command": cmd}), res("e", "A", out)]
        cases.append((f"r3: Bash «{nm}» не проверка -> блок", dec(TEXT, t) is not None))
    for nm, cmd, out in (("printf заголовок + grep -c", "printf '%s\\n' count; grep -c root /etc/passwd", "count\n1"),
                         ("лог «Permission denied: ...»", "cat /var/log/app.log", "Permission denied: failed requests=51")):
        t = [prompt("A"), use("e", "Bash", {"command": cmd}), res("e", "A", out)]
        cases.append((f"r3: ложный блок «{nm}» -> проходит", dec(TEXT, t) is None))
    t = [prompt("A"), use("e", "mcp__x__get_dataset", {"id": 1}), res("e", "A", "{rows: 51}")]
    cases.append(("r1: MCP get_dataset это чтение -> проходит", dec(TEXT, t) is None))
    cases.append(("г) ссылка, путь, @ник не цифра -> проходит",
                  fg.decide(p("Смотри https://t.me/c/123/456 и /srv/bin/x2.py, @user77"))[0] is None))

    # swarm is not a source
    sw_prompt = [prompt("S", "<channel source=\"webhook\">[Inter-agent from koder -> jarvis] 51 ошибка</channel>")]
    cases.append(("swarm-письмо в prompt без проверки -> блок", dec(TEXT, sw_prompt) is not None))
    sw_mcp = sw_prompt + [use("s1", "mcp__gbrain-swarm__list_my_pending", {"agent": "jarvis"}), res("s1", "S", "51")]
    cases.append(("mcp__gbrain-swarm__* не проверка -> блок", dec(TEXT, sw_mcp) is not None))
    sw_cat = sw_prompt + [use("s2", "Bash", {"command": "cat /var/lib/neurootdel-swarm/delivered/x.json"}),
                          res("s2", "S", "51 ошибка")]
    cases.append(("cat swarm-спула не проверка -> блок", dec(TEXT, sw_cat) is not None))
    sw_read = sw_prompt + [use("s3", "Read", {"file_path": "/srv/var/swarm/inbox/1.json"}),
                           res("s3", "S", "51")]
    cases.append(("Read swarm-файла не проверка -> блок", dec(TEXT, sw_read) is not None))

    # weak calls are not checks
    for nm, cmd in (("echo", "echo 51"), ("sleep", "sleep 2"), ("touch", "touch /tmp/x"),
                    ("echo>file", "echo koder > /tmp/channel-restart-request"), ("|| cat", "true || cat /etc/x")):
        t = [prompt("A"), use("e", "Bash", {"command": cmd}), res("e", "A", "ok")]
        cases.append((f"Bash «{nm}» не проверка -> блок", dec(TEXT, t) is not None))
    t = [prompt("A"), use("e", "Bash", {"command": "grep x /nope"}), res("e", "A", "No such file", err=True)]
    cases.append(("ошибка вызова не проверка -> блок", dec(TEXT, t) is not None))
    t = [prompt("A"), use("e", "Bash", {"command": "grep x f", "run_in_background": True}), res("e", "A", "started")]
    cases.append(("фоновый вызов не проверка -> блок", dec(TEXT, t) is not None))
    t = [prompt("A"), use("w", "mcp__gbrain-memory__create_decision_note", {"x": 1}), res("w", "A", "ok")]
    cases.append(("MCP-запись не проверка -> блок", dec(TEXT, t) is not None))
    # a check from the PREVIOUS turn does not count
    t = [prompt("A"), use("b", "Bash", {"command": "grep -c E f"}), res("b", "A", "51"), prompt("B")]
    cases.append(("проверка прошлого хода не считается -> блок", dec(TEXT, t) is not None))

    # attribution and quantities
    cases.append(("«со слов Маркуса» без цифр -> блок", dec("Со слов Маркуса, всё починено.", turn_a) is not None))
    cases.append(("«по данным Алана» -> блок", dec("По данным Алана выручка выросла.", turn_a) is not None))
    cases.append(("3.5% это число, не дата -> блок", dec("Конверсия 3.05%", turn_a) is not None))
    cases.append(("#123 это цифра -> блок", dec("#123 готово", turn_a) is not None))
    cases.append(("нет транскрипта + цифра -> блок", fg.decide(p(TEXT))[0] is not None))
    cases.append(("битый путь транскрипта -> блок", fg.decide(p(TEXT, tp="/proc/nope/x.jsonl"))[0] is not None))

    # chats and tools
    cases.append(("чужой личный чат -> пропуск", dec(TEXT, turn_a, chat="555") is None))
    cases.append(("без --owner любой личный чат считается владельцем -> блок",
                  fg.decide(p(TEXT, chat="555"), entries=turn_a)[0] is not None))
    cases.append(("без --owner группа -> пропуск", fg.decide(p(TEXT, chat="-100123"), entries=turn_a)[0] is None))
    cases.append(("группа без --groups -> пропуск", dec(TEXT, turn_a, chat="-100123") is None))
    cases.append(("группа с --groups -> блок", dec(TEXT, turn_a, chat="-100123", groups=True) is not None))
    cases.append(("edit_message тоже -> блок",
                  dec(TEXT, turn_a, tool="mcp__dashi-channel__edit_message") is not None))

    # CLI end-to-end with a real transcript file
    d = Path(tempfile.mkdtemp())
    tp = d / "t.jsonl"
    tp.write_text("\n".join(json.dumps(e, ensure_ascii=False) for e in turn_b) + "\n", encoding="utf-8")
    env_log = d / "log"
    script = HERE / "fact-number-gate.py"
    src = script.read_text(encoding="utf-8").replace('Path.home() / ".claude" / "state" / "factgate"', f'Path("{env_log}")')
    tmp_script = d / "factgate_hard.py"
    tmp_script.write_text(src, encoding="utf-8")
    out = subprocess.run([sys.executable, str(tmp_script), "testagent"], input=json.dumps(p(TEXT, tp=str(tp))),
                         capture_output=True, text=True, timeout=20)
    cases.append(("CLI: deny JSON", '"permissionDecision": "deny"' in out.stdout and out.returncode == 0))
    tp.write_text("\n".join(json.dumps(e, ensure_ascii=False) for e in turn_c) + "\n", encoding="utf-8")
    out2 = subprocess.run([sys.executable, str(tmp_script), "testagent"], input=json.dumps(p(TEXT, tp=str(tp))),
                          capture_output=True, text=True, timeout=20)
    cases.append(("CLI: pass after check (пустой stdout)", out2.stdout.strip() == "" and out2.returncode == 0))
    logl = (env_log / "testagent.log").read_text(encoding="utf-8").splitlines()
    cases.append(("CLI: лог без текста, 2 строки", len(logl) == 2 and "51" not in logl[0]))
    out3 = subprocess.run([sys.executable, str(tmp_script), "testagent"], input="not json",
                          capture_output=True, text=True, timeout=20)
    cases.append(("CLI: мусор на входе -> exit 0", out3.returncode == 0 and out3.stdout == ""))

    fails = 0
    for name, ok in cases:
        print(("ok   " if ok else "FAIL ") + name)
        fails += not ok
    print(f"{len(cases) - fails}/{fails}")
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(run())
