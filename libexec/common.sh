#!/usr/bin/env bash

# This file is sourced by the service entry points, which consume the settings
# assigned by load_config.
# shellcheck disable=SC2034

SPICE_GUEST_TOOLS_NAME="spice-guest-tools"

log() {
  printf '%s: %s\n' "${SPICE_GUEST_TOOLS_NAME}" "$*" >&2
}

die() {
  log "$*"
  exit 1
}

trim() {
  local value=$1
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

unquote() {
  local value=$1
  if [[ ${value} == \"*\" && ${value} == *\" ]]; then
    value=${value:1:${#value}-2}
  fi
  printf '%s' "${value}"
}

config_path() {
  printf '%s/spice-guest-tools/config.toml' "${XDG_CONFIG_HOME:-${HOME}/.config}"
}

state_dir() {
  printf '%s/spice-guest-tools' "${XDG_STATE_HOME:-${HOME}/.local/state}"
}

runtime_dir() {
  [[ -n ${XDG_RUNTIME_DIR:-} ]] || die "XDG_RUNTIME_DIR is not set"
  printf '%s/spice-guest-tools' "${XDG_RUNTIME_DIR}"
}

validate_uint() {
  local name=$1 value=$2 minimum=$3 maximum=$4
  [[ ${value} =~ ^[0-9]+$ ]] || die "${name} must be an integer"
  ((value >= minimum && value <= maximum)) ||
    die "${name} must be between ${minimum} and ${maximum}"
}

validate_bool() {
  local name=$1 value=$2
  [[ ${value} == true || ${value} == false ]] || die "${name} must be true or false"
}

validate_scale() {
  local name=$1 value=$2
  [[ ${value} =~ ^[0-9]+([.][0-9]+)?$ ]] || die "${name} must be a number"
  awk -v value="${value}" 'BEGIN { exit !(value >= 0.5 && value <= 4) }' ||
    die "${name} must be between 0.5 and 4"
}

parse_clipboard_derived_formats() {
  local value compact
  value=$1
  compact=${value//[[:space:]]/}
  case ${compact} in
    '[]') printf '%s' '' ;;
    '["image/png"]') printf '%s' 'image/png' ;;
    *) die 'clipboard.derived_formats must be [] or ["image/png"]' ;;
  esac
}

load_config() {
  INTEGRATION_BACKEND=auto
  DISPLAY_ENABLED=true
  DISPLAY_OUTPUT=auto
  DISPLAY_SCALE_POLICY=preserve
  DISPLAY_SCALE_THRESHOLD_HEIGHT=1800
  DISPLAY_SCALE_BELOW_THRESHOLD=1
  DISPLAY_SCALE_AT_OR_ABOVE_THRESHOLD=2
  CLIPBOARD_ENABLED=true
  CLIPBOARD_MAX_BYTES=104857600
  CLIPBOARD_MAX_PIXELS=67108864
  CLIPBOARD_DERIVED_FORMATS=image/png

  local file=${SPICE_GUEST_TOOLS_CONFIG:-$(config_path)}
  local section="" line key value setting

  if [[ -f ${file} ]]; then
    while IFS= read -r line || [[ -n ${line} ]]; do
      line=$(trim "${line}")
      [[ -z ${line} || ${line} == \#* ]] && continue

      if [[ ${line} =~ ^\[([a-z]+)\]$ ]]; then
        section=${BASH_REMATCH[1]}
        continue
      fi

      [[ ${line} == *=* ]] || die "invalid config line: ${line}"
      key=$(trim "${line%%=*}")
      value=$(unquote "$(trim "${line#*=}")")
      setting="${section}.${key}"

      case ${setting} in
        integration.backend) INTEGRATION_BACKEND=${value} ;;
        display.enabled) DISPLAY_ENABLED=${value} ;;
        display.output) DISPLAY_OUTPUT=${value} ;;
        display.scale_policy) DISPLAY_SCALE_POLICY=${value} ;;
        display.scale_threshold_height) DISPLAY_SCALE_THRESHOLD_HEIGHT=${value} ;;
        display.scale_below_threshold) DISPLAY_SCALE_BELOW_THRESHOLD=${value} ;;
        display.scale_at_or_above_threshold) DISPLAY_SCALE_AT_OR_ABOVE_THRESHOLD=${value} ;;
        clipboard.enabled) CLIPBOARD_ENABLED=${value} ;;
        clipboard.max_bytes) CLIPBOARD_MAX_BYTES=${value} ;;
        clipboard.max_pixels) CLIPBOARD_MAX_PIXELS=${value} ;;
        clipboard.derived_formats)
          CLIPBOARD_DERIVED_FORMATS=$(parse_clipboard_derived_formats "${value}")
          ;;
        *) die "unknown config setting: ${setting}" ;;
      esac
    done <"${file}"
  fi

  validate_bool display.enabled "${DISPLAY_ENABLED}"
  validate_bool clipboard.enabled "${CLIPBOARD_ENABLED}"
  [[ ${DISPLAY_OUTPUT} == auto || ${DISPLAY_OUTPUT} =~ ^[A-Za-z0-9._-]+$ ]] ||
    die "display.output contains unsupported characters"
  [[ ${DISPLAY_SCALE_POLICY} == preserve || ${DISPLAY_SCALE_POLICY} == height-threshold ]] ||
    die "display.scale_policy must be preserve or height-threshold"
  validate_uint display.scale_threshold_height "${DISPLAY_SCALE_THRESHOLD_HEIGHT}" 480 8192
  validate_scale display.scale_below_threshold "${DISPLAY_SCALE_BELOW_THRESHOLD}"
  validate_scale display.scale_at_or_above_threshold "${DISPLAY_SCALE_AT_OR_ABOVE_THRESHOLD}"
  validate_uint clipboard.max_bytes "${CLIPBOARD_MAX_BYTES}" 1 1073741824
  validate_uint clipboard.max_pixels "${CLIPBOARD_MAX_PIXELS}" 1 268435456
  [[ ${INTEGRATION_BACKEND} == auto ||
    ${INTEGRATION_BACKEND} =~ ^[a-z0-9][a-z0-9-]*$ ]] ||
    die "integration.backend contains unsupported characters"
}

