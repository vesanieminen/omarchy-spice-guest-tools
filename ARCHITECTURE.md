# Architecture

The project is split into a compositor-independent SPICE core and desktop
integration backends.

## SPICE core

The core owns:

- SPICE monitor transaction parsing and duplicate suppression;
- SPICE/X11 to Wayland text and image clipboard bridging;
- multi-representation clipboard ownership through `ext-data-control-v1` and
  GTK, including isolated Wayland publication and lazy derived image formats;
- active-seat session ownership;
- configuration, runtime state, and systemd user-service lifecycle;
- modeline generation and validation.

The core does not inspect a hypervisor, compositor, or desktop-vendor name.
It selects a display backend through `[integration].backend`. With `auto`, each
installed backend is probed and exactly one must match.

## Display backend contract

Backend implementations live in `libexec/backends/<name>.sh` and provide:

- `backend_probe`
- `backend_require_commands`
- `backend_config_file`
- `backend_snapshot_config`
- `backend_configure`
- `backend_restore_config`
- `backend_remove_integration`
- `backend_reload`
- `backend_integration_is_installed`
- `backend_detect_outputs`
- `backend_detect_any_output`
- `backend_detect_refresh_rate`
- `backend_apply_monitor_layout`
- `backend_config_is_clean`
- `backend_status`

Backend assets live under `backends/<name>/` and are installed into the matching
payload directory under `/usr/share/spice-guest-tools/backends/`.

## Current backend

`omarchy-hyprland` is the first backend. It owns every Omarchy/Hyprland-specific
assumption: `monitors.lua`, `hl.monitor`, `hyprctl`, output scale translation,
and the persistent Lua monitor block. Runtime rules retain the live per-output
scale by default. When the user opts into a display scale policy, the backend
resolves scale before applying the complete layout and persists that resolved
value with the mode and logical position. Legacy persistent state continues to
follow Omarchy's `omarchy_monitor_scale` setting.
Adding another compositor should require a new backend and its assets, without
changes to SPICE parsing or clipboard code.

## Clipboard provider

The distribution `spice-vdagent` remains the SPICE transport and initially
presents host clipboard data through X11. `spice-clipboard-bridge` reads that
selection and hands each logical item to the native
`spice-clipboard-provider`. In this ingress path the provider owns only the
Wayland selection: `spice-vdagent` remains the X11 owner, so the guest-side
publication is not reflected to the host and echoed back as a new selection.
The provider preserves the original encoded bytes, advertises every
representation it can serve, and generates a configured PNG compatibility
representation only when a consumer requests it. Its standalone mode can also
own X11 through GTK, including `TARGETS`, `MULTIPLE`, and incremental
transfers; the Wayland side uses `ext-data-control-v1` directly.

The private `application/x-spice-guest-tools` target identifies Wayland
selections owned by the provider, so the bridge ignores compositor echoes
without comparing different encodings of the same pixels. The provider uses
the public staging `ext-data-control-v1` protocol rather than vd_agent internals
or compositor-specific APIs.
