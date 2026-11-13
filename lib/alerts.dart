import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

import 'household.dart';
import 'members.dart';

// =====================================================================
// HIGH CONSUMPTION ALERTS
//
// Two limits per appliance, both optional:
//   maxWatts     an instantaneous ceiling. Trips within seconds, and is
//                the one that matters when something is actually faulty.
//   maxDailyKwh  a budget for the day. Catches "it ran all afternoon".
//
// WHO DETECTS
// Both the ESP32 and the app evaluate the same limits against the same
// readings. The plug is the only part of the system that's always
// watching, so it's the one that matters; the app checking too means
// alerts still appear if a plug hasn't been re-flashed yet.
//
// WHY THAT DOESN'T PRODUCE DUPLICATES
// Alert ids are derived, not pushed: "{deviceId}-{kind}-{YYYY-MM-DD}".
// Two writers racing on the same breach aim at the same key, and the
// rules only permit a create where nothing exists yet — so the first
// one through wins and the rest are rejected. That same property is
// what limits a breach to one alert per appliance per day instead of
// one every three seconds.
// =====================================================================

class AlertKind {
  static const power = 'power';
  static const daily = 'daily';
}

/// A suggested "this is high" ceiling for an appliance: the power draw
/// and the daily energy that sit above normal use for that kind of
/// appliance. Rough estimates from typical specs, a starting point the
/// user is expected to tune, not a safety rating.
class SuggestedLimit {
  final int maxWatts;
  final double maxDailyKwh;

  const SuggestedLimit(this.maxWatts, this.maxDailyKwh);
}

/// General estimate per appliance type. Used before a brand is picked,
/// and for brands typed in through "Other".
const Map<String, SuggestedLimit> kTypeSuggestedLimits = {
  "Aircon": SuggestedLimit(1850, 14.5),
  "Fridge": SuggestedLimit(380, 2.2),
  "TV": SuggestedLimit(220, 1.8),
  "Light": SuggestedLimit(60, 0.7),
  "Washer": SuggestedLimit(900, 1.4),
  "Fan": SuggestedLimit(90, 1.0),
  "Heater": SuggestedLimit(4000, 3.0),
};

