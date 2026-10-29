#!/usr/bin/env python3
"""End-to-end tests of protux-gui (Qt, offscreen) against the fake Proton account.

Drives the real widgets with the real `protux` command, the systemd user service and a real
FUSE mount; only Proton is fake (tests/fake-proton-rclone: pass-ok / mbox-ok / 123456).
Run inside a test VM as a user with a systemd session, after `make install`, with a polkit rule
that lets this user run pkexec (the default mount folder /media/ProtonDrive needs it).
Screenshots go to ~/shots.
"""
import importlib.util
import os
import subprocess
import sys
import time
import unittest
from importlib.machinery import SourceFileLoader

os.environ["QT_QPA_PLATFORM"] = "offscreen"
GUI = os.environ.get("PROTUX_GUI", "/usr/bin/protux-gui")
_loader = SourceFileLoader("pgui", GUI)
_spec = importlib.util.spec_from_loader("pgui", _loader)
g = importlib.util.module_from_spec(_spec)
_loader.exec_module(g)

from PyQt6.QtWidgets import QApplication, QMessageBox  # noqa: E402

HOME = os.path.expanduser("~")
SHOTS = os.path.join(HOME, "shots")
MP = "/media/ProtonDrive"
RCLONE_CONF = os.path.join(HOME, ".config/rclone/rclone.conf")
QA = QApplication.instance() or QApplication([])
# Questions would block an offscreen test: answer "No" (the remount question)
QMessageBox.question = staticmethod(lambda *a, **k: QMessageBox.StandardButton.No)
QMessageBox.warning = staticmethod(lambda *a, **k: QMessageBox.StandardButton.Ok)
_n = [0]


def shot(widget, name):
    _n[0] += 1
    QA.processEvents()
    widget.grab().save(os.path.join(SHOTS, f"{_n[0]:02d}-{name}.png"))


def wait_until(fn, timeout=30):
    end = time.time() + timeout
    while time.time() < end:
        QA.processEvents()
        if fn():
            return True
        time.sleep(0.1)
    return False


def sh(*args, stdin=None):
    return subprocess.run(args, input=stdin, capture_output=True, text=True)


def state():
    try:
        with open(os.path.join(HOME, ".local/state/protux/state")) as f:
            return f.readline().strip()
    except OSError:
        return ""


def mounted():
    return sh("mountpoint", "-q", MP).returncode == 0


def expire_session():
    sh("protux", "stop")
    with open(RCLONE_CONF) as f:
        text = f.read()
    with open(RCLONE_CONF, "w") as f:
        f.write("\n".join("client_uid = " if line.startswith("client_uid =") else line for line in text.splitlines()) + "\n")


