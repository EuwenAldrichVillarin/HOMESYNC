import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import 'alerts.dart';
import 'household.dart';
import 'activity.dart';

// ===================================================================
// APPLIANCE TYPE OPTIONS
// Each has an icon shown in the type picker grid. Extend this list if
// you add new appliance categories later.
// ===================================================================
class ApplianceType {
  final String label;
  final IconData icon;

  const ApplianceType(this.label, this.icon);
}

const List<ApplianceType> kApplianceTypes = [
  ApplianceType("Aircon", Icons.ac_unit),
  ApplianceType("Fridge", Icons.kitchen),
  ApplianceType("TV", Icons.tv),
  ApplianceType("Light", Icons.lightbulb_outline),
  ApplianceType("Washer", Icons.local_laundry_service),
  ApplianceType("Fan", Icons.mode_fan_off),
  ApplianceType("Heater", Icons.thermostat),
  ApplianceType("Other", Icons.power),
];

class AddAppliancePage extends StatefulWidget {
  // When set, this page edits that already-claimed device's info instead
  // of claiming a new one — the Device ID field becomes read-only.
  final String? editDeviceId;

  const AddAppliancePage({super.key, this.editDeviceId});

  @override
  State<AddAppliancePage> createState() => _AddAppliancePageState();
}

class _AddAppliancePageState extends State<AddAppliancePage> {
  final _formKey = GlobalKey<FormState>();

  final _deviceIdController = TextEditingController();
  final _nameController = TextEditingController();
  final _roomController = TextEditingController();
  final _maxWattsController = TextEditingController();
  final _maxDailyKwhController = TextEditingController();

  ApplianceType? _selectedType;
  bool _isSaving = false;
  bool _isRemoving = false;
  bool _isLoadingExisting = false;

  bool get _isBusy => _isSaving || _isRemoving;

  bool get _isEditing => widget.editDeviceId != null;

  @override
  void initState() {
    super.initState();
    if (_isEditing) {
      _deviceIdController.text = widget.editDeviceId!;
      _loadExistingInfo();
    }
  }

  Future<void> _loadExistingInfo() async {
    setState(() => _isLoadingExisting = true);
    try {
      final limitsSnapshot =
          await FirebaseDatabase.instance.ref('devices/${widget.editDeviceId}/limits').get();
      final limits = DeviceLimits.fromMap(limitsSnapshot.value);
      if (limits.maxWatts != null) {
        _maxWattsController.text = limits.maxWatts!.toStringAsFixed(0);
      }
      if (limits.maxDailyKwh != null) {
        _maxDailyKwhController.text = limits.maxDailyKwh!.toStringAsFixed(2);
      }

      final snapshot =
          await FirebaseDatabase.instance.ref('devices/${widget.editDeviceId}/info').get();
      final info = snapshot.value;
      if (info is Map) {
        _nameController.text = (info['name'] as String?) ?? '';
        _roomController.text = (info['room'] as String?) ?? '';
        final typeLabel = info['type'] as String?;
        _selectedType = kApplianceTypes.cast<ApplianceType?>().firstWhere(
              (t) => t?.label == typeLabel,
              orElse: () => null,
            );
      }
    } finally {
      if (mounted) setState(() => _isLoadingExisting = false);
    }
  }

  /// Pre-fills the power ceiling when a type is chosen on a new
  /// appliance. A limit nobody sets is a limit that never fires, so the
  /// form starts from a plausible number rather than an empty box —
  /// while leaving anything the user has already typed alone.
  void _applyDefaultWattsFor(ApplianceType type) {
    if (_maxWattsController.text.trim().isNotEmpty) return;
    final suggested = kDefaultMaxWatts[type.label];
    if (suggested != null) _maxWattsController.text = suggested.toString();
  }

  /// Parses a limit box. Empty means "no limit", which is written as null
  /// so the check is skipped rather than treated as a ceiling of zero.
  double? _parseLimit(TextEditingController controller) {
    final text = controller.text.trim();
    if (text.isEmpty) return null;
    final value = double.tryParse(text);
    if (value == null || value <= 0) return null;
    return value;
  }

  @override
  void dispose() {
    _deviceIdController.dispose();
    _nameController.dispose();
    _roomController.dispose();
    _maxWattsController.dispose();
    _maxDailyKwhController.dispose();
    super.dispose();
  }

