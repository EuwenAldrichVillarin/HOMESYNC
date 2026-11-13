import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import 'alerts.dart';
import 'household.dart';
import 'rate_dialog.dart';
import 'members.dart';
import 'profile.dart';
import 'activity.dart';

const double _kDefaultPesoPerKwh = 11.0;

class _HomeDevice {
  final String name;
  final String room;
  final String type;
  final bool isOn;
  final double powerW;
  final Map<String, double> dailyKwh; // "YYYY-MM-DD" -> kWh used that day
  final DeviceLimits limits;

  const _HomeDevice({
    required this.name,
    required this.room,
    required this.type,
    required this.isOn,
    required this.powerW,
    required this.dailyKwh,
    required this.limits,
  });
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const Map<String, IconData> _typeIcons = {
    "Aircon": Icons.ac_unit,
    "Fridge": Icons.kitchen,
    "TV": Icons.tv,
    "Light": Icons.lightbulb_outline,
    "Washer": Icons.local_laundry_service,
    "Fan": Icons.mode_fan_off,
    "Heater": Icons.thermostat,
    "Other": Icons.power,
  };

  static const Map<String, Color> _typeBg = {
    "Aircon": Color(0xFFE0F2FE),
    "Fridge": Color(0xFFE0F2FE),
    "TV": Color(0xFFF3E8FF),
    "Light": Color(0xFFFEF3C7),
    "Washer": Color(0xFFE0F2FE),
    "Fan": Color(0xFFE0F2FE),
    "Heater": Color(0xFFFFE4E6),
    "Other": Color(0xFFE8F8F5),
  };

  static const Map<String, Color> _typeFg = {
    "Aircon": Color(0xFF0284C7),
    "Fridge": Color(0xFF0284C7),
    "TV": Color(0xFF9333EA),
    "Light": Color(0xFFF59E0B),
    "Washer": Color(0xFF0284C7),
    "Fan": Color(0xFF0284C7),
    "Heater": Color(0xFFDC2626),
    "Other": Color(0xFF0F766E),
  };

  double _pesoPerKwh = _kDefaultPesoPerKwh;

  HouseholdSession? _session;

  StreamSubscription<DatabaseEvent>? _alertsSub;
  List<ConsumptionAlert> _openAlerts = [];

  StreamSubscription<DatabaseEvent>? _appliancesSub;
  StreamSubscription<DatabaseEvent>? _rateSub;
  final Map<String, StreamSubscription<DatabaseEvent>> _deviceSubs = {};
  final Map<String, _HomeDevice> _devices = {};

  @override
  void initState() {
    super.initState();
    // Which uid to read from depends on the role: an admin reads their
    // own appliance index, a member reads the admin's. So the session has
    // to resolve before anything subscribes.
    HouseholdSession.ensureLoaded().then((session) {
      if (!mounted) return;
      setState(() => _session = session);
      if (session.isRevoked) return;

      final householdUid = session.householdUid;
      _listenToAppliances(householdUid);
      _listenToAlerts(householdUid);
      _rateSub =
          FirebaseDatabase.instance.ref('users/$householdUid/settings/pesoPerKwh').onValue.listen((event) {
        final value = event.snapshot.value;
        if (value is num) {
          setState(() => _pesoPerKwh = value.toDouble());
        }
      });
    }).catchError((Object _) {
      // Left null — build() keeps showing the loading state.
    });
  }

