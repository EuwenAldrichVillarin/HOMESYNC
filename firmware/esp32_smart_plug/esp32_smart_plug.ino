/*
  Homesync smart plug firmware — ESP32 + PZEM-004T (v3.0) + relay,
  synced to Firebase Realtime Database.

  Libraries (install via Arduino IDE Library Manager):
    - "Firebase Arduino Client Library for ESP8266 and ESP32" by Mobizt
    - "PZEM-004T-v30" by Jakub Mandula

  Wiring:
    PZEM-004T TX  -> ESP32 GPIO16 (RX2)
    PZEM-004T RX  -> ESP32 GPIO17 (TX2)
    PZEM-004T fed from mains via its own CT/voltage taps (see module datasheet)
    Relay IN      -> ESP32 GPIO26
    Relay VCC/GND -> 5V/GND (opto-isolated relay modules recommended)

  Firebase Realtime Database schema (must match lib/add_appliance.dart
  and lib/appliances.dart in the Homesync app):
    devices/{DEVICE_ID}/state/relay      bool    actual relay state   (this device writes)
    devices/{DEVICE_ID}/telemetry/*      number  power/voltage/etc.   (this device writes)
    devices/{DEVICE_ID}/command/relay    bool    desired relay state  (the app writes, this device listens)
    devices/{DEVICE_ID}/info             map     {name, room, type}   (the app writes, never touched here)
    devices/{DEVICE_ID}/ownerId          string  set by the app when a user claims this device
    devices/{DEVICE_ID}/history/{date}   number  kWh used on that calendar date (YYYY-MM-DD, local time),
                                                  this device writes it — the app's Report screen reads it
                                                  to build the daily/weekly/monthly usage chart
    devices/{DEVICE_ID}/schedule         map     {enabled, days: {mon..sun}, startMinutes, endMinutes}
    devices/{DEVICE_ID}/limits           map     {maxWatts, maxDailyKwh}  (the app writes, this device reads)
    alerts/{OWNER_UID}/{ALERT_ID}        map     raised here when a limit is exceeded; the id is
                                                  "{DEVICE_ID}-{kind}-{YYYY-MM-DD}" so the same breach
                                                  can only ever be filed once a day
                                                  set by the app's Schedule screen, read-only here. Only
                                                  same-day windows are supported (startMinutes < endMinutes) —
                                                  this device turns the relay ON at startMinutes and OFF at
                                                  endMinutes on any enabled day, then leaves it alone for the
                                                  rest of the day, so a manual toggle in between sticks until
                                                  the next scheduled boundary.

  The app's "Add Appliance" screen only lets a user claim a device that
  already has a devices/{DEVICE_ID} node, so this firmware must publish
  at least once (see sendTelemetry) before the device ID can be added
  in the app.

  DEVICE_ID is derived from this ESP32's WiFi MAC address at boot (colons
  stripped, e.g. "AABBCCDDEEFF") rather than hardcoded, so every board gets
  a unique ID automatically. It's printed to Serial on startup — read it
  off the Serial Monitor once and type it into the app's Device ID field
  (or print it on a label/QR code for the physical plug).
*/

#include <Arduino.h>
#include <WiFi.h>
#include <time.h>
#include <PZEM004Tv30.h>
#include <Firebase_ESP_Client.h>
#include <addons/TokenHelper.h>
#include <addons/RTDBHelper.h>

// ---------------- USER CONFIG ----------------
#define WIFI_SSID         "Euwen"
#define WIFI_PASSWORD     "kalimotko"

#define API_KEY           "AIzaSyDjk93m1qry_vN5GJisTzv354B5_dJuqPc"
#define DATABASE_URL      "https://homesync-386ee-default-rtdb.asia-southeast1.firebasedatabase.app/"

// Create a dedicated Firebase Auth user for devices (e.g. in the Firebase
// console under Authentication > Users) and put its credentials here.
// Your RTDB security rules must allow this user to read/write "devices/*".
#define DEVICE_AUTH_EMAIL    "device@homesync.local"
#define DEVICE_AUTH_PASSWORD "123456"

#define RELAY_PIN         26
#define RELAY_ACTIVE_LOW  true             // most relay modules switch ON when the pin is driven LOW

#define PZEM_RX_PIN       16   // ESP32 RX2 <- PZEM TX
#define PZEM_TX_PIN       17   // ESP32 TX2 -> PZEM RX

#define TELEMETRY_INTERVAL_MS 3000
#define HISTORY_INTERVAL_MS   60000  // how often to update today's running kWh total
#define SCHEDULE_INTERVAL_MS  30000  // how often to check devices/{id}/schedule
#define LIMITS_INTERVAL_MS    60000  // how often to re-read devices/{id}/limits

