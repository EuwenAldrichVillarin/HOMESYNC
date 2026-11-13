import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import 'household.dart';
import 'activity.dart';
import 'members.dart';
import 'app_nav_bar.dart';

// =====================================================================
// SCHEDULES
//
// A schedule is its own thing: a name, a time window, a set of days, and
// the appliances it drives. Appliances no longer carry an implicit
// schedule of their own — you create a schedule and pick what it runs.
//
// HOW THIS REACHES THE HARDWARE
// The ESP32 reads one object at devices/{id}/schedule and acts on its
// two edges (see checkSchedule() in the firmware). That contract hasn't
// changed, so nothing needs re-flashing: saving a schedule mirrors its
// window down onto each appliance it covers, and removing an appliance
// from a schedule clears that appliance's copy.
//
// The firmware's one-object-per-device shape is also why an appliance
// belongs to at most one schedule. Assigning an appliance that's already
// in another schedule moves it, rather than silently letting two windows
// fight over the same plug.
// =====================================================================

const List<String> _kDayKeys = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];
const List<String> _kDayLabels = ["M", "T", "W", "T", "F", "S", "S"];

const Color _kTeal = Color(0xFF0F766E);
const Color _kInk = Color(0xFF1E293B);
const Color _kMuted = Color(0xFF64748B);
const Color _kFaint = Color(0xFF94A3B8);
const Color _kLine = Color(0xFFE2E8F0);

String _fmtMinutes(int minutes) {
  final h24 = minutes ~/ 60;
  final m = minutes % 60;
  final suffix = h24 < 12 ? "AM" : "PM";
  var h12 = h24 % 12;
  if (h12 == 0) h12 = 12;
  return "${h12.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')} $suffix";
}

// ---------------------------------------------------------------------
// MODEL
// ---------------------------------------------------------------------
class HomeSchedule {
  final String id;
  final String name;
  final bool enabled;
  final int startMinutes;
  final int endMinutes;
  final Map<String, bool> days;
  final Set<String> deviceIds;

  const HomeSchedule({
    required this.id,
    required this.name,
    required this.enabled,
    required this.startMinutes,
    required this.endMinutes,
    required this.days,
    required this.deviceIds,
  });

  factory HomeSchedule.blank() => HomeSchedule(
        id: '',
        name: '',
        enabled: true,
        startMinutes: 18 * 60,
        endMinutes: 22 * 60,
        days: {for (final k in _kDayKeys) k: true},
        deviceIds: const {},
      );

  factory HomeSchedule.fromMap(String id, Map<dynamic, dynamic> raw) {
    final daysRaw = raw['days'] is Map ? Map<String, dynamic>.from(raw['days']) : <String, dynamic>{};
    final devicesRaw = raw['devices'] is Map ? Map<String, dynamic>.from(raw['devices']) : <String, dynamic>{};
    final start = raw['startMinutes'];
    final end = raw['endMinutes'];

    return HomeSchedule(
      id: id,
      name: (raw['name'] is String && (raw['name'] as String).trim().isNotEmpty)
          ? (raw['name'] as String).trim()
          : 'Schedule',
      enabled: raw['enabled'] == true,
      startMinutes: start is num ? start.toInt() : 0,
      endMinutes: end is num ? end.toInt() : 0,
      days: {for (final k in _kDayKeys) k: daysRaw[k] == true},
      deviceIds: devicesRaw.entries.where((e) => e.value == true).map((e) => e.key.toString()).toSet(),
    );
  }

  HomeSchedule copyWith({
    String? id,
    String? name,
    bool? enabled,
    int? startMinutes,
    int? endMinutes,
    Map<String, bool>? days,
    Set<String>? deviceIds,
  }) {
    return HomeSchedule(
      id: id ?? this.id,
      name: name ?? this.name,
      enabled: enabled ?? this.enabled,
      startMinutes: startMinutes ?? this.startMinutes,
      endMinutes: endMinutes ?? this.endMinutes,
      days: days ?? this.days,
      deviceIds: deviceIds ?? this.deviceIds,
    );
  }

