---
name: feedback-detached-process-dies-with-unit
description: "Processes you start stay in your service's cgroup and die with it, however detached they look."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Know that setsid and nohup do not escape a unit

nohup and setsid do not move a process out of your service's cgroup. With the default kill mode, every process left in that cgroup dies when your service stops. A task that restarts your own service must be carried by something outside it, such as a separate unit, timer or queue.

**Why:** A self-restart script kills itself halfway and leaves the service down.

**How to apply:** Hand the restart to another unit, a queue or systemd-run (which creates its own unit); check the cgroup with systemd-cgls.
