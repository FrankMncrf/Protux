#!/usr/bin/env python3
"""README screenshots: drives protux-gui on a real X display (Xvfb + xfwm4 + xfce4-panel in a
test VM, see screenshots.sh) against the fake Proton account. Saves to ~/readme-shots.
No real account is involved: the email is made up and the drive is tests/fake-proton-rclone."""
import importlib.util
import os
import subprocess
import sys
import time
from importlib.machinery import SourceFileLoader

GUI = os.environ.get("PROTUX_GUI", "/usr/bin/protux-gui")
_loader = SourceFileLoader("pgui", GUI)
_spec = importlib.util.spec_from_loader("pgui", _loader)
g = importlib.util.module_from_spec(_spec)
_loader.exec_module(g)

from PyQt6.QtCore import QPoint  # noqa: E402
from PyQt6.QtWidgets import QApplication, QMessageBox  # noqa: E402

HOME = os.path.expanduser("~")
OUT = os.path.join(HOME, "readme-shots")
MP = "/media/ProtonDrive"
RCLONE_CONF = os.path.join(HOME, ".config/rclone/rclone.conf")
EMAIL = "alex@proton.me"
QA = QApplication.instance() or QApplication([])
QMessageBox.question = staticmethod(lambda *a, **k: QMessageBox.StandardButton.No)


def sh(*args, stdin=None):
    return subprocess.run(args, input=stdin, capture_output=True, text=True)


def pump(seconds=0.6):
    end = time.time() + seconds
    while time.time() < end:
        QA.processEvents()
        time.sleep(0.02)


def wait_until(fn, timeout=30):
    end = time.time() + timeout
    while time.time() < end:
        QA.processEvents()
        if fn():
            return True
        time.sleep(0.1)
    return False


def shot(widget, name):
    """The window with its xfwm4 frame."""
    widget.raise_()
    widget.activateWindow()
    pump(0.8)
    sh("import", "-frame", "-window", str(int(widget.winId())), os.path.join(OUT, f"{name}.png"))


def screen(name, crop=None):
    pump(0.8)
    args = ["import", "-window", "root"] + (["-crop", crop, "+repage"] if crop else [])
    sh(*args, os.path.join(OUT, f"{name}.png"))


def mounted():
    return sh("mountpoint", "-q", MP).returncode == 0


def expire_session():
    sh("protux", "stop")
    with open(RCLONE_CONF) as f:
        text = f.read()
    with open(RCLONE_CONF, "w") as f:
        f.write("\n".join("client_uid = " if line.startswith("client_uid =") else line
                          for line in text.splitlines()) + "\n")


def reset():
    os.makedirs(OUT, exist_ok=True)
    sh("systemctl", "--user", "stop", "protux.service")
    sh("systemctl", "--user", "disable", "protux.service")
    sh("fusermount3", "-uz", MP)
    sh("sudo", "rm", "-rf", MP)
    for p in (RCLONE_CONF, os.path.join(HOME, ".local/state/protux/state"), g.AUTOSTART_PATH, g.SETTINGS_PATH):
        if os.path.exists(p):
            os.unlink(p)
    os.makedirs(os.path.join(HOME, ".config/protux"), exist_ok=True)
    open(os.path.join(HOME, ".fake-drive/.force"), "w").close()
    with open(os.path.join(HOME, ".config/protux/config"), "w") as f:
        f.write("RCLONE=/usr/local/bin/fake-proton-rclone\nKEYRING=no\nNET_HOST=localhost\nGUI_WAIT=0\n")


def main():
    reset()
    app = g.Protux(QA)
    app.timer.stop()

    app.show_wizard()
    z = app.wizard
    z.move(120, 90)
    shot(z, "wizard-welcome")
    z.next()
    acc = z.account
    acc.email.setText(EMAIL)
    acc.password.setText("pass-ok")
    acc.two.setChecked(True)
    acc.mailbox.setText("mbox-ok")
    shot(z, "wizard-account")
    z.next()
    verify = z.currentPage()
    verify.code.setText("123456")
    shot(z, "wizard-2fa")
    z.next()
    if not wait_until(lambda: isinstance(z.currentPage(), g.FolderPage), 20):
        sys.exit(f"login failed: {verify.error.text()}")
    shot(z, "wizard-folder")
    z.next()
    wait_until(lambda: isinstance(z.currentPage(), g.DonePage), 30)
    shot(z, "wizard-done")
    z.accept()

    win = app.window
    wait_until(lambda: win.isVisible() and win.title.text() == g.STATE_LABELS["up"], 15)
    app.refresh(full=True)
    pump(2)
    win.move(140, 110)
    shot(win, "window")

    p = g.PrefsDialog(app, win)
    p.show()
    p.move(160, 70)
    shot(p, "preferences")
    p.reject()

    # hero: file manager on the mounted drive, the window beside it and the tray menu open
    fm = subprocess.Popen(["thunar", MP])
    pump(4)
    sh("wmctrl", "-r", "ProtonDrive", "-e", "0,30,62,650,500")
    win.move(700, 250)
    win.show()
    win.raise_()
    pump(1.5)
    screen("mounted-full")
    app.menu.popup(QPoint(1180, 36))
    pump(1.2)
    screen("tray-menu", "400x268+880+0")
    app.menu.hide()
    fm.terminate()
    sh("pkill", "-x", "Thunar")

    expire_session()
    sh("systemctl", "--user", "reset-failed", "protux.service")
    sh("protux", "start")
    wait_until(lambda: sh("cat", os.path.join(HOME, ".local/state/protux/state")).stdout.startswith("auth"), 30)
    app.refresh(full=True)
    wait_until(lambda: win.title.text() == g.STATE_LABELS["error"], 10)
    pump(1)
    shot(win, "window-expired")
    d = g.LoginDialog(app, win)
    d.show()
    d.move(200, 140)
    d.code.setText("123456")
    shot(d, "relogin")
    d.submit()
    wait_until(mounted, 30)
    app.timer.stop()
    app.runner.shutdown()


if __name__ == "__main__":
    main()
