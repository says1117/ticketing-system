// writes rules/ticketing.rules.json from tool/rules_source.dart
// run from the ticketing/ folder:  dart run tool/build_rules.dart

import 'dart:io';

import 'rules_source.dart';

void main() {
  final file = File('rules/ticketing.rules.json');
  file.writeAsStringSync(ticketingRulesJson());
  stdout.writeln('wrote ${file.path}');
}
