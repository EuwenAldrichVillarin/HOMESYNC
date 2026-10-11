import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import 'household.dart';
import 'members.dart';
import 'profile.dart';

// =====================================================================
// CONTROL LOG
//
// Who told what to do what, and when. In a shared household "why did the
// aircon come on at 2am" needs an answer, and with several accounts able
// to switch the same plug, the app is the only place that knows.
//
// WHERE IT LIVES, AND WHY NOT UNDER users/{uid}
// Entries go to activity/{householdUid}/{entryId}, at the top level, on
// purpose. Under users/{uid} the admin's blanket ".write" would cascade
// down and let them rewrite history silently. Kept separate, the rules
// can say exactly what's allowed: anyone in the household may append,
// nobody may modify an existing entry, and an entry can't claim an
// actorUid other than the caller's own. The admin can delete entries
// (it's their household, and the log has to be prunable) — but they
// can't quietly alter one.
//
// WHAT IT CANNOT SEE
// The ESP32 switches the relay itself at a schedule's edges. Those
// flips never pass through the app, so they aren't attributable to a
// person and don't appear here. What does appear is the human decision
// behind them: who created, changed or switched off the schedule.
// =====================================================================

class ActivityAction {
  static const deviceOn = 'device_on';
  static const deviceOff = 'device_off';
  static const roomOn = 'room_on';
  static const roomOff = 'room_off';
  static const scheduleCreated = 'schedule_created';
  static const scheduleUpdated = 'schedule_updated';
  static const scheduleDeleted = 'schedule_deleted';
  static const scheduleEnabled = 'schedule_enabled';
  static const scheduleDisabled = 'schedule_disabled';
  static const applianceAdded = 'appliance_added';
  static const applianceUpdated = 'appliance_updated';
  static const applianceRemoved = 'appliance_removed';
  static const memberAdded = 'member_added';
  static const memberRemoved = 'member_removed';
  static const memberPermissions = 'member_permissions';
}

/// Records one action against the household's log.
///
/// Deliberately fire-and-forget, and deliberately NOT bundled into the
/// same write as the action it describes: a logging problem must never
/// be able to stop someone switching off an appliance. The cost of that
/// choice is that a failed log write loses the entry rather than failing
/// loudly, which is the right trade for a control app.
Future<void> logActivity({
  required String action,
  required String target,
  String? detail,
}) async {
  try {
    final session = HouseholdSession.current;
    final user = FirebaseAuth.instance.currentUser;
    if (session == null || user == null || session.isRevoked) return;

    // The actor's name is stored with the entry rather than looked up
    // later, so the log still reads correctly after someone renames
    // themselves — or is removed from the household entirely.
    final actorName = (user.displayName?.trim().isNotEmpty ?? false)
        ? user.displayName!.trim()
        : (user.email?.split('@').first ?? 'Someone');

    final ref = FirebaseDatabase.instance.ref('activity/${session.householdUid}').push();
    await ref.set({
      'at': ServerValue.timestamp,
      'actorUid': user.uid,
      'actorName': actorName,
      'action': action,
      'target': target,
      if (detail != null && detail.isNotEmpty) 'detail': detail,
    });
  } catch (_) {
    // Never surfaced: the action itself already succeeded, and an error
    // here would only confuse the person who performed it.
  }
}

// ---------------------------------------------------------------------
// MODEL
// ---------------------------------------------------------------------
class ActivityEntry {
  final String id;
  final DateTime at;
  final String actorUid;
  final String actorName;
  final String action;
  final String target;
  final String? detail;

  const ActivityEntry({
    required this.id,
    required this.at,
    required this.actorUid,
    required this.actorName,
    required this.action,
    required this.target,
    this.detail,
  });

  static ActivityEntry? fromMap(String id, Map<dynamic, dynamic> raw) {
    final at = raw['at'];
    if (at is! num) return null; // still resolving the server timestamp
    return ActivityEntry(
      id: id,
      at: DateTime.fromMillisecondsSinceEpoch(at.toInt()),
      actorUid: (raw['actorUid'] as String?) ?? '',
      actorName: (raw['actorName'] as String?)?.trim().isNotEmpty == true
          ? (raw['actorName'] as String).trim()
          : 'Someone',
      action: (raw['action'] as String?) ?? '',
      target: (raw['target'] as String?) ?? '',
      detail: raw['detail'] as String?,
    );
  }