#define GMT_OFFSET_SEC   (8 * 3600) // Asia/Manila, UTC+8 — change for your timezone
#define DST_OFFSET_SEC   0
// ----------------------------------------------

PZEM004Tv30 pzem(Serial2, PZEM_RX_PIN, PZEM_TX_PIN);

FirebaseData fbdo;
FirebaseData streamFbdo;
FirebaseAuth auth;
FirebaseConfig config;

bool relayState = false;
unsigned long lastTelemetryMs = 0;
unsigned long lastHistoryMs = 0;
unsigned long lastScheduleMs = 0;
unsigned long lastLimitsMs = 0;
String deviceId; // set in setup() from the WiFi MAC address

// High-consumption limits, re-read from the database so the app can
// change them without this device being re-flashed. 0 means "no limit",
// which is also what an unset value reads back as.
float maxWatts = 0;
float maxDailyKwh = 0;
String ownerUid;    // devices/{id}/ownerId — the household alerts are filed under
String deviceName;  // devices/{id}/info/name — so an alert reads as a name, not a MAC

// One alert per kind per day. Without this a sustained overload would
// file an alert every telemetry cycle, i.e. every three seconds.
String alertLatchedDate;
bool powerAlertFired = false;
bool dailyAlertFired = false;

String scheduleCheckedDate;    // date the start/end-fired flags below apply to
bool scheduleStartFired = false;
bool scheduleEndFired = false;

float lastEnergyReading = NAN;   // most recent successful pzem.energy() reading
String currentDay;               // "YYYY-MM-DD" this device is currently logging against
float dayStartEnergy = 0;        // cumulative energy reading at the start of currentDay
bool dayBaselineReady = false;   // false until dayStartEnergy means something

String macToDeviceId() {
  String mac = WiFi.macAddress(); // e.g. "AA:BB:CC:DD:EE:FF"
  mac.replace(":", "");
  return mac; // WiFi.macAddress() is already uppercase hex
}

String devicePath(const String &suffix) {
  return String("devices/") + deviceId + "/" + suffix;
}

// Returns today's date as "YYYY-MM-DD" in local time, or "" if the clock
// hasn't synced with NTP yet.
String getDateString() {
  struct tm timeinfo;
  if (!getLocalTime(&timeinfo, 1000)) {
    return "";
  }
  char buf[11];
  strftime(buf, sizeof(buf), "%Y-%m-%d", &timeinfo);
  return String(buf);
}

// Sets dayStartEnergy so that (currentEnergy - dayStartEnergy) equals kWh
// used so far today. If Firebase already has a partial total for today
// (e.g. this device rebooted mid-day), that's recovered instead of
// restarting the day's count from zero.
void initDailyBaseline(float currentEnergy) {
  dayBaselineReady = true;
  currentDay = getDateString();
  if (currentDay == "") {
    dayStartEnergy = currentEnergy;
    return;
  }

  if (Firebase.RTDB.getFloat(&fbdo, devicePath("history/" + currentDay))) {
    dayStartEnergy = currentEnergy - fbdo.floatData();
  } else {
    dayStartEnergy = currentEnergy;
  }
}

// Publishes today's kWh-so-far, rolling the baseline over whenever the
// local calendar date changes.
void updateHistory(float currentEnergy) {
  String today = getDateString();
  if (today == "") return; // clock not synced yet, skip this cycle

  if (today != currentDay) {
    currentDay = today;
    dayStartEnergy = currentEnergy;
    dayBaselineReady = true;
  }

  float todayKwh = currentEnergy - dayStartEnergy;
  if (todayKwh < 0) todayKwh = 0; // guards against a PZEM counter reset

  if (!Firebase.RTDB.setFloat(&fbdo, devicePath("history/" + currentDay), todayKwh)) {
    Serial.println("History update failed: " + fbdo.errorReason());
  }
}

// Re-reads the limits, the owner and the display name. All three are
// the app's to change at any time, so they're polled rather than read
// once at boot.
void refreshLimits() {
  maxWatts = Firebase.RTDB.getFloat(&fbdo, devicePath("limits/maxWatts")) ? fbdo.floatData() : 0;
  maxDailyKwh = Firebase.RTDB.getFloat(&fbdo, devicePath("limits/maxDailyKwh")) ? fbdo.floatData() : 0;
  ownerUid = Firebase.RTDB.getString(&fbdo, devicePath("ownerId")) ? fbdo.stringData() : String("");
  deviceName = Firebase.RTDB.getString(&fbdo, devicePath("info/name")) ? fbdo.stringData() : String("");
}

