#!/usr/bin/env bash

# Desktop backend contract for Omarchy's Hyprland Lua monitor configuration.

backend_probe() {
  command -v hyprctl >/dev/null 2>&1 &&
    [[ -f ${XDG_CONFIG_HOME:-${HOME}/.config}/hypr/monitors.lua ]]
}

backend_require_commands() {
  require_commands hyprctl jq awk cmp install
}

backend_config_file() {
  printf '%s/hypr/monitors.lua\n' "${XDG_CONFIG_HOME:-${HOME}/.config}"
}

backend_remove_integration() {
  local monitors_file temporary
  monitors_file=$(backend_config_file)
  [[ -f ${monitors_file} ]] || return 0
  temporary=$(mktemp "$(dirname -- "${monitors_file}")/monitors.lua.XXXXXX")
  awk '
    $0 == "-- BEGIN spice-guest-tools managed mode" { managed = 1; next }
    $0 == "-- END spice-guest-tools managed mode" { managed = 0; next }
    !managed { print }
  ' "${monitors_file}" >"${temporary}"
  if cmp -s "${temporary}" "${monitors_file}"; then
    rm -f -- "${temporary}"
  else
    chmod --reference="${monitors_file}" "${temporary}"
    mv -f -- "${temporary}" "${monitors_file}"
  fi
}

backend_ensure_integration() {
  local monitors_file managed_file temporary begin_count end_count
  monitors_file=$(backend_config_file)
  managed_file=$(payload_file backends/omarchy-hyprland/managed-monitor.lua)
  begin_count=$(grep -Fc -- '-- BEGIN spice-guest-tools managed mode' \
    "${monitors_file}" || true)
  end_count=$(grep -Fc -- '-- END spice-guest-tools managed mode' \
    "${monitors_file}" || true)
  if [[ ${begin_count} -gt 1 || ${end_count} -gt 1 || ${begin_count} != "${end_count}" ]]; then
    die "managed monitor block is malformed in ${monitors_file}"
  fi

  temporary=$(mktemp "$(dirname -- "${monitors_file}")/monitors.lua.XXXXXX")
  if ! awk -v managed_file="${managed_file}" '
    {
      lines[NR] = $0
      if ($0 == "-- BEGIN spice-guest-tools managed mode") managed_begin = NR
      if ($0 == "-- END spice-guest-tools managed mode") managed_end = NR
    }
    END {
      if (managed_begin) {
        while (managed_begin > 1 && lines[managed_begin - 1] ~ /^[[:space:]]*$/) {
          managed_begin--
        }
        while (managed_end < NR && lines[managed_end + 1] ~ /^[[:space:]]*$/) {
          managed_end++
        }
      }

      for (line_number = 1; line_number <= NR; line_number++) {
        if (managed_begin && line_number >= managed_begin && line_number <= managed_end) {
          continue
        }
        print lines[line_number]
        active = lines[line_number]
        sub(/^[[:space:]]*/, "", active)
        if (!inserted && !monitor_rule && active !~ /^--/ && active ~ /^hl\.monitor\(/) {
          monitor_rule = 1
        }
        if (monitor_rule && active ~ /\)[[:space:]]*$/) {
          print ""
          while ((getline managed_line < managed_file) > 0) print managed_line
          close(managed_file)
          print ""
          inserted = 1
          monitor_rule = 0
        }
      }
      if (!inserted) exit 2
    }
  ' "${monitors_file}" >"${temporary}"; then
    rm -f -- "${temporary}"
    die "could not find an active hl.monitor rule in ${monitors_file}"
  fi
  if cmp -s "${temporary}" "${monitors_file}"; then
    rm -f -- "${temporary}"
    BACKEND_CONFIG_CHANGED=false
  else
    backup_file "${monitors_file}"
    chmod --reference="${monitors_file}" "${temporary}"
    mv -f -- "${temporary}" "${monitors_file}"
    BACKEND_CONFIG_CHANGED=true
  fi
}

backend_configure() {
  local monitors_file snapshot=$1
  monitors_file=$(backend_config_file)
  backend_ensure_integration
  if [[ ${BACKEND_CONFIG_CHANGED} == true ]] && ! hyprctl reload >/dev/null; then
    log "Hyprland rejected the integration"
    backend_restore_config "${snapshot}"
    return 1
  fi
  backend_config_is_clean || {
    hyprctl configerrors >&2
    backend_restore_config "${snapshot}"
    die "Hyprland reports configuration errors"
  }
}

backend_snapshot_config() {
  local destination=$1 monitors_file
  monitors_file=$(backend_config_file)
  cp -a -- "${monitors_file}" "${destination}"
}

backend_restore_config() {
  local snapshot=$1 monitors_file
  monitors_file=$(backend_config_file)
  cp -a -- "${snapshot}" "${monitors_file}"
  rm -f -- "${snapshot}"
  hyprctl reload >/dev/null 2>&1 || true
}

