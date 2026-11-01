/*
  AgriFeed - ESP32 feeder controller connected to Firebase (Realtime Database)
  LCD + RTC + HX711 load cell + Buzzer + Servo gate, plus Wi-Fi / Firebase Cloud.

  The ESP32 is the feeder's controller. It talks over HTTPS to the SAME
  Firebase project and database as the Flutter app (agrifeed-dda82,
  agrifeed-dda82-default-rtdb) and uses the app's paths under
  feeders/<feederId>/ with source 'device':

    ESP32 -> Firebase -> app   status (online, condition), telemetry/current
                               (hopper weight), measurements, history,
                               alerts, gate/state, Feed now progress and
                               the MEASURED result
    app -> Firebase -> ESP32   gate/request (OPEN/CLOSE), commands +
                               activeCommand (Feed now), schedules, config

  Libraries (Library Manager):
    - "ESP32Servo"        by Kevin Harrington
    - "LiquidCrystal I2C" by Frank de Brabander
    - "RTClib"            by Adafruit
    - "HX711"             by Bogdan Necula (bogde)
    - "ArduinoJson"       by Benoit Blanchon (version 7.x)
    - "WiFiManager"       by tzapu (version 2.0.x)
  WiFi, HTTPClient, NetworkClientSecure and Preferences come with the ESP32
  board package (esp32 by Espressif, 3.x).

  Wiring (unchanged):
    LCD   SDA -> GPIO25   SCL -> GPIO26   (I2C bus 0 = Wire)
    RTC   SDA -> GPIO21   SCL -> GPIO22   (I2C bus 1 = Wire1)
    HX711 DT  -> GPIO16   SCK -> GPIO17   (VCC on 3V3)
    Servo signal -> GPIO18  (servo red on EXTERNAL 5V, common GND, 1000 uF capacitor)
    Buzzer S  -> GPIO27   (V on 3V3)
    (The on-board BOOT button, GPIO0, opens Wi-Fi setup when held 3 s.)

  The load cell weighs the HOPPER: feed given = hopper weight before - after.

  Wi-Fi and the device account are NOT in this file. On first start (or after
  holding BOOT for 3 s, or sending 'w') the ESP32 opens the Wi-Fi network
  "AgriFeed-Setup". Join it with a phone, pick the farm's Wi-Fi, and enter
  the feeder ID, device email and device password. They are saved in the
  ESP32's flash; the ESP32 reconnects by itself after Wi-Fi drops.

  What it does:
    - Gate (servo): opens only when the app asks (gate OPEN, Feed now, a
      schedule). It closes itself when the time is up, even with no Wi-Fi.
      CLOSE always wins. Gate requests older than 10 s are rejected.
    - Feed now / schedules: opens the gate until the hopper has lost the
      requested grams, then closes and reports the MEASURED amount.
    - Schedules are kept in flash and run from the RTC even while offline;
      their results are sent when the connection is back.
    - Buzzer: short beep each time the servo moves.
    - LCD line 1: time + gate state + link (* online, ! offline, W setup)
      LCD line 2: weight in grams (or feeding progress / gate countdown)
    - Serial Monitor (115200, Newline): t = tare, c = calibrate, r = raw toggle,
      s = status, w = Wi-Fi setup, x = forget Wi-Fi and device account.
      Tare and calibration are saved and survive a restart.

  Hardware runs in loop() on core 1 and never waits for the network; Wi-Fi
  and Firebase run in their own task on core 0.

  COMPILE FIX: the struct PendingHistory is now defined together with the
  other structs, BEFORE the first function. The Arduino IDE inserts function
  prototypes above the first function, so a struct used in a function
  parameter (postHistory) must already be defined there.
*/

#include <Wire.h>
#include <LiquidCrystal_I2C.h>
#include <ESP32Servo.h>
#include <RTClib.h>
#include "HX711.h"
#include <WiFi.h>
#include <WiFiManager.h>
#include <NetworkClientSecure.h>
#include <HTTPClient.h>
#include <Preferences.h>
#include <ArduinoJson.h>
#include <time.h>
#include <sys/time.h>

// ---- Firebase project (same as the app's lib/firebase_options.dart) ----
// The web API key only identifies the project; access is decided by the
// device account and the database Security Rules.
const char* FIREBASE_API_KEY = "AIzaSyDKLwAToh1rYL9RHn56KBTlBXzX-6TofwE";
const char* DATABASE_HOST    = "agrifeed-dda82-default-rtdb.firebaseio.com";
const char* FIRMWARE         = "esp32-2.1-wifidiag";   // shows in status/firmware: proves this build runs
// Used until the feeder's time zone (meta/timezone) has been read once.
const char* TZ_FALLBACK      = "PHT-8";   // Asia/Manila

// ---- Wi-Fi setup portal --------------------------------------------------
const char* PORTAL_SSID     = "AgriFeed-Setup";
const char* PORTAL_PASSWORD = "agrifeed123";   // at least 8 characters; change it
const unsigned long WIFI_GIVE_UP_MS  = 60000;  // no Wi-Fi this long: open setup too
const unsigned long PORTAL_TIMEOUT_S = 300;    // setup closes after 5 min unused
const unsigned long WIFI_RETRY_MS    = 20000;  // retry the saved network this often, portal open or not
const unsigned long WIFI_RSSI_LOG_MS = 30000;  // log signal strength this often while connected
const bool WIFI_DISABLE_SLEEP = true;          // modem sleep off: fewer drops with phone hotspots
const bool ENABLE_SETUP_BUTTON = true;
#define SETUP_BUTTON_PIN 0                     // on-board BOOT button

// Google Trust Services roots (GTS Root R1 and R4, valid until 2036). They
// sign the certificates of firebaseio.com and googleapis.com.
const char* GOOGLE_ROOT_CAS = R"PEM(
-----BEGIN CERTIFICATE-----
MIIFVzCCAz+gAwIBAgINAgPlk28xsBNJiGuiFzANBgkqhkiG9w0BAQwFADBHMQsw
CQYDVQQGEwJVUzEiMCAGA1UEChMZR29vZ2xlIFRydXN0IFNlcnZpY2VzIExMQzEU
MBIGA1UEAxMLR1RTIFJvb3QgUjEwHhcNMTYwNjIyMDAwMDAwWhcNMzYwNjIyMDAw
MDAwWjBHMQswCQYDVQQGEwJVUzEiMCAGA1UEChMZR29vZ2xlIFRydXN0IFNlcnZp
Y2VzIExMQzEUMBIGA1UEAxMLR1RTIFJvb3QgUjEwggIiMA0GCSqGSIb3DQEBAQUA
A4ICDwAwggIKAoICAQC2EQKLHuOhd5s73L+UPreVp0A8of2C+X0yBoJx9vaMf/vo
27xqLpeXo4xL+Sv2sfnOhB2x+cWX3u+58qPpvBKJXqeqUqv4IyfLpLGcY9vXmX7w
Cl7raKb0xlpHDU0QM+NOsROjyBhsS+z8CZDfnWQpJSMHobTSPS5g4M/SCYe7zUjw
TcLCeoiKu7rPWRnWr4+wB7CeMfGCwcDfLqZtbBkOtdh+JhpFAz2weaSUKK0Pfybl
qAj+lug8aJRT7oM6iCsVlgmy4HqMLnXWnOunVmSPlk9orj2XwoSPwLxAwAtcvfaH
szVsrBhQf4TgTM2S0yDpM7xSma8ytSmzJSq0SPly4cpk9+aCEI3oncKKiPo4Zor8
Y/kB+Xj9e1x3+naH+uzfsQ55lVe0vSbv1gHR6xYKu44LtcXFilWr06zqkUspzBmk
MiVOKvFlRNACzqrOSbTqn3yDsEB750Orp2yjj32JgfpMpf/VjsPOS+C12LOORc92
wO1AK/1TD7Cn1TsNsYqiA94xrcx36m97PtbfkSIS5r762DL8EGMUUXLeXdYWk70p
aDPvOmbsB4om3xPXV2V4J95eSRQAogB/mqghtqmxlbCluQ0WEdrHbEg8QOB+DVrN
VjzRlwW5y0vtOUucxD/SVRNuJLDWcfr0wbrM7Rv1/oFB2ACYPTrIrnqYNxgFlQID
AQABo0IwQDAOBgNVHQ8BAf8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4E
FgQU5K8rJnEaK0gnhS9SZizv8IkTcT4wDQYJKoZIhvcNAQEMBQADggIBAJ+qQibb
C5u+/x6Wki4+omVKapi6Ist9wTrYggoGxval3sBOh2Z5ofmmWJyq+bXmYOfg6LEe
QkEzCzc9zolwFcq1JKjPa7XSQCGYzyI0zzvFIoTgxQ6KfF2I5DUkzps+GlQebtuy
h6f88/qBVRRiClmpIgUxPoLW7ttXNLwzldMXG+gnoot7TiYaelpkttGsN/H9oPM4
7HLwEXWdyzRSjeZ2axfG34arJ45JK3VmgRAhpuo+9K4l/3wV3s6MJT/KYnAK9y8J
ZgfIPxz88NtFMN9iiMG1D53Dn0reWVlHxYciNuaCp+0KueIHoI17eko8cdLiA6Ef
MgfdG+RCzgwARWGAtQsgWSl4vflVy2PFPEz0tv/bal8xa5meLMFrUKTX5hgUvYU/
Z6tGn6D/Qqc6f1zLXbBwHSs09dR2CQzreExZBfMzQsNhFRAbd03OIozUhfJFfbdT
6u9AWpQKXCBfTkBdYiJ23//OYb2MI3jSNwLgjt7RETeJ9r/tSQdirpLsQBqvFAnZ
0E6yove+7u7Y/9waLd64NnHi/Hm3lCXRSHNboTXns5lndcEZOitHTtNCjv0xyBZm
2tIMPNuzjsmhDYAPexZ3FL//2wmUspO8IFgV6dtxQ/PeEMMA3KgqlbbC1j+Qa3bb
bP6MvPJwNQzcmRk13NfIRmPVNnGuV/u3gm3c
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
MIICCTCCAY6gAwIBAgINAgPlwGjvYxqccpBQUjAKBggqhkjOPQQDAzBHMQswCQYD
VQQGEwJVUzEiMCAGA1UEChMZR29vZ2xlIFRydXN0IFNlcnZpY2VzIExMQzEUMBIG
A1UEAxMLR1RTIFJvb3QgUjQwHhcNMTYwNjIyMDAwMDAwWhcNMzYwNjIyMDAwMDAw
WjBHMQswCQYDVQQGEwJVUzEiMCAGA1UEChMZR29vZ2xlIFRydXN0IFNlcnZpY2Vz
IExMQzEUMBIGA1UEAxMLR1RTIFJvb3QgUjQwdjAQBgcqhkjOPQIBBgUrgQQAIgNi
AATzdHOnaItgrkO4NcWBMHtLSZ37wWHO5t5GvWvVYRg1rkDdc/eJkTBa6zzuhXyi
QHY7qca4R9gq55KRanPpsXI5nymfopjTX15YhmUPoYRlBtHci8nHc8iMai/lxKvR
HYqjQjBAMA4GA1UdDwEB/wQEAwIBhjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQW
BBSATNbrdP9JNqPV2Py1PsVq8JQdjDAKBggqhkjOPQQDAwNpADBmAjEA6ED/g94D
9J+uHXqnLrmvT/aDHQ4thQEd0dlq7A/Cr8deVl5c1RxYIigL9zC2L7F8AjEA8GE8
p/SgguMh1YQdc4acLa/KNJvxn7kjNuK8YAOdgLOaVsjh4rsUecrNIdSUtUlD
-----END CERTIFICATE-----
)PEM";