  // ===============================================================
  // LIVE DATA — same watch-the-index-then-watch-each-device pattern
  // used in appliances.dart and report.dart. The uid passed in is the
  // household's (the admin's), not necessarily the signed-in user's.
  // ===============================================================
  void _listenToAppliances(String householdUid) {
    final ref = FirebaseDatabase.instance.ref('users/$householdUid/appliances');
    _appliancesSub = ref.onValue.listen((event) {
      final raw = event.snapshot.value;
      final ids = <String>{};
      if (raw is Map) ids.addAll(raw.keys.map((k) => k.toString()));

      for (final id in _deviceSubs.keys.toList()) {
        if (!ids.contains(id)) {
          _deviceSubs.remove(id)?.cancel();
          setState(() => _devices.remove(id));
        }
      }

      for (final id in ids) {
        if (_deviceSubs.containsKey(id)) continue;
        final devRef = FirebaseDatabase.instance.ref('devices/$id');
        _deviceSubs[id] = devRef.onValue.listen((deviceEvent) {
          final raw = deviceEvent.snapshot.value;
          final data = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
          final info = data['info'] is Map ? Map<String, dynamic>.from(data['info']) : <String, dynamic>{};
          final state = data['state'] is Map ? Map<String, dynamic>.from(data['state']) : <String, dynamic>{};
          final telemetry =
              data['telemetry'] is Map ? Map<String, dynamic>.from(data['telemetry']) : <String, dynamic>{};
          final historyRaw =
              data['history'] is Map ? Map<String, dynamic>.from(data['history']) : <String, dynamic>{};

          final dailyKwh = <String, double>{};
          historyRaw.forEach((key, value) {
            if (value is num) dailyKwh[key.toString()] = value.toDouble();
          });

          final powerValue = telemetry['power'];
          final limits = DeviceLimits.fromMap(data['limits']);
          final name = (info['name'] as String?) ?? 'Unnamed';
          final watts = powerValue is num ? powerValue.toDouble() : 0.0;

          setState(() {
            _devices[id] = _HomeDevice(
              name: name,
              room: (info['room'] as String?) ?? '',
              type: (info['type'] as String?) ?? 'Other',
              isOn: state['relay'] == true,
              powerW: watts,
              dailyKwh: dailyKwh,
              limits: limits,
            );
          });

          // The plug checks its own limits too, and gets there first when
          // nobody has the app open. Both aim at the same alert id, so
          // whichever notices a given breach first is the one that lands.
          evaluateDeviceAlerts(
            deviceId: id,
            deviceName: name,
            limits: limits,
            watts: watts,
            todayKwh: dailyKwh[_dateKey(DateTime.now())] ?? 0,
          );
        });
      }
    });
  }

  /// Open (undismissed) alerts, for the banner further down.
  void _listenToAlerts(String householdUid) {
    _alertsSub = FirebaseDatabase.instance
        .ref('alerts/$householdUid')
        .orderByChild('at')
        .limitToLast(50)
        .onValue
        .listen((event) {
      final raw = event.snapshot.value;
      final list = <ConsumptionAlert>[];
      if (raw is Map) {
        raw.forEach((key, value) {
          if (value is Map) {
            final alert = ConsumptionAlert.fromMap(key.toString(), value);
            if (alert != null && !alert.acknowledged) list.add(alert);
          }
        });
      }
      list.sort((a, b) => b.at.compareTo(a.at));
      if (!mounted) return;
      setState(() => _openAlerts = list);
    }, onError: (Object _) {
      // Rules not deployed yet, or no access — the softer anomaly nudge
      // below still works.
    });
  }

  @override
  void dispose() {
    _alertsSub?.cancel();
    _appliancesSub?.cancel();
    _rateSub?.cancel();
    for (final sub in _deviceSubs.values) {
      sub.cancel();
    }
    super.dispose();
  }

  static String _dateKey(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return "$y-$m-$day";
  }

  Future<void> _openProfile() async {
    await Navigator.pushNamed(context, '/profile');
    // _greeting() reads the Firebase Auth displayName, which the profile
    // page may have just changed.
    if (mounted) setState(() {});
  }