// Files one alert under the owning household.
//
// The id is derived from the device, the kind and today's date rather
// than pushed, so it names the same slot every time. The security rules
// only allow a create where nothing exists yet, which makes a repeat
// write harmlessly fail — that's also what stops this device and the
// app from double-reporting the same breach.
void raiseAlert(const char *kind, float value, float limit) {
  if (ownerUid == "") return; // unclaimed plug: nowhere to file it

  String today = getDateString();
  if (today == "") return; // clock not synced yet

  String path = "alerts/" + ownerUid + "/" + deviceId + "-" + String(kind) + "-" + today;

  FirebaseJson json;
  json.set("at/.sv", "timestamp"); // resolved by the server, like the app does
  json.set("deviceId", deviceId);
  json.set("deviceName", deviceName.length() ? deviceName : deviceId);
  json.set("kind", kind);
  json.set("value", value);
  json.set("limit", limit);
  json.set("acknowledged", false);

  if (Firebase.RTDB.setJSON(&fbdo, path, &json)) {
    Serial.printf("Alert raised: %s %.2f over %.2f\n", kind, value, limit);
  } else {
    // Expected whenever this breach is already on record for today.
    Serial.println("Alert not filed: " + fbdo.errorReason());
  }
}

// Compares the latest readings against the limits. Called from the
// telemetry cycle, so a power spike is caught within a few seconds.
void checkLimits(float power, float todayKwh) {
  String today = getDateString();
  if (today == "") return;

  if (today != alertLatchedDate) {
    alertLatchedDate = today;
    powerAlertFired = false;
    dailyAlertFired = false;
  }

  if (!powerAlertFired && maxWatts > 0 && power > maxWatts) {
    powerAlertFired = true;
    raiseAlert("power", power, maxWatts);
  }

  // Without a baseline, todayKwh would be the meter's lifetime total
  // rather than today's use, and would trip any budget immediately.
  if (!dailyAlertFired && dayBaselineReady && maxDailyKwh > 0 && todayKwh > maxDailyKwh) {
    dailyAlertFired = true;
    raiseAlert("daily", todayKwh, maxDailyKwh);
  }
}

// Checks devices/{id}/schedule and flips the relay at the two boundary
// instants (window start / window end) for today, at most once each per
// day. Between those boundaries it never re-asserts anything, so a manual
// toggle from the app in the middle of the window sticks until the next
// boundary — the schedule only acts at the edges, it doesn't fight you.
//
// Only same-day windows are supported: startMinutes must be < endMinutes.
void checkSchedule() {
  String today = getDateString();
  if (today == "") return;

  if (today != scheduleCheckedDate) {
    scheduleCheckedDate = today;
    scheduleStartFired = false;
    scheduleEndFired = false;
  }

  if (!Firebase.RTDB.getJSON(&fbdo, devicePath("schedule"))) {
    return; // no schedule saved for this device yet
  }

  FirebaseJson &json = fbdo.jsonObject();
  FirebaseJsonData result;

  json.get(result, "enabled");
  if (!result.success || !result.boolValue) return;

  struct tm timeinfo;
  if (!getLocalTime(&timeinfo, 1000)) return;

  static const char *dayKeys[7] = {"sun", "mon", "tue", "wed", "thu", "fri", "sat"};
  json.get(result, String("days/") + dayKeys[timeinfo.tm_wday]);
  if (!result.success || !result.boolValue) return; // not scheduled for today

  json.get(result, "startMinutes");
  if (!result.success) return;
  int startMin = result.intValue;

  json.get(result, "endMinutes");
  if (!result.success) return;
  int endMin = result.intValue;

  if (startMin < 0 || endMin < 0 || startMin >= endMin) return; // unset or unsupported overnight window

  int nowMin = timeinfo.tm_hour * 60 + timeinfo.tm_min;

  if (!scheduleStartFired && nowMin >= startMin && nowMin < endMin) {
    scheduleStartFired = true;
    setRelay(true);
  }

  if (!scheduleEndFired && nowMin >= endMin) {
    scheduleEndFired = true;
    setRelay(false);
  }
}

void writeRelayPin(bool on) {
  bool pinLevel = RELAY_ACTIVE_LOW ? !on : on;
  digitalWrite(RELAY_PIN, pinLevel ? HIGH : LOW);
  relayState = on;
}

void setRelay(bool on) {
  writeRelayPin(on);
  Firebase.RTDB.setBool(&fbdo, devicePath("state/relay"), relayState);
}

void streamCallback(FirebaseStream data) {
  if (data.dataType() == "boolean") {
    setRelay(data.boolData());
  }
}

