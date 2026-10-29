# Changelog

## 0.1.0 — 2026-10-29

First version.

- Proton Drive mounted with rclone as a systemd user service, ready as soon as the drive is
  mounted (`Type=notify`).
- Never retries a login that can only fail: expired session, wrong password, missing second
  password, CAPTCHA or Proton's rate limit (HTTP 429) stop the service instead of hammering
  Proton until the account gets blocked.
- Asks for a new 2FA code with a notification when the session expires; after a rate limit it
  asks again once the block is over.
- Two-password accounts (login password + mailbox password).
- Graphical app (Qt): tray icon, setup wizard, status window, preferences and a Help menu.
- Mounts at `/media/ProtonDrive` by default (created once with administrator rights), or in any
  folder you choose.
- Opens the drive in your desktop's own file manager (Thunar, Dolphin, Files...).
- `protux` command for the terminal: setup, login, password, status, doctor, logs...
- English and Spanish.
