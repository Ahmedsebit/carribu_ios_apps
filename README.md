# Carribu Native iOS Apps

Native Swift/SwiftUI source for separate **Carribu Driver** and **Carribu Parent** applications in one generated Xcode project. Networking, DTOs, Keychain sessions, platform services and reusable views are shared; each app has its own target, entry point, bundle identifier and Firebase resource directory.

**Status:** Source implementation, not a validated iOS release. No Mac, Xcode, simulator or iPhone was available during creation. Swift syntax and source/configuration checks do not establish compilation, passing XCTest, signing, APNs delivery or background behavior. Complete the acceptance checklist below before distribution.

## Android baselines

Remote `main` was fetched and compared with local source on November 5, 2026:

| App | Source baseline | iOS target | Proposed bundle ID |
|---|---|---|---|
| Driver | `carribu_driver_native_app`, `1506985` | `CarribuDriver` | `com.carribu.driverios` |
| Parent | `carribu_parent_native_app`, `ab8765f` | `CarribuParent` | `com.carribu.parentios` |

Both Android working trees were clean and matched their remote baselines. This work does not modify them or the backend.

The bundle IDs must be approved and registered before configuring Apple/Firebase credentials. Minimum deployment target is iOS 17. The Firebase package range starts at 12.0.0; that baseline requires Swift 6 package tooling. Use an appropriate Xcode installation and record the resolved dependency version during build validation.

## Feature implementation

| Area | Driver | Parent |
|---|---|---|
| Authentication | Driver/coordinator/admin/school-admin role validation | Parent-only role validation |
| Secure sessions | Per-app Keychain storage; expired-session handling; environment-bound session | Same, plus first-time registration |
| Passwords | Password change and required-password gate | Registration, required-password gate and password change |
| Trips | Acknowledge/start, active trip, canonical stops, student actions and safe end | Active buses, upcoming trips and completed history |
| Student actions | Arrival, board, absent and drop-off with phase-aware deterministic keys | View child status and report multi-child absence |
| Guidance | Backend `currentStop`/`nextStop`, map and Apple Maps navigation | Bus/stop markers and approximate ordered-stop polyline |
| Tracking | Traccar-linked vehicles never share phone GPS; unlinked trips can share Core Location fixes | GPS timestamps, freshness, stale ETA suppression and monotonic location merge |
| History | Last 30 days; frozen student progress | Upcoming 7 days/history 30 days; school and student filters |
| Communication | Conversations, route-parent contacts, calling, send/delete/clear messages | Conversations, driver contacts, unread count, calling, send/delete/clear |
| Alerts | FCM/APNs registration and notification entry into messages | In-app alerts, delete/clear, FCM/APNs registration and alert navigation |
| Profile | Account, password, notification permissions and logout | Account, children/schools, pickup map/current position, password and logout |
| Updates | Configurable iOS release-page link | Same; deliberately does not treat Android APK metadata as iOS releases |

These are implemented source paths, not a claim of device-tested feature parity. MapKit and Apple Maps replace Android-specific Maps/navigation APIs. App Store/TestFlight distribution replaces Android package downloads.

## Layout

```text
carribu_ios_apps
  project.json
  Local.xcconfig.example
  DriverApp.swift
  DriverViews.swift
  ParentApp.swift
  ParentViews.swift
  Shared
    Models.swift
    Network.swift
    AppStore.swift
    PlatformServices.swift
    CommonViews.swift
  DriverResources
  ParentResources
  Tests
    DomainTests.swift
    NetworkTests.swift
```

`project.json` is an XcodeGen specification, not an existing compiled Xcode project. XcodeGen generates the project, Info plists and entitlement files on the Mac.

## First setup on a Mac

1. Install Xcode with Swift 6 package support, its iOS simulator components and XcodeGen using their official installation instructions.
2. Copy this entire folder to the Mac. Open a terminal in this folder.
3. Copy `Local.xcconfig.example` to `Local.xcconfig`.
4. Set `CARRIBU_API_BASE_URL` to the approved **HTTPS** local/staging backend ending in `/api/`. The initial `.invalid` value deliberately blocks requests; there is no automatic production default.
5. Set `DEVELOPMENT_TEAM` for device signing. Confirm the bundle IDs in `project.json`.
6. Optionally set `CARRIBU_UPDATE_URL` to an approved HTTPS App Store/TestFlight release page. A blank value is displayed as unconfigured, not as "latest version."
7. Generate and open the project:

```sh
xcodegen generate --spec project.json
open Carribu.xcodeproj
```

The `https:/$()/...` syntax in the xcconfig example preserves the double slash without starting an xcconfig comment. Retain that syntax when replacing the host.

The source requires HTTPS and does not disable certificate validation or permit arbitrary cleartext traffic. Use a trusted development HTTPS endpoint; do not put tokens, user records or credentials into the URL.

Select `CarribuDriver` or `CarribuParent` in Xcode. Resolve package dependencies, build both targets, then run with synthetic accounts.

## Firebase and APNs

Use **different iOS Firebase app registrations** for the two bundle IDs, in the Firebase project used by the backend:

