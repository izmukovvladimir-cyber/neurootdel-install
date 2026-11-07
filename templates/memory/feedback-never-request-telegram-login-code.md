---
name: feedback-never-request-telegram-login-code
description: "Telegram kills a login code shared via Telegram; QR tokens expire fast, per the expiry the API returns."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Never ask a person to send you their Telegram login code

Telegram invalidates a login code that is shared through Telegram from the account, and asking for a code anywhere is a hijack pattern, so never request it. QR login tokens are short-lived; the API returns their expiry, usually about 30 seconds.

**Why:** The login fails every time, and the person learns to hand out codes, which is a hijack pattern.

**How to apply:** Use QR login with the person present; refresh the QR before the returned expiry; never request codes in chat.