// ---- Pins -----------------------------------------------------------
#define SERVO_PIN  18
#define BUZZER_PIN 27
#define LCD_SDA    25
#define LCD_SCL    26
#define RTC_SDA    21
#define RTC_SCL    22
#define HX_DT      16
#define HX_SCK     17

// ---- Switch parts on/off for testing --------------------------------
const bool ENABLE_SERVO  = true;
const bool ENABLE_BUZZER = true;

// ---- Settings you can change ----------------------------------------
const bool BUZZER_ACTIVE_LOW = false;        // true for "low level trigger" buzzer modules
const int  ANGLE_CLOSED      = 0;
const int  ANGLE_OPEN        = 90;
const unsigned long BEEP_MS        = 100;
const unsigned long LCD_REFRESH_MS = 500;
// How often weight + status go to Firebase (the app updates as soon as they arrive).
const unsigned long REPORT_IDLE_MS  = 1000;  // weight to Firebase, gate closed (was 5000)
const unsigned long REPORT_BUSY_MS  = 1000;  // weight to Firebase, gate open or feeding
const unsigned long STATUS_EVERY_MS = 5000;  // online heartbeat (app says offline after 30 s)

// Gate and feeding limits (same as the app and the simulator).
const unsigned long GATE_MAX_MS     = 15000;  // longest timed gate OPEN (app OPEN now holds instead)
// App OPEN keeps the gate open until CLOSE. Safety net: if the feeder cannot
// reach Firebase for this long while held open, the app could not close it,
// so the controller closes it itself.
const unsigned long GATE_OFFLINE_CLOSE_MS = 30000;
const unsigned long GATE_MAX_AGE_MS = 10000;  // older OPEN/CLOSE requests are rejected
const unsigned long COMMAND_TTL_MS  = 120000; // older Feed now requests are left to the app
const unsigned long DISPENSE_MAX_MS = 15000;  // longest the gate stays open for one feeding
const unsigned long NO_FLOW_MS      = 4000;   // no weight drop by then = jam or empty
const float         NO_FLOW_MIN_G   = 3.0;
const float         DISPENSE_LEAD_G = 5.0;    // close early: feed is still falling (tune it)
const unsigned long SETTLE_MS       = 2000;   // wait after closing before measuring
const float         LOW_HYSTERESIS_G = 20.0;

// Placeholder. Calibrate with 'c' in Serial Monitor; the result is saved.
float calibrationFactor = 420.0;

// ---- Objects and state ----------------------------------------------
LiquidCrystal_I2C lcd(0x27, 16, 2);          // use 0x3F if the screen stays blank
RTC_DS3231 rtc;
HX711 scale;
Servo myServo;
Preferences prefs;       // used by loop() (scale) and the network task (account, cache)
SemaphoreHandle_t prefsLock;
SemaphoreHandle_t rtcLock;  // the RTC bus (Wire1) is used from both cores
char rtcTimeStr[20] = "";   // last good RTC reading, "YYYY-MM-DDTHH:MM:SS" local time
unsigned long lastRtcRead = 0;

bool rtcOk = false;
bool hxOk  = false;
bool rawMode = false;
bool calibrated = false;

float weightGrams = 0;
long  rawValue = 0;
unsigned long lastSampleAt = 0;

bool servoOpen = false;

bool buzzerActive = false;
unsigned long buzzerOffAt = 0;

unsigned long lastLcdUpdate = 0;
unsigned long lastSerialPrint = 0;
unsigned long buttonDownAt = 0;

// ---- Hardware jobs (run in loop(), never wait on the network) -----------
enum HwState { HW_IDLE, HW_GATE, HW_DISPENSE, HW_SETTLE, HW_CALIBRATING };
enum HwCmdType { CMD_GATE_OPEN, CMD_GATE_CLOSE, CMD_DISPENSE, CMD_TARE, CMD_CALIBRATE };

// Result of an app calibration step (CMD_TARE / CMD_CALIBRATE), core 1 -> core 0.
struct CalResult {
  uint32_t seq;
  bool ok;
  char reason[96];
};

struct HwCmd {
  HwCmdType type;
  unsigned long durationMs;  // CMD_GATE_OPEN
  float targetG;             // CMD_DISPENSE
  uint32_t seq;
};

struct HwResult {            // one finished CMD_DISPENSE
  uint32_t seq;
  char status[12];           // completed | partial | failed | rejected
  int actualG;               // -1 = not measured
  char reason[64];
};

struct Snapshot {            // what the network task may read
  float weightG;
  bool  scaleOk;             // HX711 working and in grams mode
  bool  gateOpen;
  unsigned long gateCloseAt; // millis(), HW_GATE only
  HwState state;
  char rtcTime[20];          // RTC reading for status/rtcTime ("" = none)
};

// History written while offline is sent when the connection is back.
// (The rules stamp it with the upload time.)
// Defined here, BEFORE the first function, because postHistory() takes it as a
// parameter and the Arduino IDE puts that function's prototype above the first function.
struct PendingHistory {
  char method[10];
  int  requestedG;
  int  actualG;
  char status[12];
  char idKey[11];
  char id[40];
};

volatile HwState hwState = HW_IDLE;
unsigned long gateCloseAt = 0;
uint32_t jobSeq = 0;
float jobTargetG = 0, jobStartG = 0;
unsigned long jobStartedAt = 0, settleUntil = 0;
bool jobNoFlow = false, jobTimeout = false, jobStopped = false;

QueueHandle_t cmdQueue;
QueueHandle_t resultQueue;
QueueHandle_t calQueue;
portMUX_TYPE snapMux = portMUX_INITIALIZER_UNLOCKED;
Snapshot snap;

// Set by the network task, shown on the LCD.
volatile bool netOnline = false;
volatile bool portalOpen = false;
volatile bool setupRequested = false;   // BOOT button or 'w'
volatile bool forgetRequested = false;  // 'x'
volatile bool calibrationChanged = false; // 'c' finished: send config/calibrationStatus again

// Wi-Fi diagnostics, written by the Wi-Fi event callback, printed by the network task.
volatile uint32_t wifiDropCount = 0;
volatile uint8_t  wifiLastReason = 0;
volatile int8_t   wifiLastDropRssi = 0;
volatile bool     wifiGotIp = false;

// ---- Buzzer (non-blocking) ------------------------------------------
void buzzerOn()  { digitalWrite(BUZZER_PIN, BUZZER_ACTIVE_LOW ? LOW : HIGH); }
void buzzerOff() { digitalWrite(BUZZER_PIN, BUZZER_ACTIVE_LOW ? HIGH : LOW); }

void startBeep(unsigned long ms) {
  if (!ENABLE_BUZZER) return;
  buzzerOn();
  buzzerActive = true;
  buzzerOffAt = millis() + ms;
}

void updateBuzzer() {
  if (buzzerActive && (long)(millis() - buzzerOffAt) >= 0) {
    buzzerOff();
    buzzerActive = false;
  }
}

// ---- Shared snapshot ------------------------------------------------
bool scaleUsable() { return hxOk && !rawMode; }

void publishSnapshot() {
  portENTER_CRITICAL(&snapMux);
  snap.weightG = weightGrams;
  snap.scaleOk = scaleUsable();
  snap.gateOpen = servoOpen;
  snap.gateCloseAt = gateCloseAt;
  snap.state = hwState;
  strlcpy(snap.rtcTime, rtcTimeStr, sizeof(snap.rtcTime));
  portEXIT_CRITICAL(&snapMux);
}

Snapshot readSnapshot() {
  portENTER_CRITICAL(&snapMux);
  Snapshot s = snap;
  portEXIT_CRITICAL(&snapMux);
  return s;
}

// ---- Servo gate (non-blocking) --------------------------------------
void openGate() {
  if (ENABLE_SERVO) myServo.write(ANGLE_OPEN);
  if (!servoOpen) startBeep(BEEP_MS);
  servoOpen = true;
}

void closeGate() {
  if (ENABLE_SERVO) myServo.write(ANGLE_CLOSED);
  if (servoOpen) startBeep(BEEP_MS);
  servoOpen = false;
}

void sendResult(uint32_t seq, const char* status, int actualG, const char* reason) {
  HwResult r;
  r.seq = seq;
  strlcpy(r.status, status, sizeof(r.status));
  r.actualG = actualG;
  strlcpy(r.reason, reason ? reason : "", sizeof(r.reason));
  xQueueSend(resultQueue, &r, 0);
}

void sendCalResult(uint32_t seq, bool ok, const char* reason) {
  CalResult r;
  r.seq = seq;
  r.ok = ok;
  strlcpy(r.reason, reason ? reason : "", sizeof(r.reason));
  xQueueSend(calQueue, &r, 0);
}

/**
 * App calibration, run on core 1 (the load cell's core). TARE: the empty
 * hopper becomes 0 g. CALIBRATE: the known weight now in the hopper sets the
 * grams-per-count factor. Both are saved and survive a restart.
 */
