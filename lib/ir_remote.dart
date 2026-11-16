import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

import 'activity.dart';
import 'household.dart';

// ===================================================================
// IR REMOTE CONTROL
//
// One ESP32 IR "hub" per household (HX1838 receiver + IR LED) copies
// infrared remotes — TVs, aircons, fans, ... — and plays them back. IR
// needs line of sight, so the hub only reaches appliances it can "see".
// The app never talks to the hub directly; both sides meet in the
// database (firmware/esp32_ir_hub/esp32_ir_hub.ino documents the hub's
// half):
//
//   users/{admin}/settings/irHubId      the household's hub, set once
//   hubs/{hubId}/ownerId                household admin who linked it
//   hubs/{hubId}/command                {id, action: record|send, khz,
//                                        pulses?, repeat?, at} — app writes
//   hubs/{hubId}/result                 {id, status, pulses?, message?}
//                                        — hub writes when it's done
//   hubs/{hubId}/status/lastSeen        hub heartbeat (server time)
//   devices/{id}/remote/buttons/{key}   {name, khz, pulses, createdAt}
//
// A signal is stored raw: microsecond durations of alternating IR
// mark/space, starting with a mark, comma-separated, sent on a 38 kHz
// carrier. Aircon remotes send their whole state (mode, temperature,
// fan) with every press, so a button recorded as "Cool 24°C" always
// sets exactly that.
// ===================================================================

const double kIrCarrierKhz = 38;

/// How long the hub waits for a remote while recording. The app waits a
/// little longer so a slow network doesn't cut off a successful capture.
const Duration kIrRecordWindow = Duration(seconds: 15);

class IrButton {
  final String id;
  final String name;
  final double khz;
  final String pulses;

  const IrButton({required this.id, required this.name, required this.khz, required this.pulses});

  static IrButton? fromMap(String id, Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'];
    final pulses = raw['pulses'];
    if (name is! String || pulses is! String || pulses.isEmpty) return null;
    final khz = raw['khz'];
    return IrButton(id: id, name: name, khz: khz is num ? khz.toDouble() : kIrCarrierKhz, pulses: pulses);
  }
}

class IrException implements Exception {
  final String message;
  const IrException(this.message);

  @override
  String toString() => message;
}

class IrHub {
  IrHub._();

  static DatabaseReference hubIdRef(String householdUid) =>
      FirebaseDatabase.instance.ref('users/$householdUid/settings/irHubId');

  /// Links a hub to the admin's household. The hub must have come online
  /// at least once (so a mistyped ID is caught) and not belong to someone
  /// else. Returns the normalised hub ID.
  static Future<String> link({required String adminUid, required String hubId}) async {
    final id = hubId.trim().toUpperCase();
    if (id.isEmpty) throw const IrException("Enter the hub ID");

    final db = FirebaseDatabase.instance.ref();
    final status = await db.child('hubs/$id/status').get();
    if (!status.exists) {
      throw const IrException(
        "Hub not found. Make sure it's powered on, connected to WiFi, and the ID is typed correctly.",
      );
    }
    final owner = await db.child('hubs/$id/ownerId').get();
    if (owner.exists && owner.value != adminUid) {
      throw const IrException("This hub is already linked to another household.");
    }

    await db.update({
      'hubs/$id/ownerId': adminUid,
      'users/$adminUid/settings/irHubId': id,
    });
    return id;
  }

  /// Sends one command to the hub and waits for its matching result.
  static Future<Map<String, dynamic>> _run(String hubId, Map<String, Object?> command, Duration timeout) async {
    final db = FirebaseDatabase.instance.ref();
    final requestId = db.child('hubs/$hubId/command').push().key!;
    final completer = Completer<Map<String, dynamic>>();

    // Listen before writing, so a fast hub can't answer before we look.
    // Results for earlier requests are still sitting there; skip them.
    final sub = db.child('hubs/$hubId/result').onValue.listen((event) {
      final raw = event.snapshot.value;
      if (raw is Map && raw['id'] == requestId && !completer.isCompleted) {
        completer.complete(Map<String, dynamic>.from(raw));
      }
    });

    try {
      await db.child('hubs/$hubId/command').set({
        ...command,
        'id': requestId,
        'at': ServerValue.timestamp,
      });
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      throw const IrException("No answer from the IR hub. Check that it's powered on and connected to WiFi.");
    } finally {
      await sub.cancel();
    }
  }

