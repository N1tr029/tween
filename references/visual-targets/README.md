# Visual targets

Per-screen reference images that UI slices iterate against, per the rules in
`.agents/skills/tween-design/SKILL.md`. Each iteration drops a build screenshot
into `docs/screenshots/<phase>/<screen>-<n>.png` and the gate write-up diffs it
against the target named below.

When no target image exists yet, design against `Tokens` and the prose spec in
the phase plan, and **flag the gap in the gate write-up**. Don't silently improvise.

## Phase 1 — behavior fixes (no restyling)

No target images required — Phase 1 is pure behavior. The "before" baseline is
whatever the app does on `main` before the slice; the "after" is the recorded
screenshot of the fixed behavior. Verification is interaction (camera doesn't
snap, sheet swipes down, etc.), not pixel-match.

## Phase 2 — map home screen visual overhaul

Targets needed (drop PNGs here with these exact names):

- `phase2-home-collapsed.png` — bottom sheet at the 120pt detent over the map.
- `phase2-home-medium.png` — sheet at 0.45 detent with search results + category chips.
- `phase2-home-large.png` — sheet at large detent.
- `phase2-category-chips.png` — the food/coffee/gas chip row in isolation.
- `phase2-result-row.png` — a single ResultRow with the dual-ETA chip.
- `phase2-pins.png` — the two endpoint pins + the brand midpoint pin on the map.
- `phase2-waiting-tab.png` — the repurposed "waiting on response" tab.

## Phase 3 — selected-spot detail + motion pass

- `phase3-spot-detail.png` — the spot detail sheet (post `matchedGeometryEffect`).
- `phase3-im-in-button.png` — the I'm-in button in its rest state.
- `phase3-im-in-button-tapped.png` — the button mid-animation (text + movement).

Motion (animation curves, durations, haptic feedback) is hard to capture in a
still — describe the expected feel in the gate write-up alongside the still
frames.

## Phase 4 — iMessage extension UI

- `phase4-compact.png` — the compact extension view (keyboard-height).
- `phase4-expanded.png` — the expanded extension view.
- `phase4-bubble.png` — the `MSMessageTemplateLayout` bubble as rendered in
  Messages (target image: a real bubble screenshot, not a mockup).

## How to add a target

1. Export a PNG at the simulator's native resolution (2x or 3x). Use the
   iPhone 16 Pro simulator unless a slice specifies otherwise.
2. Name it per the list above.
3. Drop it directly here. No subfolders.
4. If the target is conceptual (an animation, a haptic), write a short
   `<name>.md` instead and describe the intent.

When a target image is missing for a screen a phase is about to touch, the
implementer must call it out before the slice starts and either add one or
explicitly waive the pixel diff for that screen.
