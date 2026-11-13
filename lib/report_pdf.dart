import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

// Builds the exported Energy Consumption Report. report.dart does all of
// the number crunching and passes in exactly what the screen is showing,
// so the PDF can never disagree with the app.

class ReportPdfBar {
  final String label; // short x-axis text, e.g. "3pm" or "Mon"
  final String detail; // table text, e.g. "3pm – 4pm" or "Mon, Nov 10"
  final double kwh;
  final bool highlighted; // the current hour/day/week/month

  const ReportPdfBar({required this.label, required this.detail, required this.kwh, required this.highlighted});
}

class ReportPdfAppliance {
  final String name;
  final String room;
  final String type;
  final double kwh;

  const ReportPdfAppliance({required this.name, required this.room, required this.type, required this.kwh});
}

class ReportPdfData {
  final String rangeTitle; // e.g. "Last 7 days"
  final String periodText; // e.g. "Nov 7, 2026 – Nov 13, 2026"
  final String generatedText;
  final String xAxisTitle;
  final String currentLegend; // e.g. "Today"
  final double pesoPerKwh;
  final double totalKwh;
  final double? changePct;
  final List<ReportPdfBar> bars;
  final List<ReportPdfAppliance> appliances;

  const ReportPdfData({
    required this.rangeTitle,
    required this.periodText,
    required this.generatedText,
    required this.xAxisTitle,
    required this.currentLegend,
    required this.pesoPerKwh,
    required this.totalKwh,
    required this.changePct,
    required this.bars,
    required this.appliances,
  });
}

// Brand colours, matching the app and the logo artwork.
const _teal = PdfColor.fromInt(0xFF0F766E);
const _brandTeal = PdfColor.fromInt(0xFF1A7F72);
const _ink = PdfColor.fromInt(0xFF0D2E33);
const _amber = PdfColor.fromInt(0xFFF59E0B);
const _text = PdfColor.fromInt(0xFF1F2937);
const _muted = PdfColor.fromInt(0xFF64748B);
const _faint = PdfColor.fromInt(0xFF94A3B8);
const _line = PdfColor.fromInt(0xFFE5E7EB);
const _mint = PdfColor.fromInt(0xFFE8F8F5);
const _green = PdfColor.fromInt(0xFF059669);
const _red = PdfColor.fromInt(0xFFDC2626);

const double _chartHeight = 150;

Future<Uint8List> buildReportPdf(ReportPdfData data) async {
  final regular = pw.Font.ttf(await rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
  final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
  final logo = pw.MemoryImage((await rootBundle.load('assets/logo.png')).buffer.asUint8List());

  final doc = pw.Document(
    title: 'HomeSync Energy Consumption Report',
    author: 'HomeSync',
    theme: pw.ThemeData.withFont(base: regular, bold: bold),
  );

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(36, 32, 36, 32),
      header: (context) => context.pageNumber == 1 ? pw.SizedBox() : _runningHeader(data),
      footer: (context) => _footer(context, data),
      build: (context) => [
        _brandHeader(logo, data),
        pw.SizedBox(height: 18),
        _summaryCards(data),
        pw.SizedBox(height: 18),
        _sectionTitle('Energy usage (kWh)', data.rangeTitle),
        pw.SizedBox(height: 8),
        _chart(data),
        pw.SizedBox(height: 20),
        _sectionTitle('Usage over time', '${data.bars.length} ${data.xAxisTitle.toLowerCase()} periods'),
        pw.SizedBox(height: 8),
        _usageTable(data),
        pw.SizedBox(height: 20),
        _sectionTitle('Usage breakdown', 'By appliance, highest first'),
        pw.SizedBox(height: 8),
        _breakdownTable(data),
      ],
    ),
  );

  return doc.save();
}