  /// Puts the hub in listening mode and returns the captured signal.
  static Future<String> record(String hubId) async {
    final result = await _run(
      hubId,
      {'action': 'record', 'khz': kIrCarrierKhz},
      kIrRecordWindow + const Duration(seconds: 10),
    );
    final pulses = result['pulses'];
    if (result['status'] == 'recorded' && pulses is String && pulses.isNotEmpty) return pulses;
    throw IrException((result['message'] as String?) ??
        "Nothing was picked up. Point the remote at the hub from close by and press the button again.");
  }

  /// Has the hub transmit a recorded button.
  static Future<void> send(String hubId, IrButton button) async {
    final result = await _run(
      hubId,
      {'action': 'send', 'khz': button.khz, 'pulses': button.pulses, 'repeat': 1},
      const Duration(seconds: 12),
    );
    if (result['status'] != 'sent') {
      throw IrException((result['message'] as String?) ?? "The hub couldn't send that signal.");
    }
  }
}

/// Opens the remote for an appliance as a bottom sheet — the quick way in
/// from the Appliances page. Recording and editing buttons stay in Edit
/// Appliance; this sheet only presses them.
Future<void> showRemoteControlSheet(BuildContext context, {required String deviceId, required String applianceName}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.white,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.settings_remote, color: Color(0xFF0F766E), size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "$applianceName remote",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF1F2937)),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(sheetContext),
                  icon: const Icon(Icons.close, color: Color(0xFF64748B)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            RemoteControlPanel(deviceId: deviceId, applianceName: applianceName, allowEditing: false),
          ],
        ),
      ),
    ),
  );
}

/// The recorded buttons for one appliance. Anyone with control permission
/// can press them; with [allowEditing] the household admin can also link
/// the hub and record, rename, re-record or delete buttons.
class RemoteControlPanel extends StatefulWidget {
  final String deviceId;
  final String applianceName;
  final bool allowEditing;

  const RemoteControlPanel({
    super.key,
    required this.deviceId,
    required this.applianceName,
    this.allowEditing = true,
  });

  @override
  State<RemoteControlPanel> createState() => _RemoteControlPanelState();
}

class _RemoteControlPanelState extends State<RemoteControlPanel> {
  static const _teal = Color(0xFF0F766E);
  static const _muted = Color(0xFF64748B);
  static const _faint = Color(0xFF94A3B8);
  static const _line = Color(0xFFE2E8F0);

  HouseholdSession? _session;
  StreamSubscription<DatabaseEvent>? _hubSub;
  StreamSubscription<DatabaseEvent>? _buttonsSub;

  bool _hubLoaded = false;
  String? _hubId;
  bool _buttonsLoaded = false;
  List<IrButton> _buttons = const [];

  final _hubIdController = TextEditingController();
  bool _linking = false;
  String? _linkError;
  String? _sendingId; // button currently being transmitted

  bool get _canEdit => widget.allowEditing && (_session?.canManageAppliances ?? false);
  bool get _canPress => _session?.canControl ?? false;

  @override
  void initState() {
    super.initState();
    HouseholdSession.ensureLoaded().then((session) {
      if (!mounted) return;
      setState(() => _session = session);
      _hubSub = IrHub.hubIdRef(session.householdUid).onValue.listen((event) {
        final value = event.snapshot.value;
        setState(() {
          _hubLoaded = true;
          _hubId = value is String && value.isNotEmpty ? value : null;
        });
      });
    }).catchError((Object _) {});

    _buttonsSub = FirebaseDatabase.instance.ref('devices/${widget.deviceId}/remote/buttons').onValue.listen((event) {
      final raw = event.snapshot.value;
      final buttons = <IrButton>[];
      if (raw is Map) {
        raw.forEach((key, value) {
          final button = IrButton.fromMap(key.toString(), value);
          if (button != null) buttons.add(button);
        });
      }
      // Push keys sort by creation time, so buttons keep the order they
      // were recorded in.
      buttons.sort((a, b) => a.id.compareTo(b.id));
      if (!mounted) return;
      setState(() {
        _buttonsLoaded = true;
        _buttons = buttons;
      });
    });
  }

  @override
  void dispose() {
    _hubSub?.cancel();
    _buttonsSub?.cancel();
    _hubIdController.dispose();
    super.dispose();
  }

