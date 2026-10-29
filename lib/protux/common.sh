# shellcheck shell=bash
# Shared code for protux. Sourced by bin/protux; not meant to be run.

PTX_VERSION=0.1.0

: "${XDG_CONFIG_HOME:=$HOME/.config}"
: "${XDG_CACHE_HOME:=$HOME/.cache}"
: "${XDG_STATE_HOME:=$HOME/.local/state}"
: "${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"

PTX_CONFIG_FILE=${PROTUX_CONFIG:-$XDG_CONFIG_HOME/protux/config}
PTX_HOOKS_DIR=$XDG_CONFIG_HOME/protux/hooks
PTX_STATE_DIR=$XDG_STATE_HOME/protux
PTX_STATE_FILE=$PTX_STATE_DIR/state
PTX_ERRLOG=$PTX_STATE_DIR/last-errors.log

PTX_UNIT=protux.service
PTX_RETRY_UNIT=protux-retry
PTX_PROMPT_UNIT=protux-2fa-prompt

# ---------------------------------------------------------------- i18n

declare -A PTX_TR=()
case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in
  es*) [ -r "$PTX_LIB/locale/es.sh" ] && . "$PTX_LIB/locale/es.sh" ;;
esac

# t "format" args...: translated printf
t() {
  local fmt=${PTX_TR[$1]:-$1}
  shift
  # shellcheck disable=SC2059
  printf -- "$fmt" "$@"
}

say() { t "$@"; echo; }
warn() { { t "$@"; echo; } >&2; }
die() { warn "$@"; exit 1; }

# ---------------------------------------------------------------- config

ptx_defaults() {
  REMOTE=ProtonDrive
  MOUNTPOINT=/media/ProtonDrive
  RCLONE=rclone
  RCLONE_CONFIG=$XDG_CONFIG_HOME/rclone/rclone.conf
  KEYRING=auto
  KEYRING_ATTRS="application protux purpose rclone-config"
  CACHE_DIR=$XDG_CACHE_HOME/protux
  VFS_CACHE_MODE=writes
  VFS_CACHE_MAX_SIZE=10G
  VFS_CACHE_MAX_AGE=24h
  VFS_WRITE_BACK=5s
  DIR_CACHE_TIME=30s
  BUFFER_SIZE=16M
  UMASK=077
  ALLOW_OTHER=no
  LOG_LEVEL=INFO
  EXTRA_ARGS=()
  NET_HOST=drive-api.proton.me
  NET_TIMEOUT=180
  KEYRING_TIMEOUT=240
  RETRY_429_AFTER=65min
  HOOK_TIMEOUT=120
  GUI_WAIT=3600
  FILE_MANAGER=
}

ptx_load_config() {
  ptx_defaults
  if [ -r "$PTX_CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    . "$PTX_CONFIG_FILE"
  fi
}

ptx_config_encrypted() {
  [ -r "$RCLONE_CONFIG" ] && head -n 1 "$RCLONE_CONFIG" | grep -q '^# Encrypted rclone configuration File'
}

ptx_use_keyring() {
  case "$KEYRING" in
    yes) return 0 ;;
    no) return 1 ;;
    *) ptx_config_encrypted && command -v secret-tool >/dev/null ;;
  esac
}

# rclone with our config file and, if needed, the config password from the keyring
ptx_rclone() {
  local a=(--config "$RCLONE_CONFIG")
  ptx_use_keyring && a+=(--password-command "$PTX_SELF __config-pass")
  "$RCLONE" "${a[@]}" "$@"
}

ptx_keyring_lookup() {
  # shellcheck disable=SC2086  # attribute pairs are meant to split
  secret-tool lookup $KEYRING_ATTRS
}

ptx_mounted() { mountpoint -q "$MOUNTPOINT" 2>/dev/null; }

ptx_fusermount() {
  if command -v fusermount3 >/dev/null; then fusermount3 "$@"; else fusermount "$@"; fi
}

# ---------------------------------------------------------------- state
# The state file has three lines: state (ok|auth|ratelimit|error), epoch, message.

ptx_state_set() {
  mkdir -p "$PTX_STATE_DIR"
  printf '%s\n%s\n%s\n' "$1" "$(date +%s)" "${2:-}" >"$PTX_STATE_FILE"
}

# Sets PTX_STATE, PTX_STATE_TIME and PTX_STATE_MSG
ptx_state_get() {
  PTX_STATE=unknown PTX_STATE_TIME=0 PTX_STATE_MSG=
  [ -r "$PTX_STATE_FILE" ] || return 0
  { read -r PTX_STATE; read -r PTX_STATE_TIME; read -r PTX_STATE_MSG; } <"$PTX_STATE_FILE"
}

