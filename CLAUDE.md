# Tween — iMessage meetup app
## Workflow
- Plan mode first. Small slices. Build + screenshot to verify before claiming done.
- After every verified slice: commit (Conventional Commits) and push. Never push non-building code.
## Architecture
- Targets: TweenApp, TweenMessages + Shared/. App Group: group.com.kavigandham.tween
- No server in the MVP. MapKit only. Coordinates passed via MSMessage.url query items.
## Hard constraints (DO NOT VIOLATE)
- Extension memory is tight: MKMapSnapshotter (static image), NOT a live MKMapView.
- MSMessage.url max 5000 chars, https/file scheme only. Pass coordinates, never route geometry.
- Compact view = keyboard height, no first responder/keyboard. All search & maps in expanded mode.
- Location: When-In-Use only. NSLocationWhenInUseUsageDescription in the EXTENSION's own
  Info.plist. Retain the CLLocationManager.
- No API keys in client or message URL. App Group UserDefaults is unencrypted — no sensitive data.
## Conventions
- SwiftUI + @Observable (not ObservableObject). @State owns; @Bindable for two-way.
- Pass simple value types into views (name: String, eta: TimeInterval) for previewability.
- Use the simplest approach that works.