  /// Reads as a sentence: `<actor>` turned on `<target>`.
  String get phrase => switch (action) {
        ActivityAction.deviceOn => "turned on",
        ActivityAction.deviceOff => "turned off",
        ActivityAction.roomOn => "turned on everything in",
        ActivityAction.roomOff => "turned off everything in",
        ActivityAction.scheduleCreated => "created the schedule",
        ActivityAction.scheduleUpdated => "changed the schedule",
        ActivityAction.scheduleDeleted => "deleted the schedule",
        ActivityAction.scheduleEnabled => "switched on the schedule",
        ActivityAction.scheduleDisabled => "switched off the schedule",
        ActivityAction.applianceAdded => "added the appliance",
        ActivityAction.applianceUpdated => "edited the appliance",
        ActivityAction.applianceRemoved => "removed the appliance",
        ActivityAction.memberAdded => "added the member",
        ActivityAction.memberRemoved => "removed the member",
        ActivityAction.memberPermissions => "changed access for",
        _ => "acted on",
      };

  IconData get icon => switch (action) {
        ActivityAction.deviceOn || ActivityAction.roomOn => Icons.power_settings_new,
        ActivityAction.deviceOff || ActivityAction.roomOff => Icons.power_off,
        ActivityAction.scheduleCreated ||
        ActivityAction.scheduleUpdated ||
        ActivityAction.scheduleEnabled ||
        ActivityAction.scheduleDisabled =>
          Icons.access_time,
        ActivityAction.scheduleDeleted => Icons.timer_off_outlined,
        ActivityAction.applianceAdded => Icons.add_circle_outline,
        ActivityAction.applianceUpdated => Icons.edit_outlined,
        ActivityAction.applianceRemoved => Icons.delete_outline,
        ActivityAction.memberAdded => Icons.person_add_alt,
        ActivityAction.memberRemoved => Icons.person_remove_alt_1,
        ActivityAction.memberPermissions => Icons.tune,
        _ => Icons.info_outline,
      };

  Color get tint => switch (action) {
        ActivityAction.deviceOn || ActivityAction.roomOn => const Color(0xFF0F766E),
        ActivityAction.deviceOff || ActivityAction.roomOff => const Color(0xFF64748B),
        ActivityAction.applianceRemoved ||
        ActivityAction.scheduleDeleted ||
        ActivityAction.memberRemoved =>
          const Color(0xFFDC2626),
        _ => const Color(0xFF0284C7),
      };
}

// ---------------------------------------------------------------------
// PAGE
// ---------------------------------------------------------------------
const Color _kTeal = Color(0xFF0F766E);
const Color _kInk = Color(0xFF1F2937);
const Color _kMuted = Color(0xFF64748B);
const Color _kFaint = Color(0xFF94A3B8);
const Color _kLine = Color(0xFFE2E8F0);

/// Newest entries kept on screen. The log is append-only, so without a
/// bound an old household would pull its entire history on every open.
const int _kMaxEntries = 250;

class ActivityLogPage extends StatefulWidget {
  const ActivityLogPage({super.key});

  @override
  State<ActivityLogPage> createState() => _ActivityLogPageState();
}

class _ActivityLogPageState extends State<ActivityLogPage> {
  HouseholdSession? _session;
  StreamSubscription<DatabaseEvent>? _sub;
  List<ActivityEntry> _entries = [];
  bool _loaded = false;

  /// null = everyone; otherwise only this person's actions.
  String? _actorFilter;

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
    final query = FirebaseDatabase.instance
        .ref('activity/$householdUid')
        .orderByChild('at')
        .limitToLast(_kMaxEntries);

