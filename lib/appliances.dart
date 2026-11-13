import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'add_appliance.dart';
import 'household.dart';
import 'activity.dart';
import 'members.dart';
import 'app_nav_bar.dart';

class AppliancesPage extends StatefulWidget {
  const AppliancesPage({super.key});

  @override
  State<AppliancesPage> createState() => _AppliancesPageState();
}

class _AppliancesPageState extends State<AppliancesPage> {
  String _selectedCategory = "All";

  HouseholdSession? _session;
  StreamSubscription<DatabaseEvent>? _appliancesSub;
  final Map<String, StreamSubscription<DatabaseEvent>> _deviceSubs = {};
  final Map<String, String> _deviceRooms = {}; // deviceId -> room
  final Map<String, bool> _deviceOn = {}; // deviceId -> confirmed relay state
  bool _loaded = false;

  /// The relay state a whole-room command is currently being written
  /// for, or null when idle. Doubles as the "busy" flag, so only the
  /// button that was actually pressed shows a spinner.
  bool? _bulkTarget;

  bool get _bulkBusy => _bulkTarget != null;

  @override
  void initState() {
    super.initState();
    HouseholdSession.ensureLoaded().then((session) {
      if (!mounted) return;
      setState(() => _session = session);
      if (session.isRevoked) return;
      // A member reads the admin's index, so every appliance the admin
      // has registered shows up here without being copied anywhere.
      _listenToAppliances(session.householdUid);
    }).catchError((Object _) {
      if (mounted) setState(() => _loaded = true);
    });
  }

  // Watches which devices the household owns, then each one's room and
  // relay state — the room drives the category tabs and the grid filter,
  // the relay state drives the "x of y on" count on the room controls.
  void _listenToAppliances(String householdUid) {
    final ref = FirebaseDatabase.instance.ref('users/$householdUid/appliances');
    _appliancesSub = ref.onValue.listen((event) {
      final raw = event.snapshot.value;
      final ids = <String>{};
      if (raw is Map) ids.addAll(raw.keys.map((k) => k.toString()));

      for (final id in _deviceSubs.keys.toList()) {
        if (!ids.contains(id)) {
          _deviceSubs.remove(id)?.cancel();
          setState(() {
            _deviceRooms.remove(id);
            _deviceOn.remove(id);
          });
        }
      }

      for (final id in ids) {
        if (_deviceSubs.containsKey(id)) continue;
        final devRef = FirebaseDatabase.instance.ref('devices/$id');
        _deviceSubs[id] = devRef.onValue.listen((deviceEvent) {
          final data = deviceEvent.snapshot.value;
          final map = data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
          final info = map['info'] is Map ? Map<String, dynamic>.from(map['info']) : <String, dynamic>{};
          final state = map['state'] is Map ? Map<String, dynamic>.from(map['state']) : <String, dynamic>{};
          final room = info['room'];
          setState(() {
            _deviceRooms[id] = room is String ? room : '';
            _deviceOn[id] = state['relay'] == true;
          });
        });
      }

      setState(() => _loaded = true);
    });
  }

  @override
  void dispose() {
    _appliancesSub?.cancel();
    for (final sub in _deviceSubs.values) {
      sub.cancel();
    }
    super.dispose();
  }

  // ==============================================================
  // WHOLE-ROOM CONTROL
  // ==============================================================

  /// The appliances currently shown under the selected room tab.
  List<String> get _selectedRoomDeviceIds {
    if (_selectedCategory == "All") return const [];
    final target = _selectedCategory.trim().toLowerCase();
    final ids = _deviceRooms.entries
        .where((e) => e.value.trim().toLowerCase() == target)
        .map((e) => e.key)
        .toList()
      ..sort();
    return ids;
  }

  int get _selectedRoomOnCount =>
      _selectedRoomDeviceIds.where((id) => _deviceOn[id] ?? false).length;

