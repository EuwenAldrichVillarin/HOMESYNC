/*
  Homesync IR hub firmware — ESP32 + HX1838 IR receiver + IR LED, synced
  to Firebase Realtime Database. One hub per household copies infrared
  remotes (TVs, aircons, fans, ...) and plays them back on command from
  the app. IR needs line of sight: place the hub where it can see the
  appliances it controls.

  Libraries (install via Arduino IDE Library Manager):
    - "Firebase Arduino Client Library for ESP8266 and ESP32" by Mobizt
    - "IRremoteESP8266" by David Conran, Sebastien Warin, Mark Szabo, Ken Shirriff
    - "WiFiManager" by tzapu (v2.0.x)

  Board settings: "ESP32 Dev Module" with Tools > Partition Scheme >
  "Huge APP (3MB No OTA/1MB SPIFFS)". The sketch is about 1.4 MB, which
  doesn't fit the default 1.3 MB scheme. Checked with esp32 core 3.3.12,
  Firebase client 4.4.17, IRremoteESP8266 2.9.0 and WiFiManager 2.0.17.

  Wiring:
    HX1838 VCC -> ESP32 3V3   (keeps its output at 3.3 V, safe for the ESP32)
    HX1838 GND -> ESP32 GND
    HX1838 OUT -> ESP32 GPIO15
    IR LED     -> ESP32 GPIO4
      A bare 940 nm IR LED on a GPIO only reaches about a metre. For room
      range, drive it through an NPN transistor (e.g. 2N2222: GPIO4 ->
      1 kΩ -> base, emitter -> GND, collector -> LED cathode, LED anode ->
      ~47 Ω -> 5V). A KY-005 module's S pin connects to GPIO4 directly.

  WiFi setup works like the smart plugs: with no saved network the hub
  opens the hotspot "HomeSync-Hub-XXXX" (last 4 characters of the Hub
  ID). Join it, open 192.168.4.1, pick the home network. The setup page
  shows the Hub ID to enter in the app (Edit Appliance > Remote Control).
  Holding the BOOT button while powering on forgets the saved network;
  so does setting hubs/{HUB_ID}/wifiReset = true.

  Firebase Realtime Database schema (must match lib/ir_remote.dart):
    hubs/{HUB_ID}/status/lastSeen   server time, written here every minute
                                    (the app checks the hub exists before
                                    linking it)
    hubs/{HUB_ID}/ownerId           household admin, set by the app on link
    hubs/{HUB_ID}/command           {id, action, khz, pulses?, repeat?, at}
                                    written by the app, streamed here:
                                      action "record": listen up to 15 s for
                                        a remote, then answer with pulses
                                      action "send": transmit `pulses` on a
                                        `khz` carrier, `repeat` times
    hubs/{HUB_ID}/result            {id, status, pulses?, message?} written
                                    here; status is "recorded", "sent" or
                                    "error". `id` echoes the command's id so
                                    the app can match the answer.
    hubs/{HUB_ID}/wifiReset         bool, cleared here, then WiFi is forgotten

  Signal format ("pulses"): microsecond durations of alternating IR mark
  and space, starting with a mark, comma-separated, e.g.
  "9000,4500,560,560,560,1690,...". Stored raw rather than decoded, so any
  protocol works, including long aircon messages that carry the whole
  state (mode, temperature, fan) in one press.

  HUB_ID is this ESP32's WiFi MAC address without colons, printed to
  Serial on boot and shown on the setup page.
*/

#include <Arduino.h>
#include <WiFi.h>
#include <time.h>
#include <WiFiManager.h>
#include <Firebase_ESP_Client.h>
#include <addons/TokenHelper.h>
#include <addons/RTDBHelper.h>
#include <IRremoteESP8266.h>
#include <IRrecv.h>
#include <IRsend.h>
#include <IRutils.h>

// ---------------- USER CONFIG ----------------
#define SETUP_AP_PREFIX   "HomeSync-Hub-"

#define API_KEY           "AIzaSyDjk93m1qry_vN5GJisTzv354B5_dJuqPc"
#define DATABASE_URL      "https://homesync-386ee-default-rtdb.asia-southeast1.firebasedatabase.app/"