// =================================================================
// HEADER / FOOTER
// =================================================================
pw.Widget _brandHeader(pw.MemoryImage logo, ReportPdfData data) {
  return pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.center,
    children: [
      pw.Image(logo, width: 46, height: 46),
      pw.SizedBox(width: 10),
      pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.RichText(
            text: pw.TextSpan(
              style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold),
              children: const [
                pw.TextSpan(text: 'HOME', style: pw.TextStyle(color: _ink)),
                pw.TextSpan(text: 'SYNC', style: pw.TextStyle(color: _brandTeal)),
              ],
            ),
          ),
          pw.Text(
            'SMART ENERGY, SMARTER LIVING',
            style: const pw.TextStyle(fontSize: 7, color: _muted, letterSpacing: 1.6),
          ),
        ],
      ),
      pw.Spacer(),
      pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        children: [
          pw.Text(
            'Energy Consumption Report',
            style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: _text),
          ),
          pw.SizedBox(height: 3),
          pw.Text(data.periodText, style: const pw.TextStyle(fontSize: 9, color: _muted)),
          pw.Text('Generated ${data.generatedText}', style: const pw.TextStyle(fontSize: 8, color: _faint)),
        ],
      ),
    ],
  );
}

pw.Widget _runningHeader(ReportPdfData data) {
  return pw.Container(
    margin: const pw.EdgeInsets.only(bottom: 12),
    padding: const pw.EdgeInsets.only(bottom: 6),
    decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: _line))),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text('HomeSync · Energy Consumption Report', style: const pw.TextStyle(fontSize: 8, color: _muted)),
        pw.Text(data.periodText, style: const pw.TextStyle(fontSize: 8, color: _muted)),
      ],
    ),
  );
}

// The cost disclaimer lives here rather than after the last table, so it
// can never spill onto a page of its own.
pw.Widget _footer(pw.Context context, ReportPdfData data) {
  return pw.Container(
    margin: const pw.EdgeInsets.only(top: 12),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(
          'Generated by HomeSync · Costs are estimates at ${_peso(data.pesoPerKwh)}/kWh and may differ from your bill.',
          style: const pw.TextStyle(fontSize: 7.5, color: _faint),
        ),
        pw.Text(
          'Page ${context.pageNumber} of ${context.pagesCount}',
          style: const pw.TextStyle(fontSize: 8, color: _faint),
        ),
      ],
    ),
  );
}

pw.Widget _sectionTitle(String title, String caption) {
  return pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.end,
    children: [
      pw.Text(title, style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: _text)),
      pw.SizedBox(width: 8),
      pw.Text(caption, style: const pw.TextStyle(fontSize: 9, color: _faint)),
    ],
  );
}

// =================================================================
// SUMMARY CARDS
// =================================================================
pw.Widget _summaryCards(ReportPdfData data) {
  final change = data.changePct;
  // Words rather than arrows: Roboto has no arrow glyphs.
  final changeText = change == null ? '—' : '${change.abs().toStringAsFixed(0)}% ${change <= 0 ? 'lower' : 'higher'}';
  final changeColor = change == null ? _faint : (change <= 0 ? _green : _red);

  pw.Widget card(String title, String value, {PdfColor color = _text, String? note}) {
    return pw.Expanded(
      child: pw.Container(
        height: 60,
        padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: _line),
          borderRadius: pw.BorderRadius.circular(8),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(title, style: const pw.TextStyle(fontSize: 8, color: _muted)),
            pw.SizedBox(height: 4),
            pw.Text(value, style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold, color: color)),
            if (note != null) ...[
              pw.SizedBox(height: 2),
              pw.Text(note, style: const pw.TextStyle(fontSize: 7, color: _faint)),
            ],
          ],
        ),
      ),
    );
  }

  return pw.Row(
    children: [
      card('Total energy', '${_kwh(data.totalKwh)} kWh'),
      pw.SizedBox(width: 8),
      card('Estimated cost', _peso(data.totalKwh * data.pesoPerKwh)),
      pw.SizedBox(width: 8),
      card('vs previous period', changeText, color: changeColor, note: change == null ? 'No earlier data' : null),
      pw.SizedBox(width: 8),
      card('Electricity rate', _peso(data.pesoPerKwh), note: 'per kWh'),
    ],
  );
}

