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
3. The extension opens **compact** (keyboard height): caption + placeholder coordinate +
   "Tap to open". Tap it → it expands.
4. In the expanded view, tap **Send update**. A Tween bubble is inserted into the input
   field. Tap the send arrow to send it to **B**.
   - ✅ Pass: **B** receives a bubble with the caption text and a `lat, lon` subcaption.

### Test 2 — Recipient taps the bubble and reads state back (Phase 1, step 2)
1. On **B**, tap the Tween bubble just received.
   - ✅ Pass: the extension opens and the **Received state** panel shows the *same* message
     text and coordinate **A** sent (not the placeholder). This confirms the state was read
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
- No App Group yet and no `com.tween.app` bundle-id rename — deferred (not needed for the URL
  round-trip). Signing must be configured before the two-device test can run on hardware.
- The coordinate is a hard-coded placeholder; real location/map come in a later phase.
- Sending always requires the user to tap the send arrow (iMessage inserts into the input
  field; apps cannot send silently). This is expected.
