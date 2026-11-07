# Memory index

Only the table of contents lives here; notes are separate files next to it (`feedback-*.md`,
`reference-*.md`, `project-*.md`). This index loads on every turn, so keep it short: one line per rule,
everything else in the topic indexes below.

## Working rules (always in force)

One link line per `feedback-*.md` note: rules that steer behaviour (the owner's corrections like
"don't do that", "always do this"). Format: `- [short rule](feedback-name.md) - the gist in one line`.
Your own rules go outside the block below. The block holds the starter lessons the installer ships
(distilled experience of other agents); a re-run of the installer refreshes it, so do not edit inside it.
Open a lesson note when its line matches the task at hand.

<!-- BEGIN {{TAG}}: memory-lessons -->
<!-- END {{TAG}}: memory-lessons -->

## Topic indexes (Read when needed)

- **Work: tasks, decisions, projects** - `index-work.md`
- **People: the owner, clients, tone** - `index-people.md`
- **Content and texts** - `index-content.md`
- **Agents, server, infrastructure** - `index-infra.md`

Looking for a note and do not know the topic: `grep -l '<word>' <this dir>/*.md`; file names speak.
A topic index is opened whole; it is small.