  /// The schedule as stored under the household's own node.
  Map<String, Object?> toMap() => {
        'name': name,
        'enabled': enabled,
        'startMinutes': startMinutes,
        'endMinutes': endMinutes,
        'days': days,
        'devices': {for (final id in deviceIds) id: true},
      };

  /// The slice the ESP32 actually reads, mirrored onto every appliance
  /// this schedule covers. Deliberately the same shape the firmware has
  /// always expected.
  Map<String, Object?> toDevicePayload() => {
        'enabled': enabled,
        'startMinutes': startMinutes,
        'endMinutes': endMinutes,
        'days': days,
      };

  bool dayOn(String key) => days[key] ?? false;

  String get timeLabel => "${_fmtMinutes(startMinutes)}–${_fmtMinutes(endMinutes)}";

  String get daysLabel {
    final on = _kDayKeys.where(dayOn).toList();
    if (on.length == 7) return "Every day";
    if (on.isEmpty) return "No days selected";
    if (on.length == 5 && !dayOn('sat') && !dayOn('sun')) return "Weekdays";
    if (on.length == 2 && dayOn('sat') && dayOn('sun')) return "Weekends";
    const short = {
      'mon': 'Mon',
      'tue': 'Tue',
      'wed': 'Wed',
      'thu': 'Thu',
      'fri': 'Fri',
      'sat': 'Sat',
      'sun': 'Sun',
    };
    return on.map((k) => short[k]).join(", ");
  }
}

/// Name and room of one appliance, for the picker and the cards.
class ApplianceInfo {
  final String name;
  final String room;
  const ApplianceInfo(this.name, this.room);
}

// ---------------------------------------------------------------------
// SCHEDULE LIST PAGE
// ---------------------------------------------------------------------
class SchedulePage extends StatefulWidget {
  const SchedulePage({super.key});