  DatabaseReference get _buttonsRef => FirebaseDatabase.instance.ref('devices/${widget.deviceId}/remote/buttons');

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------------------------------------------------------
  // LINK HUB
  // ---------------------------------------------------------------
  Future<void> _linkHub() async {
    final session = _session;
    if (session == null) return;
    setState(() {
      _linking = true;
      _linkError = null;
    });
    try {
      await IrHub.link(adminUid: session.uid, hubId: _hubIdController.text);
      _hubIdController.clear();
      _snack("IR hub linked");
    } catch (e) {
      if (mounted) setState(() => _linkError = e.toString());
    } finally {
      if (mounted) setState(() => _linking = false);
    }
  }

  // ---------------------------------------------------------------
  // PRESS
  // ---------------------------------------------------------------
  Future<void> _press(IrButton button) async {
    final hubId = _hubId;
    if (hubId == null || _sendingId != null) return;
    if (!_canPress) {
      _snack("You don't have permission to control appliances");
      return;
    }
    setState(() => _sendingId = button.id);
    try {
      await IrHub.send(hubId, button);
      logActivity(action: ActivityAction.remotePressed, target: widget.applianceName, detail: button.name);
      _snack("Sent \"${button.name}\"");
    } catch (e) {
      _snack(e.toString());
    } finally {
      if (mounted) setState(() => _sendingId = null);
    }
  }