backend_contract_is_valid() {
  local function_name
  for function_name in \
    backend_probe backend_require_commands backend_config_file \
    backend_snapshot_config backend_configure backend_restore_config \
    backend_remove_integration backend_reload backend_integration_is_installed \
    backend_detect_outputs backend_detect_any_output backend_detect_refresh_rate \
    backend_apply_monitor_layout backend_config_is_clean backend_status; do
    declare -F "${function_name}" >/dev/null || return 1
  done
}

load_backend() {
  [[ -z ${SPICE_GUEST_TOOLS_BACKEND_LOADED:-} ]] || return 0
  local common_dir backend_name backend_file candidate matched=0
  common_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  backend_name=${INTEGRATION_BACKEND:-auto}
  if [[ ${backend_name} == auto ]]; then
    for candidate in "${common_dir}"/backends/*.sh; do
      [[ -f ${candidate} ]] || continue
      unset -f backend_probe 2>/dev/null || true
      # shellcheck disable=SC1090
      source "${candidate}"
      if declare -F backend_probe >/dev/null && backend_probe; then
        backend_file=${candidate}
        backend_name=$(basename -- "${candidate}" .sh)
        matched=$((matched + 1))
      fi
    done
    ((matched > 0)) || die "no integration backend supports this session"
    ((matched == 1)) ||
      die "multiple integration backends match; set integration.backend explicitly"
    # Restore the selected implementation if a later candidate did not match.
    # shellcheck disable=SC1090
    source "${backend_file}"
  else
    backend_file="${common_dir}/backends/${backend_name}.sh"
    [[ -f ${backend_file} ]] || die "integration backend is unavailable: ${backend_name}"
    # Backend names are validated by load_config and resolve only below our library root.
    # shellcheck disable=SC1090
    source "${backend_file}"
    backend_probe || die "integration backend cannot run in this session: ${backend_name}"
  fi
  backend_contract_is_valid || die "integration backend has an invalid contract: ${backend_name}"
  # Consumed by callers after this library dynamically sources the backend.
  # shellcheck disable=SC2034
  BACKEND_NAME=${backend_name}
  SPICE_GUEST_TOOLS_BACKEND_LOADED=true
}

require_commands() {
  local command_name missing=0
  for command_name in "$@"; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
      log "missing command: ${command_name}"
      missing=1
    fi
  done
  ((missing == 0))
}

active_local_wayland_session_for_user() {
  local expected_uid=${1:-${UID}} loginctl_command=${2:-loginctl}
  local sessions session_id listed_uid property value
  local session_uid session_type session_class session_active session_remote session_seat
  [[ ${expected_uid} =~ ^[1-9][0-9]*$ ]] || return 1

  sessions=$("${loginctl_command}" list-sessions --no-legend 2>/dev/null) || return 1
  while read -r session_id listed_uid _; do
    [[ ${session_id} =~ ^[A-Za-z0-9._-]+$ ]] || continue
    [[ ${listed_uid} == "${expected_uid}" ]] || continue

    session_uid=""
    session_type=""
    session_class=""
    session_active=""
    session_remote=""
    session_seat=""
    while IFS='=' read -r property value; do
      case ${property} in
        User) session_uid=${value} ;;
        Type) session_type=${value} ;;
        Class) session_class=${value} ;;
        Active) session_active=${value} ;;
        Remote) session_remote=${value} ;;
        Seat) session_seat=${value} ;;
      esac
    done < <("${loginctl_command}" show-session "${session_id}" \
      --property=User --property=Type --property=Class --property=Active \
      --property=Remote --property=Seat 2>/dev/null)

    if [[ ${session_uid} == "${expected_uid}" && ${session_type} == wayland &&
      ${session_class} == user && ${session_active} == yes &&
      ${session_remote} == no && ${session_seat} == seat0 ]]; then
      return 0
    fi
  done <<<"${sessions}"
  return 1
}

write_display_state() {
  local layout_file=$1 directory state_file temporary
  local monitor_index output modeline logical_x logical_y scale
  directory=$(state_dir)
  state_file="${directory}/display.state"
  mkdir -p -- "${directory}"
  chmod 700 "${directory}"
  temporary=$(mktemp "${directory}/display.state.XXXXXX")
  chmod 600 "${temporary}"
  printf 'version=4\n' >"${temporary}"
  while IFS=$'\t' read -r monitor_index output modeline logical_x logical_y scale; do
    printf 'monitor.%s.output=%s\n' "${monitor_index}" "${output}"
    printf 'monitor.%s.modeline=%s\n' "${monitor_index}" "${modeline}"
    printf 'monitor.%s.x=%s\n' "${monitor_index}" "${logical_x}"
    printf 'monitor.%s.y=%s\n' "${monitor_index}" "${logical_y}"
    printf 'monitor.%s.scale=%s\n' "${monitor_index}" "${scale}"
  done <"${layout_file}" >>"${temporary}"
  mv -f -- "${temporary}" "${state_file}"
}

generate_modeline() {
  local width=$1 height=$2 refresh_rate=$3 cvt_output
  cvt_output=$(cvt -r "${width}" "${height}" "${refresh_rate}" 2>/dev/null) || true
  if [[ ${cvt_output} != *Modeline* ]]; then
    cvt_output=$(cvt "${width}" "${height}" "${refresh_rate}" 2>/dev/null) || true
  fi
  [[ ${cvt_output} == *Modeline* ]] || return 1
  awk '/^Modeline / {
    sub(/^Modeline "[^"]+"[[:space:]]+/, "")
    gsub(/[[:space:]]+/, " ")
    print
    exit
  }' <<<"${cvt_output}"
}

parse_spice_monitor_stream() {
  local host_pending=0 expected=0 seen=0 line
  local monitor_index width height position_x position_y
  local layout=""
  local -A monitor_records=()
  while IFS= read -r line; do
    if [[ ${line} =~ Monitors\ config\ from\ guest:\ 16, ]]; then
      host_pending=1
      expected=0
      seen=0
      monitor_records=()
    elif [[ ${line} =~ Monitors\ config\ from\ guest: ]]; then
      host_pending=0
      expected=0
      seen=0
      monitor_records=()
      layout=""
    elif ((host_pending)) &&
      [[ ${line} =~ Monitors\ config\ after\ zeroing:\ ([0-9]+), ]]; then
      expected=${BASH_REMATCH[1]}
      seen=0
      monitor_records=()
      if ((expected < 1 || expected > 16)); then
        host_pending=0
        expected=0
      fi
    elif ((host_pending && expected > 0)) &&
      [[ ${line} =~ monitor\ ([0-9]+),\ config\ ([0-9]+)x([0-9]+)\+([+-]?[0-9]+)\+([+-]?[0-9]+)[[:space:]]*$ ]]; then
      monitor_index=${BASH_REMATCH[1]}
      width=${BASH_REMATCH[2]}
      height=${BASH_REMATCH[3]}
      position_x=${BASH_REMATCH[4]}
      position_y=${BASH_REMATCH[5]}
      if ((monitor_index <= 15)); then
        if [[ -z ${monitor_records[${monitor_index}]:-} ]]; then
          seen=$((seen + 1))
        fi
        monitor_records[${monitor_index}]="${monitor_index},${width},${height},${position_x},${position_y}"
        if ((seen == expected)); then
          for ((monitor_index = 0; monitor_index < expected; monitor_index++)); do
            if [[ -z ${monitor_records[${monitor_index}]:-} ]]; then
              host_pending=0
              expected=0
              seen=0
              monitor_records=()
              continue 2
            fi
          done
          layout=""
          for monitor_index in {0..15}; do
            if [[ -n ${monitor_records[${monitor_index}]:-} ]]; then
              if [[ -n ${layout} ]]; then
                layout+=';'
              fi
              layout+="${monitor_records[${monitor_index}]}"
            fi
          done
          printf '%s\n' "${layout}"
          host_pending=0
          expected=0
          seen=0
          monitor_records=()
          layout=""
        fi
      fi
    elif ((host_pending && expected > 0)) &&
      [[ ${line} == *monitor*config* ]]; then
      host_pending=0
      expected=0
      seen=0
      monitor_records=()
    fi
  done
}
