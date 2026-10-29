#!/bin/bash
# End-to-end tests of protux against the fake Proton account. Run as a normal user with a
# systemd user session, after `make install`.
set -u
PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); printf '  \e[32mPASS\e[0m %s\n' "$1"; }
ko() { FAIL=$((FAIL + 1)); printf '  \e[31mFAIL\e[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else ko "$d" "$*"; fi; }
expect_rc() { # description expected-rc stdin args...
  local d=$1 want=$2 in=$3 rc err; shift 3
  err=$(printf '%s' "$in" | protux "$@" 2>&1 >/dev/null); rc=$?
  [ "$rc" = "$want" ] && ok "$d (exit $rc)" || ko "$d" "expected exit $want, got $rc: $err"
}
wait_for() { local i; for ((i = 0; i < ${2:-30}; i++)); do eval "$1" && return 0; sleep 1; done; return 1; }
unit_prop() { systemctl --user show protux.service -p "$1" --value; }
force() { printf '%s' "$1" >"$HOME/.fake-drive/.force"; }

export LANG=C
mkdir -p ~/.config/protux ~/.fake-drive
echo "hello from the fake drive" >~/.fake-drive/hello.txt
: >~/.fake-drive/.force
cat >~/.config/protux/config <<CFG
RCLONE=/usr/local/bin/fake-proton-rclone
RCLONE_CONFIG=$HOME/.config/rclone/rclone.conf
KEYRING=no
NET_HOST=localhost
GUI_WAIT=0
RETRY_429_AFTER=10min
CFG

echo "== basics"
check "version" protux version
check "help" protux help
check "unknown command fails" bash -c '! protux bogus'
LANG=es_ES.UTF-8 protux help | grep -q 'Órdenes' && ok "Spanish help" || ko "Spanish help"

echo "== credentials and login (fake account: pass-ok / mbox-ok / 123456)"
expect_rc "create without password is refused" 2 $'me@proton.me\n\n\n' __set-credentials
expect_rc "create remote with a wrong password" 0 $'me@proton.me\nwrong\n\n' __set-credentials
protux __info | grep -qx 'remote_exists=1' && ok "remote exists" || ko "remote exists"
protux __info | grep -qx 'username=me@proton.me' && ok "username reported" || ko "username reported"
grep -q 'wrong' ~/.config/rclone/rclone.conf && ko "password stored in clear" || ok "password not stored in clear"
expect_rc "wrong password -> 12" 12 $'123456\n' __login
[ "$(head -n1 ~/.local/state/protux/state)" = password ] && ok "state=password" || ko "state=password"
expect_rc "fix password" 0 $'\npass-ok\n\n' __set-credentials
expect_rc "no 2FA code -> 10" 10 $'\n' __login
expect_rc "wrong 2FA code -> 10" 10 $'000000\n' __login
expect_rc "missing mailbox password -> 13" 13 $'123456\n' __login
expect_rc "set wrong mailbox password" 0 $'\n\nnope\n' __set-credentials
protux __info | grep -qx 'mailbox=1' && ok "mailbox reported" || ko "mailbox reported"
expect_rc "wrong mailbox password -> 13" 13 $'123456\n' __login
expect_rc "set right mailbox password" 0 $'\n\nmbox-ok\n' __set-credentials
expect_rc "full login -> 0" 0 $'123456\n' __login
[ "$(head -n1 ~/.local/state/protux/state)" = ok ] && ok "state=ok" || ko "state=ok"
expect_rc "saved session, no code needed" 0 $'\n' __login

echo "== settings"
check "set-config" protux __set-config VFS_CACHE_MAX_SIZE 2G MOUNTPOINT "$HOME/Proton Drive"
protux __get-config | grep -qx 'VFS_CACHE_MAX_SIZE=2G' && ok "get-config roundtrip" || ko "get-config roundtrip"
protux __get-config | grep -qx "MOUNTPOINT=$HOME/Proton Drive" && ok "path with spaces" || ko "path with spaces"
check "EXTRA_ARGS with quotes" protux __set-config EXTRA_ARGS "--transfers=2 --user-agent='a b'"
protux __get-config | grep -q "^EXTRA_ARGS='--transfers=2' '--user-agent=a b'" && ok "EXTRA_ARGS roundtrip" || ko "EXTRA_ARGS roundtrip" "$(protux __get-config | grep EXTRA)"
check "unknown setting refused" bash -c '! protux __set-config EVIL "x"'
check "broken EXTRA_ARGS refused" bash -c '! protux __set-config EXTRA_ARGS "(("'
check "config still valid bash" bash -n ~/.config/protux/config
protux __set-config EXTRA_ARGS "" >/dev/null

echo "== mount through systemd"
check "enable" protux enable
[ "$(systemctl --user is-enabled protux.service)" = enabled ] && ok "unit enabled" || ko "unit enabled"
check "start" protux start
check "mounted" mountpoint -q "$HOME/Proton Drive"
grep -q "hello from the fake drive" "$HOME/Proton Drive/hello.txt" 2>/dev/null && ok "file readable" || ko "file readable"
echo "written through the mount" >"$HOME/Proton Drive/new.txt" && wait_for '[ -f ~/.fake-drive/new.txt ]' 15 && ok "file written back" || ko "file written back"
[ "$(unit_prop ActiveState)" = active ] && ok "unit active (Type=notify)" || ko "unit active" "$(unit_prop ActiveState)"
protux status | grep -q '(mounted)' && ok "status says mounted" || ko "status says mounted"
check "stop" protux stop
check "unmounted" bash -c "! mountpoint -q '$HOME/Proton Drive'"

echo "== expired session: no restart loop, alert runs"
sed -i 's/^client_uid = .*/client_uid = /' ~/.config/rclone/rclone.conf
protux start >/dev/null 2>&1
wait_for '[ "$(unit_prop ActiveState)" = failed ]' 30 && ok "unit failed" || ko "unit failed" "$(unit_prop ActiveState)"
[ "$(unit_prop ExecMainStatus)" = 10 ] && ok "exit status 10" || ko "exit status 10" "$(unit_prop ExecMainStatus)"
sleep 25 # RestartSec=20s: a restart would have happened by now
[ "$(unit_prop NRestarts)" = 0 ] && ok "not restarted" || ko "not restarted" "NRestarts=$(unit_prop NRestarts)"
wait_for 'journalctl --user -u protux-alert.service -q --no-pager | grep -q .' 15 && ok "alert unit ran" || ko "alert unit ran"
[ "$(head -n1 ~/.local/state/protux/state)" = auth ] && ok "state=auth" || ko "state=auth"
printf '123456\n' | protux __login >/dev/null 2>&1 && protux start >/dev/null && mountpoint -q "$HOME/Proton Drive" \
  && ok "re-login and remount" || ko "re-login and remount"
protux stop

echo "== rate limit: no restart, retry timer scheduled"
sed -i 's/^client_uid = .*/client_uid = /' ~/.config/rclone/rclone.conf
force 429
systemctl --user reset-failed protux.service
protux start >/dev/null 2>&1
wait_for '[ "$(unit_prop ActiveState)" = failed ]' 30 && ok "unit failed" || ko "unit failed"
[ "$(unit_prop ExecMainStatus)" = 11 ] && ok "exit status 11" || ko "exit status 11" "$(unit_prop ExecMainStatus)"
wait_for 'systemctl --user is-active -q protux-retry.timer' 15 && ok "retry timer scheduled" || ko "retry timer scheduled"
expect_rc "login while limited -> 11" 11 $'123456\n' __login
systemctl --user is-active -q protux-retry.timer && ko "login cancels the retry timer" || ok "login cancels the retry timer"
force captcha
expect_rc "captcha -> 14" 14 $'123456\n' __login
force ""

echo "== doctor"
protux doctor >/tmp/doctor.txt 2>&1
grep -q 'Remote ProtonDrive: found' /tmp/doctor.txt && ok "doctor finds the remote" || ko "doctor finds the remote" "$(cat /tmp/doctor.txt)"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