// =================================================================
// BAR CHART
// =================================================================
pw.Widget _chart(ReportPdfData data) {
  final maxValue = data.bars.fold<double>(0, (a, b) => b.kwh > a ? b.kwh : a);
  final axisMax = _niceAxisMax(maxValue);
  final dense = data.bars.length > 12;

  final yLabels = pw.SizedBox(
    width: 28,
    height: _chartHeight,
    child: pw.Column(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      crossAxisAlignment: pw.CrossAxisAlignment.end,
      children: List.generate(6, (i) {
        final v = axisMax * (5 - i) / 5;
        return pw.Text(
          v % 1 == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1),
          style: const pw.TextStyle(fontSize: 7, color: _faint),
        );
      }),
    ),
  );

  final grid = pw.Column(
    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
    children: List.generate(6, (i) => pw.Container(height: 0.5, color: i == 5 ? _faint : _line)),
  );

  final bars = pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.end,
    children: data.bars.map((bar) {
      final height = axisMax <= 0 ? 0.0 : (bar.kwh / axisMax * _chartHeight).clamp(0.0, _chartHeight).toDouble();
      final color = bar.highlighted ? _amber : _teal;
      return pw.Expanded(
        child: pw.Column(
          mainAxisAlignment: pw.MainAxisAlignment.end,
          children: [
            if (bar.kwh > 0)
              pw.Text(_kwhShort(bar.kwh), style: pw.TextStyle(fontSize: dense ? 5 : 7, color: color)),
            pw.SizedBox(height: 2),
            pw.Container(width: dense ? 9 : 22, height: height < 1 && bar.kwh > 0 ? 1 : height, color: color),
          ],
        ),
      );
    }).toList(),
  );

  final xLabels = pw.Row(
    children: data.bars.map((bar) {
      return pw.Expanded(
        child: pw.Center(
          child: pw.Text(
            bar.label,
            style: pw.TextStyle(
              fontSize: dense ? 5.5 : 7.5,
              color: bar.highlighted ? _amber : _muted,
              fontWeight: bar.highlighted ? pw.FontWeight.bold : pw.FontWeight.normal,
            ),
          ),
        ),
      );
    }).toList(),
  );

  pw.Widget legendItem(PdfColor color, String label) => pw.Row(
        children: [
          pw.Container(width: 7, height: 7, color: color),
          pw.SizedBox(width: 4),
          pw.Text(label, style: const pw.TextStyle(fontSize: 8, color: _muted)),
        ],
      );

  return pw.Container(
    padding: const pw.EdgeInsets.fromLTRB(10, 10, 12, 8),
    decoration: pw.BoxDecoration(
      border: pw.Border.all(color: _line),
      borderRadius: pw.BorderRadius.circular(8),
    ),
    child: pw.Column(
      children: [
        pw.Row(
          children: [
            pw.Text('kWh', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: _muted)),
            pw.Spacer(),
            legendItem(_amber, data.currentLegend),
            pw.SizedBox(width: 10),
            legendItem(_teal, 'Earlier'),
          ],
        ),
        pw.SizedBox(height: 8),
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            yLabels,
            pw.SizedBox(width: 6),
            pw.Expanded(
              child: pw.SizedBox(
                height: _chartHeight,
                child: pw.Stack(children: [pw.Positioned.fill(child: grid), pw.Positioned.fill(child: bars)]),
              ),
            ),
          ],
        ),
        pw.SizedBox(height: 4),
        pw.Padding(padding: const pw.EdgeInsets.only(left: 34), child: xLabels),
        pw.SizedBox(height: 6),
        pw.Text(data.xAxisTitle, style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: _muted)),
      ],
    ),
  );
}

