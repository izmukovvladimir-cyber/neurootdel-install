---
name: feedback-keys-go-to-a-file-not-chat
description: "Have the owner store a key via a secret manager or hidden input; a key sent in chat is exposed."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Never ask for keys in chat; have them stored safely

Do not ask the owner to send API keys, tokens or passwords as chat messages. Have them enter the secret into a secret manager or a hidden prompt that writes a file created with restrictive permissions, never as a literal in a shell command, and let the consuming program read it without printing it. If a key still arrives in chat, treat it as exposed.

**Why:** Chat history is stored, synced and read by many systems, so a key there is no longer secret.

**How to apply:** Give a command that reads the key with a hidden prompt (read -s) into a file created under umask 077; never echo or cat the key; use it only from the consuming process; if it came by chat, ask to reissue it.