  // ---------------------------------------------------------------
  // RECORD / RENAME / DELETE (admin)
  // ---------------------------------------------------------------
  Future<String?> _askName({String initial = "", required String title, required String action}) {
    final controller = TextEditingController(text: initial);
    final formKey = GlobalKey<FormState>();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            autofocus: true,
            maxLength: 30,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(hintText: "Button name, e.g. Power or Cool 24°C", counterText: ""),
            validator: (value) => (value == null || value.trim().isEmpty) ? "Give the button a name" : null,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text("Cancel")),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _teal),
            onPressed: () {
              if (formKey.currentState!.validate()) Navigator.pop(dialogContext, controller.text.trim());
            },
            child: Text(action),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  /// Shows the "press your remote now" dialog while the hub listens.
  /// Returns the captured signal, or null if it failed or was cancelled.
  Future<String?> _capture(String buttonName) async {
    final hubId = _hubId;
    if (hubId == null) return null;
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RecordDialog(hubId: hubId, buttonName: buttonName),
    );
  }

  Future<void> _recordNew() async {
    final name = await _askName(title: "Record a button", action: "Next");
    if (name == null || !mounted) return;
    final pulses = await _capture(name);
    if (pulses == null) return;
    try {
      await _buttonsRef.push().set({
        'name': name,
        'khz': kIrCarrierKhz,
        'pulses': pulses,
        'createdAt': ServerValue.timestamp,
      });
      logActivity(action: ActivityAction.applianceUpdated, target: widget.applianceName, detail: "Recorded remote button \"$name\"");
      _snack("\"$name\" saved");
    } catch (e) {
      _snack("Couldn't save the button: $e");
    }
  }

  Future<void> _showButtonMenu(IrButton button) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              title: Text(button.name, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: const Text("Remote button"),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text("Rename"),
              onTap: () => Navigator.pop(sheetContext, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.fiber_manual_record_outlined),
              title: const Text("Record again"),
              onTap: () => Navigator.pop(sheetContext, 'rerecord'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Color(0xFFDC2626)),
              title: const Text("Delete", style: TextStyle(color: Color(0xFFDC2626))),
              onTap: () => Navigator.pop(sheetContext, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    final ref = _buttonsRef.child(button.id);

    try {
      switch (choice) {
        case 'rename':
          final name = await _askName(initial: button.name, title: "Rename button", action: "Save");
          if (name != null) await ref.update({'name': name});
        case 'rerecord':
          final pulses = await _capture(button.name);
          if (pulses != null) {
            await ref.update({'pulses': pulses, 'khz': kIrCarrierKhz});
            _snack("\"${button.name}\" recorded again");
          }
        case 'delete':
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.white,
              title: const Text("Delete button?"),
              content: Text("\"${button.name}\" will be removed from this appliance's remote."),
              actions: [
                TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text("Cancel")),
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text("Delete", style: TextStyle(color: Color(0xFFDC2626))),
                ),
              ],
            ),
          );
          if (confirmed == true) await ref.remove();
      }
    } catch (e) {
      _snack("Couldn't update the button: $e");
    }
  }

  // ---------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    if (_session == null || !_hubLoaded || !_buttonsLoaded) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: CircularProgressIndicator(color: _teal, strokeWidth: 2)),
      );
    }

    if (_hubId == null) return _noHub();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_buttons.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              _canEdit
                  ? "No buttons yet. Record the buttons of this appliance's IR remote so it can be controlled from the app."
                  : "No remote buttons have been recorded for this appliance yet.",
              style: const TextStyle(fontSize: 12, color: _muted),
            ),
          )
        else
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [for (final button in _buttons) _buttonTile(button)],
          ),
        if (_canEdit) ...[
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            height: 46,
            child: OutlinedButton.icon(
              onPressed: _recordNew,
              style: OutlinedButton.styleFrom(
                foregroundColor: _teal,
                side: const BorderSide(color: Color(0xFF99D5CF)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              ),
              icon: const Icon(Icons.fiber_manual_record, size: 16, color: Color(0xFFDC2626)),
              label: const Text("Record button", style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ),
          if (_buttons.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text(
              "Tap a button to send it. Long-press to rename, record again or delete.",
              style: TextStyle(fontSize: 11, color: _faint),
            ),
          ],
        ],
      ],
    );
  }

  Widget _buttonTile(IrButton button) {
    final sending = _sendingId == button.id;
    return Material(
      color: sending ? const Color(0xFFE8F8F5) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: sending ? _teal : _line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _sendingId == null ? () => _press(button) : null,
        onLongPress: _canEdit ? () => _showButtonMenu(button) : null,
        child: Opacity(
          opacity: _canPress ? 1 : 0.5,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 92, maxWidth: 160),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  sending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: _teal),
                        )
                      : const Icon(Icons.radio_button_checked, size: 16, color: _teal),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      button.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF1F2937)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _noHub() {
    if (!_canEdit) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 6),
        child: Text(
          "The household's IR remote hub hasn't been set up yet. Ask your household admin to link it.",
          style: TextStyle(fontSize: 12, color: _muted),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          "Link your HomeSync IR hub first. Its ID is shown on the hub's setup page and in its serial log. "
          "You only need to do this once for the whole household.",
          style: TextStyle(fontSize: 12, color: _muted),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _hubIdController,
                enabled: !_linking,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  hintText: "Hub ID, e.g. A1B2C3D4E5F6",
                  isDense: true,
                  errorText: _linkError,
                  errorMaxLines: 3,
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: _line)),
                  enabledBorder:
                      OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: _line)),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 48,
              child: FilledButton(
                onPressed: _linking ? null : _linkHub,
                style: FilledButton.styleFrom(
                  backgroundColor: _teal,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: _linking
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text("Link"),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// "Press the button on your remote now" — runs one recording on the hub
/// and pops with the captured signal (or null on cancel / failure).
class _RecordDialog extends StatefulWidget {
  final String hubId;
  final String buttonName;

  const _RecordDialog({required this.hubId, required this.buttonName});

  @override
  State<_RecordDialog> createState() => _RecordDialogState();
}

class _RecordDialogState extends State<_RecordDialog> {
  String? _error;
  int _secondsLeft = kIrRecordWindow.inSeconds;
  Timer? _countdown;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    setState(() {
      _error = null;
      _secondsLeft = kIrRecordWindow.inSeconds;
    });
    _countdown?.cancel();
    _countdown = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() => _secondsLeft = (_secondsLeft - 1).clamp(0, 999));
    });
    IrHub.record(widget.hubId).then((pulses) {
      if (mounted) Navigator.pop(context, pulses);
    }).catchError((Object e) {
      _countdown?.cancel();
      if (mounted) setState(() => _error = e.toString());
    });
  }

  @override
  void dispose() {
    _countdown?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final failed = _error != null;
    return AlertDialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      title: Text(
        failed ? "Couldn't record \"${widget.buttonName}\"" : "Recording \"${widget.buttonName}\"",
        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!failed) ...[
            const SizedBox(height: 4),
            const Icon(Icons.settings_remote, size: 44, color: Color(0xFF0F766E)),
            const SizedBox(height: 14),
            Text(
              "Point the remote at the hub from close by and press \"${widget.buttonName}\" once.",
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Color(0xFF334155)),
            ),
            const SizedBox(height: 16),
            const LinearProgressIndicator(color: Color(0xFF0F766E), backgroundColor: Color(0xFFE8F8F5)),
            const SizedBox(height: 8),
            Text(
              _secondsLeft > 0 ? "Listening… ${_secondsLeft}s" : "Waiting for the hub…",
              style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
            ),
          ] else
            Text(_error!, style: const TextStyle(fontSize: 13, color: Color(0xFF334155))),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
        if (failed)
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF0F766E)),
            onPressed: _start,
            child: const Text("Try again"),
          ),
      ],
    );
  }
}
