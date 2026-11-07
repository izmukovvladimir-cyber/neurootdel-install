---
name: feedback-find-every-mcp-definition
description: "MCP servers can come from several config sources; a stale copy keeps the old endpoint."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Find every MCP definition before changing an endpoint

Claude Code can take MCP server definitions from several sources: the project .mcp.json, user or local entries in ~/.claude.json, plugins, managed config and --mcp-config launch arguments. When an endpoint changes, find every source the affected session uses, including environment-variable expansion, and change only the definitions meant for this agent.

**Why:** One stale copy keeps some agents on the old endpoint after you 'fixed' it.

**How to apply:** Run claude mcp list in the affected session; check its launch arguments, plugins and env vars; search .mcp.json and ~/.claude.json for the old value, skipping backups and other clients; update, restart and check MCP status.
