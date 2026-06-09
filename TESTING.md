# Testing Tween — Phase 1 (bubble round-trip)

Phase 1 proves the GamePigeon-style round-trip: the iMessage extension sends a bubble whose
state lives in `MSMessage.url`, the recipient taps it, the extension reads that state back,
and the recipient sends an updated bubble into the same thread.

## What is verified automatically (no devices needed)

Run from the repo root:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# 1. Both targets build (app + embedded iMessage extension)
xcodebuild build -project TweenApp.xcodeproj -scheme TweenApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO

# 2. State round-trips through the message URL (encode -> decode == original)
xcodebuild test -project TweenApp.xcodeproj -scheme TweenApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:TweenAppTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

The companion `TweenApp` also renders the exact Compact and Expanded views the extension
hosts (`docs/screenshots/phase1-harness.png`), so the UI can be checked on the simulator.

**The simulator cannot fully test send/receive between two people.** A single simulator has
one iMessage account, so you cannot tap a bubble *received from someone else*. The tap →
`selectedMessage` → decode path, and the in-thread bubble appearance, must be verified on two
real devices.

## Two-device manual test

You need **two iPhones**, each signed into a *different* iMessage account (two Apple IDs), and
both must be able to iMessage each other (blue bubbles). Call them **A** (sender) and
**B** (recipient).

### One-time setup
1. In Xcode, set a valid signing Team for **both** the `TweenApp` and `TweenMessages` targets
   (Signing & Capabilities → automatic signing). This is required to run on real hardware.
2. Connect device **A**, select it as the run destination, and Run the `TweenApp` scheme.
   This installs the app and its iMessage extension. Repeat for device **B**.
   (Both devices must have the build installed for the recipient side to open the bubble.)

### Test 1 — Send a bubble with state (Phase 1, step 1)
1. On **A**, open Messages → the conversation with **B**.
2. Tap the Apps icon next to the text field, open **Tween**.
3. The extension opens **compact** (keyboard height): caption + neutral map placeholder +
   "Tap to open". Tap it → it expands.
4. In the expanded view, tap **Send update**. A Tween bubble is inserted into the input
   field. Tap the send arrow to send it to **B**.
   - ✅ Pass: **B** receives a bubble with the caption text and a `lat, lon` subcaption.

### Test 2 — Recipient taps the bubble and reads state back (Phase 1, step 2)
1. On **B**, tap the Tween bubble just received.
   - ✅ Pass: the extension opens and the **Received state** panel shows the *same* message
     text and coordinate **A** sent. This confirms the state was read
     back out of `MSMessage.url` in `willBecomeActive`.

### Test 3 — Recipient sends modified state back (Phase 1, step 3)
1. Still on **B**, in the expanded view edit the **Message** field, then tap **Send update**.
   (The view also nudges the coordinate by +0.0010 so the change is observable.)
2. Send the inserted bubble back to **A**.
   - ✅ Pass: **A** receives a bubble with **B**'s edited text and the changed coordinate.
   - ✅ Pass: tapping it on **A** shows the modified state in the Received state panel.

### What "done" looks like
A message bounces A → B → A, each side editing it, with the state surviving every hop. That
is the full round-trip.

## Notes / known limitations at this phase
- Signing must be configured before the two-device test can run on hardware.
- Sending always requires the user to tap the send arrow (iMessage inserts into the input
  field; apps cannot send silently). This is expected.

> Note: as of Phase 2 the expanded view's control is **"I'm in"** (sends your cached location),
> not the Phase 1 "edit text + Send update" demo. The A → B → A round-trip is now driven by
> tapping **I'm in** on each side.

# Testing Tween — Phase 2 (location, once)

Phase 2 captures the user's location one time in the app, caches it to the shared App Group
container (`group.com.hassanahmed.tween`), and reuses it from the extension's "I'm in" control.

## What is verified automatically

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export PATH="$DEVELOPER_DIR/usr/bin:$PATH"   # so the test runner can find simctl

# Build both targets (unsigned is fine for the simulator)
xcodebuild build -project TweenApp.xcodeproj -scheme TweenApp \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO

# LocationCache + TweenState round-trip tests
xcodebuild test -project TweenApp.xcodeproj -scheme TweenApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:TweenAppTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

Screenshots: `docs/screenshots/phase2-onboarding.png` (the app's location request screen) and
`docs/screenshots/phase2-harness.png` (the extension's compact + "I'm in" expanded views,
rendered in the app — launch the app with the `HARNESS` argument).

**What the simulator/CLI cannot verify:** the *cross-process* App Group share (app writes →
extension reads) and the in-Messages "I'm in" send. The App Group entitlement is not embedded
in the unsigned simulator build, and the Messages UI can't be driven from the CLI. Both need
the two-device test below.

## Two-device manual test (builds on Phase 1 setup)

Prerequisite: a valid signing Team on **both** targets (already set: `T4VT6R837D`), so Xcode
can provision the `group.com.hassanahmed.tween` App Group when you build to a device.

### Test 4 — Capture location in the app
1. Run the `TweenApp` scheme on device **A**. On the onboarding screen tap **Share my
   location** and allow "While Using the App".
   - ✅ Pass: the screen shows "Saved <lat, lon>".

### Test 5 — Extension reuses the cached location
1. On **A**, open Messages → a conversation → the Tween iMessage app → expand.
   - ✅ Pass: the **Your location** panel shows the same coordinate the app saved (proving the
     App Group share works), and the button reads **I'm in**.
2. Tap **I'm in**, then send the inserted bubble to **B**.
   - ✅ Pass: **B** receives an "I'm in" bubble whose location matches **A**'s saved coordinate.

### Test 6 — Request-in-extension fallback
1. On a device where the app has **not** captured a location yet, open the Tween extension and
   expand. The button reads **Share location & say I'm in**.
2. Tap it and allow location.
   - ✅ Pass: the extension requests location in-place (using its own Info.plist usage string),
     caches it, and sends the "I'm in" bubble.
