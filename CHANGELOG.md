# Changelog

All notable changes to SCCS are documented in this file.

## [1.1.2.12082026] - 2026-08-12

### Added
- **Scenes:** each scene button shows its config `description` on its own line under the title
- **System tab:** tiles pack into columns by height (tallest-first onto the shortest column) so the page fills more evenly
- **Phases:** Save / Cancel for timing editors only appear after values are modified

### Changed
- **Home 6-col (~1121–2520px, incl. 1920):** Lighting and Panels stack left of Weather; Sonos sits above System; Appearance stays 1-wide with System 2-wide on the bottom row (left/right flip, widths preserved)
- **Home 3-col:** trailing tile order adjusted (Location, Lighting, Panels, Sonos, System, Appearance)
- Scene button type uses home tile tokens (label / title / icon scale) so Scenes matches Home typography
- Empty Sonos / touchscreens / unconfigured Victron status areas no longer show placeholder “searching” or “add address” copy
- **Water gauge:** continuous low-level colour — normal above 50%, orange fading to red from 50%→20%, full red at/below 20% (replaces discrete 25%/10% steps)

### Fixed
- Phases Save/Cancel stayed visible when clean because `display:flex` overrode the HTML `hidden` attribute
- **System tab:** column packer no longer thrash-rebuilds on hover/scroll in Chrome (ignore style noise, skip no-op packs, settle cooldown); hover lift disabled on Settings tiles to stop bounce

## [1.1.1.11082026] - 2026-08-11

### Changed
- Version scheme is now `major.minor.patch.DDMMYYYY` (patch segment added)
- Home and Settings status modules: **ESP32** renamed to **Lighting** (id `esp32` unchanged)

### Fixed
- Water circular gauge could bleed outside the tile when a sibling tile (power) grew taller from wrapped text at mid breakpoints; gauge now fits `min(width, height)` and clips to the tile
- Power tile metric labels/values less likely to wrap and inflate row height (ellipsis + tighter column gaps)

## [1.1.08112026] - 2026-08-11

### Added
- **Phases:** Settings tile can edit Day/Evening offsets and Night start time (7:30 PM–midnight, half-hour steps); Save writes `sccs.conf` and recalculates the schedule without a restart
- **Network:** Preferred internet control (Wi‑Fi vs USB Hotspot) always available; preference is persisted and applied via route metrics when paths are online
- **Development mode** (`[system] development_mode`): hides force phase, GPS simulate, force reed, and toast-test tools when off
- Optional fridge/freezer climate fields only show when sensor IDs are configured
- Sonos default speaker can be set from the Settings tile (writes `[sonos] player_name`)

### Changed
- Settings multi-column layout: 3 columns from ~1024px (was only at ~2520px)
- SCCS Core / GPS status copy clarified (connected vs modules vs Pi host; GPS unavailable vs fallback)
- Network tile heading renamed from Wi‑Fi; USB preference wording uses “USB Hotspot”
- Reeds summary uses open/closed consistently (not secure/latched)
- Sonos enable/disable config flag removed; Home tile follows discovery + disconnected-tiles preference

### Fixed
- Fridge/freezer tiles stayed visible when unconfigured (CSS `display:flex` overriding `hidden`)
- Phase timing editors and related Settings UI polish

## [1.0.08092026] - 2026-08-09

### Added
- Initial release of the Singularity Camper Control System (SCCS)