  void _toggleRelay(String deviceId, bool currentlyOn) {
    final session = _session;
    if (session != null && !session.canControl) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("You don't have permission to control appliances")),
      );
      return;
    }
    final name = _devices[deviceId]?.name ?? 'an appliance';
    final turningOn = !currentlyOn;

    unawaited(
      FirebaseDatabase.instance.ref('devices/$deviceId/command/relay').set(turningOn).then((_) {
        // Logged only once the command is actually accepted, so the log
        // never claims someone switched something they couldn't.
        logActivity(
          action: turningOn ? ActivityAction.deviceOn : ActivityAction.deviceOff,
          target: name,
        );
      }).catchError((Object e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Couldn't send command: $e")),
        );
      }),
    );
  }

  // ===============================================================
  // LOGOUT CONFIRMATION
  // ===============================================================
  void _showLogoutDialog(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          contentPadding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(color: const Color(0xFFE6F7F5), shape: BoxShape.circle),
                child: const Icon(Icons.logout, size: 30, color: Color(0xFF0F766E)),
              ),
              const SizedBox(height: 18),
              const Text(
                "Log Out?",
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF1F2937)),
              ),
              const SizedBox(height: 10),
              const Text(
                "Are you sure you want to log out of your account?",
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Color(0xFF64748B), height: 1.4),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: () async {
                    Navigator.of(dialogContext).pop();
                    HouseholdSession.clear();
                    await FirebaseAuth.instance.signOut();
                    if (!context.mounted) return;
                    Navigator.pushReplacementNamed(context, '/login');
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0F766E),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text("Yes, Log Out", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF0F766E),
                    side: const BorderSide(color: Color(0xFF0F766E)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text("Cancel", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ===============================================================
  // GREETING
  // ===============================================================
  String _greeting() {
    final user = FirebaseAuth.instance.currentUser;

    String name = "there";
    if (user?.displayName != null && user!.displayName!.trim().isNotEmpty) {
      name = user.displayName!.trim().split(" ").first;
    } else if (user?.email != null) {
      name = user!.email!.split("@").first;
    }

    final hour = DateTime.now().hour;
    final timeOfDay = hour < 12
        ? "morning"
        : hour < 17
            ? "afternoon"
            : "evening";

    return "Good $timeOfDay, $name";
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    if (uid == null) {
      return const Scaffold(
        backgroundColor: Color(0xFFF9FAFB),
        body: SafeArea(child: Center(child: Text("Not signed in"))),
      );
    }

    final session = _session;
    if (session == null) {
      return const Scaffold(
        backgroundColor: Color(0xFFF9FAFB),
        body: SafeArea(child: Center(child: CircularProgressIndicator())),
      );
    }
    if (session.isRevoked) {
      return const RevokedAccessScreen();
    }

    final devices = _devices.values.toList();
    final deviceEntries = _devices.entries.toList();

    final totalWatts = devices.fold<double>(0, (a, d) => a + d.powerW);
    final totalKw = totalWatts / 1000;
    final activeCount = devices.where((d) => d.isOn).length;

    final today = DateTime.now();
    final todayKey = _dateKey(DateTime(today.year, today.month, today.day));
    final yesterdayKey = _dateKey(DateTime(today.year, today.month, today.day - 1));

    double todayKwh = 0;
    double yesterdayKwh = 0;
    for (final d in devices) {
      todayKwh += d.dailyKwh[todayKey] ?? 0;
      yesterdayKwh += d.dailyKwh[yesterdayKey] ?? 0;
    }
    final todayCost = todayKwh * _pesoPerKwh;
    final double? changePct = yesterdayKwh > 0 ? ((todayKwh - yesterdayKwh) / yesterdayKwh) * 100 : null;

    _HomeDevice? topDevice;
    for (final d in devices) {
      if (topDevice == null || d.powerW > topDevice.powerW) topDevice = d;
    }
    final topDeviceLabel = (topDevice != null && topDevice.powerW > 0) ? topDevice.name : "--";

    final weeklyTotals = List.generate(7, (i) {
      final d = DateTime(today.year, today.month, today.day - (6 - i));
      final key = _dateKey(d);
      double total = 0;
      for (final dev in devices) {
        total += dev.dailyKwh[key] ?? 0;
      }
      return MapEntry(_weekdayLabel(d.weekday), total);
    });
    final maxWeekly = weeklyTotals.fold<double>(0, (a, e) => e.value > a ? e.value : a);
    final weeklyAxisMax = maxWeekly <= 0 ? 1.0 : maxWeekly * 1.15;

    // High-usage heuristic: flag a device whose kWh so far today is well
    // above the average of its last 6 logged days.
    _HomeDevice? alertDevice;
    double alertPct = 0;
    for (final d in devices) {
      final todayVal = d.dailyKwh[todayKey] ?? 0;
      final priorValues = <double>[];
      for (int i = 1; i <= 6; i++) {
        final key = _dateKey(DateTime(today.year, today.month, today.day - i));
        final v = d.dailyKwh[key];
        if (v != null) priorValues.add(v);
      }
      if (priorValues.isEmpty) continue;
      final avgPrior = priorValues.reduce((a, b) => a + b) / priorValues.length;
      if (avgPrior <= 0) continue;
      // Percentages alone are meaningless at tiny absolute values — going
      // from 0.01 to 0.02 kWh is "100% over" and worth nobody's
      // attention. Require a real amount of extra energy as well.
      if (todayVal - avgPrior < kMinKwhForAnomaly) continue;
      final pctOver = (todayVal - avgPrior) / avgPrior * 100;
      if (pctOver > 20 && pctOver > alertPct) {
        alertPct = pctOver;
        alertDevice = d;
      }
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            children: [

              // =====================================================
              // 1. HEADER
              // =====================================================
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Tapping your own picture opens the profile editor.
                    // LiveProfileAvatar watches users/{uid}/profile, so a
                    // change made there shows up here without a reload.
                    InkWell(
                      borderRadius: BorderRadius.circular(21),
                      onTap: _openProfile,
                      child: LiveProfileAvatar(
                        uid: uid,
                        fallbackName: FirebaseAuth.instance.currentUser?.displayName ??
                            FirebaseAuth.instance.currentUser?.email ??
                            '',
                        size: 42,
                      ),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _greeting(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1F2937)),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              const Icon(Icons.home, size: 14, color: Color(0xFF0F766E)),
                              const SizedBox(width: 3),
                              Text(
                                session.isMember && (session.householdName?.isNotEmpty ?? false)
                                    ? "${session.householdName}'s home"
                                    : "My Home",
                                style: const TextStyle(fontSize: 11, color: Color(0xFF0F766E)),
                              ),
                              if (session.isMember) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFE6F7F5),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: const Text(
                                    "Member",
                                    style: TextStyle(
                                      fontSize: 8,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF0F766E),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                    Row(
                      children: [
                        // Members share the admin's rate but can't change it.
                        if (session.canEditRate) ...[
                          InkWell(
                            borderRadius: BorderRadius.circular(19),
                            onTap: () => showEditRateDialog(context, session.householdUid, _pesoPerKwh),
                            child: Container(
                              width: 38,
                              height: 38,
                              decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                              child: const Tooltip(
                                message: "Edit electricity rate",
                                child: Icon(Icons.payments_outlined, size: 18, color: Color(0xFF1F2937)),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                        ],
                        if (session.canManageMembers) ...[
                          InkWell(
                            borderRadius: BorderRadius.circular(19),
                            onTap: () => Navigator.pushNamed(context, '/members'),
                            child: Container(
                              width: 38,
                              height: 38,
                              decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                              child: const Tooltip(
                                message: "Household members",
                                child: Icon(Icons.group_outlined, size: 18, color: Color(0xFF1F2937)),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                        ],
                        InkWell(
                          borderRadius: BorderRadius.circular(19),
                          onTap: () => Navigator.pushNamed(context, '/activity'),
                          child: Container(
                            width: 38,
                            height: 38,
                            decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                            child: const Tooltip(
                              message: "Control log",
                              child: Icon(Icons.history, size: 18, color: Color(0xFF1F2937)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // =====================================================
              // 2. REAL-TIME CONSUMPTION
              // =====================================================
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(color: const Color(0xFF0F766E), borderRadius: BorderRadius.circular(16)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              "Real-time Consumption",
                              style: TextStyle(fontSize: 11, color: Colors.white70),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: () => _showLogoutDialog(context),
                              borderRadius: BorderRadius.circular(30),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.10),
                                  borderRadius: BorderRadius.circular(30),
                                  border: Border.all(color: Colors.white.withValues(alpha: 0.30), width: 1),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.logout, size: 13, color: Colors.white),
                                    SizedBox(width: 5),
                                    Text(
                                      "Log Out",
                                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.white),
                                    ),
                                    SizedBox(width: 4),
                                    Icon(Icons.arrow_forward, size: 14, color: Colors.white),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            totalKw.toStringAsFixed(2),
                            style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                          const SizedBox(width: 5),
                          const Padding(
                            padding: EdgeInsets.only(bottom: 5),
                            child: Text("kW", style: TextStyle(fontSize: 11, color: Colors.white70)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          if (changePct == null)
                            const Text(
                              "No data from yesterday yet",
                              style: TextStyle(fontSize: 9, color: Colors.white70),
                            )
                          else ...[
                            Icon(
                              changePct <= 0 ? Icons.arrow_downward : Icons.arrow_upward,
                              size: 12,
                              color: changePct <= 0 ? const Color(0xFF86EFAC) : const Color(0xFFFCA5A5),
                            ),
                            const SizedBox(width: 3),
                            Text(
                              "${changePct.abs().toStringAsFixed(0)}% from yesterday",
                              style: TextStyle(
                                fontSize: 9,
                                color: changePct <= 0 ? const Color(0xFF86EFAC) : const Color(0xFFFCA5A5),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // =====================================================
              // 3. SMALL STATISTICS
              // =====================================================
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Expanded(child: _statTile("Active", "$activeCount")),
                    const SizedBox(width: 8),
                    Expanded(child: _statTile("Today", "₱${todayCost.toStringAsFixed(0)}")),
                    const SizedBox(width: 8),
                    Expanded(child: _statTile("Top Now", topDeviceLabel)),
                  ],
                ),
              ),

              const SizedBox(height: 18),

              // =====================================================
              // 4. QUICK CONTROLS
              // =====================================================
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      "Quick Controls",
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF1F2937)),
                    ),
                    InkWell(
                      onTap: () => Navigator.pushReplacementNamed(context, '/appliances'),
                      child: const Text(
                        "View All",
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF0F766E)),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 10),

              // =====================================================
              // APPLIANCES
              // =====================================================
              if (devices.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Container(
                    width: double.infinity,
                    height: 100,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
                    child: TextButton(
                      onPressed: () => Navigator.pushReplacementNamed(context, '/appliances'),
                      child: const Text(
                        "No appliances yet — tap to add one",
                        style: TextStyle(fontSize: 12, color: Color(0xFF0F766E), fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                )
              else
                SizedBox(
                  height: 115,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: deviceEntries.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (context, i) => _quickControlCard(deviceEntries[i]),
                  ),
                ),

              const SizedBox(height: 18),

              // =====================================================
              // 5. WEEKLY TREND
              // =====================================================
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      "Weekly Trend",
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF1F2937)),
                    ),
                    InkWell(
                      onTap: () => Navigator.pushReplacementNamed(context, '/report'),
                      child: const Text(
                        "Full Report",
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF0F766E)),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 10),

              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Container(
                  width: double.infinity,
                  height: 150,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: weeklyTotals.map((entry) {
                      final isToday = entry.key == _weekdayLabel(today.weekday) &&
                          weeklyTotals.last.key == entry.key;
                      final height = (entry.value / weeklyAxisMax * 100).clamp(3.0, 100.0).toDouble();
                      return _bar(entry.key, height, isToday);
                    }).toList(),
                  ),
                ),
              ),

              const SizedBox(height: 18),

              // =====================================================
              // 6. HIGH USAGE ALERT
              // =====================================================
              // A recorded limit breach is a fact and takes precedence.
              // The percentage-based nudge is only a hint, so it fills in
              // when there's nothing harder to report.
              if (_openAlerts.isNotEmpty)
                _alertBanner(
                  title: _openAlerts.length == 1
                      ? "${_openAlerts.first.deviceName} · ${_openAlerts.first.headline}"
                      : "${_openAlerts.length} alerts need a look",
                  body: _openAlerts.length == 1
                      ? _openAlerts.first.detail
                      : "${_openAlerts.first.deviceName} and ${_openAlerts.length - 1} other"
                          "${_openAlerts.length == 2 ? '' : 's'} went over their limits.",
                )
              else if (alertDevice != null)
                _alertBanner(
                  title: "High Usage Alert",
                  body: "${alertDevice.name} is using ${alertPct.toStringAsFixed(0)}% "
                      "more than its recent average today.",
                ),

              const SizedBox(height: 20),
            ],
          ),
        ),
      ),

      // ===========================================================
      // 7. BOTTOM NAVIGATION
      // ===========================================================
      bottomNavigationBar: Container(
        height: 65,
        decoration: const BoxDecoration(color: Colors.white),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _navItem(icon: Icons.home, label: "Home", selected: true, onTap: () {}),
            _navItem(
              icon: Icons.devices_other,
              label: "Appliances",
              selected: false,
              onTap: () => Navigator.pushReplacementNamed(context, '/appliances'),
            ),
            if (session.canViewReports)
              _navItem(
                icon: Icons.bar_chart,
                label: "Report",
                selected: false,
                onTap: () => Navigator.pushReplacementNamed(context, '/report'),
              ),
            _navItem(
              icon: Icons.calendar_today,
              label: "Schedule",
              selected: false,
              onTap: () => Navigator.pushReplacementNamed(context, '/schedule'),
            ),
          ],
        ),
      ),
    );
  }

  /// Tapping anywhere on it opens the full list — the banner is the
  /// only entry point to Alerts, which keeps another icon out of an
  /// already busy header.
  Widget _alertBanner({required String title, required String body}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => Navigator.pushNamed(context, '/alerts'),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFFFFBEB),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFFDE68A)),
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration:
                    BoxDecoration(color: const Color(0xFFFEF3C7), borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.warning_amber_rounded, size: 19, color: Color(0xFFF59E0B)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF92400E),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      body,
                      style: const TextStyle(fontSize: 10, color: Color(0xFF78350F), height: 1.4),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, size: 18, color: Color(0xFFB45309)),
            ],
          ),
        ),
      ),
    );
  }

  static String _weekdayLabel(int weekday) {
    const labels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
    return labels[weekday - 1];
  }

  // ===============================================================
  // STAT TILE
  // ===============================================================
  static Widget _statTile(String label, String value) {
    return Container(
      height: 55,
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label, style: const TextStyle(fontSize: 8, color: Color(0xFF94A3B8))),
          const SizedBox(height: 3),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF0F766E)),
            ),
          ),
        ],
      ),
    );
  }

  // ===============================================================
  // QUICK CONTROL CARD (tap to toggle relay)
  // ===============================================================
  Widget _quickControlCard(MapEntry<String, _HomeDevice> entry) {
    final id = entry.key;
    final device = entry.value;
    final bg = _typeBg[device.type] ?? const Color(0xFFE8F8F5);
    final fg = _typeFg[device.type] ?? const Color(0xFF0F766E);

    return GestureDetector(
      onTap: () => _toggleRelay(id, device.isOn),
      child: Container(
        width: 110,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(9)),
              child: Icon(_typeIcons[device.type] ?? Icons.power, size: 17, color: fg),
            ),
            const Spacer(),
            Text(
              device.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF1F2937)),
            ),
            const SizedBox(height: 2),
            Text(
              device.room,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 8, color: Color(0xFF94A3B8)),
            ),
            const Spacer(),
            Text(
              device.isOn ? "ON" : "OFF",
              style: TextStyle(
                fontSize: 8,
                fontWeight: device.isOn ? FontWeight.bold : FontWeight.normal,
                color: device.isOn ? const Color(0xFF0F766E) : const Color(0xFF94A3B8),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ===============================================================
  // BOTTOM NAV ITEM
  // ===============================================================
  static Widget _navItem({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final color = selected ? const Color(0xFF0F766E) : const Color(0xFF94A3B8);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 21, color: color),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(fontSize: 9, fontWeight: selected ? FontWeight.bold : FontWeight.normal, color: color),
            ),
          ],
        ),
      ),
    );
  }

  // ===============================================================
  // WEEKLY TREND BAR
  // ===============================================================
  static Widget _bar(String day, double height, bool selected) {
    return Expanded(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Container(
            width: 14,
            height: height,
            decoration: BoxDecoration(
              color: selected ? const Color(0xFF0F766E) : const Color(0xFF99F6E4),
              borderRadius: BorderRadius.circular(5),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            day,
            style: TextStyle(
              fontSize: 8,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              color: selected ? const Color(0xFF0F766E) : const Color(0xFF94A3B8),
            ),
          ),
        ],
      ),
    );
  }
}
