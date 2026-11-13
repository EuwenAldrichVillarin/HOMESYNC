import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

// ===================================================================
// ELECTRICITY RATE EDITOR
// Shared by Home and Energy Report so both buttons behave the same and
// write the same setting: users/{householdUid}/settings/pesoPerKwh.
// Both screens listen to that path, so a change on one shows on the
// other straight away.
// ===================================================================
Future<void> showEditRateDialog(BuildContext context, String uid, double currentRate) async {
  final controller = TextEditingController(text: currentRate.toStringAsFixed(2));
  final result = await showDialog<double>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          "Electricity Rate",
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1F2937)),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Used to estimate cost from your kWh usage on Home and Report.",
              style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                prefixText: "₱ ",
                suffixText: "/ kWh",
                filled: true,
                fillColor: const Color(0xFFF8FAFC),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text("Cancel", style: TextStyle(color: Color(0xFF64748B))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0F766E),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () {
              final value = double.tryParse(controller.text.trim());
              if (value == null || value <= 0) return;
              Navigator.pop(dialogContext, value);
            },
            child: const Text("Save"),
          ),
        ],
      );
    },
  );
  controller.dispose();

  if (result != null) {
    await FirebaseDatabase.instance.ref('users/$uid/settings/pesoPerKwh').set(result);
  }
}