  @override
  State<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends State<SchedulePage> {
  HouseholdSession? _session;

  StreamSubscription<DatabaseEvent>? _schedulesSub;
  StreamSubscription<DatabaseEvent>? _appliancesSub;
  final Map<String, StreamSubscription<DatabaseEvent>> _infoSubs = {};

  final Map<String, HomeSchedule> _schedules = {};
  final Map<String, ApplianceInfo> _appliances = {};

  bool _loaded = false;
  bool _busy = false;
  bool _legacyResetChecked = false;

  bool get _canEdit => _session?.canEditSchedules ?? false;
  String? get _householdUid => _session?.householdUid;

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
      _listenToSchedules(session.householdUid);
      _listenToAppliances(session.householdUid);
    }).catchError((Object _) {
      if (mounted) setState(() => _loaded = true);
    });
  }

  void _listenToSchedules(String householdUid) {
    final ref = FirebaseDatabase.instance.ref('users/$householdUid/schedules');
    _schedulesSub = ref.onValue.listen((event) {
      final raw = event.snapshot.value;
      final next = <String, HomeSchedule>{};
      if (raw is Map) {
        raw.forEach((key, value) {
          if (value is Map) {
            next[key.toString()] = HomeSchedule.fromMap(key.toString(), value);
          }
        });
      }
      if (!mounted) return;
      setState(() {
        _schedules
          ..clear()
          ..addAll(next);
        _loaded = true;
      });
    }, onError: (Object _) {
      if (mounted) setState(() => _loaded = true);
    });
  }

  void _listenToAppliances(String householdUid) {
    final ref = FirebaseDatabase.instance.ref('users/$householdUid/appliances');
    _appliancesSub = ref.onValue.listen((event) {
      final raw = event.snapshot.value;
      final ids = <String>{};
      if (raw is Map) ids.addAll(raw.keys.map((k) => k.toString()));

      for (final id in _infoSubs.keys.toList()) {
        if (!ids.contains(id)) {
          _infoSubs.remove(id)?.cancel();
          setState(() => _appliances.remove(id));
        }
      }

      _resetLegacySchedulesOnce(householdUid, ids);

      for (final id in ids) {
        if (_infoSubs.containsKey(id)) continue;
        _infoSubs[id] = FirebaseDatabase.instance.ref('devices/$id/info').onValue.listen((infoEvent) {
          final info = infoEvent.snapshot.value;
          final map = info is Map ? Map<String, dynamic>.from(info) : <String, dynamic>{};
          if (!mounted) return;
          setState(() {
            _appliances[id] = ApplianceInfo(
              (map['name'] as String?) ?? 'Unnamed',
              (map['room'] as String?) ?? '',
            );
          });
        });
      }
    });
  }

  /// Clears the per-appliance schedules left over from the old model,
  /// once, the first time an admin opens this page.
  ///
  /// Without this they'd keep firing on the hardware forever with nothing
  /// in the app describing them — the appliance would switch itself on
  /// and there'd be no schedule anywhere to explain why.
  ///
  /// Admin-only because the marker lives on the admin's own node, which
  /// is the only place a member can't write.
  Future<void> _resetLegacySchedulesOnce(String householdUid, Set<String> deviceIds) async {
    if (_legacyResetChecked) return;
    final session = _session;
    if (session == null || !session.isAdmin) return;
    _legacyResetChecked = true;

    try {
      final marker = await FirebaseDatabase.instance.ref('users/$householdUid/schedulesReset').get();
      if (marker.exists) return;

      final updates = <String, Object?>{
        'users/$householdUid/schedulesReset': ServerValue.timestamp,
      };
      for (final id in deviceIds) {
        updates['devices/$id/schedule'] = null;
      }
      await FirebaseDatabase.instance.ref().update(updates);
    } catch (_) {
      // Non-fatal: worst case it's retried next time the page opens.
      _legacyResetChecked = false;
    }
  }

  @override
  void dispose() {
    _schedulesSub?.cancel();
    _appliancesSub?.cancel();
    for (final sub in _infoSubs.values) {
      sub.cancel();
    }
    super.dispose();
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  bool _blockIfReadOnly() {
    if (_canEdit) return false;
    _notify("You don't have permission to change schedules");
    return true;
  }

  // ==================================================================
  // WRITES
  //
  // Every write touches two places in one update: the schedule itself,
  // and the mirrored copy on each appliance the firmware reads. Doing it
  // as a single multi-path update means an appliance can't be left
  // running a window that no schedule in the app still describes.
  // ==================================================================

  /// Appliance -> the schedule that currently owns it.
  Map<String, HomeSchedule> get _ownerByDevice {
    final map = <String, HomeSchedule>{};
    for (final schedule in _schedules.values) {
      for (final deviceId in schedule.deviceIds) {
        map[deviceId] = schedule;
      }
    }
    return map;
  }

  Future<void> _saveSchedule(
    HomeSchedule schedule, {
    HomeSchedule? previous,
    // Set by the on/off switch, which is a different event to a person
    // opening the editor and changing the schedule's times.
    String? logAction,
  }) async {
    final householdUid = _householdUid;
    if (householdUid == null) return;

    setState(() => _busy = true);
    try {
      final db = FirebaseDatabase.instance.ref();
      final id = schedule.id.isEmpty
          ? (db.child('users/$householdUid/schedules').push().key ?? '')
          : schedule.id;
      if (id.isEmpty) throw Exception("Couldn't allocate a schedule id");

      final saved = schedule.copyWith(id: id);
      final updates = <String, Object?>{
        'users/$householdUid/schedules/$id': saved.toMap(),
      };

      // Appliances this schedule no longer covers lose their mirrored
      // window, otherwise the plug would keep firing on it forever.
      final dropped = (previous?.deviceIds ?? const <String>{}).difference(saved.deviceIds);
      for (final deviceId in dropped) {
        updates['devices/$deviceId/schedule'] = null;
      }

      // An appliance can only carry one window, so taking one from
      // another schedule has to remove it there too.
      final owners = _ownerByDevice;
      for (final deviceId in saved.deviceIds) {
        final owner = owners[deviceId];
        if (owner != null && owner.id != id) {
          final remaining = owner.deviceIds.where((d) => d != deviceId).toList();
          updates['users/$householdUid/schedules/${owner.id}/devices'] = {
            for (final d in remaining) d: true,
          };
        }
      }

      for (final deviceId in saved.deviceIds) {
        updates['devices/$deviceId/schedule'] = saved.toDevicePayload();
      }

      await db.update(updates);

      logActivity(
        action: logAction ??
            (schedule.id.isEmpty ? ActivityAction.scheduleCreated : ActivityAction.scheduleUpdated),
        target: saved.name,
      );

      _notify(schedule.id.isEmpty ? "Schedule created" : "Schedule updated");
    } catch (e) {
      _notify("Couldn't save the schedule: $e");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteSchedule(HomeSchedule schedule) async {
    final householdUid = _householdUid;
    if (householdUid == null) return;
    if (_blockIfReadOnly()) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          "Delete schedule?",
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _kInk),
        ),
        content: Text(
          "\"${schedule.name}\" will be deleted and its appliances will stop switching "
          "on this timetable. They keep whatever state they're in right now.",
          style: const TextStyle(fontSize: 13, color: _kMuted, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text("Cancel", style: TextStyle(color: _kMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text("Delete"),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    try {
      final updates = <String, Object?>{
        'users/$householdUid/schedules/${schedule.id}': null,
      };
      for (final deviceId in schedule.deviceIds) {
        updates['devices/$deviceId/schedule'] = null;
      }
      await FirebaseDatabase.instance.ref().update(updates);
      logActivity(action: ActivityAction.scheduleDeleted, target: schedule.name);
      _notify("Schedule deleted");
    } catch (e) {
      _notify("Couldn't delete the schedule: $e");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleEnabled(HomeSchedule schedule) async {
    if (_blockIfReadOnly()) return;
    await _saveSchedule(
      schedule.copyWith(enabled: !schedule.enabled),
      previous: schedule,
      logAction: schedule.enabled ? ActivityAction.scheduleDisabled : ActivityAction.scheduleEnabled,
    );
  }

  Future<void> _openEditor({HomeSchedule? existing}) async {
    if (_blockIfReadOnly()) return;

    if (_appliances.isEmpty && existing == null) {
      _notify("Add an appliance first — a schedule needs something to switch");
      return;
    }

    final result = await Navigator.push<HomeSchedule>(
      context,
      MaterialPageRoute(
        builder: (_) => ScheduleEditorPage(
          initial: existing ?? HomeSchedule.blank(),
          appliances: Map.of(_appliances),
          ownerByDevice: {
            for (final entry in _ownerByDevice.entries)
              if (entry.value.id != existing?.id) entry.key: entry.value.name,
          },
          isNew: existing == null,
        ),
      ),
    );

    if (result != null) {
      await _saveSchedule(result, previous: existing);
    }
  }

  // ==================================================================
  // BUILD
  // ==================================================================
  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    if (uid == null) {
      return const Scaffold(
        backgroundColor: Color(0xFFF8FAFC),
        body: SafeArea(child: Center(child: Text("Not signed in"))),
      );
    }

    final session = _session;
    if (session == null) {
      return const Scaffold(
        backgroundColor: Color(0xFFF8FAFC),
        body: SafeArea(child: Center(child: CircularProgressIndicator())),
      );
    }
    if (session.isRevoked) {
      return const RevokedAccessScreen();
    }

    final schedules = _schedules.values.toList()
      ..sort((a, b) {
        final byTime = a.startMinutes.compareTo(b.startMinutes);
        return byTime != 0 ? byTime : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      floatingActionButton: _canEdit
          ? FloatingActionButton.extended(
              onPressed: _busy ? null : () => _openEditor(),
              backgroundColor: _kTeal,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add, size: 20),
              label: const Text(
                "New Schedule",
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
              ),
            )
          : null,
      // The nav row belongs in bottomNavigationBar, not inside the body:
      // a Scaffold floats its button above bottomNavigationBar, but over
      // anything that's merely the last child of the body. This is also
      // how Home, Appliances and Report are laid out.
      body: SafeArea(
        child: !_loaded
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                // Bottom padding clears the floating button so it can't
                // sit on top of the last schedule card.
                padding: const EdgeInsets.fromLTRB(16, 22, 16, 96),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Schedules",
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: _kInk),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _canEdit
                          ? "Create a schedule, choose which appliances it switches, and it runs itself."
                          : "These are the household's schedules. Your admin hasn't given you permission to change them.",
                      style: const TextStyle(fontSize: 11, color: _kMuted),
                    ),
                    const SizedBox(height: 18),
                    if (schedules.isEmpty)
                      _emptyState(session)
                    else
                      for (int i = 0; i < schedules.length; i++) ...[
                        if (i > 0) const SizedBox(height: 13),
                        _scheduleCard(schedules[i]),
                      ],
                  ],
                ),
              ),
      ),

      // =================================================
      // BOTTOM NAVIGATION
      // =================================================
      bottomNavigationBar: AppNavBar(current: AppTab.schedule, showReports: session.canViewReports),
    );
  }

  Widget _emptyState(HouseholdSession session) {
    final noAppliances = _appliances.isEmpty;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 46),
      alignment: Alignment.center,
      child: Column(
        children: [
          const Icon(Icons.access_time, size: 42, color: Color(0xFFCBD5E1)),
          const SizedBox(height: 12),
          Text(
            noAppliances ? "No appliances yet" : "No schedules yet",
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF1F2937)),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              noAppliances
                  ? (session.canManageAppliances
                      ? "Add an appliance first, then you can schedule it."
                      : "Once your admin registers an appliance, you can schedule it here.")
                  : (_canEdit
                      ? "Create one and pick the appliances it should switch on and off."
                      : "Your admin hasn't set up any schedules yet."),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: _kFaint, height: 1.45),
            ),
          ),
          if (noAppliances && session.canManageAppliances) ...[
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => Navigator.pushReplacementNamed(context, '/appliances'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _kTeal,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              ),
              child: const Text("Add Appliance"),
            ),
          ],
        ],
      ),
    );
  }

  // ==================================================================
  // SCHEDULE CARD
  // ==================================================================
  Widget _scheduleCard(HomeSchedule schedule) {
    final names = schedule.deviceIds
        .map((id) => _appliances[id]?.name)
        .whereType<String>()
        .toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: _kLine),
        boxShadow: const [BoxShadow(color: Color(0x08000000), blurRadius: 4, offset: Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // TITLE + SWITCH + MENU
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      schedule.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: schedule.enabled ? _kInk : _kFaint,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      schedule.timeLabel,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: schedule.enabled ? _kTeal : _kFaint,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: schedule.enabled,
                onChanged: _busy ? null : (_) => _toggleEnabled(schedule),
                activeThumbColor: Colors.white,
                activeTrackColor: _kTeal,
              ),
              if (_canEdit)
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, size: 19, color: _kFaint),
                  color: Colors.white,
                  onSelected: (value) {
                    if (value == 'edit') _openEditor(existing: schedule);
                    if (value == 'delete') _deleteSchedule(schedule);
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'edit',
                      child: Text("Edit schedule", style: TextStyle(fontSize: 13, color: _kInk)),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text("Delete schedule", style: TextStyle(fontSize: 13, color: Color(0xFFDC2626))),
                    ),
                  ],
                ),
            ],
          ),

          const SizedBox(height: 10),

          // DAYS
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Row(
              children: [
                for (int i = 0; i < _kDayKeys.length; i++) ...[
                  if (i > 0) const SizedBox(width: 6),
                  _dayDot(_kDayLabels[i], schedule.dayOn(_kDayKeys[i]) && schedule.enabled),
                ],
                const Spacer(),
                Text(
                  schedule.daysLabel,
                  style: const TextStyle(fontSize: 10, color: _kFaint),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),
          const Divider(height: 1, color: Color(0xFFF1F5F9)),
          const SizedBox(height: 10),

          // APPLIANCES
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.power, size: 14, color: _kFaint),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  names.isEmpty ? "No appliances — this schedule won't do anything" : names.join(", "),
                  style: TextStyle(
                    fontSize: 11,
                    color: names.isEmpty ? const Color(0xFFDC2626) : _kMuted,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static Widget _dayDot(String label, bool on) {
    return Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: on ? _kTeal : const Color(0xFFF1F5F9),
        shape: BoxShape.circle,
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: on ? Colors.white : _kFaint,
        ),
      ),
    );
  }
}