  /// Switches every appliance in the selected room at once. Only the
  /// devices that aren't already in the target state are written, so
  /// pressing "All On" twice doesn't re-command appliances needlessly.
  Future<void> _setRoomRelay(bool turnOn) async {
    final session = _session;
    if (session != null && !session.canControl) {
      _notify("You don't have permission to control appliances");
      return;
    }
    if (_bulkBusy) return;

    final room = _selectedCategory;
    final targets = _selectedRoomDeviceIds.where((id) => (_deviceOn[id] ?? false) != turnOn).toList();

    if (targets.isEmpty) {
      _notify("Everything in $room is already ${turnOn ? 'on' : 'off'}");
      return;
    }

    setState(() => _bulkTarget = turnOn);
    try {
      // One multi-path update rather than a write per appliance: the room
      // switches together, and a rejected device can't leave the rest
      // half-switched.
      await FirebaseDatabase.instance.ref().update({
        for (final id in targets) 'devices/$id/command/relay': turnOn,
      });
      final noun = targets.length == 1 ? "appliance" : "appliances";

      logActivity(
        action: turnOn ? ActivityAction.roomOn : ActivityAction.roomOff,
        target: room,
        detail: "${targets.length} $noun",
      );

      _notify("Turning ${turnOn ? 'on' : 'off'} ${targets.length} $noun in $room");
    } catch (e) {
      _notify("Couldn't switch $room: $e");
    } finally {
      if (mounted) setState(() => _bulkTarget = null);
    }
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // "All" plus every distinct, non-empty room currently in use, so a
  // newly added room (e.g. "Master Bedroom") shows up automatically.
  List<String> get _categories {
    final rooms = <String>{};
    for (final room in _deviceRooms.values) {
      final trimmed = room.trim();
      if (trimmed.isNotEmpty) rooms.add(trimmed);
    }
    final sorted = rooms.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return ["All", ...sorted];
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final session = _session;
    final categories = _categories;
    if (!categories.contains(_selectedCategory)) {
      _selectedCategory = "All";
    }

    if (session != null && session.isRevoked) {
      return const RevokedAccessScreen();
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),

      body: SafeArea(
        child: Column(
          children: [

            // =====================================================
            // HEADER
            // =====================================================
            Container(
              width: double.infinity,
              color: Colors.white,

              padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),

              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [

                  // TITLE
                  const Text(
                    "Appliances",
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1F2937),
                    ),
                  ),

                  // SEARCH + FILTER + ADD
                  Row(
                    children: [

                      const Icon(
                        Icons.search,
                        size: 23,
                        color: Color(0xFF1F2937),
                      ),

                      const SizedBox(width: 20),

                      const Icon(
                        Icons.tune,
                        size: 22,
                        color: Color(0xFF1F2937),
                      ),

                      // Claiming a device writes devices/{id}/ownerId, so
                      // only the admin gets this.
                      if (session?.canManageAppliances ?? false) ...[
                        const SizedBox(width: 16),
                        InkWell(
                          borderRadius: BorderRadius.circular(20),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) =>
                                    const AddAppliancePage(),
                              ),
                            );
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 7,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF0F766E),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Row(
                              children: [
                                Icon(Icons.add, size: 16, color: Colors.white),
                                SizedBox(width: 4),
                                Text(
                                  "Add",
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),

            // =====================================================
            // CATEGORY TABS
            // =====================================================
            Container(
              width: double.infinity,
              color: Colors.white,
              padding: const EdgeInsets.only(top: 2, bottom: 12),

              child: SizedBox(
                height: 40,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  itemCount: categories.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (context, i) {
                    final category = categories[i];
                    return _category(category, category == _selectedCategory);
                  },
                ),
              ),
            ),

            // =====================================================
            // WHOLE-ROOM ON/OFF — only meaningful once a specific room
            // is picked, and only for someone allowed to switch things.
            // =====================================================
            if (_selectedCategory != "All" &&
                (session?.canControl ?? false) &&
                _selectedRoomDeviceIds.isNotEmpty)
              _roomControls(),

            // =====================================================
            // APPLIANCE CARDS (live data)
            // =====================================================
            Expanded(
              child: uid == null
                  ? const Center(child: Text("Not signed in"))
                  : (!_loaded || session == null)
                      ? const Center(child: CircularProgressIndicator())
                      : _ApplianceGrid(
                          deviceRooms: _deviceRooms,
                          category: _selectedCategory,
                          canControl: session.canControl,
                          canManage: session.canManageAppliances,
                        ),
            ),
          ],
        ),
      ),

      // ===========================================================
      // BOTTOM NAVIGATION
      // ===========================================================
      bottomNavigationBar: AppNavBar(current: AppTab.appliances, showReports: session?.canViewReports ?? true),
    );
  }

