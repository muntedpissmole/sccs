# Lighting bug mode — Option A (separate chip)

**Date:** 2026-06-11  
**Status:** Applied

## Problem

On `rgb_bug` lights (e.g. Kitchen Panel, Awning), the header toggle pill toggled **white ↔ bug (red) mode**, not on/off. Other cards use the same pill for **power**. Same control, different meaning.

## Solution (Option A)

- **Toggle pill** — on/off only (brightness 0 ↔ last brightness), same as PWM dimmers. Still uses `.bug-mode` styling (red) when bug mode is active.
- **Bug mode chip** — new mosquito button left of the pill; toggles `white` ↔ `red` mode only.
- **Slider / card chrome** — still turns red in bug mode (unchanged).

## Files changed

| File | Change |
|------|--------|
| `static/js/lighting-controller.js` | Pill logic, `toggleBugMode()`, chip in card HTML, click handler |
| `static/css/components/lighting.css` | `.bug-mode-chip` styles |

## Behaviour before (revert target)

In `lighting-controller.js` → `updateLightUI()`:

```javascript
const pillOn = light.has_mode ? isBugMode : brightness > 0;
pills.forEach((pill) => {
    pill.classList.toggle('on', pillOn);
    pill.classList.toggle('bug-mode', isBugMode);
    ...
});
```

In `toggleControl()`:

```javascript
if (light.has_mode) {
    const newMode = currentMode === 'white' ? 'red' : 'white';
    // ... mode toggle only, no brightness change
    return;
}
```

Card HTML used `colour-toggle` class on the pill; no bug chip.

## How to revert

1. Delete `.bug-mode-chip` rules from `lighting.css`.
2. In `lighting-controller.js`:
   - Restore `pillOn = light.has_mode ? isBugMode : brightness > 0`.
   - Restore `bug-mode` class on pills in `updateLightUI()`.
   - Restore `if (light.has_mode) { ... mode toggle ... return; }` in `toggleControl()`.
   - Remove `toggleBugMode()` and bug-chip branch in `handleLightingClick`.
   - Remove bug chip from card HTML; restore `colour-toggle` on pill for `has_mode` lights.
3. Delete this doc if no longer needed.

## Unchanged

- Socket/API: `light_change` still sends `{ name, brightness, mode }`.
- Home tile bug indicator (`is-bug-mode` when `mode === 'red'`).
- Scenes / `*_mode` keys in state.
- Slider `.bug-mode` fill/thumb styling.