// Same dedicated device account as the smart plugs; the database rules
// let only this account write hubs/*/result and hubs/*/status.
#define DEVICE_AUTH_EMAIL    "device@homesync.local"
#define DEVICE_AUTH_PASSWORD "123456"

#define IR_RECV_PIN   15   // HX1838 OUT
#define IR_LED_PIN     4   // IR LED / transistor base / KY-005 S
#define BOOT_BUTTON_PIN 0  // hold at power-on to forget WiFi

#define DEFAULT_CARRIER_KHZ 38
#define RECORD_WINDOW_MS    15000   // must match kIrRecordWindow in the app
#define STATUS_INTERVAL_MS  60000
#define WIFI_RESET_INTERVAL_MS 10000
#define COMMAND_MAX_AGE_MS  60000   // ignore commands older than this (e.g. left over from before a reboot)
#define REPEAT_GAP_MS       40      // pause between repeats of the same signal

// Capture tuning. Aircon remotes send long messages, sometimes as several
// frames with short gaps between them, hence the large buffer and a
// 50 ms end-of-message timeout (the values IRremoteESP8266 recommends for
// aircons).
const uint16_t kCaptureBufferSize = 1024;
const uint8_t kCaptureTimeoutMs = 50;
const uint16_t kMinRawLength = 12;   // shorter captures are noise or "repeat" codes

#define GMT_OFFSET_SEC   (8 * 3600)  // Asia/Manila, UTC+8
#define DST_OFFSET_SEC   0
// ----------------------------------------------

FirebaseData fbdo;
FirebaseData streamFbdo;
FirebaseAuth auth;
FirebaseConfig config;

WiFiManager wifiManager;
String hubId;

IRrecv irrecv(IR_RECV_PIN, kCaptureBufferSize, kCaptureTimeoutMs, true);
IRsend irsend(IR_LED_PIN);
decode_results results;

unsigned long lastStatusMs = 0;
unsigned long lastWifiResetMs = 0;

// The stream callback only stores the command; the work happens in loop()
// so a 15-second recording never blocks the Firebase stream.
volatile bool commandPending = false;
String cmdId;
String cmdAction;
String cmdPulses;
int cmdKhz = DEFAULT_CARRIER_KHZ;
int cmdRepeat = 1;
String lastHandledId;

// ---------------- HELPERS ----------------
String macToHubId() {
  String mac = WiFi.macAddress();
  mac.replace(":", "");
  return mac;
}

String hubPath(const String &suffix) {
  return String("hubs/") + hubId + "/" + suffix;
}

uint64_t nowMs() {
  time_t seconds;
  time(&seconds);
  return (uint64_t)seconds * 1000ULL;
}

void writeResult(const String &id, const char *status, const String &pulses, const String &message) {
  FirebaseJson json;
  json.set("id", id);
  json.set("status", status);
  if (pulses.length() > 0) json.set("pulses", pulses);
  if (message.length() > 0) json.set("message", message);
  json.set("at/.sv", "timestamp");
  if (!Firebase.RTDB.setJSON(&fbdo, hubPath("result"), &json)) {
    Serial.println("Result write failed: " + fbdo.errorReason());
  }
}

// ---------------- RECORD ----------------
// Waits for the first real IR message. The receiver only listens during
// a recording, so remotes pressed at other times are ignored.
void handleRecord(const String &id) {
  Serial.println("Recording IR...");
  irrecv.enableIRIn();
  irrecv.resume();   // drop anything captured before this command

  bool captured = false;
  bool overflowed = false;
  unsigned long start = millis();
  while (millis() - start < RECORD_WINDOW_MS) {
    if (irrecv.decode(&results)) {
      if (results.overflow) {
        overflowed = true;
        irrecv.resume();
        continue;
      }
      if (results.rawlen >= kMinRawLength) {
        captured = true;
        break;
      }
      irrecv.resume();   // noise or a "button held" repeat code
    }
    delay(1);   // let WiFi/Firebase tasks run
  }
  irrecv.disableIRIn();

  if (!captured) {
    Serial.println("Nothing recognisable picked up");
    writeResult(id, "error", "",
                overflowed ? "That remote's signal was too long to record."
                           : "Nothing was picked up. Point the remote at the hub from close by and press the button again.");
    return;
  }

  // Durations in microseconds, mark first.
  uint16_t *raw = resultToRawArray(&results);
  uint16_t length = getCorrectedRawLength(&results);
  String pulses;
  pulses.reserve(length * 6);
  for (uint16_t i = 0; i < length; i++) {
    if (i > 0) pulses += ',';
    pulses += String(raw[i]);
  }
  delete[] raw;

  Serial.printf("Recorded %u durations (%s)\n", length, typeToString(results.decode_type).c_str());
  writeResult(id, "recorded", pulses, "");
}