/// Brand-specific estimates per appliance type, based on the typical
/// specs of each brand's common household models in the Philippines
/// (e.g. inverter aircons and fridges draw less than non-inverter ones,
/// DC fans less than AC ones). Models vary a lot within a brand, so
/// these are deliberately approximate.
const Map<String, Map<String, SuggestedLimit>> kBrandSuggestedLimits = {
  "Aircon": {
    "Carrier": SuggestedLimit(1900, 15.0),
    "Koppel": SuggestedLimit(1900, 15.0),
    "Condura": SuggestedLimit(2000, 16.0),
    "Kolin": SuggestedLimit(2000, 16.0),
    "LG": SuggestedLimit(1700, 13.0),
    "Samsung": SuggestedLimit(1700, 13.0),
    "Panasonic": SuggestedLimit(1700, 13.0),
    "Daikin": SuggestedLimit(1600, 12.0),
    "Midea": SuggestedLimit(1900, 15.0),
    "TCL": SuggestedLimit(1900, 15.0),
    "Hitachi": SuggestedLimit(1700, 13.0),
    "Fujidenzo": SuggestedLimit(2000, 16.0),
    "American Home": SuggestedLimit(2000, 16.0),
  },
  "Fridge": {
    "Samsung": SuggestedLimit(350, 2.0),
    "LG": SuggestedLimit(350, 2.0),
    "Panasonic": SuggestedLimit(330, 1.9),
    "Sharp": SuggestedLimit(380, 2.2),
    "Condura": SuggestedLimit(400, 2.4),
    "Whirlpool": SuggestedLimit(400, 2.4),
    "Fujidenzo": SuggestedLimit(420, 2.5),
    "Hisense": SuggestedLimit(380, 2.2),
    "Midea": SuggestedLimit(380, 2.2),
    "Haier": SuggestedLimit(380, 2.2),
    "Electrolux": SuggestedLimit(380, 2.2),
    "American Home": SuggestedLimit(420, 2.5),
  },
  "TV": {
    "Samsung": SuggestedLimit(250, 2.0),
    "LG": SuggestedLimit(250, 2.0),
    "Sony": SuggestedLimit(260, 2.1),
    "TCL": SuggestedLimit(220, 1.8),
    "Hisense": SuggestedLimit(220, 1.8),
    "Sharp": SuggestedLimit(220, 1.8),
    "Panasonic": SuggestedLimit(230, 1.9),
    "Xiaomi": SuggestedLimit(200, 1.6),
    "Skyworth": SuggestedLimit(200, 1.6),
    "Devant": SuggestedLimit(200, 1.6),
    "Coocaa": SuggestedLimit(180, 1.5),
  },
  "Light": {
    "Philips": SuggestedLimit(60, 0.7),
    "Firefly": SuggestedLimit(60, 0.7),
    "Omni": SuggestedLimit(60, 0.7),
    "Akari": SuggestedLimit(60, 0.7),
    "Osram": SuggestedLimit(60, 0.7),
    "GE": SuggestedLimit(70, 0.8),
    "Xiaomi": SuggestedLimit(40, 0.5),
    "TP-Link Tapo": SuggestedLimit(40, 0.5),
  },
  "Washer": {
    "LG": SuggestedLimit(1000, 1.5),
    "Samsung": SuggestedLimit(1000, 1.5),
    "Panasonic": SuggestedLimit(900, 1.4),
    "Electrolux": SuggestedLimit(2100, 2.5),
    "Whirlpool": SuggestedLimit(1000, 1.5),
    "Sharp": SuggestedLimit(600, 1.0),
    "Fujidenzo": SuggestedLimit(500, 0.9),
    "Haier": SuggestedLimit(900, 1.4),
    "Hanabishi": SuggestedLimit(500, 0.9),
    "Midea": SuggestedLimit(800, 1.3),
    "American Home": SuggestedLimit(500, 0.9),
  },
  "Fan": {
    "Asahi": SuggestedLimit(90, 1.0),
    "Hanabishi": SuggestedLimit(90, 1.0),
    "Standard": SuggestedLimit(90, 1.0),
    "Dowell": SuggestedLimit(90, 1.0),
    "Kolin": SuggestedLimit(80, 0.9),
    "Union": SuggestedLimit(90, 1.0),
    "Imarflex": SuggestedLimit(90, 1.0),
    "Xiaomi": SuggestedLimit(40, 0.5),
    "Panasonic": SuggestedLimit(80, 0.9),
    "Iwata": SuggestedLimit(150, 1.6),
    "Camel": SuggestedLimit(100, 1.1),
  },
  "Heater": {
    "Ariston": SuggestedLimit(4000, 3.0),
    "Panasonic": SuggestedLimit(4000, 3.0),
    "Joven": SuggestedLimit(4000, 3.0),
    "Rheem": SuggestedLimit(3600, 3.5),
    "Centon": SuggestedLimit(4000, 3.0),
    "Alpha": SuggestedLimit(4000, 3.0),
    "Electrolux": SuggestedLimit(4000, 3.0),
    "Imarflex": SuggestedLimit(2500, 2.5),
  },
};

/// The estimate for a type and brand. Falls back to the type's general
/// estimate when the brand is unknown (null, or typed via "Other").
SuggestedLimit? suggestedLimitFor(String? type, String? brand) {
  if (type == null) return null;
  return kBrandSuggestedLimits[type]?[brand] ?? kTypeSuggestedLimits[type];
}

/// Below this, a percentage swing isn't worth anyone's attention: a
/// device going from 0.01 to 0.02 kWh is "100% over" and means nothing.
/// The old Home banner had no such floor and cried wolf on idle plugs.
const double kMinKwhForAnomaly = 0.10;

class DeviceLimits {
  /// null or 0 means "no limit set" — the check is skipped entirely.
  final double? maxWatts;
  final double? maxDailyKwh;

  const DeviceLimits({this.maxWatts, this.maxDailyKwh});

  static const none = DeviceLimits();

  factory DeviceLimits.fromMap(Object? raw) {
    if (raw is! Map) return DeviceLimits.none;
    double? read(Object? v) {
      if (v is num && v > 0) return v.toDouble();
      return null;
    }

    return DeviceLimits(
      maxWatts: read(raw['maxWatts']),
      maxDailyKwh: read(raw['maxDailyKwh']),
    );
  }

  bool get isEmpty => maxWatts == null && maxDailyKwh == null;
}

String _dateKey(DateTime d) {
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return "$y-$m-$day";
}

/// Deterministic, and therefore idempotent — see the note at the top.
String alertIdFor(String deviceId, String kind, DateTime when) =>
    "$deviceId-$kind-${_dateKey(when)}";