void calibrationStep(const HwCmd& c) {
  if (hwState != HW_IDLE || servoOpen) {
    sendCalResult(c.seq, false, "The gate is open or the feeder is busy; try again when it is idle");
    return;
  }
  if (!hxOk) {
    sendCalResult(c.seq, false, "The load cell (HX711) is not responding; check its wiring");
    return;
  }
  rawMode = false;
  if (c.type == CMD_TARE) {
    lcdShow("Calibration", "setting zero...");
    scale.tare(15);
    saveScale();
    weightGrams = 0;
    Serial.println("App calibration: zero set (empty hopper)");
    sendCalResult(c.seq, true, nullptr);
    return;
  }
  float knownG = c.targetG;
  lcdShow("Calibration", "measuring...");
  float raw = scale.get_value(15);          // counts above the zero
  if (fabs(raw) < 1000) {
    sendCalResult(c.seq, false, "The reading did not change: put the known weight in the hopper (after setting zero)");
    return;
  }
  calibrationFactor = raw / knownG;
  scale.set_scale(calibrationFactor);
  weightGrams = knownG;
  calibrated = true;
  saveScale();
  xSemaphoreTake(prefsLock, portMAX_DELAY);
  prefs.putBool("calibrated", true);
  xSemaphoreGive(prefsLock);
  calibrationChanged = true;
  Serial.printf("App calibration: %.0f g, calibrationFactor = %.4f (saved)\n", knownG, calibrationFactor);
  sendCalResult(c.seq, true, nullptr);
}

void handleHwCommand(const HwCmd& c) {
  unsigned long now = millis();
  if (c.type == CMD_GATE_CLOSE) {           // CLOSE always wins
    closeGate();
    if (hwState == HW_DISPENSE) {
      jobStopped = true;
      settleUntil = now + SETTLE_MS;
      hwState = HW_SETTLE;
    } else if (hwState == HW_GATE) {
      hwState = HW_IDLE;
    }
    return;
  }
  if (c.type == CMD_TARE || c.type == CMD_CALIBRATE) {
    calibrationStep(c);
    return;
  }
  if (hwState == HW_DISPENSE || hwState == HW_SETTLE || hwState == HW_CALIBRATING) {
    if (c.type == CMD_DISPENSE) sendResult(c.seq, "rejected", -1, "Feeder is busy");
    return;
  }
  if (c.type == CMD_GATE_OPEN) {
    openGate();
    // durationMs 0 = hold open until CLOSE (gateCloseAt 0 = no timer)
    gateCloseAt = c.durationMs == 0 ? 0 : now + min(c.durationMs, GATE_MAX_MS);
    hwState = HW_GATE;
  } else if (c.type == CMD_DISPENSE) {
    if (!scaleUsable() || hwState != HW_IDLE) {
      sendResult(c.seq, "rejected", -1, hwState == HW_GATE ? "Gate is open" : "Load cell not ready");
      return;
    }
    jobSeq = c.seq;
    jobTargetG = c.targetG;
    jobStartG = weightGrams;
    jobStartedAt = now;
    jobNoFlow = jobTimeout = jobStopped = false;
    openGate();
    hwState = HW_DISPENSE;
  }
}

void updateGate() {
  HwCmd c;
  while (xQueueReceive(cmdQueue, &c, 0) == pdTRUE) handleHwCommand(c);

  unsigned long now = millis();
  static unsigned long heldOfflineSince = 0;
  if (hwState == HW_GATE && gateCloseAt == 0) {          // held open by the app
    if (netOnline) {
      heldOfflineSince = 0;
    } else if (!heldOfflineSince) {
      heldOfflineSince = now;
    } else if (now - heldOfflineSince >= GATE_OFFLINE_CLOSE_MS) {
      closeGate();                          // fail-safe: the app can no longer close it
      hwState = HW_IDLE;
      heldOfflineSince = 0;
      Serial.println("Gate closed: no Firebase connection while held open");
    }
  } else if (hwState == HW_GATE && (long)(now - gateCloseAt) >= 0) {
    closeGate();                            // auto-close, no network needed
    hwState = HW_IDLE;
  } else if (hwState == HW_DISPENSE) {
    float given = jobStartG - weightGrams;
    if (!scaleUsable()) {
      jobStopped = true;
    } else if (given >= jobTargetG - DISPENSE_LEAD_G) {
      // requested amount reached
    } else if (now - jobStartedAt >= NO_FLOW_MS && given < NO_FLOW_MIN_G) {
      jobNoFlow = true;
    } else if (now - jobStartedAt >= DISPENSE_MAX_MS) {
      jobTimeout = true;
    } else {
      return;                               // keep feeding
    }
    closeGate();
    settleUntil = now + SETTLE_MS;
    hwState = HW_SETTLE;
  } else if (hwState == HW_SETTLE && (long)(now - settleUntil) >= 0) {
    hwState = HW_IDLE;
    if (!scaleUsable()) {
      sendResult(jobSeq, "failed", -1, "Load cell stopped responding");
      return;
    }
    int actual = max(0, (int)lround(jobStartG - weightGrams));
    if (jobNoFlow && actual < NO_FLOW_MIN_G) {
      sendResult(jobSeq, "failed", 0, "No feed flow detected (jam or empty hopper)");
      startBeep(800);
    } else if (actual >= jobTargetG * 0.9) {
      sendResult(jobSeq, "completed", actual, nullptr);
    } else if (actual > 0) {
      sendResult(jobSeq, "partial", actual,
                 jobStopped ? "Stopped before the full amount"
                 : jobTimeout ? "Gate time limit reached" : "Less feed came out than requested");
    } else {
      sendResult(jobSeq, "failed", 0, jobStopped ? "Stopped before any feed came out" : "No feed came out");
    }
  }
}

// ---- HX711 (non-blocking read) --------------------------------------
void updateWeight() {
  if (!scale.is_ready()) {                  // never waits
    if (hxOk && millis() - lastSampleAt > 2000) {
      hxOk = false;
      Serial.println("HX711: stopped responding");
    }
    return;
  }
  if (!hxOk) {
    hxOk = true;
    Serial.println("HX711: OK again");
  }
  lastSampleAt = millis();

  if (rawMode) {
    rawValue = scale.read();
  } else {
    float g = scale.get_units(1);
    weightGrams = 0.7 * weightGrams + 0.3 * g;   // light smoothing
  }
}

void saveScale() {
  xSemaphoreTake(prefsLock, portMAX_DELAY);
  prefs.putLong("offset", scale.get_offset());
  prefs.putFloat("factor", calibrationFactor);
  xSemaphoreGive(prefsLock);
}

void calibrate() {
  closeGate();
  hwState = HW_CALIBRATING;
  publishSnapshot();

  // Kept so a cancelled calibration changes nothing (it used to re-tare with
  // whatever was on the scale, which left a wrong zero).
  const long oldOffset = scale.get_offset();
  const float oldFactor = calibrationFactor;
  auto cancel = [&](const char* why) {
    Serial.printf("Calibration cancelled: %s. The previous zero and factor are kept.\n", why);
    scale.set_offset(oldOffset);
    scale.set_scale(oldFactor);
    calibrationFactor = oldFactor;
    lcdShow("Calibration", "cancelled");
    delay(1500);
    hwState = HW_IDLE;
  };

  Serial.println("Calibration step 1/2: leave the EMPTY hopper on the scale. Taring in 3 seconds...");
  lcdShow("CAL 1/2: empty", "taring in 3 s");
  delay(3000);
  scale.set_scale();
  scale.tare();

  // Anything typed during the countdown is discarded here, so type the
  // weight only after this prompt.
  while (Serial.available()) Serial.read();
  Serial.println("Calibration step 2/2: put a KNOWN weight in the hopper, then type its weight "
                 "in grams (e.g. 500) and press Enter. You have 2 minutes.");
  lcdShow("CAL 2/2: add wt", "type grams+Enter");
  unsigned long waitStart = millis();
  while (!Serial.available()) {
    if (millis() - waitStart > 120000) { cancel("no weight typed within 2 minutes"); return; }
    delay(50);
  }
  float knownGrams = Serial.parseFloat();
  while (Serial.available()) Serial.read();  // the rest of the line

  if (knownGrams <= 0 || knownGrams > 5000) { cancel("type a weight between 1 and 5000 g"); return; }

  delay(1000);
  float raw = scale.get_value(15);
  if (fabs(raw) < 1000) {                    // the reading barely changed: nothing was placed
    cancel("the scale did not change; was the known weight placed in the hopper?");
    return;
  }
  calibrationFactor = raw / knownGrams;
  scale.set_scale(calibrationFactor);
  weightGrams = knownGrams;
  lcdShow("Calibration", "done, saved");
  calibrated = true;
  saveScale();
  xSemaphoreTake(prefsLock, portMAX_DELAY);
  prefs.putBool("calibrated", true);
  calibrationChanged = true;
  xSemaphoreGive(prefsLock);

  Serial.print("Done. calibrationFactor = ");
  Serial.println(calibrationFactor, 4);
  Serial.println("Saved; it is used again after a restart.");
  hwState = HW_IDLE;
}

// ---- RTC (DS3231 on Wire1), shared by both cores --------------------
/** Reads the RTC; false when missing or the reading is not a real date. */
bool rtcRead(DateTime& out) {
  if (!rtcOk) return false;
  xSemaphoreTake(rtcLock, portMAX_DELAY);
  out = rtc.now();
  xSemaphoreGive(rtcLock);
  return out.year() >= 2024 && out.year() <= 2099 && out.month() >= 1 && out.month() <= 12 &&
         out.day() >= 1 && out.day() <= 31 && out.hour() <= 23 && out.minute() <= 59 && out.second() <= 59;
}

void rtcWrite(const DateTime& t) {
  xSemaphoreTake(rtcLock, portMAX_DELAY);
  rtc.adjust(t);
  xSemaphoreGive(rtcLock);
}

/** Called from loop() once a second: keeps rtcTimeStr for status/rtcTime. */
void updateRtcReading() {
  if (millis() - lastRtcRead < 1000) return;
  lastRtcRead = millis();
  DateTime n;
  if (rtcRead(n)) {
    snprintf(rtcTimeStr, sizeof(rtcTimeStr), "%04d-%02d-%02dT%02d:%02d:%02d",
             n.year(), n.month(), n.day(), n.hour(), n.minute(), n.second());
  } else {
    rtcTimeStr[0] = 0;                      // not sent: the app shows "no RTC reading"
  }
}

// ---- LCD helpers ----------------------------------------------------
void lcdShow(const char* line1, const char* line2) {
  char buf[17];
  lcd.setCursor(0, 0);
  snprintf(buf, sizeof(buf), "%-16s", line1);
  lcd.print(buf);
  lcd.setCursor(0, 1);
  snprintf(buf, sizeof(buf), "%-16s", line2);
  lcd.print(buf);
}

