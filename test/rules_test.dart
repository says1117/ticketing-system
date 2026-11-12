// checks on the generated security rules. these don't run the rules (that's
// rules_test/, in the Firebase emulator); they make sure the JSON is current
// and lines up with the Dart code. run with: flutter test test/rules_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lsi_ticketing/lsi_ticketing.dart';

import '../tool/rules_source.dart';

void main() {
  final rules = buildTicketingRules();
  final ticketing = (rules['rules'] as Map)['ticketing'] as Map;
  final job = (ticketing['jobs'] as Map)['\$jobId'] as Map;
  final line = (job['lines'] as Map)['\$itemId'] as Map;

  test('rules/ticketing.rules.json is up to date (run dart run tool/build_rules.dart)', () {
    expect(File('rules/ticketing.rules.json').readAsStringSync(), ticketingRulesJson());
    expect(() => jsonDecode(ticketingRulesJson()), returnsNormally);
  });

  test('only ticketing/ is covered; inventory keeps its own rules', () {
    expect((rules['rules'] as Map).keys, ['ticketing']);
  });

  test('every status and history type is allowed', () {
    final status = (job['status'] as Map)['.validate'] as String;
    for (final s in JobStatus.values) {
      expect(status, contains(s.name));
    }
    final types = (((ticketing['history'] as Map)['\$historyId'] as Map)['type'] as Map)['.validate'] as String;
    for (final t in HistoryType.values) {
      expect(types, contains(t.name));
    }
  });

  test('every model field has a rule and unknown fields are refused', () {
    final now = DateTime.utc(2026);
    final fields = Job(
      jobId: 'JOB-0001', jobName: 'n', requestedBy: 'u', submittedBy: 'u', priority: JobPriority.low,
      lines: const {'-a': JobLine(itemId: '-a', quantity: 1)}, claimers: {'u': now},
      status: JobStatus.completed, neededBy: now, createdAt: now, updatedAt: now,
      claimedAt: now, completedAt: now, lastHistoryId: 'h',
    ).toJson().keys;
    for (final f in fields) {
      expect(job.containsKey(f), isTrue, reason: 'job field $f has no rule');
    }
    for (final f in const JobLine(itemId: '-a', quantity: 1).toJson().keys) {
      expect(line.containsKey(f), isTrue, reason: 'line field $f has no rule');
    }
    expect((job['\$other'] as Map)['.validate'], 'false');
    expect((line['\$other'] as Map)['.validate'], 'false');
  });

  test('each line checks its stock change against what the job took', () {
    final v = line['.validate'] as String;
    expect(v, contains("child('inventory/' + \$itemId + '/stock')"));
    expect(v, contains('=== 0 - ((newData'));
    expect(v, contains('>= 0'));
  });

  test('jobs can\'t be deleted, every save links a new history row and bumps rev', () {
    expect(job['.write'], contains('newData.exists()'));
    final v = job['.validate'] as String;
    expect(v, contains("!root.child('ticketing/history/'"));
    expect(v, contains("data.child('rev').val() + 1"));
  });

  test('roles come only from orgData', () {
    expect(jsonEncode(rules), isNot(contains('ticketing/roles')));
    expect(jsonEncode(rules), contains("orgData/status').val() === 'OrgStatus.admin'"));
  });
}