    _sub = query.onValue.listen((event) {
      final raw = event.snapshot.value;
      final list = <ActivityEntry>[];
      if (raw is Map) {
        raw.forEach((key, value) {
          if (value is Map) {
            final entry = ActivityEntry.fromMap(key.toString(), value);
            if (entry != null) list.add(entry);
          }
        });
      }
      list.sort((a, b) => b.at.compareTo(a.at)); // newest first
      if (!mounted) return;
      setState(() {
        _entries = list;
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

  // ------------------------------------------------------------------
  // DAY GROUPING
  // ------------------------------------------------------------------
  static String _dayLabel(DateTime when) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(when.year, when.month, when.day);
    final diff = today.difference(day).inDays;

    if (diff == 0) return "Today";
    if (diff == 1) return "Yesterday";

    const months = [
      "Jan", "Feb", "Mar", "Apr", "May", "Jun",
      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];
    final label = "${months[when.month - 1]} ${when.day}";
    return when.year == now.year ? label : "$label, ${when.year}";
  }

  static String _timeLabel(DateTime when) {
    final suffix = when.hour < 12 ? "AM" : "PM";
    var h = when.hour % 12;
    if (h == 0) h = 12;
    return "$h:${when.minute.toString().padLeft(2, '0')} $suffix";
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;

    if (session != null && session.isRevoked) {
      return const RevokedAccessScreen();
    }

    final visible = _actorFilter == null
        ? _entries
        : _entries.where((e) => e.actorUid == _actorFilter).toList();

    // Who appears in the log at all, for the filter chips.
    final actors = <String, String>{};
    for (final entry in _entries) {
      // Entries are newest-first, so the first name seen for someone is
      // the one they were using most recently.
      actors.putIfAbsent(entry.actorUid, () => entry.actorName);
    }

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
                    icon: const Icon(Icons.arrow_back, color: _kInk),
                  ),
                  const Expanded(
                    child: Text(
                      "Control Log",
                      style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: _kInk),
                    ),
                  ),
                ],
              ),
            ),

            // WHO FILTER
            if (actors.length > 1)
              Container(
                width: double.infinity,
                color: Colors.white,
                padding: const EdgeInsets.only(bottom: 12),
                child: SizedBox(
                  height: 32,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    children: [
                      _actorChip(null, "Everyone"),
                      for (final entry in actors.entries) ...[
                        const SizedBox(width: 8),
                        _actorChip(entry.key, entry.value),
                      ],
                    ],
                  ),
                ),
              ),

            Expanded(child: _body(visible)),
          ],
        ),
      ),
    );
  }

  Widget _actorChip(String? uid, String label) {
    final selected = _actorFilter == uid;
    return GestureDetector(
      onTap: () => setState(() => _actorFilter = uid),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? _kTeal : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: selected ? null : Border.all(color: _kLine),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : _kMuted,
          ),
        ),
      ),
    );
  }

  Widget _body(List<ActivityEntry> visible) {
    if (!_loaded) return const Center(child: CircularProgressIndicator());

    if (visible.isEmpty) {
      return const AccessNotice(
        icon: Icons.history,
        title: "Nothing logged yet",
        message: "Switching an appliance on or off, changing a schedule, or managing "
            "your household will show up here with who did it.",
      );
    }

    // Flatten into rows with a day header wherever the date changes.
    final rows = <Widget>[];
    String? lastDay;
    for (final entry in visible) {
      final day = _dayLabel(entry.at);
      if (day != lastDay) {
        rows.add(Padding(
          padding: EdgeInsets.only(top: lastDay == null ? 4 : 20, bottom: 10),
          child: Text(
            day,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _kFaint),
          ),
        ));
        lastDay = day;
      }
      rows.add(Padding(
        padding: const EdgeInsets.only(bottom: 9),
        child: _entryCard(entry),
      ));
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
    );
  }

  Widget _entryCard(ActivityEntry entry) {
    return Container(
      padding: const EdgeInsets.fromLTRB(13, 12, 13, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _kLine),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: entry.tint.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(entry.icon, size: 17, color: entry.tint),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RichText(
                  text: TextSpan(
                    style: const TextStyle(fontSize: 12.5, color: _kMuted, height: 1.4),
                    children: [
                      TextSpan(
                        text: entry.actorName,
                        style: const TextStyle(fontWeight: FontWeight.bold, color: _kInk),
                      ),
                      TextSpan(text: " ${entry.phrase} "),
                      TextSpan(
                        text: entry.target,
                        style: const TextStyle(fontWeight: FontWeight.w600, color: _kInk),
                      ),
                    ],
                  ),
                ),
                if (entry.detail != null && entry.detail!.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    entry.detail!,
                    style: const TextStyle(fontSize: 10.5, color: _kFaint),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  _timeLabel(entry.at),
                  style: const TextStyle(fontSize: 10, color: _kFaint),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          LiveProfileAvatar(
            uid: entry.actorUid,
            fallbackName: entry.actorName,
            size: 28,
          ),
        ],
      ),
    );
  }
}