bool clockValid() { return time(nullptr) > 1700000000; }   // set from NTP, Firebase or the RTC

void updateLcd() {
  char line1[17];
  char line2[17];
  char t[10];

  struct tm lt;
  if (clockValid() && getLocalTime(&lt, 0)) {
    snprintf(t, sizeof(t), "%02d:%02d:%02d", lt.tm_hour, lt.tm_min, lt.tm_sec);
  } else if (rtcOk) {
    DateTime now;
    rtcRead(now);
    snprintf(t, sizeof(t), "%02d:%02d:%02d", now.hour(), now.minute(), now.second());
  } else {
    snprintf(t, sizeof(t), "RTC ERR ");
  }

  bool feeding = hwState == HW_DISPENSE || hwState == HW_SETTLE;
  const char* st = !ENABLE_SERVO ? "OFF" : feeding ? "FEED" : servoOpen ? "OPEN" : "CLOSED";
  snprintf(line1, sizeof(line1), "%s %-6s%c", t, st, portalOpen ? 'W' : netOnline ? '*' : '!');

  if (portalOpen && !feeding && hwState != HW_GATE) {
    snprintf(line2, sizeof(line2), "WiFi:%s", PORTAL_SSID);
  } else if (!hxOk) {
    snprintf(line2, sizeof(line2), "HX711 ERROR");
  } else if (rawMode) {
    snprintf(line2, sizeof(line2), "Raw:%ld", rawValue);
  } else if (feeding) {
    float given = max(0.0f, jobStartG - weightGrams);
    snprintf(line2, sizeof(line2), "Feed %d/%d g", (int)given, (int)jobTargetG);
  } else if (hwState == HW_GATE && gateCloseAt == 0) {
    snprintf(line2, sizeof(line2), "W:%.0f g  OPEN", weightGrams);
  } else if (hwState == HW_GATE) {
    long left = ((long)(gateCloseAt - millis()) + 999) / 1000;
    snprintf(line2, sizeof(line2), "W:%.0f g  %lds", weightGrams, max(0L, left));
  } else {
    float shown = (fabs(weightGrams) < 0.5) ? 0 : weightGrams;
    snprintf(line2, sizeof(line2), "W: %.1f g", shown);
  }

  lcdShow(line1, line2);
}

// =====================================================================
// Wi-Fi + Firebase (HTTPS REST), core 0
// =====================================================================

// Device account, entered in the setup portal and kept in flash.
char feederId[33] = "";
char deviceEmail[65] = "";
char devicePassword[65] = "";

WiFiManager wm;
WiFiManagerParameter pFeeder("feeder", "Feeder ID (from npm run production:provision)", "", 32);
WiFiManagerParameter pEmail("email", "Device account email", "", 64);
WiFiManagerParameter pPassword("dpass", "Device account password (blank = keep)", "", 64, "type='password'");

String idToken, refreshToken;
unsigned long tokenRefreshAt = 0;
long long serverOffsetMs = 0;     // server time = millis() + offset
bool serverTimeKnown = false;
unsigned long lastDbOk = 0;
// Connection statistics, printed with the RSSI line every 30 s.
uint32_t dbOkCount = 0, dbFailCount = 0;
unsigned long dbMsTotal = 0, dbLastErrLog = 0, dbBackoffUntil = 0;
bool accountRejected = false;     // wrong email/password, or not provisioned
bool newAccount = false;          // saved in the portal: start over

NetworkClientSecure dbTls;        // one kept-alive HTTPS connection to the database
HTTPClient dbHttp;

bool hasAccount() { return feederId[0] && deviceEmail[0] && devicePassword[0]; }

void loadAccount() {
  xSemaphoreTake(prefsLock, portMAX_DELAY);
  prefs.getString("feederId", feederId, sizeof(feederId));
  prefs.getString("devEmail", deviceEmail, sizeof(deviceEmail));
  prefs.getString("devPass", devicePassword, sizeof(devicePassword));
  xSemaphoreGive(prefsLock);
}

void saveParams() {                      // called by WiFiManager on Save
  String f = pFeeder.getValue(), e = pEmail.getValue(), p = pPassword.getValue();
  f.trim();
  e.trim();
  xSemaphoreTake(prefsLock, portMAX_DELAY);
  if (f.length()) { strlcpy(feederId, f.c_str(), sizeof(feederId)); prefs.putString("feederId", feederId); }
  if (e.length()) { strlcpy(deviceEmail, e.c_str(), sizeof(deviceEmail)); prefs.putString("devEmail", deviceEmail); }
  if (p.length()) { strlcpy(devicePassword, p.c_str(), sizeof(devicePassword)); prefs.putString("devPass", devicePassword); }
  xSemaphoreGive(prefsLock);
  idToken = refreshToken = "";            // sign in again with the new account
  accountRejected = false;
  newAccount = true;
  Serial.printf("Setup saved: feeder %s, account %s\n", feederId, deviceEmail);
}

bool portalAuto = false;   // portal opened only because Wi-Fi was lost: close it once Wi-Fi is back

void openPortal() {
  portalAuto = false;                     // the Wi-Fi-lost path sets it again right after this call
  if (wm.getConfigPortalActive()) return;
  pFeeder.setValue(feederId, 32);
  pEmail.setValue(deviceEmail, 64);
  Serial.printf("Wi-Fi setup: join \"%s\" (password %s) and open 192.168.4.1\n", PORTAL_SSID, PORTAL_PASSWORD);
  wm.startConfigPortal(PORTAL_SSID, PORTAL_PASSWORD);
  portalOpen = true;
}

long long serverNow() { return (long long)millis() + serverOffsetMs; }

void learnServerTime(long long serverMs) {
  serverOffsetMs = serverMs - (long long)millis();
  if (!serverTimeKnown) Serial.println("Clock synced from Firebase");
  serverTimeKnown = true;
  if (llabs(serverMs / 1000 - (long long)time(nullptr)) > 2) {
    struct timeval tv = { (time_t)(serverMs / 1000), (suseconds_t)((serverMs % 1000) * 1000) };
    settimeofday(&tv, nullptr);
  }
}

/** HTTPS POST to Firebase Auth; returns the HTTP code. */
int authPost(const String& url, const char* contentType, const String& body, JsonDocument& out) {
  dbHttp.end();                           // free the database connection's memory first
  dbTls.stop();
  NetworkClientSecure tls;
  tls.setCACert(GOOGLE_ROOT_CAS);
  HTTPClient http;
  http.begin(tls, url);
  http.setConnectTimeout(8000);
  http.setTimeout(8000);
  http.addHeader("Content-Type", contentType);
  int code = http.POST(body);
  if (code > 0) deserializeJson(out, http.getString());
  else {                                  // -1 = no TCP/TLS connection: say why
    char err[96] = "";
    tls.lastError(err, sizeof(err));
    Serial.printf("Firebase Auth: %s | TLS: %s | Wi-Fi %s RSSI %d dBm | free heap %u\n",
                  http.errorToString(code).c_str(), err[0] ? err : "-",
                  WiFi.status() == WL_CONNECTED ? "up" : "DOWN", (int)WiFi.RSSI(), ESP.getFreeHeap());
  }
  http.end();
  return code;
}

/** ID tokens last expiresIn seconds (sent as a string); refresh 5 min early. */
unsigned long tokenLifetimeMs(const char* expiresIn) {
  long s = atol(expiresIn);
  return (unsigned long)max(60L, s - 300) * 1000UL;
}

bool signIn() {
  JsonDocument res;
  if (refreshToken.length()) {
    int code = authPost(String("https://securetoken.googleapis.com/v1/token?key=") + FIREBASE_API_KEY,
                        "application/x-www-form-urlencoded",
                        "grant_type=refresh_token&refresh_token=" + refreshToken, res);
    if (code == 200) {
      idToken = res["id_token"].as<String>();
      refreshToken = res["refresh_token"].as<String>();
      tokenRefreshAt = millis() + tokenLifetimeMs(res["expires_in"] | "3600");
      return true;
    }
  }
  JsonDocument req;
  req["email"] = deviceEmail;
  req["password"] = devicePassword;
  req["returnSecureToken"] = true;
  String body;
  serializeJson(req, body);
  int code = authPost(String("https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=") +
                      FIREBASE_API_KEY, "application/json", body, res);
  if (code != 200) {
    const char* why = res["error"]["message"] | "no response";
    Serial.printf("Firebase sign-in failed (%d %s)\n", code, why);
    if (code == 400) {
      accountRejected = true;
      Serial.println("  Check the device email/password: hold BOOT 3 s or send 'w' to open setup.");
    }
    return false;
  }
  idToken = res["idToken"].as<String>();
  refreshToken = res["refreshToken"].as<String>();
  tokenRefreshAt = millis() + tokenLifetimeMs(res["expiresIn"] | "3600");
  accountRejected = false;
  Serial.printf("Signed in to Firebase as %s\n", deviceEmail);
  return true;
}

/**
 * One Realtime Database REST call over HTTPS. [sub] is relative to
 * feeders/<id>/. Returns the HTTP code (200 = ok, 401 = refused by the
 * Security Rules or an expired token).
 */
int dbCall(const char* method, const String& sub, const String& body, String* response) {
  if (WiFi.status() != WL_CONNECTED || !idToken.length()) return -1;
  String url = String("https://") + DATABASE_HOST + "/feeders/" + feederId + "/" + sub + ".json?auth=" + idToken;
  // A broken connection is retried once on a fresh one. POST is never retried:
  // if only the reply was lost, a retry would add a duplicate history entry.
  bool canRetry = strcmp(method, "POST") != 0;
  int code = -1;
  String resp;
  unsigned long started = millis();
  for (int attempt = 0; attempt < (canRetry ? 2 : 1); attempt++) {
    dbHttp.begin(dbTls, url);
    dbHttp.setConnectTimeout(5000);
    dbHttp.setTimeout(6000);              // 4 s gave read timeouts on slow replies
    if (body.length()) dbHttp.addHeader("Content-Type", "application/json");
    code = dbHttp.sendRequest(method, body);
    resp = code > 0 ? dbHttp.getString() : "";
    dbHttp.end();                         // keeps the TLS connection open for the next call
    if (code > 0) break;
    dbTls.stop();                         // drop the broken connection
    if (millis() - dbLastErrLog >= 10000) {   // at most one detailed line per 10 s
      dbLastErrLog = millis();
      char err[80] = "";
      dbTls.lastError(err, sizeof(err));
      Serial.printf("Firebase %s %s: %s | TLS: %s | RSSI %d dBm | heap %u\n", method, sub.c_str(),
                    HTTPClient::errorToString(code).c_str(), err[0] ? err : "-", (int)WiFi.RSSI(),
                    ESP.getFreeHeap());
    }
    if (WiFi.status() != WL_CONNECTED) break;
    vTaskDelay(pdMS_TO_TICKS(300));       // let the old socket close before reconnecting
  }
  if (code > 0) {
    dbOkCount++;
    dbMsTotal += millis() - started;
  } else {
    dbFailCount++;
    dbBackoffUntil = millis() + 2000;     // pause polling briefly instead of hammering a bad link
  }
  if (code == 200) lastDbOk = millis();
  if (code == 401 && resp.indexOf("expired") >= 0) tokenRefreshAt = millis();   // refresh now
  if (response) *response = resp;
  return code;
}