void streamTimeoutCallback(bool timeout) {
  if (timeout) {
    Serial.println("Command stream timed out, resuming...");
  }
  if (!streamFbdo.httpConnected()) {
    Serial.printf(
        "Command stream error, code: %d, reason: %s\n",
        streamFbdo.httpCode(), streamFbdo.errorReason().c_str());
  }
}

void sendTelemetry() {
  float voltage = pzem.voltage();
  float current = pzem.current();
  float power = pzem.power();
  float energy = pzem.energy();
  float frequency = pzem.frequency();
  float pf = pzem.pf();

  if (isnan(voltage)) {
    Serial.println("PZEM read error (check wiring)");
    return;
  }

  lastEnergyReading = energy;

  FirebaseJson json;
  json.set("power", power);
  json.set("voltage", voltage);
  json.set("current", current);
  json.set("energy", energy);
  json.set("frequency", frequency);
  json.set("pf", pf);

  if (Firebase.RTDB.updateNode(&fbdo, devicePath("telemetry"), &json)) {
    Serial.printf("Telemetry sent: %.1fW, %.1fV, %.2fA\n", power, voltage, current);
  } else {
    Serial.println("Telemetry send failed: " + fbdo.errorReason());
  }

  // Same readings we just published, checked against the user's limits.
  float todayKwh = energy - dayStartEnergy;
  if (todayKwh < 0) todayKwh = 0;
  checkLimits(power, todayKwh);
}

void setup() {
  Serial.begin(115200);

  pinMode(RELAY_PIN, OUTPUT);
  writeRelayPin(false); // safe default before Firebase/WiFi are up

  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  Serial.print("Connecting to WiFi");
  while (WiFi.status() != WL_CONNECTED) {
    delay(300);
    Serial.print(".");
  }
  Serial.println("\nWiFi connected: " + WiFi.localIP().toString());

  configTime(GMT_OFFSET_SEC, DST_OFFSET_SEC, "pool.ntp.org", "time.nist.gov");
  Serial.print("Syncing time");
  struct tm timeinfo;
  while (!getLocalTime(&timeinfo, 1000)) {
    Serial.print(".");
  }
  Serial.println();

  deviceId = macToDeviceId();
  Serial.println("======================================");
  Serial.println("DEVICE ID (enter this in the Homesync app): " + deviceId);
  Serial.println("======================================");

  config.api_key = API_KEY;
  config.database_url = DATABASE_URL;
  config.token_status_callback = tokenStatusCallback;

  auth.user.email = DEVICE_AUTH_EMAIL;
  auth.user.password = DEVICE_AUTH_PASSWORD;

  Firebase.begin(&config, &auth);
  Firebase.reconnectWiFi(true);

  Serial.print("Authenticating with Firebase");
  while (!Firebase.ready()) {
    delay(300);
    Serial.print(".");
  }
  Serial.println("\nFirebase ready");

  // Establish today's kWh baseline (recovers any partial total already
  // logged today if this device is rebooting mid-day).
  float bootEnergy = pzem.energy();
  if (!isnan(bootEnergy)) {
    lastEnergyReading = bootEnergy;
    initDailyBaseline(bootEnergy);
  }

  // Pick up any relay command left pending from before this device booted.
  if (Firebase.RTDB.getBool(&fbdo, devicePath("command/relay"))) {
    setRelay(fbdo.boolData());
  } else {
    setRelay(false);
  }

  if (!Firebase.RTDB.beginStream(&streamFbdo, devicePath("command/relay"))) {
    Serial.println("Command stream begin failed: " + streamFbdo.errorReason());
  }
  Firebase.RTDB.setStreamCallback(&streamFbdo, streamCallback, streamTimeoutCallback);

  refreshLimits(); // before the first telemetry cycle, so it can already alert
  lastLimitsMs = millis();

  sendTelemetry(); // publish once immediately so devices/{DEVICE_ID} exists right away
  lastTelemetryMs = millis();

  checkSchedule(); // let a schedule immediately override the restored command above if needed
  lastScheduleMs = millis();
}

void loop() {
  if (Firebase.ready() && millis() - lastTelemetryMs > TELEMETRY_INTERVAL_MS) {
    lastTelemetryMs = millis();
    sendTelemetry();
  }

  if (Firebase.ready() && millis() - lastHistoryMs > HISTORY_INTERVAL_MS) {
    lastHistoryMs = millis();
    if (!isnan(lastEnergyReading)) {
      updateHistory(lastEnergyReading);
    }
  }

  if (Firebase.ready() && millis() - lastScheduleMs > SCHEDULE_INTERVAL_MS) {
    lastScheduleMs = millis();
    checkSchedule();
  }

  if (Firebase.ready() && millis() - lastLimitsMs > LIMITS_INTERVAL_MS) {
    lastLimitsMs = millis();
    refreshLimits();
  }
}
