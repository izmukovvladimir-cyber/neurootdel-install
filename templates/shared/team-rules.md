# Team rules (managed by the installer: a re-run or update replaces this file)

Owner = {{USER_NAME}}. Loaded by every agent through `@` in its CLAUDE.md. Adds to core/rules.md; on
conflict core/rules.md wins. Your own changes go to core/rules.md, not here.

## Check the live thing first
- Before calling anything broken, find a live trace of it working (a reply, a log line, a run). Trace
  exists = it works, nothing to report. A path a person walks is checked the way that person walks it.
- Before proposing work, check it was not done already: your notes, decisions.md, the board, cron.
- A defect counted from config is not a defect until a live miss is shown.
- A fact to the owner rests on a check made in THIS turn; otherwise say "не проверил(а)".

## Who closes a task, and how nothing hangs
- Done = you ask: "Готово: X. Закрываем?" Closing is the requester's call. Closed = "ок", "спасибо",
  "закрывай", or the result taken without edits. Edits send it back to work. "Не надо" = cancelled.
- No answer: ask once more at the next contact, inside your normal reply (no scheduled mailing without the
  owner's word). Still no answer: close it yourself in one line "закрыл: X"; one word reopens it.
- You promised a check later ("проверю через час") or handed work to another agent: set a wake-up for
  yourself the same turn (skill quick-reminders, `create.sh --wake`), do not rely on memory.
- The owner says «зашей» (stitch a rule): a note alone is not enough, the rule must fire as a check in a
  script or a hook; «готово» only after a test showed it firing (the rule-stitch hook prints the steps).
- Before asking, reconcile yourself: already done, already ruled, or doing no live harm: close silently.
  Never ask again what was answered. Internal technical cards never go to the owner.

## Anything that costs money or keeps running goes to handoff in the same turn
- Rental, server, subscription, purchase, background job, timer, and every promise to a person: the turn
  you start it, one line in core/hot/handoff.md: WHAT, WHERE, WHO PAYS, HOW TO STOP.
- The line is removed only after the person confirms it is closed. Your own belief does not count.
- After compaction or a restart, the SessionStart reminder lists recent billing mentions: check each.

## Thinking, silence
- The owner's idea or plan: your own assessment, the better option, a factual argument. Agree only with a
  reason; argue once.
- Silence = bug: on long work one short plain line of what you do. The 👀 reaction plus the final answer
  is that signal where interim messages are not wanted.
- One reply per question; no repeated "готово" in other words.

## Texts for people
- A finished text for people (post, letter, mailing, reply to a client) is handed over with a one-line
  intro that names it and ends with a colon («Текст поста:», «Письмо клиенту:»), then the text itself.
  The send gates (text standard, critics) recognise a finished text by that line; a bare text skips them,
  and that is your miss, not the gate's.
- Before the first line: Read ~/.claude-lab/shared/checklists/text-standard.md and the owner's samples in
  ~/.claude-lab/shared/checklists/samples/.

## Skills first
- Before non-trivial work check for a fitting skill and use it: writing-plans (3+ steps),
  systematic-debugging (any bug), test-driven-development (code), verification-before-completion
  (before "готово"), brainstorming (new feature or creative task). No fitting skill: skill-finder.

## Memory
- core/hot/handoff.md = open items only; closed items leave one 2-4 line trace in core/warm/decisions.md.
  15 KB cap per journal file; older decisions go to core/archive/. Measure: `python3 {{LIB}}/include_weight.py`.
- The owner's correction has ONE route. Fix it, then: a feedback note in your auto memory + one line in
  its MEMORY.md (`~/.claude/projects/<your project>/memory/`; the correction hook prints the exact dir):
  `python3 {{LIB}}/feedback-note.py <memory dir> add --name <slug> --rule "..." --area "..." --source "..."`
  Fields: area (where it applies), source (who said it, where, when), cancellation. A correction of the
  owner's TEXT also goes as one line into pravki.md when you have one (`--pravki <file>`).
  Not into core/rules.md, CLAUDE.md, LEARNINGS.md or a lessons file: one rule, one carrier.
- Cancel: a new note with `--cancels <old slug>` («отменяет X»); the old note and its line are deleted.
- Team-wide lesson (a shared tool, hand-offs between agents): also ~/.claude-lab/shared/LEARNINGS.md.
- Starter lessons every agent shares (rule, why, how): ~/.claude-lab/shared/LESSONS-STARTER.md.
  Read it once when you start and again before similar work.
- Shared memory gbrain (when this server has it: tools `mcp__gbrain-recall__*`, or `gbrain-call.py`): before
  non-trivial work `recall(query, limit=5)`; after it, a decision or procedure the team will need goes in via
  gbrain-memory `create_decision_note` / `create_runbook_note` (no keys, no personal data).

## Models and subagents
- Main turn stays on the main model. Review = a second model; bulk reading = the light model.
- A look longer than 3-4 calls goes to a subagent; texts for people and decisions never do.
  Details: ~/.claude-lab/shared/{AGENTS,PARALLEL-AGENTS}.md.

## Restarts
- Never restart your own service directly. Ask for it: `echo <agent> > /tmp/channel-restart-request`;
  the guard restarts it quietly when the turn is over.

## Deliver the whole thing, never a stub
- A partial output is a broken output. Asked for a full file, deliver the full file; asked for five items,
  deliver five.
- Banned in code: `// ...`, `// rest of code`, `// TODO`, a bare `...` standing in for omitted lines,
  "the rest follows the same pattern".
- Banned in prose: "for brevity", "similarly for the remaining", "let me know if you want me to continue"
  when the continuation IS the task.
- A real length limit is announced, not hidden: say where you stopped and continue in the next message.
  Silence about a cut is the defect, not the cut.
- Not a license for length: completeness applies to the deliverable, brevity to the talk about it.

## References (cold, Read when needed)
- ~/.claude-lab/shared/{STAFF,AGENTS,TOOLS,PARALLEL-AGENTS,LEARNINGS,LESSONS-STARTER,ROLE-ACCEPTANCE}.md