// =================================================================
// TABLES
// =================================================================
pw.Widget _table({
  required List<String> headers,
  required List<List<String>> rows,
  required Map<int, pw.Alignment> alignments,
  required Map<int, pw.TableColumnWidth> widths,
  List<String>? totalRow,
}) {
  final body = [...rows, ?totalRow];
  return pw.TableHelper.fromTextArray(
    headers: headers,
    data: body,
    border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: _line, width: 0.5)),
    headerDecoration: const pw.BoxDecoration(color: _mint),
    headerStyle: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: _teal),
    cellStyle: const pw.TextStyle(fontSize: 8.5, color: _text),
    headerAlignments: alignments,
    cellAlignments: alignments,
    columnWidths: widths,
    cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    headerPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
    textStyleBuilder: totalRow == null
        ? null
        : (index, data, rowNum) => rowNum == body.length
            ? pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: _text)
            : null,
  );
}

pw.Widget _usageTable(ReportPdfData data) {
  return _table(
    headers: [data.xAxisTitle, 'Energy (kWh)', 'Estimated cost'],
    rows: [
      for (final bar in data.bars) [bar.detail, _kwh(bar.kwh), _peso(bar.kwh * data.pesoPerKwh)],
    ],
    totalRow: ['Total', _kwh(data.totalKwh), _peso(data.totalKwh * data.pesoPerKwh)],
    alignments: const {0: pw.Alignment.centerLeft, 1: pw.Alignment.centerRight, 2: pw.Alignment.centerRight},
    widths: const {0: pw.FlexColumnWidth(3), 1: pw.FlexColumnWidth(1.4), 2: pw.FlexColumnWidth(1.4)},
  );
}

pw.Widget _breakdownTable(ReportPdfData data) {
  if (data.appliances.isEmpty) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 10),
      child: pw.Text('No appliances in this household yet.', style: const pw.TextStyle(fontSize: 9, color: _faint)),
    );
  }
  return _table(
    headers: ['Appliance', 'Room', 'Type', 'Energy (kWh)', 'Share', 'Estimated cost'],
    rows: [
      for (final a in data.appliances)
        [
          a.name,
          a.room.isEmpty ? '—' : a.room,
          a.type,
          _kwh(a.kwh),
          data.totalKwh > 0 ? '${(a.kwh / data.totalKwh * 100).toStringAsFixed(1)}%' : '0.0%',
          _peso(a.kwh * data.pesoPerKwh),
        ],
    ],
    totalRow: ['Total', '', '', _kwh(data.totalKwh), data.totalKwh > 0 ? '100%' : '0.0%', _peso(data.totalKwh * data.pesoPerKwh)],
    alignments: const {
      0: pw.Alignment.centerLeft,
      1: pw.Alignment.centerLeft,
      2: pw.Alignment.centerLeft,
      3: pw.Alignment.centerRight,
      4: pw.Alignment.centerRight,
      5: pw.Alignment.centerRight,
    },
    widths: const {
      0: pw.FlexColumnWidth(2.4),
      1: pw.FlexColumnWidth(1.6),
      2: pw.FlexColumnWidth(1.2),
      3: pw.FlexColumnWidth(1.3),
      4: pw.FlexColumnWidth(0.9),
      5: pw.FlexColumnWidth(1.4),
    },
  );
}

// =================================================================
// FORMATTING
// =================================================================
double _niceAxisMax(double value) {
  if (value <= 0) return 5;
  final raw = value * 1.15;
  double step;
  if (raw <= 1) {
    step = 0.2;
  } else if (raw <= 10) {
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

String _kwh(double v) => v.toStringAsFixed(2);

String _kwhShort(double v) {
  if (v < 1) return v.toStringAsFixed(2);
  if (v < 100) return v.toStringAsFixed(1);
  return v.toStringAsFixed(0);
}

String _peso(double v) {
  final fixed = v.toStringAsFixed(2);
  final parts = fixed.split('.');
  final digits = parts[0].replaceFirst('-', '');
  final buffer = StringBuffer();
  for (int i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return '${v < 0 ? '-' : ''}₱$buffer.${parts[1]}';
}