  // =============================================================
  // WHOLE-ROOM CONTROL BAR
  // =============================================================
  Widget _roomControls() {
    final ids = _selectedRoomDeviceIds;
    final onCount = _selectedRoomOnCount;
    final allOn = onCount == ids.length;
    final allOff = onCount == 0;
    final noun = ids.length == 1 ? "appliance" : "appliances";

    return Container(
      width: double.infinity,
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _selectedCategory,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1F2937),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  "$onCount of ${ids.length} $noun on",
                  style: const TextStyle(fontSize: 10.5, color: Color(0xFF94A3B8)),
                ),
              ],
            ),
          ),
          _roomButton(
            label: "All Off",
            icon: Icons.power_settings_new,
            filled: false,
            // Nothing to do when the room is already off.
            enabled: !_bulkBusy && !allOff,
            busy: _bulkTarget == false,
            onTap: () => _setRoomRelay(false),
          ),
          const SizedBox(width: 8),
          _roomButton(
            label: "All On",
            icon: Icons.bolt,
            filled: true,
            enabled: !_bulkBusy && !allOn,
            busy: _bulkTarget == true,
            onTap: () => _setRoomRelay(true),
          ),
        ],
      ),
    );
  }

  Widget _roomButton({
    required String label,
    required IconData icon,
    required bool filled,
    required bool enabled,
    required bool busy,
    required VoidCallback onTap,
  }) {
    const teal = Color(0xFF0F766E);
    final foreground = filled ? Colors.white : teal;

    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: enabled ? onTap : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
          decoration: BoxDecoration(
            color: filled ? teal : Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: filled ? null : Border.all(color: const Color(0xFFE5E7EB)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy)
                SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(strokeWidth: 1.6, color: foreground),
                )
              else
                Icon(icon, size: 14, color: foreground),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.bold,
                  color: foreground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // =============================================================
  // CATEGORY PILL
  // =============================================================
  Widget _category(String text, bool selected) {
    return GestureDetector(
      onTap: () => setState(() => _selectedCategory = text),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF0F766E) : Colors.white,
          borderRadius: BorderRadius.circular(22),
          border: selected
              ? null
              : Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : const Color(0xFF6B7280),
          ),
        ),
      ),
    );
  }
}

// =====================================================================
// APPLIANCE GRID — filters the already-loaded deviceId->room map by the
// selected category (exact match, since categories are now generated
// directly from real room names). Each visible card independently
// listens to its own devices/{deviceId} node, so toggling one appliance
// doesn't rebuild the whole grid.
// =====================================================================
class _ApplianceGrid extends StatelessWidget {
  final Map<String, String> deviceRooms;
  final String category;

  /// From the signed-in user's household permissions: whether they may
  /// switch appliances, and whether they may add or rename them.
  final bool canControl;
  final bool canManage;

  const _ApplianceGrid({
    required this.deviceRooms,
    required this.category,
    required this.canControl,
    required this.canManage,
  });

  bool _matchesCategory(String room) {
    if (category == "All") return true;
    // Trimmed on both sides: the category pills are built from trimmed
    // room names, so an appliance saved as "Living Room " would otherwise
    // never match its own tab.
    return room.trim().toLowerCase() == category.trim().toLowerCase();
  }

  @override
  Widget build(BuildContext context) {
    if (deviceRooms.isEmpty) {
      // A member can't fix an empty house themselves, so don't offer them
      // a button that would only fail.
      if (!canManage) {
        return const AccessNotice(
          icon: Icons.power_off,
          title: "No appliances yet",
          message: "Your household admin hasn't registered any appliances. "
              "Once they do, they'll appear here automatically.",
        );
      }
      return _EmptyState(
        onAddPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const AddAppliancePage()),
          );
        },
      );
    }

    final deviceIds = deviceRooms.entries.where((e) => _matchesCategory(e.value)).map((e) => e.key).toList()
      ..sort();

    if (deviceIds.isEmpty) {
      return Center(
        child: Text(
          "No appliances in $category",
          style: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 100),
      child: GridView.count(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 0.92,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        children: deviceIds
            .map((deviceId) => _ApplianceCard(
                  // Without a per-device key, changing the category filter
                  // hands an existing card's State a different deviceId —
                  // and that State keeps streaming the device it first
                  // subscribed to, so the wrong appliance is drawn.
                  key: ValueKey(deviceId),
                  deviceId: deviceId,
                  canControl: canControl,
                  canManage: canManage,
                ))
            .toList(),
      ),
    );
  }
}

