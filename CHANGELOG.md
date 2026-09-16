# Changelog

## Unreleased

- Add an opt-in height-threshold display scale policy and apply the resolved
  mode, position, and scale atomically, avoiding invalid intermediate scale
  combinations during host-display transitions.
- Fall back to scale 1 when a selected scale would produce fractional logical
  dimensions for a transient SPICE mode.
- Persist each resolved scale with the display state so session restoration
  reproduces the complete working layout.

## 0.1.4 — 2026-08-28

- Publish SPICE/X11 clipboard items to Wayland without replacing the X11
  selection, preventing `spice-vdagent` and the host from reflecting the same
  item back and cancelling the multi-format provider.

## 0.1.3 — 2026-08-28

- Replace single-MIME `wl-copy` publication with an independent native
  Wayland/X11 clipboard provider built on `ext-data-control-v1` and GTK.
- Preserve original PNG, JPEG, TIFF, and BMP bytes while advertising a lazy
  PNG compatibility representation for non-PNG images.
- Add configurable derived formats and decoded-pixel limits, plus byte and
  pixel bounds for generated PNG data.
- Mark provider-owned selections with a private MIME target so X11/Wayland
  clipboard echoes do not collapse multiple representations back to one.

## 0.1.2 — 2026-08-27

- Add binary-safe, two-way PNG, JPEG, TIFF, and BMP clipboard forwarding while
  retaining plain-text support and MIME-aware duplicate suppression.
- Validate PNG clipboard transport in both directions on a live UTM aarch64
  guest.

## 0.1.1 — 2026-08-27

- Keep each output's current scale during live SPICE layout updates.
- Make persisted SPICE monitor rules follow `omarchy_monitor_scale`, preventing
  Hyprland from defaulting omitted scales to 1 after a restart.

## 0.1.0 — 2026-08-25

- Add two-way plain-text clipboard sharing between SPICE/X11 and Wayland.
- Add immediate SPICE display resizing through persistent Hyprland modelines,
  with duplicate requests suppressed and no user-facing timing controls.
- Parse complete SPICE monitor transactions and map multiple active outputs
  automatically, and apply their modes and positions in one Hyprland Lua call.
- Validate independent dual-display resizing without changing either output's
  scale.
- Keep display scale exclusively owned by Omarchy's `monitors.lua`.
- Preserve each output's independent live scale while translating multi-monitor
  positions; generated runtime and persistent rules never set scale.
- Derive and cache refresh rate from the current Hyprland output instead of
  exposing it as user configuration.
- Apply resize modelines through one runtime monitor update without restarting
  `spice-vdagent` or reloading the full Hyprland monitor configuration.
- Add systemd user services, environment diagnostics, and safe user install.
- Add an idempotent per-user bootstrap service and package-level
  `graphical-session.target` links for zero-configuration setup on next login.
- Activate an existing local Wayland session immediately from package
  install/upgrade hooks via its systemd user manager, without requiring logout
  or writing user configuration as root.
- Keep package installation out of user home directories and provide a
  persistent per-user opt-out through `spice-guest-tools uninstall`.
- Define the production boundary as system-packaged files with exclusively
  per-user runtime services, configuration, and state; retain user installation
  only for development.
- Gate every clipboard and resize operation on logind's active local Wayland
  owner for `seat0`, allowing safe logout and fast user switching.
- Add Arch packaging metadata and isolated shell tests.
- Split the desktop-independent SPICE core from the `omarchy-hyprland` display
  backend, with automatic or explicit backend selection.
- Clarify local system-package installation before AUR publication, document
  development dependencies and every supported configuration setting, and
  align the first-release milestone with version 0.1.0.