# Map rclone's error output (a file) to a state:
#   auth       2FA code needed or wrong / session expired
#   ratelimit  Proton is refusing logins for a while (HTTP 429)
#   password   wrong account password
#   mailbox    two-password account: mailbox password missing or wrong
#   captcha    Proton wants a human verification rclone can't do
#   config     the rclone config password is wrong
#   error      anything else
# Prints "state<TAB>message".
ptx_classify() {
  local last state
  last=$(tail -n 40 "$1" 2>/dev/null)
  if grep -qiE '\b429\b|Too many (recent|requests)|APP_REQUEST_TOO_MANY' <<<"$last"; then state=ratelimit
  elif grep -qiE 'human verification|captcha' <<<"$last"; then state=captcha
  elif grep -qiE 'decrypt configuration' <<<"$last"; then state=config
  elif grep -qiE 'requires a mailbox password|decrypt mailbox password' <<<"$last"; then state=mailbox
  elif grep -qiE 'Incorrect login credentials|wrong password|incorrect password' <<<"$last"; then state=password
  elif grep -qiE 'requires a 2FA code|2FA code (is )?required|incorrect (2FA )?code|invalid 2FA|2FA codes can.t be blank|session has expired|reauthenticate|refresh token|invalid access token' <<<"$last"; then state=auth
  else
    printf 'error\t%s\n' "$(grep -E 'ERROR|CRITICAL|Fatal' <<<"$last" | tail -n 1 | sed -E 's/^.*(ERROR|CRITICAL|Fatal error)[^:]*: //' | cut -c1-200)"
    return
  fi
  printf '%s\t%s\n' "$state" "$(ptx_state_message "$state")"
}

ptx_state_message() {
  case "$1" in
    auth) t 'The Proton session expired; a new 2FA login is needed' ;;
    ratelimit) t 'Proton is limiting login attempts (HTTP 429)' ;;
    password) t 'Proton rejected the password' ;;
    mailbox) t 'This account needs its second (mailbox) password' ;;
    captcha) t 'Proton asks for a human verification (CAPTCHA); log in once at proton.me from this network and try again' ;;
    config) t 'Wrong rclone config password (protux keyring set)' ;;
  esac
}

# Exit codes for each state; protux.service doesn't restart on any of them, because every
# restart is another login and repeated logins get the account blocked
ptx_state_exit() {
  case "$1" in
    ok) echo 0 ;;
    auth) echo 10 ;;
    ratelimit) echo 11 ;;
    password) echo 12 ;;
    mailbox) echo 13 ;;
    captcha) echo 14 ;;
    config) echo 15 ;;
    *) echo 1 ;;
  esac
}

# ---------------------------------------------------------------- desktop session

# Make DISPLAY/WAYLAND_DISPLAY/DBUS_SESSION_BUS_ADDRESS usable from a systemd unit
ptx_import_gui_env() {
  local line sid type display
  if [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    while IFS= read -r line; do
      case "$line" in
        DISPLAY=* | WAYLAND_DISPLAY=* | XAUTHORITY=* | DBUS_SESSION_BUS_ADDRESS=*) export "${line?}" ;;
      esac
    done < <(systemctl --user show-environment 2>/dev/null)
  fi
  if [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    # Desktops that don't import their environment into systemd (XFCE, for instance)
    for sid in $(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$USER" '$3 == u {print $1}'); do
      type=$(loginctl show-session "$sid" -p Type --value 2>/dev/null)
      display=$(loginctl show-session "$sid" -p Display --value 2>/dev/null)
      if [ "$type" = x11 ] && [ -n "$display" ]; then
        export DISPLAY=$display
        break
      fi
      if [ "$type" = wayland ]; then
        for display in "$XDG_RUNTIME_DIR"/wayland-[0-9]; do
          [ -S "$display" ] && export WAYLAND_DISPLAY=${display##*/} && break 2
        done
      fi
    done
  fi
  export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
  [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]
}

# With lingering the user manager starts at boot, long before anyone logs in
ptx_wait_gui() {
  local i
  for ((i = 0; i <= GUI_WAIT / 10; i++)); do
    ptx_import_gui_env && return 0
    ((i < GUI_WAIT / 10)) && sleep 10
  done
  return 1
}

ptx_notify() { # urgency title body
  command -v notify-send >/dev/null || return 0
  notify-send -a "Protux" -i folder-remote -u "$1" "$2" "$3" 2>/dev/null || true
}

ptx_notify_has_actions() {
  notify-send --help 2>&1 | grep -q -- '--action'
}

ptx_has_app() { command -v protux-gui >/dev/null; }

ptx_gui_tool() {
  if command -v zenity >/dev/null; then echo zenity
  elif command -v kdialog >/dev/null; then echo kdialog
  fi
}