// ---------------- SEND ----------------
void handleSend(const String &id, int khz, const String &pulses, int repeat) {
  static uint16_t durations[kCaptureBufferSize];
  uint16_t count = 0;
  int startIdx = 0;
  for (int i = 0; i <= (int)pulses.length() && count < kCaptureBufferSize; i++) {
    if (i == (int)pulses.length() || pulses[i] == ',') {
      long value = pulses.substring(startIdx, i).toInt();
      if (value > 0) durations[count++] = value > 65000 ? 65000 : value;
      startIdx = i + 1;
    }
  }
  if (count < 2) {
    writeResult(id, "error", "", "That button's recording is empty. Record it again.");
    return;
  }
  if (khz < 30 || khz > 60) khz = DEFAULT_CARRIER_KHZ;
  if (repeat < 1) repeat = 1;
  if (repeat > 5) repeat = 5;

  Serial.printf("Sending %u durations x%d at %d kHz\n", count, repeat, khz);
  for (int r = 0; r < repeat; r++) {
    if (r > 0) delay(REPEAT_GAP_MS);
    irsend.sendRaw(durations, count, khz);
  }
  writeResult(id, "sent", "", "");
}

// ---------------- COMMAND STREAM ----------------
void streamCallback(FirebaseStream data) {
  // Only whole-command writes matter; the app always sets the full node.
  if (data.dataType() != "json") return;
  FirebaseJson *json = data.jsonObjectPtr();
  FirebaseJsonData item;

  String id, action, pulses;
  int khz = DEFAULT_CARRIER_KHZ;
  int repeat = 1;
  double at = 0;

  if (json->get(item, "id")) id = item.stringValue;
  if (json->get(item, "action")) action = item.stringValue;
  if (json->get(item, "pulses")) pulses = item.stringValue;
  if (json->get(item, "khz")) khz = (int)(item.floatValue + 0.5);
  if (json->get(item, "repeat")) repeat = item.intValue;
  if (json->get(item, "at")) at = item.doubleValue;

  if (id.length() == 0 || id == lastHandledId) return;
  // Skip commands that sat there while the hub was off.
  if (at > 0 && nowMs() > (uint64_t)at + COMMAND_MAX_AGE_MS) {
    Serial.println("Ignoring stale command " + id);
    lastHandledId = id;
    return;
  }

  cmdId = id;
  cmdAction = action;
  cmdPulses = pulses;
  cmdKhz = khz;
  cmdRepeat = repeat;
  commandPending = true;
}

void streamTimeoutCallback(bool timeout) {
  if (timeout) Serial.println("Command stream timed out, resuming...");
  if (!streamFbdo.httpConnected()) {
    Serial.printf("Command stream error, code: %d, reason: %s\n",
                  streamFbdo.httpCode(), streamFbdo.errorReason().c_str());
  }
}

void handlePendingCommand() {
  if (!commandPending) return;
  commandPending = false;
  String id = cmdId;
  lastHandledId = id;

  if (cmdAction == "record") {
    handleRecord(id);
  } else if (cmdAction == "send") {
    handleSend(id, cmdKhz, cmdPulses, cmdRepeat);
  } else {
    writeResult(id, "error", "", "Unknown command");
  }
}

// ---------------- STATUS / WIFI ----------------
void publishStatus() {
  FirebaseJson json;
  json.set("lastSeen/.sv", "timestamp");
  json.set("ip", WiFi.localIP().toString());
  if (!Firebase.RTDB.updateNode(&fbdo, hubPath("status"), &json)) {
    Serial.println("Status write failed: " + fbdo.errorReason());
  }
}