class GuiFlow(unittest.TestCase):
    """One long user story, in order: test names are numbered."""

    @classmethod
    def setUpClass(cls):
        os.makedirs(SHOTS, exist_ok=True)
        for f in os.listdir(SHOTS):
            os.unlink(os.path.join(SHOTS, f))
        sh("systemctl", "--user", "stop", "protux.service")
        sh("systemctl", "--user", "disable", "protux.service")
        sh("fusermount3", "-uz", MP)
        sh("sudo", "rm", "-rf", MP)
        for p in (RCLONE_CONF, os.path.join(HOME, ".local/state/protux/state"), g.AUTOSTART_PATH,
                  g.SETTINGS_PATH):
            if os.path.exists(p):
                os.unlink(p)
        os.makedirs(os.path.join(HOME, ".config/protux"), exist_ok=True)
        os.makedirs(os.path.join(HOME, ".fake-drive"), exist_ok=True)
        with open(os.path.join(HOME, ".fake-drive/hello.txt"), "w") as f:
            f.write("hello from the fake drive\n")
        open(os.path.join(HOME, ".fake-drive/.force"), "w").close()
        with open(os.path.join(HOME, ".config/protux/config"), "w") as f:
            f.write("RCLONE=/usr/local/bin/fake-proton-rclone\nKEYRING=no\nNET_HOST=localhost\nGUI_WAIT=0\n")
        cls.app = g.Protux(QA)
        cls.app.timer.stop()

    def test_01_wizard_opens_with_requirements(self):
        app = self.app
        self.assertNotEqual(app.info.get("remote_exists"), "1")
        app.show_wizard()
        z = app.wizard
        self.assertTrue(z.currentPage().isComplete(), "rclone and FUSE found")
        shot(z, "asistente-bienvenida")

    def test_02_account_without_second_password(self):
        z = self.app.wizard
        z.next()
        acc = z.account
        self.assertIs(z.currentPage(), acc)
        acc.email.setText("me@proton.me")
        acc.password.setText("pass-ok")
        shot(z, "asistente-cuenta")
        z.next()
        self.assertIsInstance(z.currentPage(), g.VerifyPage)
        with open(RCLONE_CONF) as f:
            conf = f.read()
        self.assertIn("username = me@proton.me", conf)
        self.assertNotIn("pass-ok", conf, "password stored obscured")

    def test_03_missing_second_password_goes_back_to_it(self):
        z = self.app.wizard
        z.currentPage().code.setText("123456")
        z.next()
        self.assertTrue(wait_until(lambda: z.currentPage() is z.account, 10))
        acc = z.account
        self.assertEqual(state(), "mailbox")
        self.assertTrue(acc.two.isChecked())
        self.assertFalse(acc.mailbox.isHidden())
        self.assertIs(acc.focus, acc.mailbox, "cursor goes to the second password")
        self.assertEqual(acc.email.text(), "me@proton.me", "email untouched")
        self.assertIn("second", acc.error.text().lower())
        shot(z, "asistente-pide-segunda-contrasena")

    def test_04_wrong_code_then_login(self):
        z = self.app.wizard
        z.account.mailbox.setText("mbox-ok")
        z.next()
        verify = z.currentPage()
        verify.code.setText("000000")
        z.next()
        self.assertIs(z.currentPage(), verify, "wrong code stays on the page")
        self.assertIn("2FA", verify.error.text())
        shot(z, "asistente-codigo-incorrecto")
        verify.code.setText("123456")
        z.next()
        self.assertIsInstance(z.currentPage(), g.FolderPage, f"{verify.error.text()} / state={state()}")
        self.assertEqual(state(), "ok")

    def test_05_default_folder_media_created_and_mounted(self):
        z = self.app.wizard
        folder = z.currentPage()
        self.assertEqual(folder.path.text(), MP)
        shot(z, "asistente-carpeta")
        z.next()
        self.assertIsInstance(z.currentPage(), g.DonePage, folder.error.text())
        self.assertTrue(mounted())
        self.assertEqual(os.stat(MP).st_uid, os.getuid(), "/media/ProtonDrive belongs to the user")
        with open(os.path.join(MP, "hello.txt")) as f:
            self.assertIn("hello from the fake drive", f.read())
        self.assertEqual(sh("systemctl", "--user", "is-enabled", "protux.service").stdout.strip(), "enabled")
        self.assertTrue(os.path.exists(g.AUTOSTART_PATH), "tray autostart created")
        shot(z, "asistente-listo")

    def test_06_main_window_after_wizard(self):
        app = self.app
        app.wizard.accept()
        self.assertTrue(wait_until(lambda: app.window.isVisible(), 5))
        self.assertTrue(wait_until(lambda: app.window.title.text() == g.STATE_LABELS["up"], 10))
        self.assertEqual(app.window.d["account"].text(), "me@proton.me")
        self.assertEqual(app.window.d["folder"].text(), MP)
        self.assertEqual(app.window.toggle_btn.text(), g.tr("Unmount"))
        self.assertTrue(app.window.open_btn.isEnabled())
        shot(app.window, "ventana-conectado")

    def test_07_help_menu_like_swangui(self):
        menus = {m.title(): m for m in (a.menu() for a in self.app.window.menuBar().actions()) if m}
        self.assertEqual(list(menus), [g.tr("&File"), g.tr("&Drive"), g.tr("&View"), g.tr("&Help")])
        items = [a.text() for a in menus[g.tr("&Help")].actions() if not a.isSeparator()]
        self.assertEqual(items, [g.tr(x) for x in (
            "Documentation", "Keyboard shortcuts", "What's new", "Report a bug…", "Send feedback…",
            "Copy system information", "Check for updates", "GitHub repository", "Donate…",
            "Third-party licenses", "About Protux")])
        info = g.system_info(self.app)
        self.assertNotIn("me@proton.me", info, "no account data in bug reports")
        self.assertNotIn(MP, info)

    def test_08_tray_menu(self):
        app = self.app
        app.update_view()
        texts = [a.text() for a in app.menu.actions() if not a.isSeparator()]
        for t in (g.STATE_LABELS["up"], g.tr("Unmount"), g.tr("Open folder"), g.tr("Show Protux"),
                  g.tr("Preferences…"), g.tr("Help"), g.tr("Quit")):
            self.assertIn(t, texts)

    def test_09_preferences(self):
        app = self.app
        p = g.PrefsDialog(app, app.window)
        self.assertTrue(p.auto_mount.isChecked())
        self.assertTrue(p.autostart.isChecked())
        self.assertEqual(p.mountpoint.text(), MP)
        shot(p, "preferencias")
        size = p.fields["VFS_CACHE_MAX_SIZE"][0]
        size.setText("3 gigas")
        p.save()
        self.assertFalse(p.error.isHidden(), "invalid value rejected")
        self.assertNotEqual(p.result(), 1)
        size.setText("3G")
        p.save()
        self.assertEqual(p.result(), 1)
        cfg = g.parse_kv(sh("protux", "__get-config").stdout)
        self.assertEqual(cfg["VFS_CACHE_MAX_SIZE"], "3G")

    def test_10_unmount_and_mount_from_window(self):
        app = self.app
        app.toggle_mount()
        self.assertTrue(wait_until(lambda: not mounted() and not app.busy, 30))
        self.assertTrue(wait_until(lambda: app.window.toggle_btn.text() == g.tr("Mount"), 10))
        app.toggle_mount()
        self.assertTrue(wait_until(lambda: mounted() and not app.busy, 30))

    def test_11_expired_session_and_login_dialog(self):
        app = self.app
        expire_session()
        sh("systemctl", "--user", "reset-failed", "protux.service")
        sh("protux", "start")
        self.assertTrue(wait_until(lambda: state() == "auth", 30))
        app.refresh(full=True)
        self.assertTrue(wait_until(lambda: app.window.title.text() == g.STATE_LABELS["error"], 10))
        self.assertFalse(app.window.login_btn.isHidden())
        shot(app.window, "ventana-sesion-caducada")
        d = g.LoginDialog(app, app.window)
        d.show()
        d.code.setText("000000")
        d.submit()
        self.assertFalse(mounted())
        self.assertIn("2FA", d.error.text())
        shot(d, "login-codigo-incorrecto")
        d.code.setText("123456")
        d.submit()
        self.assertTrue(mounted())
        self.assertEqual(d.result(), 1)

    def test_12_login_dialog_asks_for_wrong_second_password(self):
        app = self.app
        sh("protux", "__set-credentials", stdin="\n\nnope\n")
        expire_session()
        d = g.LoginDialog(app, app.window)
        d.show()
        d.code.setText("123456")
        d.submit()
        self.assertTrue(d.form.isRowVisible(3), "second password field shown")
        shot(d, "login-pide-segunda-contrasena")
        d.mailbox.setText("mbox-ok")
        d.code.setText("123456")
        d.submit()
        self.assertTrue(mounted())

    @classmethod
    def tearDownClass(cls):
        cls.app.timer.stop()
        cls.app.runner.shutdown()
        sh("protux", "stop")


if __name__ == "__main__":
    unittest.main(verbosity=2)
