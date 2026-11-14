import 'package:flutter/material.dart';

enum AppTab { home, appliances, report, schedule }

/// The bottom navigation shared by Home, Appliances, Report and Schedule.
/// Kept in one place so the icons, sizes and spacing can't drift apart
/// between pages again.
class AppNavBar extends StatelessWidget {
  final AppTab current;

  /// Members without report access don't get the Report tab.
  final bool showReports;

  const AppNavBar({super.key, required this.current, this.showReports = true});

  static const Color _selected = Color(0xFF0F766E);
  static const Color _unselected = Color(0xFF94A3B8);

  @override
  Widget build(BuildContext context) {
    // Grows by the system inset so phones with on-screen nav buttons
    // (or a gesture bar) don't draw them over the nav items.
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Container(
      height: 64 + bottomInset,
      padding: EdgeInsets.only(bottom: bottomInset),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFF1F5F9))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _item(context, AppTab.home, Icons.home, "Home", '/home'),
          _item(context, AppTab.appliances, Icons.power, "Appliances", '/appliances'),
          if (showReports) _item(context, AppTab.report, Icons.show_chart, "Report", '/report'),
          _item(context, AppTab.schedule, Icons.access_time_filled, "Control", '/schedule'),
        ],
      ),
    );
  }

  Widget _item(BuildContext context, AppTab tab, IconData icon, String label, String route) {
    final selected = tab == current;
    final color = selected ? _selected : _unselected;
    return InkWell(
      onTap: selected ? null : () => Navigator.pushReplacementNamed(context, route),
      child: SizedBox(
        width: 70,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: selected ? FontWeight.bold : FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