void runSetupPortal() {
  String apName = String(SETUP_AP_PREFIX) + hubId.substring(hubId.length() - 4);

  static String hubIdHtml;
  hubIdHtml =
      "<p style='margin:12px 0 4px'>Hub ID (enter this in the HomeSync app under Remote Control):</p>"
      "<p style='font-size:1.4em;font-weight:bold;letter-spacing:1px;margin:0 0 12px'>" +
      hubId + "</p>";
  static WiFiManagerParameter hubIdInfo(hubIdHtml.c_str());
  wifiManager.addParameter(&hubIdInfo);

  wifiManager.setTitle("HomeSync IR Hub");
  wifiManager.setConfigPortalTimeout(0);
  wifiManager.setConnectTimeout(20);

  Serial.println("No WiFi saved. Join the hotspot \"" + apName + "\" and open 192.168.4.1 to set it up.");
  if (wifiManager.startConfigPortal(apName.c_str())) {
    Serial.println("WiFi saved: " + WiFi.SSID());
  }
  delay(1000);
  ESP.restart();
}

void connectWiFi() {
  if (!wifiManager.getWiFiIsSaved()) {
    runSetupPortal();
    return;
  }
  WiFi.begin();
  Serial.print("Connecting to saved WiFi");
  while (WiFi.status() != WL_CONNECTED) {
    delay(300);
    Serial.print(".");
  }
  Serial.println("\nWiFi connected: " + WiFi.localIP().toString());
}

void checkWifiReset() {
  if (!Firebase.RTDB.getBool(&fbdo, hubPath("wifiReset"))) return;
  if (!fbdo.boolData()) return;
  Serial.println("WiFi reset requested from the app");
  if (!Firebase.RTDB.deleteNode(&fbdo, hubPath("wifiReset"))) {
    Serial.println("Couldn't clear wifiReset: " + fbdo.errorReason());
    return;
  }
  wifiManager.resetSettings();
  delay(1000);
  ESP.restart();
}

// ---------------- SETUP / LOOP ----------------
void setup() {
  Serial.begin(115200);
  pinMode(BOOT_BUTTON_PIN, INPUT_PULLUP);

  irsend.begin();                       // LED pin low (off) until a send
  irrecv.setUnknownThreshold(kMinRawLength);

  WiFi.mode(WIFI_STA);
  hubId = macToHubId();
  Serial.println("======================================");
  Serial.println("HUB ID (enter this in the Homesync app): " + hubId);
  Serial.println("======================================");

  // BOOT held at power-on: forget WiFi and reopen the setup hotspot.
  if (digitalRead(BOOT_BUTTON_PIN) == LOW) {
    delay(2000);
    if (digitalRead(BOOT_BUTTON_PIN) == LOW) {
      Serial.println("BOOT held: forgetting WiFi");
      wifiManager.resetSettings();
    }
  }

  connectWiFi();

  configTime(GMT_OFFSET_SEC, DST_OFFSET_SEC, "pool.ntp.org", "time.nist.gov");
  Serial.print("Syncing time");
  struct tm timeinfo;
  while (!getLocalTime(&timeinfo, 1000)) {
    Serial.print(".");
  }
  Serial.println();

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

  publishStatus();   // so hubs/{HUB_ID} exists before the app tries to link it
  lastStatusMs = millis();

  if (!Firebase.RTDB.beginStream(&streamFbdo, hubPath("command"))) {
    Serial.println("Command stream begin failed: " + streamFbdo.errorReason());
  }
  Firebase.RTDB.setStreamCallback(&streamFbdo, streamCallback, streamTimeoutCallback);
}

void loop() {
  if (Firebase.ready()) handlePendingCommand();

  if (Firebase.ready() && millis() - lastStatusMs > STATUS_INTERVAL_MS) {
    lastStatusMs = millis();
    publishStatus();
  }

  if (Firebase.ready() && millis() - lastWifiResetMs > WIFI_RESET_INTERVAL_MS) {
    lastWifiResetMs = millis();
    checkWifiReset();
  }
}