  // ===============================================================
  // SCAN QR (placeholder — wire up a QR scanner package here later)
  // ===============================================================
  void _scanDeviceQr() {
    // TODO: integrate a QR scanner (e.g. mobile_scanner) and set
    // _deviceIdController.text = scannedValue;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("QR scanning not wired up yet")),
    );
  }

  // ===============================================================
  // SAVE — claims the device for the current user in Realtime Database
  // ===============================================================
  Future<void> _handleSave() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedType == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please select an appliance type")),
      );
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("You need to be signed in to do this")),
      );
      return;
    }

    // Claiming a device writes devices/{id}/ownerId and indexes it under
    // the claimer, so this stays with the household admin. The Appliances
    // page hides the entry points for members; this is the backstop.
    final session = HouseholdSession.current;
    if (session != null && !session.canManageAppliances) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Only the household admin can add or edit appliances")),
      );
      return;
    }

    // Normalize the device ID so casing/whitespace differences don't create
    // duplicate entries (e.g. "a1b2c3" vs "A1B2C3").
    final deviceId = _deviceIdController.text.trim().toUpperCase();
    final name = _nameController.text.trim();
    final room = _roomController.text.trim();

    setState(() => _isSaving = true);

    final db = FirebaseDatabase.instance.ref();

    try {
      final maxWatts = _parseLimit(_maxWattsController);
      final maxDailyKwh = _parseLimit(_maxDailyKwhController);

      if (_isEditing) {
        // Already claimed and owned — just update the display info.
        await db.update({
          'devices/$deviceId/info': {
            'name': name,
            'room': room,
            'type': _selectedType!.label,
          },
          // null clears a limit, which is what an emptied box means.
          'devices/$deviceId/limits/maxWatts': maxWatts,
          'devices/$deviceId/limits/maxDailyKwh': maxDailyKwh,
        });

        logActivity(action: ActivityAction.applianceUpdated, target: name);

        if (!mounted) return;
        Navigator.pop(context, true);
        return;
      }

      // 1. Confirm the device actually exists — i.e. the physical unit has
      //    connected to WiFi and published at least once under devices/{id}.
      //    This stops someone from "claiming" a device ID that was never
      //    provisioned or was typed incorrectly.
      final deviceSnapshot = await db.child('devices/$deviceId').get();

      if (!deviceSnapshot.exists) {
        _showError(
          "Device not found. Make sure it's powered on, connected to "
          "WiFi, and the ID is entered correctly.",
        );
        return;
      }

      // 2. Make sure this device isn't already claimed by someone else.
      final ownerSnapshot =
          await db.child('devices/$deviceId/ownerId').get();

      if (ownerSnapshot.exists && ownerSnapshot.value != user.uid) {
        _showError("This device is already registered to another account.");
        return;
      }

      // 3. Write ownership + display info, and index it under this user.
      //    Done as a single multi-path update so it either all succeeds or
      //    all fails together, rather than leaving a half-written state.
      await db.update({
        'devices/$deviceId/ownerId': user.uid,
        'devices/$deviceId/info': {
          'name': name,
          'room': room,
          'type': _selectedType!.label,
        },
        'devices/$deviceId/limits/maxWatts': maxWatts,
        'devices/$deviceId/limits/maxDailyKwh': maxDailyKwh,
        'users/${user.uid}/appliances/$deviceId': true,
      });

      logActivity(action: ActivityAction.applianceAdded, target: name);

      if (!mounted) return;
      Navigator.pop(context, true); // true = "an appliance was added"
    } catch (e) {
      _showError("Something went wrong: $e");
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // ===============================================================
  // REMOVE — releases the device so it can be claimed again
  //
  // What gets cleared is deliberate:
  //   ownerId   the claim itself; without it anyone can re-add the plug
  //   info      name/room/type, so the next owner doesn't inherit yours
  //   schedule  ESSENTIAL. A schedule left behind keeps running on the
  //             device, switching a plug nobody in this app controls any
  //             more. Removing the appliance has to stop that too.
  //
  // state/telemetry/history stay: they're written by the plug itself and
  // the rules only let the firmware's account touch them. The energy log
  // belongs to the hardware, and it survives being re-claimed.
  //
  // The relay is left exactly as it is. Removing an appliance from an app
  // shouldn't reach out and switch off someone's fridge — so if it was on
  // when it was removed, it stays on.
  // ===============================================================
  Future<void> _handleRemove() async {
    final user = FirebaseAuth.instance.currentUser;
    final deviceId = widget.editDeviceId;
    if (user == null || deviceId == null) return;

    final session = HouseholdSession.current;
    if (session != null && !session.canManageAppliances) {
      _showError("Only the household admin can remove appliances");
      return;
    }

    final confirmed = await _confirmRemoval();
    if (confirmed != true) return;

    setState(() => _isRemoving = true);
    try {
      // One multi-path update: the claim, the details and the household's
      // index entry all go together, so a half-removed appliance can't be
      // left stranded in someone's list.
      await FirebaseDatabase.instance.ref().update({
        'devices/$deviceId/ownerId': null,
        'devices/$deviceId/info': null,
        'devices/$deviceId/schedule': null,
        'devices/$deviceId/limits': null,
        'users/${user.uid}/appliances/$deviceId': null,
      });

      logActivity(
        action: ActivityAction.applianceRemoved,
        target: _nameController.text.trim().isEmpty ? deviceId : _nameController.text.trim(),
      );

      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isRemoving = false);
      _showError("Couldn't remove the appliance: $e");
    }
  }

  Future<bool?> _confirmRemoval() {
    final name = _nameController.text.trim();
    final label = name.isEmpty ? "this appliance" : name;

    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          "Remove appliance?",
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1F2937)),
        ),
        content: Text(
          "$label will be removed from your household, along with its schedule. "
          "The plug itself keeps running — if it's switched on right now, it stays on.\n\n"
          "You can add it back any time with the same Device ID.",
          style: const TextStyle(fontSize: 13, color: Color(0xFF64748B), height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text("Cancel", style: TextStyle(color: Color(0xFF64748B))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text("Remove"),
          ),
        ],
      ),
    );
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),

      body: SafeArea(
        child: Column(
          children: [

            // =========================================================
            // HEADER
            // =========================================================
            Container(
              width: double.infinity,
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(12, 14, 20, 16),

              child: Row(
                children: [

                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(
                      Icons.arrow_back,
                      color: Color(0xFF1F2937),
                    ),
                  ),

                  const SizedBox(width: 4),

                  Text(
                    _isEditing ? "Edit Appliance" : "Add Appliance",
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1F2937),
                    ),
                  ),
                ],
              ),
            ),

            // =========================================================
            // FORM
            // =========================================================
            Expanded(
              child: _isLoadingExisting
                  ? const Center(child: CircularProgressIndicator())
                  : SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),

                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [

                      // =================================================
                      // DEVICE ID
                      // =================================================
                      const Text(
                        "Device ID",
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF4B5563),
                        ),
                      ),

                      const SizedBox(height: 8),

                      TextFormField(
                        controller: _deviceIdController,
                        textCapitalization: TextCapitalization.characters,
                        readOnly: _isEditing,
                        style: TextStyle(
                          color: _isEditing ? const Color(0xFF94A3B8) : null,
                        ),
                        decoration: InputDecoration(
                          hintText: "e.g. A1B2C3D4E5F6",

                          filled: true,
                          fillColor: _isEditing ? const Color(0xFFF1F5F9) : Colors.white,

                          suffixIcon: _isEditing
                              ? null
                              : IconButton(
                                  onPressed: _scanDeviceQr,
                                  icon: const Icon(
                                    Icons.qr_code_scanner,
                                    color: Color(0xFF0F766E),
                                  ),
                                ),

                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: const BorderSide(
                              color: Color(0xFFE2E8F0),
                            ),
                          ),

                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: const BorderSide(
                              color: Color(0xFFE2E8F0),
                            ),
                          ),

                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: const BorderSide(
                              color: Color(0xFF0F766E),
                              width: 1.5,
                            ),
                          ),

                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 16,
                          ),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return "Enter the device ID printed on the plug";
                          }
                          return null;
                        },
                      ),

                      const SizedBox(height: 4),

                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Text(
                          _isEditing
                              ? "Device ID can't be changed after adding"
                              : "Found on the label of your smart plug, or tap the scan icon",
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF94A3B8),
                          ),
                        ),
                      ),

                      const SizedBox(height: 26),

                      // =================================================
                      // APPLIANCE NAME
                      // =================================================
                      const Text(
                        "Appliance Name",
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF4B5563),
                        ),
                      ),

                      const SizedBox(height: 8),

                      TextFormField(
                        controller: _nameController,
                        decoration: _fieldDecoration("e.g. Living Room Aircon"),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return "Give this appliance a name";
                          }
                          return null;
                        },
                      ),

                      const SizedBox(height: 26),

                      // =================================================
                      // ROOM
                      // =================================================
                      const Text(
                        "Room",
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF4B5563),
                        ),
                      ),

                      const SizedBox(height: 8),

                      TextFormField(
                        controller: _roomController,
                        decoration: _fieldDecoration("e.g. Living Room"),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return "Enter which room this is in";
                          }
                          return null;
                        },
                      ),

                      const SizedBox(height: 26),

                      // =================================================
                      // HIGH CONSUMPTION LIMITS
                      // =================================================
                      const Text(
                        "Alert me when it goes over",
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF4B5563),
                        ),
                      ),

                      const SizedBox(height: 4),

                      const Text(
                        "Leave a box empty to skip that check.",
                        style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                      ),

                      const SizedBox(height: 10),

                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _maxWattsController,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              decoration: _fieldDecoration("e.g. 1500").copyWith(
                                labelText: "Power",
                                labelStyle: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                                suffixText: "W",
                              ),
                              validator: (value) => _validateLimit(value, 5000, "watts"),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextFormField(
                              controller: _maxDailyKwhController,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              decoration: _fieldDecoration("e.g. 3.5").copyWith(
                                labelText: "Per day",
                                labelStyle: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                                suffixText: "kWh",
                              ),
                              validator: (value) => _validateLimit(value, 500, "kWh"),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 26),

                      // =================================================
                      // APPLIANCE TYPE
                      // =================================================
                      const Text(
                        "Appliance Type",
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF4B5563),
                        ),
                      ),

                      const SizedBox(height: 12),

                      GridView.count(
                        crossAxisCount: 4,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 0.85,
                        children: kApplianceTypes.map((type) {
                          final selected = _selectedType == type;

                          return GestureDetector(
                            onTap: () {
                              setState(() {
                                _selectedType = type;
                                _applyDefaultWattsFor(type);
                              });
                            },
                            child: Column(
                              children: [
                                Container(
                                  width: 56,
                                  height: 56,
                                  decoration: BoxDecoration(
                                    color: selected
                                        ? const Color(0xFF0F766E)
                                        : Colors.white,
                                    borderRadius:
                                        BorderRadius.circular(16),
                                    border: Border.all(
                                      color: selected
                                          ? const Color(0xFF0F766E)
                                          : const Color(0xFFE2E8F0),
                                      width: selected ? 0 : 1,
                                    ),
                                  ),
                                  child: Icon(
                                    type.icon,
                                    color: selected
                                        ? Colors.white
                                        : const Color(0xFF64748B),
                                    size: 24,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  type.label,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: selected
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                    color: selected
                                        ? const Color(0xFF0F766E)
                                        : const Color(0xFF64748B),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ),

                      const SizedBox(height: 40),

                      // =================================================
                      // SAVE BUTTON
                      // =================================================
                      SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: ElevatedButton(
                          onPressed: _isBusy ? null : _handleSave,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF0F766E),
                            foregroundColor: Colors.white,
                            elevation: 4,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(30),
                            ),
                          ),
                          child: _isSaving
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(
                                  _isEditing ? "Save Changes" : "Add Appliance",
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                        ),
                      ),

                      const SizedBox(height: 12),

                      // =================================================
                      // CANCEL
                      // =================================================
                      SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: TextButton(
                          onPressed:
                              _isBusy ? null : () => Navigator.pop(context),
                          child: const Text(
                            "Cancel",
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF64748B),
                            ),
                          ),
                        ),
                      ),

                      // =================================================
                      // REMOVE (editing an existing appliance only)
                      // =================================================
                      if (_isEditing) ...[
                        const SizedBox(height: 4),
                        SizedBox(
                          width: double.infinity,
                          height: 56,
                          child: OutlinedButton.icon(
                            onPressed: _isBusy ? null : _handleRemove,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFFDC2626),
                              side: const BorderSide(color: Color(0xFFFECACA)),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(30),
                              ),
                            ),
                            icon: _isRemoving
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      color: Color(0xFFDC2626),
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.delete_outline, size: 19),
                            label: const Text(
                              "Remove Appliance",
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Blank is valid — it means the check is off.
  String? _validateLimit(String? value, double max, String unit) {
    final text = (value ?? '').trim();
    if (text.isEmpty) return null;
    final parsed = double.tryParse(text);
    if (parsed == null) return "Enter a number";
    if (parsed <= 0) return "Must be more than 0";
    if (parsed > max) return "Too high (max ${max.toStringAsFixed(0)} $unit)";
    return null;
  }

  InputDecoration _fieldDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Color(0xFF0F766E), width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 18,
        vertical: 16,
      ),
    );
  }
}