// =====================================================================
// SCHEDULE EDITOR
// =====================================================================
class ScheduleEditorPage extends StatefulWidget {
  final HomeSchedule initial;
  final Map<String, ApplianceInfo> appliances;

  /// Appliances already driven by a *different* schedule, mapped to that
  /// schedule's name — so the picker can say so before they're moved.
  final Map<String, String> ownerByDevice;

  final bool isNew;

  const ScheduleEditorPage({
    super.key,
    required this.initial,
    required this.appliances,
    required this.ownerByDevice,
    required this.isNew,
  });

  @override
  State<ScheduleEditorPage> createState() => _ScheduleEditorPageState();
}

class _ScheduleEditorPageState extends State<ScheduleEditorPage> {
  late final TextEditingController _nameController = TextEditingController(text: widget.initial.name);
  late int _start = widget.initial.startMinutes;
  late int _end = widget.initial.endMinutes;
  late Map<String, bool> _days = Map.of(widget.initial.days);
  late final Set<String> _selected = Set.of(widget.initial.deviceIds);

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pickTime({required bool isStart}) async {
    final current = isStart ? _start : _end;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current ~/ 60, minute: current % 60),
      helpText: isStart ? "TURNS ON AT" : "TURNS OFF AT",
    );
    if (picked == null) return;
    setState(() {
      final minutes = picked.hour * 60 + picked.minute;
      if (isStart) {
        _start = minutes;
      } else {
        _end = minutes;
      }
    });
  }

  void _save() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      _notify("Give the schedule a name");
      return;
    }
    if (!_days.values.any((v) => v)) {
      _notify("Pick at least one day, or it will never run");
      return;
    }
    if (_end <= _start) {
      // The firmware only handles same-day windows — see checkSchedule().
      _notify("The off time must be after the on time (overnight schedules aren't supported)");
      return;
    }

    Navigator.pop(
      context,
      widget.initial.copyWith(
        name: name,
        startMinutes: _start,
        endMinutes: _end,
        days: _days,
        deviceIds: _selected,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ids = widget.appliances.keys.toList()
      ..sort((a, b) {
        final an = widget.appliances[a]!.name.toLowerCase();
        final bn = widget.appliances[b]!.name.toLowerCase();
        return an.compareTo(bn);
      });

    final moving = _selected.where(widget.ownerByDevice.containsKey).toList();

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: SafeArea(
        child: Column(
          children: [
            // HEADER
            Container(
              width: double.infinity,
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(8, 10, 20, 14),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back, color: Color(0xFF1F2937)),
                  ),
                  Text(
                    widget.isNew ? "New Schedule" : "Edit Schedule",
                    style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: Color(0xFF1F2937)),
                  ),
                ],
              ),
            ),

            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _label("Schedule name"),
                    TextField(
                      controller: _nameController,
                      textCapitalization: TextCapitalization.sentences,
                      maxLength: 40,
                      decoration: _fieldDecoration("e.g. Evening lights"),
                    ),

                    const SizedBox(height: 10),
                    _label("When"),
                    Row(
                      children: [
                        Expanded(
                          child: _timeCard(
                            caption: "Turns on",
                            value: _fmtMinutes(_start),
                            icon: Icons.wb_sunny_outlined,
                            onTap: () => _pickTime(isStart: true),
                          ),
                        ),
                        const SizedBox(width: 11),
                        Expanded(
                          child: _timeCard(
                            caption: "Turns off",
                            value: _fmtMinutes(_end),
                            icon: Icons.nightlight_outlined,
                            onTap: () => _pickTime(isStart: false),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 22),
                    _label("Repeat on"),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        for (int i = 0; i < _kDayKeys.length; i++)
                          _dayToggle(_kDayLabels[i], _kDayKeys[i]),
                      ],
                    ),

                    const SizedBox(height: 22),
                    _label("Appliances"),
                    if (widget.appliances.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          "No appliances registered yet.",
                          style: TextStyle(fontSize: 12, color: _kFaint),
                        ),
                      )
                    else
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: _kLine),
                        ),
                        child: Column(
                          children: [
                            for (int i = 0; i < ids.length; i++) ...[
                              if (i > 0) const Divider(height: 1, color: Color(0xFFF1F5F9)),
                              _applianceRow(ids[i]),
                            ],
                          ],
                        ),
                      ),

                    // An appliance carries one window, so saving takes it
                    // away from whatever schedule has it now. Say so here
                    // rather than surprising them after the fact.
                    if (moving.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFFBEB),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFFDE68A)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.swap_horiz, size: 16, color: Color(0xFFB45309)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                moving
                                    .map((id) =>
                                        "${widget.appliances[id]?.name ?? id} will move here from \"${widget.ownerByDevice[id]}\"")
                                    .join("\n"),
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF92400E),
                                  height: 1.45,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: 26),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        onPressed: _save,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _kTeal,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: Text(
                          widget.isNew ? "Create Schedule" : "Save Changes",
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _applianceRow(String id) {
    final info = widget.appliances[id]!;
    final checked = _selected.contains(id);
    final owner = widget.ownerByDevice[id];

    return InkWell(
      onTap: () => setState(() {
        if (checked) {
          _selected.remove(id);
        } else {
          _selected.add(id);
        }
      }),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: Row(
          children: [
            Icon(
              checked ? Icons.check_box : Icons.check_box_outline_blank,
              size: 21,
              color: checked ? _kTeal : const Color(0xFFCBD5E1),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    info.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF1F2937)),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    owner != null
                        ? "${info.room.isEmpty ? 'No room' : info.room} · in \"$owner\""
                        : (info.room.isEmpty ? "No room" : info.room),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      color: owner != null ? const Color(0xFFB45309) : _kFaint,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dayToggle(String label, String key) {
    final on = _days[key] ?? false;
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: () => setState(() => _days = {..._days, key: !on}),
      child: Container(
        width: 38,
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? _kTeal : Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: on ? _kTeal : _kLine),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: on ? Colors.white : _kFaint,
          ),
        ),
      ),
    );
  }

  static Widget _timeCard({
    required String caption,
    required String value,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _kLine),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 13, color: _kFaint),
                const SizedBox(width: 5),
                Text(caption, style: const TextStyle(fontSize: 10, color: _kFaint)),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              value,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: _kTeal),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _label(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF1F2937)),
      ),
    );
  }

  static InputDecoration _fieldDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(fontSize: 13, color: _kFaint),
      counterText: "",
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _kLine),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _kLine),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _kTeal),
      ),
    );
  }
}
