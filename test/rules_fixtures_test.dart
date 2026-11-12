// the emulator tests replay rules_test/fixtures/writes.json; this makes sure it
// still matches what the repository writes. if it fails, run:
//   dart run tool/export_rule_fixtures.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/export_rule_fixtures.dart';

void main() {
  test('rules_test/fixtures/writes.json is up to date', () async {
    expect(File('rules_test/fixtures/writes.json').readAsStringSync(), fixturesJson(await recordWrites()));
  });
}