int dbJson(const char* method, const String& sub, JsonDocument& doc, String* response) {
  String body;
  serializeJson(doc, body);
  int code = dbCall(method, sub, body, response);
  if (code != 200 && code != 401) Serial.printf("Firebase %s %s failed (%d)\n", method, sub.c_str(), code);
  return code;
}

int dbDelete(const String& sub) { return dbCall("DELETE", sub, "", nullptr); }

bool dbGet(const String& sub, JsonDocument& out) {
  String resp;
  if (dbCall("GET", sub, "", &resp) != 200) return false;
  return !deserializeJson(out, resp);
}

// Server timestamp placeholder: SV(doc["lastSeen"]) -> {".sv":"timestamp"}
#define SV(field) ((field)[".sv"] = "timestamp")

// ---- what the feeder knows from Firebase (cached in flash for offline) ----
float lowThresholdG = 500;
bool schedulesPaused = false;
String timezoneName = "";
char tzPosix[40] = "";

struct Schedule { char id[32]; int hh, mm, amountG; bool enabled; uint8_t days; };
Schedule schedules[16];
int scheduleCount = 0;
struct RanToday { char id[32]; int day; };
RanToday ranToday[16];

String lastGateRequestId = "";
int reportedGate = -1;              // -1 unknown, 0 closed, 1 open
bool stuckFeed = false;
int alertState[3] = { -1, -1, -1 }; // low_feed, stuck_feed, sensor_error

// One feeding at a time (Feed now or a schedule); its result is retried
// until Firebase has it.
struct Job { bool active; bool manual; String id; int requestedG; uint32_t seq; bool hasResult; HwResult result; };
Job job;
uint32_t nextSeq = 1;

// (struct PendingHistory is defined near the top of the file.)
PendingHistory pending[10];
int pendingCount = 0;

void putCache(const char* key, const void* data, size_t len) {
  xSemaphoreTake(prefsLock, portMAX_DELAY);
  uint8_t old[sizeof(schedules)];
  size_t have = prefs.getBytes(key, old, sizeof(old));
  if (have != len || memcmp(old, data, len) != 0) prefs.putBytes(key, data, len);   // spare the flash
  xSemaphoreGive(prefsLock);
}

void loadCache() {
  xSemaphoreTake(prefsLock, portMAX_DELAY);
  scheduleCount = prefs.getBytes("sched", schedules, sizeof(schedules)) / sizeof(Schedule);
  prefs.getBytes("ranToday", ranToday, sizeof(ranToday));
  prefs.getString("tz", tzPosix, sizeof(tzPosix));
  lowThresholdG = prefs.getFloat("lowG", 500);
  schedulesPaused = prefs.getBool("paused", false);
  xSemaphoreGive(prefsLock);
  if (!tzPosix[0]) strlcpy(tzPosix, TZ_FALLBACK, sizeof(tzPosix));
}

const char* tzToPosix(const String& name) {
  if (name == "Asia/Manila") return "PHT-8";
  if (name == "UTC") return "UTC0";
  if (name == "Asia/Singapore" || name == "Asia/Kuala_Lumpur" || name == "Asia/Shanghai" ||
      name == "Asia/Hong_Kong" || name == "Asia/Taipei") return "<+08>-8";
  if (name == "Asia/Jakarta" || name == "Asia/Bangkok" || name == "Asia/Ho_Chi_Minh") return "<+07>-7";
  if (name == "Asia/Tokyo") return "JST-9";
  if (name == "Asia/Kolkata") return "IST-5:30";
  if (name.length()) Serial.printf("Time zone %s not in tzToPosix(); using TZ_FALLBACK\n", name.c_str());
  return TZ_FALLBACK;
}

void pollTimezone() {
  JsonDocument d;
  if (!dbGet("meta/timezone", d)) return;
  String tz = d.is<const char*>() ? d.as<String>() : "";
  if (tz == timezoneName) return;
  timezoneName = tz;
  strlcpy(tzPosix, tzToPosix(tz), sizeof(tzPosix));
  setenv("TZ", tzPosix, 1);
  tzset();
  xSemaphoreTake(prefsLock, portMAX_DELAY);
  if (prefs.getString("tz", "") != tzPosix) prefs.putString("tz", tzPosix);
  xSemaphoreGive(prefsLock);
}

void pollConfig() {
  JsonDocument d;
  if (!dbGet("config", d)) return;
  float low = d["lowThresholdG"].is<float>() ? d["lowThresholdG"].as<float>() : lowThresholdG;
  bool paused = d["schedulesPaused"] | false;
  if (low == lowThresholdG && paused == schedulesPaused) return;
  lowThresholdG = low;
  schedulesPaused = paused;
  xSemaphoreTake(prefsLock, portMAX_DELAY);
  prefs.putFloat("lowG", lowThresholdG);
  prefs.putBool("paused", schedulesPaused);
  xSemaphoreGive(prefsLock);
}

void pollSchedules() {
  JsonDocument d;
  if (!dbGet("schedules", d)) return;
  Schedule next[16];
  memset(next, 0, sizeof(next));
  int n = 0;
  for (JsonPair kv : d.as<JsonObject>()) {
    if (n >= 16) break;
    JsonObject s = kv.value().as<JsonObject>();
    const char* hhmm = s["time"] | "";
    if (strlen(hhmm) != 5) continue;
    Schedule& x = next[n++];
    strlcpy(x.id, kv.key().c_str(), sizeof(x.id));
    x.hh = atoi(hhmm);
    x.mm = atoi(hhmm + 3);
    x.amountG = s["amountG"] | 0;
    x.enabled = s["enabled"] | false;
    JsonVariant w = s["weekdays"];   // saved as {"0":true,...}, read back as an array
    for (int day = 0; day < 7; day++) {
      bool on = w.is<JsonArray>() ? (w[day] | false) : (w[String(day)] | false);
      if (on) x.days |= 1 << day;
    }
  }
  memcpy(schedules, next, sizeof(schedules));
  scheduleCount = n;
  putCache("sched", schedules, n * sizeof(Schedule));
}

// ---- reporting -------------------------------------------------------------
void writeAlert(int i, const char* type, const char* severity, bool active) {
  int want = active ? 1 : 0;
  if (alertState[i] == want) return;
  JsonDocument a;
  a["type"] = type;
  a["severity"] = severity;
  a["state"] = active ? "active" : "resolved";
  SV(a["lastAt"]);
  a["source"] = "device";
  String path = String("alerts/") + type;
  // The device may write alerts but not read them: PATCH keeps an existing
  // firstAt; only a brand-new active alert is created with firstAt = now.
  int code = dbJson("PATCH", path, a, nullptr);
  if (code != 200 && active) {
    SV(a["firstAt"]);
    code = dbJson("PUT", path, a, nullptr);
  }
  if (code == 200 || (!active && code == 401)) alertState[i] = want;   // 401 on resolve: there was none
  if (code == 200) Serial.printf("Alert %s %s\n", type, active ? "active" : "resolved");
}

void report() {
  Snapshot s = readSnapshot();
  bool calibrating = s.state == HW_CALIBRATING;
  bool feeding = s.state == HW_DISPENSE || s.state == HW_SETTLE;
  bool lowNow = s.scaleOk && (alertState[0] == 1 ? s.weightG <= lowThresholdG + LOW_HYSTERESIS_G
                                                 : s.weightG <= lowThresholdG);

  // Heartbeat (status) every STATUS_EVERY_MS or when the condition changes;
  // the weight below goes out on every call.
  static unsigned long lastStatusAt = 0;
  static String lastCondition = "";
  const char* condition = calibrating ? "unknown" : !s.scaleOk ? "error" : stuckFeed ? "jam" : lowNow ? "low_feed" : "ok";
  if (lastStatusAt == 0 || millis() - lastStatusAt >= STATUS_EVERY_MS || lastCondition != condition) {
    JsonDocument st;
    SV(st["lastSeen"]);
    st["condition"] = condition;
    st["rssi"] = constrain((int)WiFi.RSSI(), -150, 0);
    st["firmware"] = FIRMWARE;
    if (s.rtcTime[0]) st["rtcTime"] = s.rtcTime;   // DS3231 local time, shown in the app
    st["source"] = "device";
    String resp;
    int code = dbJson("PUT", "status", st, &resp);
    if (code == 200) {
      lastStatusAt = millis();
      lastCondition = condition;
      JsonDocument back;                      // the server returns lastSeen resolved
      if (!deserializeJson(back, resp) && back["lastSeen"].is<long long>()) {
        learnServerTime(back["lastSeen"].as<long long>());
      }
    } else if (code == 401 && resp.indexOf("expired") < 0) {
      Serial.printf("Firebase refused feeder %s: is this device account provisioned for it?\n", feederId);
    }
  }
  if (calibrating) return;

  if (s.scaleOk) {
    // Send the weight when it changed (>= 2 g), while the gate is open or
    // feeding, or at least every 5 s; a steady hopper does not need a write
    // every second.
    static int lastSentG = -100000;
    static unsigned long lastSentAt = 0;
    int w = (int)lround(max(0.0f, s.weightG));   // never negative (noise around empty)
    bool busyNow = feeding || s.gateOpen;
    if (busyNow || abs(w - lastSentG) >= 2 || millis() - lastSentAt >= 5000) {
      JsonDocument t;
      t["weightG"] = w;
      SV(t["measuredAt"]);
      t["quality"] = busyNow ? "unstable" : "ok";
      t["source"] = "device";
      if (dbJson("PUT", "telemetry/current", t, nullptr) == 200) {
        lastSentG = w;
        lastSentAt = millis();
      }
    }
    writeAlert(0, "low_feed", "warning", lowNow);
  }
  writeAlert(1, "stuck_feed", "critical", stuckFeed);
  writeAlert(2, "sensor_error", "critical", !s.scaleOk);
}

