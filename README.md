# AI Tools

Reusable procedures, scripts and hard-won findings for AI agents working on this
machine. Each subfolder is self-contained and written so an agent can follow it
start to finish without prior context.

| Folder | What it covers |
|--------|----------------|
| [`Raspberry Pi Imaging`](./Raspberry%20Pi%20Imaging/) | Writing a headless Raspberry Pi OS card on Windows that reaches the network unattended on first boot. Includes the Trixie `custom.toml` trap, the `firstrun.sh` mechanism, a guarded raw writer, and a pre-eject boot-chain simulator. |
| [`Raspberry Pi RDP`](./Raspberry%20Pi%20RDP/) | Remote Desktop into a headless Pi from Windows `mstsc`: X11 Pi desktop + xrdp, the `~/.xsession` that makes it work, the polkit rule that stops the updater password prompt, and a headless way to verify the login with a screenshot. |

## Conventions

- **No secrets in this repository.** Scripts use clearly-marked `{{PLACEHOLDER}}`
  values, filled at use time.
- Shell scripts are **LF-only** — CRLF breaks them on Linux targets.
- Findings are documented with the **evidence** that established them, not as
  received wisdom, so a future reader can re-verify rather than trust.
