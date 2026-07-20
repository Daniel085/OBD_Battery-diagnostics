import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../app/app_controller.dart';
import '../engine/battery_health.dart';
import 'report_pdf.dart';

class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key});

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  final _vinController = TextEditingController();

  Color _sevColor(BuildContext context, Severity s) {
    switch (s) {
      case Severity.ok:
        return Colors.green.shade700;
      case Severity.info:
        return Colors.blue.shade700;
      case Severity.warning:
        return Colors.orange.shade800;
      case Severity.critical:
        return Colors.red.shade800;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.read<AppController>();
    final vin = _vinController.text.trim();
    final report = c.buildReport(vin: vin.isEmpty ? null : vin);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Battery Health Report'),
        actions: [
          IconButton(
            tooltip: 'Print / save PDF',
            icon: const Icon(Icons.picture_as_pdf),
            onPressed: () async {
              final bytes = await buildReportPdf(report);
              await Printing.layoutPdf(onLayout: (_) async => bytes);
            },
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              final text = v == 'json'
                  ? report.toJsonString()
                  : report.toReadingsCsv();
              await Share.share(text,
                  subject: 'Battery report ${report.vehicle}');
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'csv', child: Text('Share CSV')),
              PopupMenuItem(value: 'json', child: Text('Share JSON')),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _sevColor(context, report.overallSeverity),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'Overall: ${report.overallSeverity.name.toUpperCase()}',
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _vinController,
            decoration: const InputDecoration(
              labelText: 'VIN (optional, for the report)',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 20),
          Text('Metrics', style: Theme.of(context).textTheme.titleMedium),
          ...report.metrics.entries.map((e) => ListTile(
                dense: true,
                title: Text(e.key),
                trailing: Text(e.value?.toStringAsFixed(3) ?? '—'),
              )),
          const SizedBox(height: 12),
          Text('Warnings', style: Theme.of(context).textTheme.titleMedium),
          ...report.warnings.map((w) => ListTile(
                leading: Icon(Icons.circle,
                    size: 12, color: _sevColor(context, w.severity)),
                title: Text(w.message),
                subtitle: Text(w.code),
              )),
          const SizedBox(height: 12),
          ExpansionTile(
            title: const Text('Raw JSON'),
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  const JsonEncoder.withIndent('  ').convert(report.toJson()),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _vinController.dispose();
    super.dispose();
  }
}