void measure() {
  Snapshot s = readSnapshot();
  if (!s.scaleOk || s.state == HW_CALIBRATING) return;
  JsonDocument m;
  m["weightG"] = (int)lround(max(0.0f, s.weightG));
  SV(m["ts"]);
  m["source"] = "device";
  dbJson("POST", "measurements", m, nullptr);
}

void writeGateState(const char* result, const char* reason) {
  Snapshot s = readSnapshot();
  JsonDocument g;
  g["position"] = s.gateOpen ? "open" : "closed";
  SV(g["reportedAt"]);
  g["source"] = "device";
  if (lastGateRequestId.length()) g["lastRequestId"] = lastGateRequestId;
  if (result) g["lastResult"] = result;
  if (reason) g["reason"] = reason;
  if (s.gateOpen && s.state == HW_GATE && s.gateCloseAt != 0 && serverTimeKnown) {
    g["closesAt"] = serverNow() + (long)(s.gateCloseAt - millis());
  }
  if (dbJson("PUT", "gate/state", g, nullptr) == 200) reportedGate = s.gateOpen ? 1 : 0;
}

bool postHistory(const PendingHistory& p) {
  JsonDocument h;
  h["method"] = p.method;
  h["requestedG"] = p.requestedG;
  if (p.actualG >= 0) h["actualG"] = p.actualG;
  h["status"] = p.status;
  SV(h["ts"]);
  h["source"] = "device";
  h[p.idKey] = p.id;
  int code = dbJson("POST", "history", h, nullptr);
  return code == 200 || code == 401;      // 401: refused for good, do not retry
}

void recordHistory(const char* method, int requestedG, int actualG, const char* status,
                   const char* idKey, const String& id) {
  PendingHistory p;
  strlcpy(p.method, method, sizeof(p.method));
  p.requestedG = requestedG;
  p.actualG = actualG;
  strlcpy(p.status, status, sizeof(p.status));
  strlcpy(p.idKey, idKey, sizeof(p.idKey));
  strlcpy(p.id, id.c_str(), sizeof(p.id));
  if (postHistory(p)) return;
  if (pendingCount == 10) {               // keep the newest
    memmove(pending, pending + 1, sizeof(PendingHistory) * 9);
    pendingCount = 9;
  }
  pending[pendingCount++] = p;
  Serial.printf("History kept for later (%d waiting)\n", pendingCount);
}

void flushHistory() {
  while (pendingCount > 0 && postHistory(pending[0])) {
    memmove(pending, pending + 1, sizeof(PendingHistory) * (pendingCount - 1));
    pendingCount--;
  }
}

/** Asks loop() to move the gate and waits briefly until it has. */
void sendHw(HwCmdType type, unsigned long durationMs, float targetG, uint32_t seq) {
  HwCmd c = { type, durationMs, targetG, seq };
  xQueueSend(cmdQueue, &c, pdMS_TO_TICKS(100));
  if (type == CMD_DISPENSE) return;
  bool wantOpen = type == CMD_GATE_OPEN;
  for (int i = 0; i < 20 && readSnapshot().gateOpen != wantOpen; i++) vTaskDelay(pdMS_TO_TICKS(25));
}

// ---- gate requests -----------------------------------------------------------
void pollGate() {
  JsonDocument r;
  if (!dbGet("gate/request", r) || r.isNull()) return;
  String id = r["id"] | "";
  if (!id.length() || id == lastGateRequestId) return;
  lastGateRequestId = id;
  String action = r["action"] | "";
  long long requestedAt = r["requestedAt"] | 0LL;

  if (!serverTimeKnown || serverNow() - requestedAt > (long long)GATE_MAX_AGE_MS) {
    writeGateState("rejected", "Request older than 10 s");
    Serial.println("Gate request rejected (too old)");
    return;
  }
  if (action == "close") {
    sendHw(CMD_GATE_CLOSE, 0, 0, 0);
    writeGateState("done", nullptr);
    Serial.println("Gate closed (app)");
    return;
  }
  Snapshot s = readSnapshot();
  if (s.state == HW_DISPENSE || s.state == HW_SETTLE || s.state == HW_CALIBRATING) {
    writeGateState("rejected", "Feeder is busy feeding");
    return;
  }
  sendHw(CMD_GATE_OPEN, 0, 0, 0);            // 0 = stay open until CLOSE (durationS ignored)
  writeGateState("done", nullptr);
  Serial.println("Gate open until CLOSE (app)");
}

// ---- calibration from the app (calibration/request -> calibration/state) ------------
String lastCalRequestId = "";
uint32_t calSeq = 1;
const unsigned long CAL_MAX_AGE_MS = 30000;   // older requests are refused, never run late

void writeCalState(const String& id, const String& action, bool ok, const char* reason) {
  JsonDocument d;
  d["lastRequestId"] = id;
  if (action == "tare" || action == "calibrate") d["action"] = action;
  d["result"] = ok ? "done" : "rejected";
  if (reason && reason[0]) d["reason"] = reason;
  SV(d["reportedAt"]);
  d["source"] = "device";
  dbJson("PUT", "calibration/state", d, nullptr);
}

void pollCalibration() {
  JsonDocument r;
  if (!dbGet("calibration/request", r) || r.isNull()) return;
  String id = r["id"] | "";
  if (!id.length() || id == lastCalRequestId) return;
  lastCalRequestId = id;
  String action = r["action"] | "";
  long long requestedAt = r["requestedAt"] | 0LL;
  float knownG = r["knownG"] | 0.0f;

  if (!serverTimeKnown || serverNow() - requestedAt > (long long)CAL_MAX_AGE_MS) {
    writeCalState(id, action, false, "Request too old; try again");
    return;
  }
  if (job.active) {
    writeCalState(id, action, false, "A feeding is running; try again when it has finished");
    return;
  }
  if (action != "tare" && !(action == "calibrate" && knownG >= 1)) {
    writeCalState(id, action, false, "Unknown calibration request");
    return;
  }
  uint32_t seq = calSeq++;
  xQueueReset(calQueue);
  sendHw(action == "tare" ? CMD_TARE : CMD_CALIBRATE, 0, knownG, seq);
  CalResult res;
  bool got = false;
  unsigned long until = millis() + 10000;
  while (!got && (long)(millis() - until) < 0) {
    if (xQueueReceive(calQueue, &res, pdMS_TO_TICKS(200)) == pdTRUE && res.seq == seq) got = true;
  }
  if (!got) {
    writeCalState(id, action, false, "The load cell did not answer in time");
    return;
  }
  writeCalState(id, action, res.ok, res.ok ? nullptr : res.reason);
  Serial.printf("App calibration %s: %s %s\n", action.c_str(), res.ok ? "done" : "rejected", res.reason);
  if (res.ok) report();                     // the new weight goes to the app at once
}

// ---- Feed now (commands + activeCommand lock) ------------------------------------
void finishCommandEarly(const String& cid, int amountG, const char* status, const char* reason) {
  JsonDocument u;
  u["status"] = status;
  u["reason"] = reason;
  u["executedBy"] = "device";
  SV(u["completedAt"]);
  if (dbJson("PATCH", "commands/" + cid, u, nullptr) != 200) return;
  recordHistory("manual", amountG, strcmp(status, "rejected") == 0 ? 0 : -1, status, "commandId", cid);
  dbDelete("activeCommand");
  Serial.printf("Feed now %s: %s\n", status, reason);
}

void pollCommand() {
  JsonDocument lock;
  if (!dbGet("activeCommand", lock) || lock.isNull()) return;
  String cid = lock["commandId"] | "";
  if (!cid.length()) return;
  JsonDocument c;
  if (!dbGet("commands/" + cid, c)) return;
  if (c.isNull()) {                         // a lock without its command
    dbDelete("activeCommand");
    return;
  }
  String status = c["status"] | "";
  int amountG = c["amountG"] | 0;
  long long requestedAt = c["requestedAt"] | 0LL;

  if (status == "accepted" || status == "dispensing") {
    // We are idle, so this one was cut short by a restart.
    finishCommandEarly(cid, amountG, "failed", "Controller restarted during feeding");
    return;
  }
  if (status != "pending") {                // already finished: release the lock
    dbDelete("activeCommand");
    return;
  }
  if (!serverTimeKnown || serverNow() - requestedAt > (long long)COMMAND_TTL_MS) return;  // the app expires it

  Serial.printf("Feed now %d g requested\n", amountG);
  Snapshot s = readSnapshot();
  if (!s.scaleOk) { finishCommandEarly(cid, amountG, "rejected", "Load cell not ready"); return; }
  if (s.state != HW_IDLE) { finishCommandEarly(cid, amountG, "rejected", "Gate is open or feeder is busy"); return; }
  if (!calibrated) { finishCommandEarly(cid, amountG, "rejected", "Scale not calibrated: hopper weight cannot be verified"); return; }
  if (s.weightG <= NO_FLOW_MIN_G) { finishCommandEarly(cid, amountG, "rejected", "Hopper is empty"); return; }
  if (s.weightG < amountG) {                // not enough feed for the requested amount
    char why[96];
    snprintf(why, sizeof(why), "Not enough feed: %d g in the hopper, %d g requested",
             (int)lround(max(0.0f, s.weightG)), amountG);
    finishCommandEarly(cid, amountG, "rejected", why);
    return;
  }

  JsonDocument a;
  a["status"] = "accepted";
  SV(a["acceptedAt"]);
  a["executedBy"] = "device";
  if (dbJson("PATCH", "commands/" + cid, a, nullptr) != 200) return;
  JsonDocument d;
  d["status"] = "dispensing";
  dbJson("PATCH", "commands/" + cid, d, nullptr);

  job.active = true;
  job.manual = true;
  job.id = cid;
  job.requestedG = amountG;
  job.seq = nextSeq++;
  job.hasResult = false;
  sendHw(CMD_DISPENSE, 0, amountG, job.seq);
}