/// Raises an alert if [value] is over [limit], unless one already exists
/// for this appliance, kind and day.
///
/// Fire-and-forget: a rejected write is the normal, expected outcome
/// (it means someone already logged this breach) and must never surface
/// as an error to whoever happens to have the app open.
Future<void> raiseAlert({
  required String deviceId,
  required String deviceName,
  required String kind,
  required double value,
  required double limit,
}) async {
  try {
    final session = HouseholdSession.current;
    if (session == null || session.isRevoked) return;

    final now = DateTime.now();
    final id = alertIdFor(deviceId, kind, now);

    await FirebaseDatabase.instance.ref('alerts/${session.householdUid}/$id').set({
      'at': ServerValue.timestamp,
      'deviceId': deviceId,
      'deviceName': deviceName,
      'kind': kind,
      'value': value,
      'limit': limit,
      'acknowledged': false,
    });
  } catch (_) {
    // Already recorded, or not permitted. Either way, nothing to say.
  }
}

/// Checks one appliance's live readings against its limits.
///
/// Called from the Home page, which already streams power and history
/// for every appliance in the household — so this costs no extra reads.
void evaluateDeviceAlerts({
  required String deviceId,
  required String deviceName,
  required DeviceLimits limits,
  required double watts,
  required double todayKwh,
}) {
  if (limits.isEmpty) return;

  final maxWatts = limits.maxWatts;
  if (maxWatts != null && watts > maxWatts) {
    raiseAlert(
      deviceId: deviceId,
      deviceName: deviceName,
      kind: AlertKind.power,
      value: watts,
      limit: maxWatts,
    );
  }

  final maxDaily = limits.maxDailyKwh;
  if (maxDaily != null && todayKwh > maxDaily) {
    raiseAlert(
      deviceId: deviceId,
      deviceName: deviceName,
      kind: AlertKind.daily,
      value: todayKwh,
      limit: maxDaily,
    );
  }
}

// ---------------------------------------------------------------------
// MODEL
// ---------------------------------------------------------------------
class ConsumptionAlert {
  final String id;
  final DateTime at;
  final String deviceId;
  final String deviceName;
  final String kind;
  final double value;
  final double limit;
  final bool acknowledged;

  const ConsumptionAlert({
    required this.id,
    required this.at,
    required this.deviceId,
    required this.deviceName,
    required this.kind,
    required this.value,
    required this.limit,
    required this.acknowledged,
  });

  static ConsumptionAlert? fromMap(String id, Map<dynamic, dynamic> raw) {
    final at = raw['at'];
    if (at is! num) return null; // server timestamp not resolved yet
    return ConsumptionAlert(
      id: id,
      at: DateTime.fromMillisecondsSinceEpoch(at.toInt()),
      deviceId: (raw['deviceId'] as String?) ?? '',
      deviceName: (raw['deviceName'] as String?)?.trim().isNotEmpty == true
          ? (raw['deviceName'] as String).trim()
          : 'An appliance',
      kind: (raw['kind'] as String?) ?? AlertKind.power,
      value: raw['value'] is num ? (raw['value'] as num).toDouble() : 0,
      limit: raw['limit'] is num ? (raw['limit'] as num).toDouble() : 0,
      acknowledged: raw['acknowledged'] == true,
    );
  }

  bool get isPower => kind == AlertKind.power;

  String get headline => isPower ? "Power spike" : "Daily usage over budget";

  String get detail => isPower
      ? "Drew ${value.toStringAsFixed(0)} W, over its ${limit.toStringAsFixed(0)} W limit"
      : "Used ${value.toStringAsFixed(2)} kWh today, over its ${limit.toStringAsFixed(2)} kWh budget";
}

// ---------------------------------------------------------------------
// ALERTS PAGE
// ---------------------------------------------------------------------
const Color _kInk = Color(0xFF1F2937);
const Color _kFaint = Color(0xFF94A3B8);
const Color _kLine = Color(0xFFE2E8F0);
const Color _kAmber = Color(0xFFF59E0B);

class AlertsPage extends StatefulWidget {
  const AlertsPage({super.key});

  @override
  State<AlertsPage> createState() => _AlertsPageState();
}

class _AlertsPageState extends State<AlertsPage> {
  HouseholdSession? _session;
  StreamSubscription<DatabaseEvent>? _sub;
  List<ConsumptionAlert> _alerts = [];
  bool _loaded = false;
  bool _showAcknowledged = false;

  @override
  void initState() {
    super.initState();
    HouseholdSession.ensureLoaded().then((session) {
      if (!mounted) return;
      setState(() => _session = session);
      if (session.isRevoked) {
        setState(() => _loaded = true);
        return;
      }
      _listen(session.householdUid);
    }).catchError((Object _) {
      if (mounted) setState(() => _loaded = true);
    });
  }