// =====================================================================
// EMPTY STATE
// =====================================================================
class _EmptyState extends StatelessWidget {
  final VoidCallback onAddPressed;

  const _EmptyState({required this.onAddPressed});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.power_off,
              size: 48,
              color: Color(0xFFCBD5E1),
            ),
            const SizedBox(height: 16),
            const Text(
              "No appliances yet",
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1F2937),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              "Add your first smart plug to start monitoring and "
              "controlling it here.",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: onAddPressed,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0F766E),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
              ),
              child: const Text(
                "Add Appliance",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =====================================================================
// APPLIANCE CARD — listens to its own devices/{deviceId} node for
// info, live power reading, and relay state. Tapping the switch writes
// a command that the ESP32 picks up and acts on.
//
// Toggling used to just fire-and-forget a write and rely on state/relay
// to catch up whenever it did. That gave no feedback while the command
// was in flight, so a slow/flaky WiFi round trip (or a genuinely offline
// device) looked exactly like "the button doesn't work" — worse, tapping
// again before the first command landed computed !currentlyOn from the
// same stale value both times, silently cancelling itself out. Now a tap
// locks the switch into a pending state immediately, ignores further taps
// until the device confirms the change (or 8s pass with no response, at
// which point it gives up and says so).
// =====================================================================
class _ApplianceCard extends StatefulWidget {
  final String deviceId;
  final bool canControl;
  final bool canManage;

  const _ApplianceCard({
    super.key,
    required this.deviceId,
    required this.canControl,
    required this.canManage,
  });

  @override
  State<_ApplianceCard> createState() => _ApplianceCardState();
}

class _ApplianceCardState extends State<_ApplianceCard> {
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

  StreamSubscription<DatabaseEvent>? _sub;
  Map<String, dynamic>? _data;

  bool? _pendingTarget; // relay state we're waiting for the device to confirm
  Timer? _pendingTimeout;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  // The cards are keyed by device id, so normally a card keeps its own
  // device for life. This is the backstop: if this State is ever handed a
  // different device, point the subscription at the new one instead of
  // quietly going on showing the old device's readings.
  @override
  void didUpdateWidget(_ApplianceCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.deviceId != widget.deviceId) {
      _sub?.cancel();
      _pendingTimeout?.cancel();
      _pendingTimeout = null;
      _pendingTarget = null;
      _data = null;
      _subscribe();
    }
  }

  void _subscribe() {
    final deviceId = widget.deviceId;
    _sub = FirebaseDatabase.instance.ref('devices/$deviceId').onValue.listen((event) {
      // A late event from a subscription we already replaced must not
      // overwrite the current device's data.
      if (!mounted || deviceId != widget.deviceId) return;

      final raw = event.snapshot.value;
      final data = raw is Map ? Map<String, dynamic>.from(raw) : null;
      final state = data?['state'] is Map ? Map<String, dynamic>.from(data!['state']) : <String, dynamic>{};
      final isOn = state['relay'] == true;

      setState(() {
        _data = data;
        if (_pendingTarget != null && isOn == _pendingTarget) {
          // Device confirmed the change we asked for.
          _pendingTimeout?.cancel();
          _pendingTimeout = null;
          _pendingTarget = null;
        }
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _pendingTimeout?.cancel();
    super.dispose();
  }

  void _toggleRelay(bool currentlyOn) {
    if (!widget.canControl) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("You don't have permission to control appliances")),
      );
      return;
    }
    if (_pendingTarget != null) return; // a previous tap is still in flight
    final target = !currentlyOn;

    setState(() => _pendingTarget = target);

    final info = _data?['info'];
    final name = (info is Map && info['name'] is String) ? info['name'] as String : 'an appliance';

    unawaited(
      FirebaseDatabase.instance.ref('devices/${widget.deviceId}/command/relay').set(target).then((_) {
        logActivity(
          action: target ? ActivityAction.deviceOn : ActivityAction.deviceOff,
          target: name,
        );
      }).catchError((Object e) {
        if (!mounted) return;
        _pendingTimeout?.cancel();
        setState(() => _pendingTarget = null);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Couldn't send command: $e")),
        );
      }),
    );

    _pendingTimeout?.cancel();
    _pendingTimeout = Timer(const Duration(seconds: 8), () {
      if (!mounted) return;
      setState(() => _pendingTarget = null);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("No response from the device — check that it's powered on and connected to WiFi"),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;

    if (data == null) {
      // Device node briefly missing/loading — show a light placeholder
      // instead of a blank gap so the grid doesn't jump around.
      return Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
      );
    }

    final info = data['info'] is Map ? Map<String, dynamic>.from(data['info']) : <String, dynamic>{};
    final state = data['state'] is Map ? Map<String, dynamic>.from(data['state']) : <String, dynamic>{};
    final telemetry = data['telemetry'] is Map ? Map<String, dynamic>.from(data['telemetry']) : <String, dynamic>{};

    final title = (info['name'] as String?) ?? "Unnamed";
    final room = (info['room'] as String?) ?? "";
    final type = (info['type'] as String?) ?? "Other";

    final isOn = state['relay'] == true;
    final pending = _pendingTarget != null;
    // While waiting on a command, show the state we asked for rather than
    // the (stale) confirmed one, so the switch visually flips immediately.
    final displayedIsOn = _pendingTarget ?? isOn;

    final powerValue = telemetry['power'];
    final watts = powerValue == null
        ? "0"
        : (powerValue is num ? powerValue.toStringAsFixed(0) : powerValue.toString());

    // "Online" here just reflects whether the appliance is currently
    // switched on. If you want true connectivity status (is the ESP32
    // itself reachable), have the device write a heartbeat timestamp
    // and compare it against DateTime.now() here instead.
    final status = pending ? "Updating..." : (displayedIsOn ? "Online" : "Offline");

    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          // ICON + STATUS
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: displayedIsOn ? const Color(0xFFE8F8F5) : const Color(0xFFF3F4F6),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  _typeIcons[type] ?? Icons.power,
                  color: displayedIsOn ? const Color(0xFF0F766E) : const Color(0xFF9CA3AF),
                  size: 21,
                ),
              ),
              Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: pending
                          ? const Color(0xFFF59E0B)
                          : (displayedIsOn ? const Color(0xFF34D399) : const Color(0xFFD1D5DB)),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    status,
                    style: TextStyle(
                      fontSize: 9,
                      color: displayedIsOn ? const Color(0xFF9CA3AF) : const Color(0xFFD1D5DB),
                    ),
                  ),
                  // Renaming writes devices/{id}/info, which the rules
                  // keep to the owner.
                  if (widget.canManage) ...[
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => AddAppliancePage(editDeviceId: widget.deviceId),
                          ),
                        );
                      },
                      child: const Icon(
                        Icons.edit_outlined,
                        size: 14,
                        color: Color(0xFF9CA3AF),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),

          const SizedBox(height: 12),

          // TITLE
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1F2937),
            ),
          ),

          const SizedBox(height: 7),

          // ROOM
          Text(
            room,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10, color: Color(0xFF9CA3AF)),
          ),

          const Spacer(),

          // WATTS + SWITCH
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              RichText(
                text: TextSpan(
                  children: [
                    TextSpan(
                      text: watts,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: displayedIsOn ? const Color(0xFF0F766E) : const Color(0xFF9CA3AF),
                      ),
                    ),
                    const TextSpan(
                      text: "W",
                      style: TextStyle(fontSize: 10, color: Color(0xFF9CA3AF)),
                    ),
                  ],
                ),
              ),

              // TAPPABLE SWITCH
              GestureDetector(
                onTap: pending ? null : () => _toggleRelay(isOn),
                child: Opacity(
                  opacity: widget.canControl ? 1 : 0.45,
                  child: Container(
                    width: 34,
                    height: 19,
                    decoration: BoxDecoration(
                      color: displayedIsOn ? const Color(0xFF0F766E) : const Color(0xFFE5E7EB),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: pending
                        ? const Center(
                            child: SizedBox(
                              width: 10,
                              height: 10,
                              child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white),
                            ),
                          )
                        : AnimatedAlign(
                            duration: const Duration(milliseconds: 150),
                            alignment: displayedIsOn ? Alignment.centerRight : Alignment.centerLeft,
                            child: Container(
                              width: 15,
                              height: 15,
                              margin: const EdgeInsets.all(2),
                              decoration: const BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