- Put the driver's `GoogleService-Info.plist` in `DriverResources`.
- Put the parent's `GoogleService-Info.plist` in `ParentResources`.
- Regenerate the project after adding the files.
- Enable Push Notifications for the approved Apple App IDs and provisioning profiles.
- Configure the APNs authentication key/certificates in Firebase through the approved credential process.
- Confirm the deployed backend Firebase service-account configuration and its `fcm` token support.

No Firebase credential file is required to compile the app source, but Firebase SDK dependencies still need to resolve. Without per-app Firebase configuration, the app reports that notifications are unavailable; it does not claim registration succeeded.

APNs entitlements are generated with development environment for Debug and production for Release. Real-device signing/provisioning must match. The app handles the APNs device-token callback explicitly because Firebase delegate proxying is disabled.

After signing in, notification permission and token registration are attempted. Profile offers explicit retry and a link to permission settings. Token refresh triggers registration; duplicate foreground events with a stable `eventId` are suppressed. In-app alerts/messages remain server-owned and are reloaded from their APIs.

The current backend stores one FCM token per user, not a multi-device token collection. Registering an iPhone and Android device on the same account can replace that provider token. A multi-device backend change is a separate requirement.

Never commit APNs keys, signing certificates, provisioning profiles, device tokens or Firebase configuration files. Never embed the backend service account in either app.

## Driver GPS policy and iOS limitations

- Phone sharing starts only for an active trip without a linked Traccar tracker.
- A linked tracker, even when offline, never enables phone fallback.
- The app requests location permission only for phone sharing or parent pickup selection.
- Driver background permission is requested explicitly. The UI distinguishes foreground-only from background-authorized sharing.
- Fixes are validated and uploads are throttled to no more than one every five seconds. Speed is converted from metres/second to km/h.
- Actual callbacks are controlled by iOS and movement; there is no guarantee of a five-second background interval.
- HTTP 401/404/409 stops phone uploading rather than silently changing source.
- Phone sharing stops after successful backend completion, confirmed absence of an active trip, logout or explicit pause.
- Pause is respected across trip refreshes. Explicit resume uses the current server trip and source policy.

Test backgrounding, permission changes, tracker linking while sharing, app termination and restart on a physical iPhone. Do not assume an Android foreground-service model exists on iOS. Force-quit behavior is not guaranteed background tracking.

## Domain rules retained

- Backend owns trip phase, current/next stop, roster snapshot and completion eligibility.
- Morning pickups precede school drop-offs.
- Afternoon school boarding/absence must resolve before home drop-offs.
- Arrival does not locally advance a stop.
- Student action keys are `<tripId>:<studentId>:<phase>:<action>`.
- Matching retry behavior is determined by the backend; a conflict is surfaced.
- Parent freshness uses the server flag, a valid coordinate and the -30 through 120 second timestamp window.
- Old responses do not overwrite newer eligible tracking state; stale/error cases hide ETA.
- Completed buses leave active selection when no longer returned by the API.
- Provider acceptance is not device receipt or parent read.

## Tests and build verification

Both schemes include the shared XCTest sources:

- Freshness equality and just-outside boundaries.
- Zero/invalid coordinates and decimal-string decoding.
- Canonical action phase, stable keys and school-drop-off action gating.
- Password validation and role gating.
- Older GPS preservation with outdated ETA suppression.
- HTTPS/environment configuration rejection.
- API path/authorization, missing active-trip envelope, HTTP 401 and HTTP 409.

Network tests use a synthetic `URLProtocol`; they do not contact the backend.

First list available simulator destinations:

```sh
xcodebuild -project Carribu.xcodeproj -scheme CarribuDriver -showdestinations
```

Replace `SIMULATOR_ID` with an available simulator UUID, then run both schemes:

```sh
xcodebuild -project Carribu.xcodeproj -scheme CarribuDriver -destination 'platform=iOS Simulator,id=SIMULATOR_ID' test CODE_SIGNING_ALLOWED=NO
xcodebuild -project Carribu.xcodeproj -scheme CarribuParent -destination 'platform=iOS Simulator,id=SIMULATOR_ID' test CODE_SIGNING_ALLOWED=NO
```

Use approved signing for physical-device builds and archives. Do not distribute an unsigned simulator build.

## Required acceptance before release

- [ ] Generate the Xcode project successfully and resolve/record dependencies.
- [ ] Compile both app targets and run both XCTest suites.
- [ ] Add and validate app icons, launch presentation and iPhone/iPad layouts.
- [ ] Complete morning and afternoon journeys against staging.
- [ ] Check validation, wrong-role login, first-time setup, password gate, expiry and logout.
- [ ] Verify old responses cannot restore ended/previously selected trip state.
- [ ] Exercise driver unlinked-phone and linked-Traccar paths, including source changes.
- [ ] Validate foreground/background/denied permission behavior on a physical iPhone.
- [ ] Verify actual APNs/FCM receipt, foreground display, tap navigation and token refresh.
- [ ] Verify messaging, absence, filtered history, alerts and pickup editing.
- [ ] Review personal-data handling, location purpose disclosures, privacy declarations and dependency privacy manifests.
- [ ] Approve bundle IDs, signing custody, provisioning, versioning and distribution.
- [ ] Configure a correct iOS release link; never publish an Android APK as an iOS update.

No production deployment, signing or App Store submission was performed.
