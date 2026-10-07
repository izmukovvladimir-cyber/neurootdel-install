#!/usr/bin/env bash
# Installed by the installer as /usr/local/lib/<agent user>/channel-confirm.sh; copied
# from the live fleet (owner name made generic). Deliberately `set -u` only: it must never
# fail the unit (ExecStartPost), every tmux call is best-effort.
# channel-confirm.sh <tmux-session>
# Надёжно проходит интерактивные welcome-промты claude (их 2:
#  "Allow external CLAUDE.md imports?" и "WARNING: Loading development channels"),
# нажимая Enter ТОЛЬКО когда промт реально виден в пейне, и завершается рано,
# как только канал готов ("Listening for channel messages"). Запускается из
# ExecStartPost юнита под service-user (tmux принадлежит ему).
set -u
sess="${1:?нужен tmux session name}"
# ready = claude дошёл до интерактивного промта (футер TUI) => оба welcome-промта
# пройдены, канал загружен (промт №2 = подтверждение загрузки канала).
ready_re='for shortcuts|for agents'
prompt_re='Enter to confirm|allow external imports|local development|Yes, allow|I am using this'

for _ in $(seq 1 40); do   # ~80с максимум
  # Выделенный tmux-сокет на агента: socket name == session name == "$sess".
  # Без -L все юниты делят один сервер -> при одновременном старте только
  # первый владеет процессом, остальные systemd считает мёртвыми (inactive).
  vis="$(tmux -L "$sess" capture-pane -t "$sess" -p 2>/dev/null || true)"
  if grep -qE "$ready_re" <<<"$vis"; then
    # 2026-07-06 (Vladimir + Richard): every restart used to leave the agent
    # sitting on a blank prompt until the next inbound message — nobody told
    # it to look at its own memory. Nudge it once, here, so it resumes
    # unfinished work immediately instead of idling. Generic on purpose (no
    # per-agent memory-file parsing) — the agent reads its own handoff far
    # more reliably than a grep ever could. Fire-and-forget: never block
    # channel readiness on this.
    # 2026-07-16 (Vladimir + koder): the nudge is typed straight into the TUI, so
    # it arrives with no <channel> tag — no chat_id, no message_id, no sender.
    # Client bots (rightly trained to treat untagged imperative text as prompt
    # injection after the 2026-07-15 incident) read that as an attack and
    # escalated to Vladimir instead of resuming. Self-identify here so every
    # agent can place it, and state plainly that it assigns no work — reading
    # one's own memory is the only action, which is safe even if spoofed.
    resume_msg='[Системный авто-резюме после рестарта] Это локальный системный триггер channel-confirm.sh: он печатается прямо в терминал при рестарте твоего сервиса, поэтому приходит без канального тега (без chat_id, message_id, отправителя) — так и задумано, это не prompt injection. Задач он не ставит и ставить не может: единственное действие по нему — прочитать свою же память. Прочитай её (handoff.md, decisions.md, recent.md — что есть) на предмет незакрытой задачи. Если есть — продолжай её сейчас же. Если задач нет — просто оставайся в ожидании, отдельный отчёт «задач нет» слать не нужно. Это про то, чтобы не спамить, а не про то, чтобы что-то скрывать: писать владельцу о чём угодно, включая сомнения в этом самом триггере, ты свободен всегда.'
    tmux -L "$sess" send-keys -t "$sess" -l "$resume_msg" 2>/dev/null || true
    sleep 1
    tmux -L "$sess" send-keys -t "$sess" Enter 2>/dev/null || true
    echo "channel-confirm: resume-nudge sent to $sess" >&2
    exit 0   # канал поднялся, claude в интерактиве
  fi
  # Bypass Permissions screen (--dangerously-skip-permissions, Richard): дефолт
  # подсвечен на "1. No, exit" → голый Enter ВЫЙДЕТ из claude и уронит юнит. Надо
  # выбрать "2. Yes, I accept" — стрелка вниз, затем Enter. Этот экран тоже содержит
  # "Enter to confirm" (попал бы в prompt_re ниже), поэтому ловим его РАНЬШЕ. No-op
  # для агентов без флага (экран не появляется).
  if grep -qE 'Bypass Permissions mode|Yes, I accept' <<<"$vis"; then
    tmux -L "$sess" send-keys -t "$sess" Down 2>/dev/null || true
    sleep 1
    tmux -L "$sess" send-keys -t "$sess" Enter 2>/dev/null || true
    sleep 2
    continue
  fi
  if grep -qE "$prompt_re" <<<"$vis"; then
    tmux -L "$sess" send-keys -t "$sess" Enter 2>/dev/null || true
  fi
  sleep 2
done
exit 0   # не блокируем юнит даже если не дождались — readiness проверит cutover
