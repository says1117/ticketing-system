// what the deployment tools (tool/merge_rules.dart, tool/check_live_data.dart)
// report, and how they print it.

import 'dart:io';

enum FindingLevel {
  // ticketing won't be safe or won't work until this is fixed
  blocker,
  // a person has to read this and confirm it
  check,
  // for the record
  info,
}

class Finding {
  const Finding(this.level, this.message);
  final FindingLevel level;
  final String message;

  @override
  String toString() => '${level.name.toUpperCase()}: $message';
}

bool hasBlockers(Iterable<Finding> findings) =>
    findings.any((f) => f.level == FindingLevel.blocker);

// prints findings grouped by level, blockers first
void printFindings(Iterable<Finding> findings, [IOSink? out]) {
  final sink = out ?? stdout;
  for (final level in FindingLevel.values) {
    final found = findings.where((f) => f.level == level);
    if (found.isEmpty) continue;
    sink.writeln('\n${level.name.toUpperCase()}');
    for (final f in found) {
      sink.writeln('- ${f.message}');
    }
  }
}
