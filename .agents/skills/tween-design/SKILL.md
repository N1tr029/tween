---
name: tween-design
description: Tween-specific design system — token contract, build-screenshot-iterate workflow, and per-screen visual targets that every UI slice in this repo must obey.
---

# Tween Design System

## Initial response

When this skill is invoked without a specific question, respond only with:

> tween-design loaded — I'll use `Tokens` from `Shared/Tokens.swift` for every value, compare against `references/visual-targets/` at each gate, and iterate at least three build → screenshot cycles per screen before moving on.

Do not provide anything else until the user asks for it.

## Operating contract

Every UI change in `TweenApp/` or `TweenMessages/` follows these rules. Violations are bugs.

### 1. No hardcoded values

Colors, spacings, radii, font sizes, durations, and elevations come from `Shared/Tokens.swift` — never inline. `.padding(16)` is wrong; `.padding(Tokens.Space.s4)` is right. `Color.blue` is wrong; `Tokens.Palette.pinSelf` is right. The one exception: SwiftUI `Color.clear` / `nil` / `0` sentinel values.

When a needed token doesn't exist, **add it to `Tokens.swift`** and reuse it. Never inline a one-off value with a comment promising to extract it later.

### 2. Glass surfaces

The persistent bottom sheet and any other glass surface use `View.tweenGlass(...)`. Today that resolves to `.regularMaterial` on iOS 18 with a tokened corner radius and a soft border; it's the single seam where Liquid Glass (`.glassEffect`) will swap in once the deployment target moves to iOS 26. Do not call `.regularMaterial` directly in new code.

Primary CTAs use `TweenPrimaryButtonStyle` (which exposes a `prominent` variant — that's the seam for `glassProminent` later). Don't reach for `.buttonStyle(.borderedProminent)` in new code.

### 3. Build → screenshot → compare → iterate

For every screen modified:

1. `xcodebuild build` clean.
2. Drive the simulator to the target state via `cliclick` (or a `HARNESS` launch argument when feasible).
3. `xcrun simctl io <udid> screenshot` to a path under `docs/screenshots/<phase>/<screen>-<iteration>.png`.
4. Diff against `references/visual-targets/<screen>.png` (or the spec when no target image exists).
5. Adjust tokens or layout. **Minimum three iterations** per screen before the gate is considered passable. Three iterations is a floor, not a ceiling — iterate until it matches.

The reason for three: the first pass establishes the rough layout, the second hits proportion/balance, the third sweats the unseen details (icon weights, optical alignment, motion timing). Skipping the third is where polish dies.

### 4. Stop at gates

Each phase has a `>>> STOP.` line. When you hit it: present before/after screenshots, the diff against tokens / visual-targets, the relevant code diff, then wait. Do not start the next phase before approval. If the build or any existing test breaks, the gate is not passable — fix or revert before presenting.

### 5. Existing code is legacy, not license

Hardcoded values in code written before the design system landed are *legacy*. Touching the same file during a slice means migrating the values you touched. You do not need to migrate the whole file in one go — but you cannot copy a hardcoded value into new code because "the surrounding code does it."

## Token surface

Defined in `Shared/Tokens.swift` and shared between `TweenApp` and `TweenMessages`. Group names are fixed; values can be tuned.

### `Tokens.Palette` — colors

- **Surface**: `background`, `surface`, `onSurface`, `onSurfaceMuted` — adapt to dark mode for free.
- **Brand**: `brand`, `brandMuted`, `accent` — Tween's identity. `accent` is the user-tappable primary; `brand` is for marks and active emphasis; `brandMuted` for selected backgrounds.
- **Semantic**: `success`, `warning`, `danger`.
- **Pins**: `pinSelf` (you, blue), `pinFriend` (orange), `pinMidpoint` (fair midpoint, brand). The midpoint pin is intentionally a brand color, not a status color — it's a *Tween* concept.
- **Glass**: `glassStroke`, `glassShadow` — used by `tweenGlass(...)`.

### `Tokens.Space` — 4pt grid

`s0=0, s1=4, s2=8, s3=12, s4=16, s5=20, s6=24, s7=32, s8=40, s9=56`. Use the smallest token that holds; don't reach for s5 because s4 looks "slightly tight" — the tightness is usually right.

### `Tokens.Radius`

`chip`, `card`, `sheet`, `pin`, `pill`. `pill` is `.infinity` for capsules.

### `Tokens.Typography` — typography

Semantic, not size-based: `display`, `title`, `headline`, `body`, `callout`, `caption`, `captionEmphasized`, `mono`. All resolve to `Font` values built from system Dynamic Type with weight overrides — accessibility is free. (Named `Typography` rather than `Type` because `Type` collides with Swift's metatype keyword.)

### `Tokens.Duration` and `Tokens.Motion`

`Tokens.Duration.fast/standard/slow` for explicit durations. `Tokens.Motion.snappy`, `.spring`, `.gentle` return ready-to-use `Animation` values. Press feedback is `Tokens.Motion.press` (`scaleEffect(0.96)` by convention).

### `Tokens.Elevation`

`floating`, `sheet`, `pin` — `.shadow(color:radius:x:y:)` parameters bundled into a view modifier each.

## Components (build them when a phase needs them)

The design system is the contract. Components live next to the screens that use them, but they MUST be composed from tokens. Phase 2 introduces:

- `ResultRow` — a category symbol + ETAChip showing both drive times, tinted on balance.
- `ETAChip` — a small capsule that shows one or two ETAs side by side. Tinted via `Palette.pinSelf` / `Palette.pinFriend` per side.
- `CategoryChip` — Google-Maps-style preset chip (food / coffee / gas / parks…).
- `TweenPin` — the branded map annotation. Two endpoint variants and one midpoint variant.
- `TweenPrimaryButtonStyle` — the only primary CTA style. Exposes `prominent` and `subtle` variants.

Don't anticipate Phase 3's haptics / Phase 4's `MSMessageTemplateLayout` until those phases are active.

## Per-screen visual targets

Targets live in `references/visual-targets/`. The README there enumerates the screens with expected target images. When no target image exists yet, design against the tokens and the prose spec in the phase plan — and note in the gate write-up that no target image was provided.

## Failure modes to avoid

- **"Just for now, I'll inline this color."** — No. The whole point of the system is one source of truth.
- **"I added a new color directly in the view."** — No. Add it to `Palette`, then use it.
- **"Three iterations took too long; it looks fine."** — The third pass is where details land. Skip it and the polish is wrong.
- **"The build broke but the screen looks right."** — The gate isn't passable.
- **"I migrated half the file."** — Fine. Migrate the lines you touched; leave the rest as a follow-up. Don't bundle a giant cleanup with a feature slice.