/** Reports the finished feeding; false = try again later. */
bool reportJob() {
  const HwResult& r = job.result;
  if (job.manual) {
    // 'rejected' is not allowed after 'dispensing': the gate never opened, so it failed.
    const char* status = strcmp(r.status, "rejected") == 0 ? "failed" : r.status;
    JsonDocument u;
    u["status"] = status;
    if (r.actualG >= 0) u["actualG"] = r.actualG;
    if (r.reason[0]) u["reason"] = r.reason;
    SV(u["completedAt"]);
    int code = dbJson("PATCH", "commands/" + job.id, u, nullptr);
    if (code != 200 && code != 401) return false;
    if (code == 200) recordHistory("manual", job.requestedG, r.actualG, status, "commandId", job.id);
    dbDelete("activeCommand");
  } else {
    recordHistory("scheduled", job.requestedG, r.actualG, r.status, "scheduleId", job.id);  // queued if offline
  }
  Serial.printf("Feeding %s: %d g of %d g %s\n", r.status, r.actualG, job.requestedG, r.reason);
  return true;
}

void finishJob() {
  if (!job.active || !job.hasResult) return;
  if (!reportJob()) return;
  job.active = false;
  if (netOnline) report();
}

void takeResult(const HwResult& r) {
  if (!job.active || r.seq != job.seq || job.hasResult) return;
  job.result = r;
  job.hasResult = true;
  if (strstr(r.reason, "No feed flow")) stuckFeed = true;
  else if (r.actualG > 0) stuckFeed = false;
}

// ---- schedules (run from the clock, online or offline) ---------------------------
void checkSchedules() {
  if (job.active || schedulesPaused || !clockValid()) return;
  struct tm lt;
  if (!getLocalTime(&lt, 0)) return;
  int today = (lt.tm_year + 1900) * 10000 + (lt.tm_mon + 1) * 100 + lt.tm_mday;
  for (int i = 0; i < scheduleCount; i++) {
    Schedule& s = schedules[i];
    if (!s.enabled || s.hh != lt.tm_hour || s.mm != lt.tm_min || !(s.days & (1 << lt.tm_wday))) continue;
    int slot = -1, freeSlot = -1;
    for (int k = 0; k < 16; k++) {
      if (strcmp(ranToday[k].id, s.id) == 0) slot = k;
      else if (freeSlot < 0 && (ranToday[k].id[0] == 0 || ranToday[k].day != today)) freeSlot = k;
    }
    if (slot >= 0 && ranToday[slot].day == today) continue;   // once per day, also across restarts
    if (slot < 0) slot = freeSlot < 0 ? 0 : freeSlot;
    strlcpy(ranToday[slot].id, s.id, sizeof(ranToday[slot].id));
    ranToday[slot].day = today;
    putCache("ranToday", ranToday, sizeof(ranToday));

    Serial.printf("Scheduled feed %02d:%02d: %d g%s\n", s.hh, s.mm, s.amountG, netOnline ? "" : " (offline)");
    Snapshot now = readSnapshot();
    if (!now.scaleOk || now.state != HW_IDLE || !calibrated || now.weightG < s.amountG) {
      Serial.printf("Scheduled feed rejected: %s\n", !now.scaleOk ? "load cell not ready"
                    : now.state != HW_IDLE ? "feeder busy" : !calibrated ? "scale not calibrated"
                    : "not enough feed in the hopper");
      recordHistory("scheduled", s.amountG, 0, "rejected", "scheduleId", s.id);
      return;
    }
    job.active = true;
    job.manual = false;
    job.id = s.id;
    job.requestedG = s.amountG;
    job.seq = nextSeq++;
    job.hasResult = false;
    sendHw(CMD_DISPENSE, 0, s.amountG, job.seq);
    return;
  }
}

/** The DS3231 keeps local time; it sets the clock at boot and is corrected once online. */
void clockFromRtc() {
  DateTime d;
  if (!rtcRead(d)) return;
  struct tm lt = {};
  lt.tm_year = d.year() - 1900;
  lt.tm_mon = d.month() - 1;
  lt.tm_mday = d.day();
  lt.tm_hour = d.hour();
  lt.tm_min = d.minute();
  lt.tm_sec = d.second();
  lt.tm_isdst = -1;
  struct timeval tv = { mktime(&lt), 0 };   // uses TZ
  settimeofday(&tv, nullptr);
  Serial.println("Clock set from the RTC");
}

void syncRtc() {
  if (!rtcOk || !serverTimeKnown) return;
  struct tm lt;
  if (!getLocalTime(&lt, 0)) return;
  DateTime local(lt.tm_year + 1900, lt.tm_mon + 1, lt.tm_mday, lt.tm_hour, lt.tm_min, lt.tm_sec);
  DateTime have;
  bool ok = rtcRead(have);
  if (!ok || labs((long)(have.unixtime() - local.unixtime())) > 2) {
    rtcWrite(local);
    Serial.println("RTC set from internet time");
  }
}

void forgetEverything() {
  wm.resetSettings();                       // saved Wi-Fi networks
  xSemaphoreTake(prefsLock, portMAX_DELAY);
  prefs.remove("feederId");
  prefs.remove("devEmail");
  prefs.remove("devPass");
  xSemaphoreGive(prefsLock);
  feederId[0] = deviceEmail[0] = devicePassword[0] = 0;
  idToken = refreshToken = "";
  Serial.println("Wi-Fi and device account forgotten (calibration kept)");
}

// ---- Wi-Fi events (runs in the Wi-Fi event task: only store, never print) ----------
void onWifiEvent(arduino_event_id_t event, arduino_event_info_t info) {
  if (event == ARDUINO_EVENT_WIFI_STA_DISCONNECTED) {
    wifiLastReason = info.wifi_sta_disconnected.reason;
    wifiLastDropRssi = info.wifi_sta_disconnected.rssi;
    wifiDropCount = wifiDropCount + 1;
    wifiGotIp = false;
  } else if (event == ARDUINO_EVENT_WIFI_STA_GOT_IP) {
    wifiGotIp = true;
  }
}

// ---- network task ------------------------------------------------------------------
void networkTask(void*) {
  unsigned long lastPoll = 0, lastReport = 0, lastConfig = 0, lastMeasure = 0, lastMinute = 0;
  unsigned long lastSchedule = 0, wifiLostAt = millis(), lastWifiTry = millis(), retryAt = 0;
  bool started = false;

  loadAccount();
  loadCache();
  setenv("TZ", tzPosix, 1);
  tzset();
  clockFromRtc();                            // schedules work before the first connection
  configTzTime(tzPosix, "time.google.com", "pool.ntp.org");

  dbTls.setCACert(GOOGLE_ROOT_CAS);
  dbHttp.setReuse(true);

  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);
  WiFi.persistent(true);
  WiFi.onEvent(onWifiEvent);
  if (WIFI_DISABLE_SLEEP) WiFi.setSleep(false);
  wm.addParameter(&pFeeder);
  wm.addParameter(&pEmail);
  wm.addParameter(&pPassword);
  wm.setSaveParamsCallback(saveParams);
  wm.setSaveConfigCallback(saveParams);      // fields shown on the Wi-Fi page
  wm.setConfigPortalBlocking(false);         // feeding and schedules keep running
  wm.setConfigPortalTimeout(PORTAL_TIMEOUT_S);
  wm.setBreakAfterConfig(true);
  wm.setTitle("AgriFeed feeder setup");

  if (!hasAccount() || !wm.getWiFiIsSaved()) openPortal();
  else WiFi.begin();                         // the saved network

  for (;;) {
    vTaskDelay(pdMS_TO_TICKS(100));
    unsigned long now = millis();

    // -- Wi-Fi: setup portal, reconnect ---------------------------------
    if (forgetRequested) { forgetRequested = false; forgetEverything(); openPortal(); }
    if (setupRequested) { setupRequested = false; openPortal(); }
    if (wm.getConfigPortalActive()) {
      wm.process();
    }
    portalOpen = wm.getConfigPortalActive();

    // -- Wi-Fi diagnostics: disconnect reason, RSSI, reconnect result --------
    static uint32_t dropsLogged = 0, wifiTries = 0;
    static unsigned long lastDropLog = 0, lastRssiLog = 0;
    static bool wifiWasUp = false;
    if (wifiDropCount != dropsLogged && now - lastDropLog >= 5000) {
      uint32_t n = wifiDropCount;
      uint8_t reason = wifiLastReason;
      Serial.printf("Wi-Fi: disconnected, reason %u (%s), RSSI at drop %d dBm, %u event(s)\n",
                    reason, WiFi.disconnectReasonName((wifi_err_reason_t)reason),
                    (int)wifiLastDropRssi, (unsigned)(n - dropsLogged));
      dropsLogged = n;
      lastDropLog = now;
    }
    bool wifiUp = WiFi.status() == WL_CONNECTED;
    if (wifiUp && !wifiWasUp) {
      Serial.printf("Wi-Fi: connected to \"%s\" ch %d, RSSI %d dBm, IP %s (retries %u)\n",
                    WiFi.SSID().c_str(), WiFi.channel(), (int)WiFi.RSSI(),
                    WiFi.localIP().toString().c_str(), (unsigned)wifiTries);
      wifiTries = 0;
      lastRssiLog = now;
      if (portalOpen && portalAuto) {         // opened only because Wi-Fi was lost
        wm.stopConfigPortal();
        portalOpen = false;
        Serial.println("Wi-Fi: back on the saved network, setup portal closed");
      }
    } else if (!wifiUp && wifiWasUp) {
      Serial.printf("Wi-Fi: link lost, retrying the saved network every %lu s\n", WIFI_RETRY_MS / 1000);
    }
    wifiWasUp = wifiUp;
    if (wifiUp && now - lastRssiLog >= WIFI_RSSI_LOG_MS) {
      lastRssiLog = now;
      Serial.printf("Wi-Fi: RSSI %d dBm (ch %d), Firebase %s | last 30 s: %u ok, %u failed, avg %lu ms\n",
                    (int)WiFi.RSSI(), WiFi.channel(), netOnline ? "online" : "offline",
                    (unsigned)dbOkCount, (unsigned)dbFailCount,
                    dbOkCount ? dbMsTotal / dbOkCount : 0UL);
      dbOkCount = dbFailCount = 0;
      dbMsTotal = 0;
    }

    if (newAccount) {
      newAccount = false;
      retryAt = 0;
      started = false;
      reportedGate = -1;
      for (int i = 0; i < 3; i++) alertState[i] = -1;
    }

    // Schedules run from the clock even without Wi-Fi; their history is
    // queued until Firebase can take it.
    HwResult r;
    while (xQueueReceive(resultQueue, &r, 0) == pdTRUE) takeResult(r);
    if (job.active && !job.manual) finishJob();
    if (now - lastSchedule >= 1000) { lastSchedule = now; checkSchedules(); }

    if (WiFi.status() != WL_CONNECTED) {
      netOnline = false;
      started = false;
      if (!portalOpen && now - wifiLostAt > WIFI_GIVE_UP_MS) {
        Serial.println("Wi-Fi: saved network not reachable; opening setup, still retrying it");
        openPortal();
        portalAuto = true;
        wifiLostAt = now;
      }
      // Keep retrying the saved network even while the portal is open, except
      // while a phone is joined to AgriFeed-Setup (a retry changes the channel
      // and would drop that phone).
      if (wm.getWiFiIsSaved() && now - lastWifiTry > WIFI_RETRY_MS &&
          !(portalOpen && WiFi.softAPgetStationNum() > 0)) {
        if (wifiTries) Serial.printf("Wi-Fi: retry %u failed (status %d)\n", (unsigned)wifiTries, (int)WiFi.status());
        lastWifiTry = now;
        wifiTries++;
        Serial.printf("Wi-Fi: retry %u on the saved network%s\n", (unsigned)wifiTries,
                      portalOpen ? " (setup portal open)" : "");
        WiFi.begin();                        // try the saved network again
      }
      continue;
    }
    wifiLostAt = now;

    if (!hasAccount()) { netOnline = false; if (!portalOpen) openPortal(); continue; }
    if ((long)(now - retryAt) < 0) continue;   // waiting after a failure; the portal still works

    if (!idToken.length() || (long)(now - tokenRefreshAt) >= 0) {
      if (!signIn()) {
        netOnline = false;
        retryAt = millis() + (accountRejected ? 60000 : 10000);
        continue;
      }
    }

    if (!started) {                          // first contact after boot or reconnect
      JsonDocument last;
      if (dbGet("gate/state/lastRequestId", last) && last.is<const char*>()) lastGateRequestId = last.as<String>();
      JsonDocument lastCal;                  // never re-run an old calibration request after a restart
      if (dbGet("calibration/state/lastRequestId", lastCal) && lastCal.is<const char*>()) lastCalRequestId = lastCal.as<String>();
      JsonDocument cal;
      cal.set(calibrated ? "calibrated" : "uncalibrated");
      dbJson("PUT", "config/calibrationStatus", cal, nullptr);
      pollTimezone();
      pollConfig();
      pollSchedules();
      report();
      writeGateState(nullptr, nullptr);
      measure();
      lastReport = lastConfig = lastMeasure = lastMinute = now;
      // millis(), not now: lastDbOk was set after now was read, so now - lastDbOk
      // would wrap around and the feeder would never leave this start-up block.
      started = lastDbOk != 0 && millis() - lastDbOk < 5000;
      if (!started) { retryAt = millis() + 10000; continue; }
      Serial.printf("Firebase: connected, feeder %s (%s)\n", feederId, WiFi.SSID().c_str());
    }

    if (calibrationChanged) {                // tell the app right away, not only after a restart
      JsonDocument cal;
      cal.set(calibrated ? "calibrated" : "uncalibrated");
      if (dbJson("PUT", "config/calibrationStatus", cal, nullptr) == 200) calibrationChanged = false;
    }

    // Short pause after a failed call; the hardware (gate, feeding) keeps
    // running on the other core meanwhile.
    if ((long)(millis() - dbBackoffUntil) < 0) continue;

    finishJob();
    flushHistory();

    Snapshot s = readSnapshot();
    if ((s.gateOpen ? 1 : 0) != reportedGate) writeGateState(nullptr, nullptr);  // auto-close, feeding

    if (now - lastPoll >= 1000) {
      lastPoll = now;
      pollGate();
      if (!job.active) pollCalibration();
      if (!job.active) pollCommand();
    }
    bool busy = job.active || s.gateOpen;
    if (now - lastReport >= (busy ? REPORT_BUSY_MS : REPORT_IDLE_MS)) { lastReport = now; report(); }
    if (now - lastConfig >= 15000) { lastConfig = now; pollConfig(); pollSchedules(); }
    if (now - lastMeasure >= 60000) { lastMeasure = now; measure(); }
    if (now - lastMinute >= 60000) { lastMinute = now; pollTimezone(); syncRtc(); }

    netOnline = lastDbOk != 0 && millis() - lastDbOk < 15000;
  }
}

