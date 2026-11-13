# HomeSync

**Smart energy, smarter living.**

A smart-plug system for households: measure what each appliance actually
draws, switch it from your phone, put it on a timetable, and see who did
what. Built as a Flutter app over Firebase, driving ESP32 smart plugs
with real energy metering.

The app is not a single-user dashboard. One account is the household
**admin**; they create limited accounts for everyone else in the house
and decide what each person is allowed to do.

---

## Contents

- [What it does](#what-it-does)
- [How it fits together](#how-it-fits-together)
- [Data model](#data-model)
- [Hardware](#hardware)
- [Running the app](#running-the-app)
- [Firebase setup](#firebase-setup)
- [Flashing a plug](#flashing-a-plug)
- [Project layout](#project-layout)
- [Known limitations](#known-limitations)

---

## What it does

**Household accounts**
The account that signs up is the admin. From the Members page they create
logins for the rest of the household, each with its own permissions:
control appliances, edit schedules, view reports. Members automatically
see every appliance registered under the admin — nothing is copied, so
adding an appliance makes it appear for everyone at once. Removing a
member revokes access immediately, enforced by the database rules rather
than just hidden in the UI.

**Appliance control**
Claim a plug by its device ID, give it a name, room and type. Switch it
from Home or Appliances, or switch a whole room at once. Toggles show a
pending state until the plug confirms, so a slow connection doesn't look
like a dead button.

**Scheduling**
A schedule is its own object with a name, a time window, a set of days
and the appliances it drives — not a hidden setting on each appliance.
Create one, pick what it switches, delete it when you're done.

**Energy monitoring**
Live wattage per appliance, daily kWh history, and cost estimates from a
configurable ₱/kWh rate. The Report page breaks usage down by day, week,
month or a custom range.

**High-consumption alerts**
Per-appliance limits on instantaneous watts and daily kWh. Both the plug
and the app check them, so a breach is caught within seconds even with
nobody's phone open. One alert per appliance per kind per day.

**Control log**
An append-only record of who switched what, changed which schedule, and
managed which member. The rules permit appending but not editing, and an
entry cannot be written under someone else's name.

**Accounts**
Email/password, Google and Facebook sign-in; password recovery by email;
editable display name and profile picture.

---

## How it fits together

```
   Flutter app                Firebase Realtime DB              ESP32 plug
  (Android / web)                                          (PZEM-004T + relay)
        |                              |                            |
        |  write command/relay  ------>|                            |
        |                              |<---- streams command/relay |
        |                              |                            |
        |                              |<---- state, telemetry,     |
        |  read state & telemetry <----|      daily history         |
        |                              |                            |
        |  write limits, schedule ---->|----> read limits, schedule |
        |                              |                            |
        |  read alerts          <------|<---- write alerts          |
```

Nothing talks directly to anything else — the database is the only
meeting point. The app never reaches the plug, and the plug never knows
about the app. Either can be offline without breaking the other: commands
queue in the database, and the plug picks up whatever it missed on boot.

The one thing that follows from this: **the plug acts on its own**. It
runs schedules and checks limits itself, which is why those still work
with every phone in the house switched off, and also why a
schedule-driven switch has no person to attribute it to in the control
log.

---

## Data model

Realtime Database, two top-level trees plus the per-device one.

```
devices/{DEVICE_ID}/
    ownerId        uid of the admin who claimed it; absent = unclaimed
    info/          name, room, type                       (app writes)
    limits/        maxWatts, maxDailyKwh                  (app writes)
    command/relay  desired on/off                         (app writes)
    schedule/      mirrored from a schedule, for the plug  (app writes)
    state/relay    actual relay position                  (plug writes)
    telemetry/     power, voltage, current, energy, pf    (plug writes)
    history/{date} kWh used that calendar day             (plug writes)

users/{UID}/
    profile/            name, email, role, photo (base64 JPEG)
    householdAdminUid   members only: a pointer to their admin
    appliances/         {deviceId: true} — the household's index
    settings/           pesoPerKwh
    schedules/{id}      name, enabled, days, start/end, devices
    members/{memberUid} name, email, permissions — admin-writable only

activity/{HOUSEHOLD_UID}/{entryId}   append-only control log
alerts/{HOUSEHOLD_UID}/{alertId}     limit breaches; id is derived
```

Three decisions worth knowing, because the rules depend on them:

**Membership lives on the admin's node.** A member's own record holds
only a pointer back to their admin. If it were the other way round, a
member could edit their own permissions.

**The log and alerts are top-level, not under `users/`.** Under
`users/{uid}` the admin's blanket write permission cascades to every
child, so they could rewrite history. Kept separate, the rules can allow
appending while forbidding edits.

**Alert ids are derived, not pushed** — `{deviceId}-{kind}-{date}`. The
plug and the app both aim at the same key, and the rules only allow a
create where nothing exists. That gives deduplication between the two
writers and a one-per-day limit from the same mechanism.

---

## Hardware

Per plug:

| Part | Notes |
|---|---|
| ESP32 dev board | Any variant with two hardware UARTs |
| PZEM-004T v3.0 | Energy meter — voltage, current, power, cumulative kWh |
| Relay module | Switches the load; active-low by default |

Wiring:

| PZEM-004T | ESP32 |
|---|---|
| TX | GPIO16 (RX2) |
| RX | GPIO17 (TX2) |
| Relay IN | GPIO26 |

The PZEM is fed from mains through its own voltage taps and current
transformer — see the module's datasheet. **Mains wiring is dangerous.
Do not work on it live.**

Each plug derives its own `DEVICE_ID` from its WiFi MAC address at boot,
so no two plugs need to be flashed differently.

---

## Running the app

Requires the Flutter SDK (built against **3.47**, Dart 3.13) and, for
Android, the Android SDK with cmdline-tools.

```bash
flutter pub get
flutter run -d chrome --web-port=5000   # web
flutter run -d <device-id>              # a connected phone
```

Pin the web port. Google and Facebook sign-in both check the origin, and
a random port means re-registering it every session.

### Building an APK

```bash
flutter build apk --release
```

The output lands in `build/app/outputs/flutter-apk/`. Release builds are
currently signed with the **debug key** — fine for sideloading and for a
demo, not publishable to Play. Creating a real release keystore means
registering its SHA-1 with Firebase too, or Google Sign-In breaks in that
build specifically.

---

## Firebase setup

The project expects a Realtime Database and Authentication.

1. **Sign-in providers** — Authentication → Sign-in method: enable
   Email/Password, Google, and Facebook (Facebook needs the App ID and
   App Secret from your Meta app).

2. **Security rules** — these are not optional. Members reading the
   admin's appliances, members switching relays, the control log and the
   alerts all depend on them:

   ```bash
   firebase deploy --only database
   ```

   No Firebase CLI? Paste `database.rules.json` into the console's
   Realtime Database → Rules tab and publish.

3. **Android SHA fingerprint** — Google Sign-In on Android fails with
   `ApiException: 10` without it. Add your signing certificate's SHA-1
   under Project settings → Your apps → Android, then **re-download
   `google-services.json`** — the OAuth client it creates is stored in
   that file.

4. **The plug's account** — the rules let exactly one uid write
   `state`, `telemetry` and `history`. Create that account, and put its
   uid in `database.rules.json` and its credentials in the firmware.

### Facebook login

Needs matching setup on three sides: the app (App ID in
`android/app/src/main/res/values/strings.xml` and
`lib/facebook_auth.dart`), Meta (package name, class name, key hash,
valid OAuth redirect URI), and Firebase (App ID + App Secret). Miss the
redirect URI and login fails with "URL Blocked".

---

## Flashing a plug

Arduino IDE with the ESP32 board package, plus:

- *Firebase Arduino Client Library for ESP8266 and ESP32* (Mobizt)
- *PZEM-004T-v30* (Jakub Mandula)
- *WiFiManager* (tzapu)

Set the Firebase API key and database URL, and the plug account's email
and password at the top of `firmware/esp32_smart_plug/esp32_smart_plug.ino`,
then upload. WiFi is not set in the code.

**Connecting a plug to WiFi:** on first boot the plug opens an open
hotspot named `HomeSync-XXXX` (the last 4 characters of its device ID).
Join it from a phone; the setup page opens (or go to `192.168.4.1`).
Tap **Configure WiFi**, pick your network and enter its password. The
same page shows the device ID — that's what you type into
**Add Appliance**. The serial monitor at 115200 prints it too.

To move a plug to a different network, open the appliance in the app
(**Edit Appliance → Reset WiFi**). The plug forgets its network and
reopens the `HomeSync-XXXX` hotspot. If the saved network is just
temporarily down, the plug keeps retrying it instead of reopening the
hotspot.

> **Do not commit real WiFi credentials.** They are impossible to remove
> from git history once pushed, and a public repo means a public
> password.

---

## Project layout

```
lib/
  main.dart            routes and Firebase init
  login.dart           sign-in, social buttons, password recovery
  signup.dart          registration (creates a household admin)
  household.dart       session, roles, permissions — the access model
  home.dart            dashboard, quick controls, alert banner
  appliances.dart      appliance grid, room filter, whole-room on/off
  add_appliance.dart   claim, edit, set limits, remove
  schedule.dart        schedules and the schedule editor
  report.dart          usage and cost breakdowns
  members.dart         household member management (admin only)
  profile.dart         name and picture, shared avatar widgets
  activity.dart        control log
  alerts.dart          high-consumption alerts
  google_auth.dart     Google Sign-In init (once, process-wide)
  facebook_auth.dart   Facebook web SDK init
  logout.dart          sign-out screen

firmware/esp32_smart_plug/   plug firmware
tool/make_logo.dart          regenerates assets/logo.png from the brand art
database.rules.json          security rules — deploy these
```

---

## Known limitations

**No push notifications.** Alerts appear in the app, not on your lock
screen. Sending a push needs a Cloud Function to trigger it, which needs
the Blaze plan. FCM itself is free; the trigger is not.

**One schedule per appliance.** The plug reads a single schedule object
with one pair of fired-today flags, so an appliance can't be in two
schedules. Assigning one that's already taken moves it.

**No overnight schedules.** The off time must be after the on time —
windows that cross midnight aren't supported by the firmware.

**Schedule-driven switching isn't in the control log.** Those flips
happen on the plug and never pass through the app, so there's no person
to attribute them to. What is logged is who created or changed the
schedule.

**Profile pictures are stored in the database**, as base64 JPEG
downscaled to 256×256 on the device. Cloud Storage would be the proper
home, but it requires the Blaze plan on newer projects.

**`devices` is readable by any signed-in account.** Tightening it risks
breaking the firmware's own reads, so it has been left alone.

**Removing an appliance doesn't erase its history.** `history` is
writable only by the plug's account, so a re-claimed plug carries its
energy log over to the next owner.