backend_reload() {
  hyprctl reload >/dev/null 2>&1 || true
}

backend_integration_is_installed() {
  local monitors_file
  monitors_file=$(backend_config_file)
  [[ -f ${monitors_file} ]] &&
    grep -Fq -- '-- BEGIN spice-guest-tools managed mode' "${monitors_file}"
}

backend_detect_outputs() {
  local expected_count=$1 monitors_json outputs output actual_count
  validate_uint display.monitor_count "${expected_count}" 1 16

  if [[ ${DISPLAY_OUTPUT} != auto ]]; then
    ((expected_count == 1)) ||
      die "display.output can override only a single-monitor layout"
    printf '%s\n' "${DISPLAY_OUTPUT}"
    return
  fi

  monitors_json=$(hyprctl -j monitors all 2>/dev/null) ||
    die "could not query Hyprland monitors"
  outputs=$(jq -r --argjson expected "${expected_count}" '
    ([.[] | select(.disabled != true)]) as $active |
    if ($active | length) == $expected then
      $active | sort_by(.id, .name)[] | .name
    else
      empty
    end
  ' <<<"${monitors_json}") || outputs=""

  actual_count=0
  while IFS= read -r output; do
    [[ -z ${output} ]] && continue
    [[ ${output} =~ ^[A-Za-z0-9._-]+$ ]] ||
      die "Hyprland returned an invalid output name"
    actual_count=$((actual_count + 1))
  done <<<"${outputs}"
  ((actual_count == expected_count)) ||
    die "could not match ${expected_count} SPICE monitors to active outputs"
  printf '%s\n' "${outputs}"
}

backend_detect_any_output() {
  if [[ ${DISPLAY_OUTPUT} != auto ]]; then
    printf '%s\n' "${DISPLAY_OUTPUT}"
    return
  fi

  local monitors_json output
  monitors_json=$(hyprctl -j monitors all 2>/dev/null) ||
    die "could not query Hyprland monitors"
  output=$(jq -r '
    [.[] | select(.disabled != true)] |
    if length == 1 then .[0].name else empty end
  ' <<<"${monitors_json}")
  [[ ${output} =~ ^[A-Za-z0-9._-]+$ ]] ||
    die "could not unambiguously detect an active SPICE-managed display"
  printf '%s\n' "${output}"
}

backend_detect_refresh_rate() {
  local output=$1 monitors_json refresh_rate rounded_rate
  monitors_json=$(hyprctl -j monitors all 2>/dev/null) || monitors_json=""
  if [[ -n ${monitors_json} ]]; then
    refresh_rate=$(jq -r --arg output "${output}" '
      first(.[] | select(.name == $output) | .refreshRate) // empty
    ' <<<"${monitors_json}" 2>/dev/null) || refresh_rate=""
  else
    refresh_rate=""
  fi

  if [[ ${refresh_rate} =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    rounded_rate=$(awk -v value="${refresh_rate}" 'BEGIN { print int(value + 0.5) }')
    if ((rounded_rate >= 24 && rounded_rate <= 240)); then
      printf '%s\n' "${rounded_rate}"
      return
    fi
  fi

  log "could not derive the refresh rate for ${output}; using 60Hz"
  printf '%s\n' 60
}

backend_resolve_monitor_scale() {
  local modeline=$1 current_scale=$2 width height target_scale
  read -r width height < <(awk '{ if (NF >= 6) print $2, $6 }' <<<"${modeline}")
  [[ ${width} =~ ^[0-9]+$ && ${height} =~ ^[0-9]+$ ]] || return 1

  if [[ ${DISPLAY_SCALE_POLICY:-preserve} == preserve ]]; then
    target_scale=${current_scale}
  elif ((height < DISPLAY_SCALE_THRESHOLD_HEIGHT)); then
    target_scale=${DISPLAY_SCALE_BELOW_THRESHOLD}
  else
    target_scale=${DISPLAY_SCALE_AT_OR_ABOVE_THRESHOLD}
  fi

  # Temporary safety workaround: remove this fallback once the bridge obtains
  # an authoritative target scale that is guaranteed compatible with each
  # incoming mode. Until then, never pass fractional logical dimensions to
  # Hyprland during transient SPICE resize sequences.
  if ! awk -v width="${width}" -v height="${height}" -v scale="${target_scale}" '
    function abs(value) { return value < 0 ? -value : value }
    function is_integer(value) { return abs(value - int(value + 0.5)) < 0.000001 }
    BEGIN { exit !(scale > 0 && is_integer(width / scale) && is_integer(height / scale)) }
  '; then
    log "scale ${target_scale} does not evenly divide ${width}x${height}; using scale 1"
    target_scale=1
  fi
  printf '%s\n' "${target_scale}"
}

backend_apply_monitor_layout() {
  local layout_file=$1 monitors_json lua_command="do " resolved_file
  local monitor_index output modeline raw_x raw_y context monitor_scale current_x current_y
  local logical_x logical_y delta monitor_count=0 result
  local previous_raw_x previous_raw_y previous_logical_x previous_logical_y previous_scale

  monitors_json=$(hyprctl -j monitors all 2>/dev/null) || {
    log "could not query the current monitor state"
    return 1
  }
  resolved_file=$(mktemp "${layout_file}.resolved.XXXXXX")

  while IFS=$'\t' read -r monitor_index output modeline raw_x raw_y; do
    [[ ${monitor_index} =~ ^[0-9]+$ ]] || {
      log "runtime monitor layout has an invalid monitor index"
      rm -f -- "${resolved_file}"
      return 1
    }
    [[ ${output} =~ ^[A-Za-z0-9._-]+$ ]] || {
      log "runtime monitor layout has an invalid output"
      rm -f -- "${resolved_file}"
      return 1
    }
    [[ ${modeline} =~ ^[A-Za-z0-9.+[:space:]-]+$ ]] || {
      log "runtime monitor layout has an invalid modeline"
      rm -f -- "${resolved_file}"
      return 1
    }
    [[ ${raw_x} =~ ^-?[0-9]+$ && ${raw_y} =~ ^-?[0-9]+$ ]] || {
      log "runtime monitor layout has an invalid position"
      rm -f -- "${resolved_file}"
      return 1
    }

    context=$(jq -r --arg output "${output}" '
      first(.[] | select(.name == $output)) |
      select(. != null) | [.scale, .x, .y] | @tsv
    ' <<<"${monitors_json}" 2>/dev/null) || context=""
    IFS=$'\t' read -r monitor_scale current_x current_y <<<"${context}"
    [[ ${monitor_scale} =~ ^[0-9]+([.][0-9]+)?$ &&
      ${current_x} =~ ^-?[0-9]+$ && ${current_y} =~ ^-?[0-9]+$ ]] || {
      log "could not read the current geometry for ${output}"
      rm -f -- "${resolved_file}"
      return 1
    }
    monitor_scale=$(backend_resolve_monitor_scale "${modeline}" "${monitor_scale}") || {
      log "could not resolve the target scale for ${output}"
      rm -f -- "${resolved_file}"
      return 1
    }

    if ((monitor_count == 0)); then
      logical_x=${current_x}
      logical_y=${current_y}
    elif ((raw_y == previous_raw_y)); then
      if ((raw_x >= previous_raw_x)); then
        delta=$(awk -v value="$((raw_x - previous_raw_x))" -v scale="${previous_scale}" '
          BEGIN { print int((value / scale) + 0.5) }
        ')
      else
        delta=$(awk -v value="$((raw_x - previous_raw_x))" -v scale="${monitor_scale}" '
          BEGIN { print int((value / scale) - 0.5) }
        ')
      fi
      logical_x=$((previous_logical_x + delta))
      logical_y=${previous_logical_y}
    elif ((raw_x == previous_raw_x)); then
      if ((raw_y >= previous_raw_y)); then
        delta=$(awk -v value="$((raw_y - previous_raw_y))" -v scale="${previous_scale}" '
          BEGIN { print int((value / scale) + 0.5) }
        ')
      else
        delta=$(awk -v value="$((raw_y - previous_raw_y))" -v scale="${monitor_scale}" '
          BEGIN { print int((value / scale) - 0.5) }
        ')
      fi
      logical_x=${previous_logical_x}
      logical_y=$((previous_logical_y + delta))
    else
      logical_x=${current_x}
      logical_y=${current_y}
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${monitor_index}" "${output}" "${modeline}" "${logical_x}" "${logical_y}" \
      "${monitor_scale}" \
      >>"${resolved_file}"
    printf -v lua_command \
      '%shl.monitor({ output = "%s", mode = "modeline %s", position = "%sx%s", scale = %s }); ' \
      "${lua_command}" "${output}" "${modeline}" "${logical_x}" "${logical_y}" \
      "${monitor_scale}"

    previous_raw_x=${raw_x}
    previous_raw_y=${raw_y}
    previous_logical_x=${logical_x}
    previous_logical_y=${logical_y}
    previous_scale=${monitor_scale}
    monitor_count=$((monitor_count + 1))
  done <"${layout_file}"

  ((monitor_count > 0)) || {
    log "runtime monitor layout is empty"
    rm -f -- "${resolved_file}"
    return 1
  }
  lua_command+="end"
  if hyprctl -r eval "${lua_command}"; then
    mv -f -- "${resolved_file}" "${layout_file}"
    return 0
  fi
  result=$?
  rm -f -- "${resolved_file}"
  return "${result}"
}

backend_config_is_clean() {
  [[ -z $(hyprctl configerrors) ]]
}

backend_status() {
  hyprctl -j monitors all 2>/dev/null | jq -r '.[] |
    "\(.name): \(.width)x\(.height)@\(.refreshRate), scale \(.scale)"'
}
