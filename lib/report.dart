import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:share_plus/share_plus.dart';

import 'household.dart';
import 'rate_dialog.dart';
import 'members.dart';
import 'app_nav_bar.dart';
import 'report_pdf.dart';

// Fallback used until users/{uid}/settings/pesoPerKwh loads (or if it was
// never set). Editable from the rate button on Home and on this screen.
const double _kDefaultPesoPerKwh = 11.0;

enum _ReportRange { hour, day, week, month, custom }

class _DeviceReport {
  final String name;
  final String room;
  final String type;
  final Map<String, double> dailyKwh; // "YYYY-MM-DD" -> kWh used that day
  final Map<DateTime, double> hourlyKwh; // start of the hour (local) -> kWh used in it

  const _DeviceReport({
    required this.name,
    required this.room,
    required this.type,
    required this.dailyKwh,
    required this.hourlyKwh,
  });
}

class _Bucket {
  final String label; // short x-axis text under the bar
  final String detail; // longer text shown in the bar's tooltip
  final DateTime start; // inclusive
  final DateTime end; // exclusive

  const _Bucket({required this.label, required this.detail, required this.start, required this.end});
}

class ReportPage extends StatefulWidget {
  const ReportPage({super.key});

  @override
  State<ReportPage> createState() => _ReportPageState();
}

class _ReportPageState extends State<ReportPage> {
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

  _ReportRange _range = _ReportRange.day;
  DateTimeRange? _customRange;
  double _pesoPerKwh = _kDefaultPesoPerKwh;
  bool _exporting = false;

  HouseholdSession? _session;
  StreamSubscription<DatabaseEvent>? _appliancesSub;
  StreamSubscription<DatabaseEvent>? _rateSub;
  final Map<String, StreamSubscription<DatabaseEvent>> _deviceSubs = {};
  final Map<String, _DeviceReport> _devices = {};

  @override
  void initState() {
    super.initState();
    HouseholdSession.ensureLoaded().then((session) {
      if (!mounted) return;
      setState(() => _session = session);
      // Nothing to subscribe to if this member isn't allowed to see
      // usage history in the first place.
      if (session.isRevoked || !session.canViewReports) return;

      final householdUid = session.householdUid;
      _listenToAppliances(householdUid);
      _rateSub =
          FirebaseDatabase.instance.ref('users/$householdUid/settings/pesoPerKwh').onValue.listen((event) {
        final value = event.snapshot.value;
        if (value is num) {
          setState(() => _pesoPerKwh = value.toDouble());
        }
      });
    }).catchError((Object _) {});
  }

  // ===============================================================
  // LIVE DATA — mirrors the pattern in appliances.dart: watch the
  // household's appliance index, then watch each owned device's own
  // node so history keeps updating without re-fetching everything.
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
          final historyRaw =
              data['history'] is Map ? Map<String, dynamic>.from(data['history']) : <String, dynamic>{};

          final dailyKwh = <String, double>{};
          historyRaw.forEach((key, value) {
            if (value is num) dailyKwh[key.toString()] = value.toDouble();
          });

          final hourlyKwh = _parseHourly(data['hourly']);