  void _listen(String householdUid) {
    _sub = FirebaseDatabase.instance
        .ref('alerts/$householdUid')
        .orderByChild('at')
        .limitToLast(200)
        .onValue
        .listen((event) {
      final raw = event.snapshot.value;
      final list = <ConsumptionAlert>[];
      if (raw is Map) {
        raw.forEach((key, value) {
          if (value is Map) {
            final alert = ConsumptionAlert.fromMap(key.toString(), value);
            if (alert != null) list.add(alert);
          }
        });
      }
      list.sort((a, b) => b.at.compareTo(a.at));
      if (!mounted) return;
      setState(() {
        _alerts = list;
        _loaded = true;
      });
    }, onError: (Object _) {
      if (mounted) setState(() => _loaded = true);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _acknowledge(ConsumptionAlert alert) async {
    final householdUid = _session?.householdUid;
    if (householdUid == null) return;
    try {
      await FirebaseDatabase.instance
          .ref('alerts/$householdUid/${alert.id}/acknowledged')
          .set(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't dismiss that alert: $e")),
      );
    }
  }

  Future<void> _acknowledgeAll(List<ConsumptionAlert> open) async {
    final householdUid = _session?.householdUid;
    if (householdUid == null || open.isEmpty) return;
    try {
      await FirebaseDatabase.instance.ref().update({
        for (final a in open) 'alerts/$householdUid/${a.id}/acknowledged': true,
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't dismiss those alerts: $e")),
      );
    }
  }

  static String _timeLabel(DateTime when) {
    final now = DateTime.now();
    final diff = now.difference(when);
    if (diff.inMinutes < 1) return "Just now";
    if (diff.inMinutes < 60) return "${diff.inMinutes}m ago";
    if (diff.inHours < 24) return "${diff.inHours}h ago";
    if (diff.inDays == 1) return "Yesterday";
    return "${diff.inDays}d ago";
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    if (session != null && session.isRevoked) {
      return const RevokedAccessScreen();
    }

    final open = _alerts.where((a) => !a.acknowledged).toList();
    final visible = _showAcknowledged ? _alerts : open;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: SafeArea(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(8, 10, 16, 14),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back, color: _kInk),
                  ),
                  const Expanded(
                    child: Text(
                      "Alerts",
                      style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: _kInk),
                    ),
                  ),
                  if (open.isNotEmpty)
                    TextButton(
                      onPressed: () => _acknowledgeAll(open),
                      child: const Text(
                        "Dismiss all",
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF0F766E)),
                      ),
                    ),
                ],
              ),
            ),

            if (_alerts.any((a) => a.acknowledged))
              Container(
                width: double.infinity,
                color: Colors.white,
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Row(
                  children: [
                    Text(
                      _showAcknowledged ? "Showing all alerts" : "Showing open alerts",
                      style: const TextStyle(fontSize: 11, color: _kFaint),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => setState(() => _showAcknowledged = !_showAcknowledged),
                      child: Text(
                        _showAcknowledged ? "Hide dismissed" : "Show dismissed",
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF0F766E),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            Expanded(child: _body(visible)),
          ],
        ),
      ),
    );
  }

  Widget _body(List<ConsumptionAlert> visible) {
    if (!_loaded) return const Center(child: CircularProgressIndicator());

    if (visible.isEmpty) {
      return const AccessNotice(
        icon: Icons.verified_outlined,
        title: "Nothing to worry about",
        message: "Appliances that go over the limits you set will show up here. "
            "Set a limit from an appliance's edit screen.",
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 26),
      itemCount: visible.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, i) => _alertCard(visible[i]),
    );
  }

  Widget _alertCard(ConsumptionAlert alert) {
    final dimmed = alert.acknowledged;

    return Opacity(
      opacity: dimmed ? 0.55 : 1,
      child: Container(
        padding: const EdgeInsets.fromLTRB(13, 12, 13, 12),
        decoration: BoxDecoration(
          color: dimmed ? Colors.white : const Color(0xFFFFFBEB),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: dimmed ? _kLine : const Color(0xFFFDE68A)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: dimmed ? const Color(0xFFF1F5F9) : const Color(0xFFFEF3C7),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                alert.isPower ? Icons.bolt : Icons.trending_up,
                size: 18,
                color: dimmed ? _kFaint : _kAmber,
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "${alert.deviceName} · ${alert.headline}",
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: _kInk),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    alert.detail,
                    style: const TextStyle(fontSize: 11, color: Color(0xFF78350F), height: 1.4),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _timeLabel(alert.at),
                    style: const TextStyle(fontSize: 10, color: _kFaint),
                  ),
                ],
              ),
            ),
            if (!alert.acknowledged)
              IconButton(
                onPressed: () => _acknowledge(alert),
                icon: const Icon(Icons.check, size: 18, color: Color(0xFF0F766E)),
                tooltip: "Dismiss",
              ),
          ],
        ),
      ),
    );
  }
}