// ---- Setup ----------------------------------------------------------
void setup() {
  Serial.begin(115200);

  Wire.begin(LCD_SDA, LCD_SCL);     // LCD bus
  Wire1.begin(RTC_SDA, RTC_SCL);    // RTC bus

  lcd.init();
  lcd.backlight();
  lcdShow("AgriFeed", "Self test...");

  pinMode(BUZZER_PIN, OUTPUT);
  buzzerOff();
  if (ENABLE_SETUP_BUTTON) pinMode(SETUP_BUTTON_PIN, INPUT_PULLUP);

  // RTC
  rtcOk = rtc.begin(&Wire1);
  if (rtcOk && rtc.lostPower()) {
    rtc.adjust(DateTime(F(__DATE__), F(__TIME__)));
  }
  Serial.println(rtcOk ? "RTC: OK" : "RTC: NOT FOUND (check GPIO21/22, 3V3, GND)");

  // HX711
  scale.begin(HX_DT, HX_SCK);
  unsigned long start = millis();
  while (!scale.is_ready() && millis() - start < 3000) delay(50);
  hxOk = scale.is_ready();
  lastSampleAt = millis();
  Serial.println(hxOk ? "HX711: OK" : "HX711: NOT FOUND (check GPIO16/17, 3V3, GND)");

  // Show self-test result
  char l2[17];
  snprintf(l2, sizeof(l2), "RTC:%s HX:%s", rtcOk ? "OK" : "NO", hxOk ? "OK" : "NO");
  lcdShow("Self test", l2);
  delay(2000);

  // Saved tare + calibration. The hopper may hold feed when the power comes
  // back, so the zero is only taken on the very first start (or with 't').
  prefsLock = xSemaphoreCreateMutex();
  rtcLock = xSemaphoreCreateMutex();
  prefs.begin("agrifeed", false);
  calibrationFactor = prefs.getFloat("factor", calibrationFactor);
  calibrated = prefs.getBool("calibrated", false);
  scale.set_scale(calibrationFactor);
  if (prefs.isKey("offset")) {
    scale.set_offset(prefs.getLong("offset"));
    Serial.println("HX711: using saved tare");
  } else if (hxOk) {
    lcdShow("Keep scale empty", "Taring...");
    delay(2000);
    scale.tare();
    saveScale();
  }
  if (hxOk) weightGrams = scale.get_units(5);

  // Servo: always starts closed
  if (ENABLE_SERVO) {
    myServo.setPeriodHertz(50);
    myServo.attach(SERVO_PIN, 500, 2500);
    myServo.write(ANGLE_CLOSED);
  }
  servoOpen = false;

  cmdQueue = xQueueCreate(8, sizeof(HwCmd));
  resultQueue = xQueueCreate(4, sizeof(HwResult));
  calQueue = xQueueCreate(2, sizeof(CalResult));
  publishSnapshot();

  xTaskCreatePinnedToCore(networkTask, "firebase", 20480, nullptr, 1, nullptr, 0);

  startBeep(300);                   // startup beep
  Serial.println("Ready. Commands: t = tare, c = calibrate, r = raw/grams, s = status, w = Wi-Fi setup, x = forget Wi-Fi");
}

// ---- Main loop (never blocks) ---------------------------------------
void loop() {
  if (Serial.available()) {
    char cmd = Serial.read();
    if (cmd == 't' && hxOk) {
      if (hwState != HW_IDLE) {
        Serial.println("Not while the gate is open or feeding.");
      } else {
        scale.tare();
        saveScale();
        weightGrams = 0;
        Serial.println("Tared (saved).");
      }
    } else if (cmd == 'c' && hxOk) {
      if (hwState != HW_IDLE) Serial.println("Not while the gate is open or feeding.");
      else calibrate();
    } else if (cmd == 'r') {
      rawMode = !rawMode;
      Serial.println(rawMode ? "Raw mode ON (feeding disabled)" : "Grams mode ON");
    } else if (cmd == 's') {
      Serial.printf("Wi-Fi %s %s RSSI %d dBm, Firebase %s, feeder %s, account %s, calibrated %s\n",
                    WiFi.status() == WL_CONNECTED ? WiFi.SSID().c_str() : "down",
                    WiFi.status() == WL_CONNECTED ? WiFi.localIP().toString().c_str() : "",
                    WiFi.status() == WL_CONNECTED ? (int)WiFi.RSSI() : 0,
                    netOnline ? "online" : "offline", feederId[0] ? feederId : "(none)",
                    deviceEmail[0] ? deviceEmail : "(none)", calibrated ? "yes" : "no");
    } else if (cmd == 'w') {
      setupRequested = true;
    } else if (cmd == 'x') {
      forgetRequested = true;
    }
  }

  // Hold the on-board BOOT button 3 s to open Wi-Fi setup.
  if (ENABLE_SETUP_BUTTON) {
    if (digitalRead(SETUP_BUTTON_PIN) == LOW) {
      if (!buttonDownAt) buttonDownAt = millis();
      else if (buttonDownAt != 1 && millis() - buttonDownAt > 3000) {
        setupRequested = true;
        startBeep(200);
        buttonDownAt = 1;                     // once per press
      }
    } else {
      buttonDownAt = 0;
    }
  }

  updateWeight();
  updateGate();
  updateBuzzer();
  updateRtcReading();
  publishSnapshot();

  if (millis() - lastLcdUpdate >= LCD_REFRESH_MS) {
    lastLcdUpdate = millis();
    updateLcd();
  }

  if (millis() - lastSerialPrint >= 1000) {
    lastSerialPrint = millis();
    Serial.print("Weight: ");
    Serial.print(weightGrams, 1);
    Serial.print(" g | Gate: ");
    Serial.print(servoOpen ? "OPEN" : "CLOSED");
    Serial.print(" | RTC: ");
    Serial.print(rtcOk ? "OK" : "ERR");
    Serial.print(" | HX711: ");
    Serial.print(hxOk ? "OK" : "ERR");
    Serial.print(" | Firebase: ");
    Serial.println(portalOpen ? "setup" : netOnline ? "online" : "offline");
  }
}