          setState(() {
            _devices[id] = _DeviceReport(
              name: (info['name'] as String?) ?? 'Unnamed',
              room: (info['room'] as String?) ?? '',
              type: (info['type'] as String?) ?? 'Other',
              dailyKwh: dailyKwh,
              hourlyKwh: hourlyKwh,
            );
          });
        });
      }
    });
  }

  /// devices/{id}/hourly/{YYYY-MM-DD}/{HH} -> kWh, written by the plug
  /// firmware. Hour keys "00".."23" can come back from the database as a
  /// list (index = hour) rather than a map, so both shapes are handled.
  static Map<DateTime, double> _parseHourly(Object? raw) {
    final result = <DateTime, double>{};
    if (raw is! Map) return result;
    raw.forEach((dateKey, hours) {
      final date = DateTime.tryParse(dateKey.toString());
      if (date == null) return;
      void add(int? hour, Object? value) {
        if (hour == null || hour < 0 || hour > 23 || value is! num) return;
        result[DateTime(date.year, date.month, date.day, hour)] = value.toDouble();
      }

      if (hours is Map) {
        hours.forEach((h, v) => add(int.tryParse(h.toString()), v));
      } else if (hours is List) {
        for (int h = 0; h < hours.length; h++) {
          add(h, hours[h]);
        }
      }
    });
    return result;
  }

  @override
  void dispose() {
    _appliancesSub?.cancel();
    _rateSub?.cancel();
    for (final sub in _deviceSubs.values) {
      sub.cancel();
    }
    super.dispose();
  }

  // ===============================================================
  // TIME BUCKETING — turns the selected filter into a list of date
  // ranges to sum history against. Each device only stores one kWh
  // number per calendar day in history/, plus one per hour in hourly/
  // for "Hour". "Day" shows the last 7 individual days.
  // ===============================================================
  List<_Bucket> _buckets() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    switch (_range) {
      case _ReportRange.hour:
        // Today, midnight to midnight, one bar per hour. Every hour is
        // labelled; the chart turns the labels sideways so they fit.
        return List.generate(24, (h) {
          final start = DateTime(today.year, today.month, today.day, h);
          return _Bucket(
            label: _hourLabel(h),
            detail: "${_hourLabel(h)} – ${_hourLabel((h + 1) % 24)}",
            start: start,
            end: start.add(const Duration(hours: 1)),
          );
        });

      case _ReportRange.day:
        return List.generate(7, (i) {
          final d = today.subtract(Duration(days: 6 - i));
          return _Bucket(
            label: _weekdayLabel(d.weekday),
            detail: "${_weekdayLabel(d.weekday)}, ${_dateLabel(d)}",
            start: d,
            end: d.add(const Duration(days: 1)),
          );
        });

      case _ReportRange.week:
        final startOfThisWeek = today.subtract(Duration(days: today.weekday - 1));
        return List.generate(6, (i) {
          final start = startOfThisWeek.subtract(Duration(days: 7 * (5 - i)));
          final end = start.add(const Duration(days: 7));
          return _Bucket(
            label: _dateLabel(start),
            detail: "${_dateLabel(start)} – ${_dateLabel(end.subtract(const Duration(days: 1)))}",
            start: start,
            end: end,
          );
        });

      case _ReportRange.month:
        return List.generate(6, (i) {
          final monthStart = DateTime(today.year, today.month - (5 - i), 1);
          final nextMonth = DateTime(monthStart.year, monthStart.month + 1, 1);
          return _Bucket(
            label: _monthLabel(monthStart.month),
            detail: "${_monthLabel(monthStart.month)} ${monthStart.year}",
            start: monthStart,
            end: nextMonth,
          );
        });

      case _ReportRange.custom:
        final range = _customRange ?? DateTimeRange(start: today.subtract(const Duration(days: 6)), end: today);
        final start = DateTime(range.start.year, range.start.month, range.start.day);
        final end = DateTime(range.end.year, range.end.month, range.end.day);
        final dayCount = (end.difference(start).inDays + 1).clamp(1, 31).toInt();
        return List.generate(dayCount, (i) {
          final d = start.add(Duration(days: i));
          return _Bucket(label: "${d.day}", detail: _dateLabel(d), start: d, end: d.add(const Duration(days: 1)));
        });
    }
  }

  static String _hourLabel(int hour) {
    final h = hour % 12 == 0 ? 12 : hour % 12;
    return "$h${hour < 12 ? 'am' : 'pm'}";
  }

  static String _dateLabel(DateTime d) => "${_monthLabel(d.month)} ${d.day}";

  // Chart captions for each filter.
  String get _chartSubtitle {
    switch (_range) {
      case _ReportRange.hour:
        return "Today, by hour";
      case _ReportRange.day:
        return "Last 7 days";
      case _ReportRange.week:
        return "Last 6 weeks";
      case _ReportRange.month:
        return "Last 6 months";
      case _ReportRange.custom:
        return "Selected dates (up to 31 days)";
    }
  }

  String get _xAxisTitle {
    switch (_range) {
      case _ReportRange.hour:
        return "Time of day";
      case _ReportRange.day:
        return "Day";
      case _ReportRange.week:
        return "Week starting";
      case _ReportRange.month:
        return "Month";
      case _ReportRange.custom:
        return "Day of month";
    }
  }

  String get _currentLegend {
    switch (_range) {
      case _ReportRange.hour:
        return "This hour";
      case _ReportRange.week:
        return "This week";
      case _ReportRange.month:
        return "This month";
      case _ReportRange.day:
      case _ReportRange.custom:
        return "Today";
    }
  }

  static String _kwhLabel(double v) {
    if (v <= 0) return "0";
    if (v < 1) return v.toStringAsFixed(2);
    if (v < 100) return v.toStringAsFixed(1);
    return v.toStringAsFixed(0);
  }

  static String _weekdayLabel(int weekday) {
    const labels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
    return labels[weekday - 1];
  }

  static String _monthLabel(int month) {
    const labels = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    return labels[month - 1];
  }

  double _kwhForDevice(_DeviceReport device, DateTime start, DateTime end) {
    // The Hour view sums the hourly log; every other view the daily one.
    if (_range == _ReportRange.hour) {
      double total = 0;
      device.hourlyKwh.forEach((hourStart, kwh) {
        if (!hourStart.isBefore(start) && hourStart.isBefore(end)) total += kwh;
      });
      return total;
    }

    double total = 0;
    device.dailyKwh.forEach((dateStr, kwh) {
      final date = DateTime.tryParse(dateStr);
      if (date == null) return;
      if (!date.isBefore(start) && date.isBefore(end)) {
        total += kwh;
      }
    });
    return total;
  }

  double _totalForRange(DateTime start, DateTime end) {
    double total = 0;
    for (final device in _devices.values) {
      total += _kwhForDevice(device, start, end);
    }
    return total;
  }

  static double _niceAxisMax(double value) {
    if (value <= 0) return 5;
    final raw = value * 1.15;
    double step;
    if (raw <= 10) {
      step = 1;
    } else if (raw <= 50) {
      step = 5;
    } else if (raw <= 100) {
      step = 10;
    } else if (raw <= 500) {
      step = 50;
    } else {
      step = 100;
    }
    return (raw / step).ceil() * step;
  }

  static String _formatThousands(num value) {
    final rounded = value.round();
    final digits = rounded.abs().toString();
    final buffer = StringBuffer();
    for (int i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
      buffer.write(digits[i]);
    }
    return (rounded < 0 ? '-' : '') + buffer.toString();
  }

  // ===============================================================
  // EXPORT — turns exactly what the screen is showing for the current
  // filter (summary, the chart's buckets, the per-appliance breakdown)
  // into a PDF and hands it to the platform share sheet. On web, where
  // file sharing is often unsupported, share_plus downloads it instead.
  // ===============================================================
  Future<void> _exportPdf(
    BuildContext buttonContext, {
    required List<_Bucket> buckets,
    required List<double> bucketTotals,
    required double totalKwh,
    required double? changePct,
    required List<MapEntry<_DeviceReport, double>> breakdown,
  }) async {
    final box = buttonContext.findRenderObject() as RenderBox?;
    final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    final messenger = ScaffoldMessenger.of(context);

    final now = DateTime.now();
    final periodStart = buckets.first.start;
    final lastDay = buckets.last.end.subtract(const Duration(days: 1));
    final periodText = _range == _ReportRange.hour
        ? _longDate(periodStart)
        : "${_longDate(periodStart)} – ${_longDate(lastDay)}";

    final data = ReportPdfData(
      rangeTitle: _chartSubtitle,
      periodText: periodText,
      generatedText: "${_longDate(now)}, ${_clockLabel(now)}",
      xAxisTitle: _xAxisTitle,
      currentLegend: _currentLegend,
      pesoPerKwh: _pesoPerKwh,
      totalKwh: totalKwh,
      changePct: changePct,
      bars: [
        for (int i = 0; i < buckets.length; i++)
          ReportPdfBar(
            label: buckets[i].label,
            detail: buckets[i].detail,
            kwh: bucketTotals[i],
            highlighted: !now.isBefore(buckets[i].start) && now.isBefore(buckets[i].end),
          ),
      ],
      appliances: [
        for (final entry in breakdown)
          ReportPdfAppliance(name: entry.key.name, room: entry.key.room, type: entry.key.type, kwh: entry.value),
      ],
    );
    final fileName = "homesync-report-${_range.name}-${_isoDate(now)}.pdf";

    setState(() => _exporting = true);
    try {
      final bytes = await buildReportPdf(data);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile.fromData(bytes, mimeType: 'application/pdf', name: fileName)],
          fileNameOverrides: [fileName],
          subject: "HomeSync energy report",
          sharePositionOrigin: origin,
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text("Couldn't export the report: $e")));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  static String _longDate(DateTime d) => "${_monthLabel(d.month)} ${d.day}, ${d.year}";

  static String _isoDate(DateTime d) =>
      "${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}";

  static String _clockLabel(DateTime d) {
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    return "$h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'am' : 'pm'}";
  }

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 2),
      lastDate: now,
      initialDateRange: _customRange ??
          DateTimeRange(start: now.subtract(const Duration(days: 6)), end: now),
    );
    if (picked == null) return;
    setState(() {
      _range = _ReportRange.custom;
      _customRange = picked;
    });
  }

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
    if (!session.canViewReports) {
      // Reachable by deep link even though the nav item is hidden.
      return Scaffold(
        backgroundColor: const Color(0xFFF8FAFC),
        body: SafeArea(
          child: AccessNotice(
            icon: Icons.lock_outline,
            title: "Reports are off for you",
            message: "Your household admin hasn't given this account access to "
                "usage reports.",
            action: OutlinedButton(
              onPressed: () => Navigator.pushReplacementNamed(context, '/home'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF0F766E),
                side: const BorderSide(color: Color(0xFF0F766E)),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              ),
              child: const Text("Back to Home", style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ),
      );
    }

    final buckets = _buckets();
    final bucketTotals = buckets.map((b) => _totalForRange(b.start, b.end)).toList();
    final totalKwh = bucketTotals.fold<double>(0, (a, b) => a + b);
    final estCost = totalKwh * _pesoPerKwh;

    final periodStart = buckets.first.start;
    final periodEnd = buckets.last.end;
    final previousStart = periodStart.subtract(periodEnd.difference(periodStart));
    final previousTotal = _totalForRange(previousStart, periodStart);
    final double? changePct = previousTotal > 0 ? ((totalKwh - previousTotal) / previousTotal) * 100 : null;

    final breakdown = _devices.values
        .map((device) => MapEntry(device, _kwhForDevice(device, periodStart, periodEnd)))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final maxBucket = bucketTotals.fold<double>(0, (a, b) => a > b ? a : b);
    final axisMax = _niceAxisMax(maxBucket);

    final now = DateTime.now();
    // Hourly and long custom ranges have too many bars for flat labels.
    final dense = buckets.length > 12;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),

      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [

                    // =========================================
                    // HEADER
                    // =========================================
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // Expanded so the longer title wraps on narrow
                        // phones instead of pushing the buttons off-screen.
                        const Expanded(
                          child: Text(
                            "Energy Consumption Report",
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1F2937),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Row(
                          children: [
                            // Same rate editor as Home. Members share the
                            // admin's rate but can't change it.
                            if (_session?.canEditRate ?? false) ...[
                              InkWell(
                                borderRadius: BorderRadius.circular(17),
                                onTap: () => showEditRateDialog(context, _session!.householdUid, _pesoPerKwh),
                                child: Container(
                                  width: 34,
                                  height: 34,
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: const Color(0xFFE5E7EB)),
                                  ),
                                  child: const Tooltip(
                                    message: "Edit electricity rate",
                                    child: Icon(
                                      Icons.payments_outlined,
                                      size: 18,
                                      color: Color(0xFF0F766E),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            // Builder so the share sheet can anchor to this
                            // button on iPad, which requires an origin.
                            Builder(
                              builder: (buttonContext) => InkWell(
                                borderRadius: BorderRadius.circular(17),
                                onTap: _exporting
                                    ? null
                                    : () => _exportPdf(
                                          buttonContext,
                                          buckets: buckets,
                                          bucketTotals: bucketTotals,
                                          totalKwh: totalKwh,
                                          changePct: changePct,
                                          breakdown: breakdown,
                                        ),
                                child: Container(
                                  width: 34,
                                  height: 34,
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: const Color(0xFFE5E7EB)),
                                  ),
                                  child: Tooltip(
                                    message: "Export report (PDF)",
                                    child: _exporting
                                        ? const Padding(
                                            padding: EdgeInsets.all(9),
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Color(0xFF0F766E),
                                            ),
                                          )
                                        : const Icon(
                                            Icons.file_download_outlined,
                                            size: 18,
                                            color: Color(0xFF0F766E),
                                          ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),

                    const SizedBox(height: 14),

                    // =========================================
                    // TIME FILTER
                    // =========================================
                    SizedBox(
                      height: 34,
                      child: Row(
                        children: [
                          _filterTab("Hour", _ReportRange.hour),
                          const SizedBox(width: 6),
                          _filterTab("Day", _ReportRange.day),
                          const SizedBox(width: 6),
                          _filterTab("Week", _ReportRange.week),
                          const SizedBox(width: 6),
                          _filterTab("Month", _ReportRange.month),
                          const SizedBox(width: 6),
                          _filterTab("Date Range", _ReportRange.custom, onCustomTap: _pickCustomRange),
                        ],
                      ),
                    ),

                    if (_range == _ReportRange.custom && _customRange != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        "${_customRange!.start.month}/${_customRange!.start.day}/${_customRange!.start.year}"
                        " – ${_customRange!.end.month}/${_customRange!.end.day}/${_customRange!.end.year}",
                        style: const TextStyle(fontSize: 10, color: Color(0xFF94A3B8)),
                      ),
                    ],

                    const SizedBox(height: 12),

                    // =========================================
                    // BAR CHART
                    // =========================================
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(10, 12, 10, 8),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFFE5E7EB)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [

                          // TITLE + LEGEND
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      "Energy Usage (kWh)",
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFF1F2937),
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      _chartSubtitle,
                                      style: const TextStyle(fontSize: 9, color: Color(0xFF94A3B8)),
                                    ),
                                  ],
                                ),
                              ),
                              _legendItem(const Color(0xFFF59E0B), _currentLegend),
                              const SizedBox(width: 8),
                              _legendItem(const Color(0xFF0F766E), "Earlier"),
                            ],
                          ),

                          const SizedBox(height: 10),

                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [

                              // Y-AXIS TITLE
                              SizedBox(
                                height: _valueLabelHeight(dense) + _kBarAreaHeight,
                                child: const RotatedBox(
                                  quarterTurns: 3,
                                  child: Center(
                                    child: Text(
                                      "kWh",
                                      style: TextStyle(
                                        fontSize: 8,
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFF64748B),
                                      ),
                                    ),
                                  ),
                                ),
                              ),

                              const SizedBox(width: 3),

                              // Y-AXIS LABELS — spans exactly the bar area so
                              // the top label lines up with a full-height bar.
                              Padding(
                                padding: EdgeInsets.only(top: _valueLabelHeight(dense) - 4),
                                child: SizedBox(
                                  width: 24,
                                  height: _kBarAreaHeight + 8,
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: List.generate(6, (i) {
                                      final v = axisMax * (5 - i) / 5;
                                      return Text(
                                        v % 1 == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1),
                                        style: const TextStyle(fontSize: 7, color: Color(0xFF94A3B8)),
                                      );
                                    }),
                                  ),
                                ),
                              ),

                              const SizedBox(width: 5),

                              // BARS
                              Expanded(
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: List.generate(buckets.length, (i) {
                                    final bucket = buckets[i];
                                    // The bar for the current hour/day/week/month.
                                    final isToday = !now.isBefore(bucket.start) &&
                                        now.isBefore(bucket.end);
                                    return _reportBar(
                                      label: bucket.label,
                                      tooltip: "${bucket.detail}: ${_kwhLabel(bucketTotals[i])} kWh",
                                      value: bucketTotals[i],
                                      axisMax: axisMax,
                                      highlighted: isToday,
                                      dense: dense,
                                      // Many bars need to be thinner to leave
                                      // a gap between them.
                                      barWidth: dense ? 7 : 14,
                                    );
                                  }),
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 4),

                          // X-AXIS TITLE
                          Center(
                            child: Text(
                              _xAxisTitle,
                              style: const TextStyle(
                                fontSize: 8,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF64748B),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 10),

                    // =========================================
                    // 3 SUMMARY CARDS
                    // =========================================
                    Row(
                      children: [
                        Expanded(
                          child: _summaryCard(
                            title: "Total kWh",
                            value: totalKwh.toStringAsFixed(1),
                            valueColor: const Color(0xFF1F2937),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _summaryCard(
                            title: "Est. Cost",
                            value: "₱${_formatThousands(estCost)}",
                            valueColor: const Color(0xFF1F2937),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Container(
                            height: 60,
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: const Color(0xFFE5E7EB)),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Text(
                                  "vs Last",
                                  style: TextStyle(fontSize: 7, color: Color(0xFF6B7280)),
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  changePct == null
                                      ? "—"
                                      : "${changePct <= 0 ? '↓' : '↑'} ${changePct.abs().toStringAsFixed(0)}%",
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: changePct == null
                                        ? const Color(0xFF94A3B8)
                                        : (changePct <= 0 ? const Color(0xFF34D399) : const Color(0xFFEF4444)),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 12),

                    // =========================================
                    // USAGE BREAKDOWN HEADER
                    // =========================================
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          "Usage Breakdown",
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1F2937),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE8F8F5),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text(
                            "% OF TOTAL",
                            style: TextStyle(
                              fontSize: 7,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF0F766E),
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 8),

                    // =========================================
                    // USAGE BREAKDOWN ITEMS
                    // =========================================
                    if (breakdown.isEmpty)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        alignment: Alignment.center,
                        child: const Text(
                          "No usage recorded for this period yet",
                          style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                        ),
                      )
                    else
                      for (int i = 0; i < breakdown.length; i++) ...[
                        if (i > 0) const SizedBox(height: 8),
                        _usageItem(
                          icon: _typeIcons[breakdown[i].key.type] ?? Icons.power,
                          iconBackground: const Color(0xFFE8F8F5),
                          iconColor: const Color(0xFF0F766E),
                          title: breakdown[i].key.room.isNotEmpty
                              ? "${breakdown[i].key.name} (${breakdown[i].key.room})"
                              : breakdown[i].key.name,
                          percentage: totalKwh > 0
                              ? "${(breakdown[i].value / totalKwh * 100).toStringAsFixed(0)}%"
                              : "0%",
                        ),
                      ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),

      // ===================================================
      // BOTTOM NAVIGATION
      // ===================================================
      bottomNavigationBar: const AppNavBar(current: AppTab.report),
    );
  }

  // ===============================================================
  // TIME FILTER TAB
  // ===============================================================
  Widget _filterTab(String label, _ReportRange value, {VoidCallback? onCustomTap}) {
    final selected = _range == value;
    return Expanded(
      child: GestureDetector(
        onTap: onCustomTap ?? () => setState(() => _range = value),
        child: Container(
          alignment: Alignment.center,
          height: 34,
          decoration: BoxDecoration(
            color: selected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 9,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              color: selected ? const Color(0xFF0F766E) : const Color(0xFF1F2937),
            ),
          ),
        ),
      ),
    );
  }

  // ===============================================================
  // REPORT BAR
  // ===============================================================
  static const double _kBarAreaHeight = 128;

  // Room above the bar for its value; taller when the value is turned
  // sideways on dense charts.
  static double _valueLabelHeight(bool dense) => dense ? 24 : 12;

  static Widget _reportBar({
    required String label,
    required String tooltip,
    required double value,
    required double axisMax,
    required bool highlighted,
    required bool dense,
    double barWidth = 14,
  }) {
    final height =
        axisMax <= 0 ? 2.0 : (value / axisMax * _kBarAreaHeight).clamp(2.0, _kBarAreaHeight).toDouble();
    final color = highlighted ? const Color(0xFFF59E0B) : const Color(0xFF0F766E);

    Widget sideways(Widget child) => dense ? RotatedBox(quarterTurns: 3, child: child) : child;

    return Expanded(
      child: Tooltip(
        message: tooltip,
        child: Column(
          children: [
            SizedBox(
              height: _valueLabelHeight(dense) + _kBarAreaHeight,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (value > 0)
                    sideways(
                      Text(
                        _kwhLabel(value),
                        maxLines: 1,
                        softWrap: false,
                        style: TextStyle(fontSize: 6, fontWeight: FontWeight.w600, color: color),
                      ),
                    ),
                  const SizedBox(height: 2),
                  Container(width: barWidth, height: height, color: color),
                ],
              ),
            ),
            // Baseline under the bars.
            Container(height: 1, color: const Color(0xFFE5E7EB)),
            const SizedBox(height: 4),
            SizedBox(
              height: dense ? 22 : 10,
              child: sideways(
                Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    fontSize: 7,
                    fontWeight: highlighted ? FontWeight.bold : FontWeight.normal,
                    color: highlighted ? const Color(0xFFF59E0B) : const Color(0xFF64748B),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _legendItem(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 8, height: 8, color: color),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 8, color: Color(0xFF64748B))),
      ],
    );
  }

  // ===============================================================
  // SUMMARY CARD
  // ===============================================================
  static Widget _summaryCard({
    required String title,
    required String value,
    required Color valueColor,
  }) {
    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 7, color: Color(0xFF6B7280)),
          ),
          const SizedBox(height: 5),
          Text(
            value,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: valueColor),
          ),
        ],
      ),
    );
  }

  // ===============================================================
  // USAGE ITEM
  // ===============================================================
  static Widget _usageItem({
    required IconData icon,
    required Color iconBackground,
    required Color iconColor,
    required String title,
    required String percentage,
  }) {
    return Container(
      width: double.infinity,
      height: 54,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(color: iconBackground, borderRadius: BorderRadius.circular(9)),
            child: Icon(icon, size: 17, color: iconColor),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF334155)),
            ),
          ),
          Text(
            percentage,
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF334155)),
          ),
        ],
      ),
    );
  }
}
