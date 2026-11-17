// records every write the real TicketingRepository makes during a full set of
// job flows, and saves them with the starting inventory to
// rules_test/fixtures/writes.json. the emulator tests replay them in order,
// each as the user who made it, so the security rules are tested against
// exactly what the app sends rather than a hand-written copy.
//
// run from the ticketing/ folder after changing the repository:
//   dart run tool/export_rule_fixtures.dart
// (test/rules_fixtures_test.dart fails if the file is out of date)
//
// only imports pure-Dart files, so it runs without Flutter.

import 'dart:convert';
import 'dart:io';

import 'package:lsi_ticketing/src/data/memory_ticketing_store.dart';
import 'package:lsi_ticketing/src/data/ticketing_repository.dart';
import 'package:lsi_ticketing/src/models/enums.dart';
import 'package:lsi_ticketing/src/models/job.dart';
import 'package:lsi_ticketing/src/rules/permissions.dart';

// starting inventory, shaped like lsicompapp's inventory page items
const Map<String, Object?> fixtureInventory = {
  '-invFingertip': {'name': 'Fingertip', 'itemNumber': 'FT-01', 'stock': 12, 'threshold': 4, 'type': 'Parts'},
  '-invPalm': {'name': 'Left Palm Plate', 'itemNumber': 'LP-02', 'stock': 3, 'threshold': 1, 'type': 'Parts'},
  '-invBase': {'name': 'Index Base', 'itemNumber': 'IB-03', 'stock': 4, 'threshold': 1, 'type': 'Parts'},
};

class _Step {
  _Step(this.label, this.user, this.update);
  final String label;
  final String user;
  final Map<String, Object?> update;
  Map<String, Object?> toJson() => {'label': label, 'user': user, 'update': update};
}

// a memory store that also keeps a copy of every write
class _RecordingStore extends MemoryTicketingStore {
  _RecordingStore() : super({'inventory': fixtureInventory});

  final steps = <_Step>[];
  String label = '';
  String user = '';

  @override
  Future<void> update(Map<String, Object?> values) async {
    await super.update(values);
    steps.add(_Step(label, user, jsonDecode(jsonEncode(values)) as Map<String, Object?>));
  }

  @override
  Future<int> nextNumber(String counterPath) async {
    final n = await super.nextNumber(counterPath);
    steps.add(_Step('$label (job number)', user, {counterPath: n}));
    return n;
  }
}

Future<List<Map<String, Object?>>> recordWrites() async {
  final store = _RecordingStore();
  final users = {
    'adm': const TicketingUser(uid: 'adm', role: Role.admin),
    'req': const TicketingUser(uid: 'req', role: Role.member, departments: {'Finishing'}),
    'man': const TicketingUser(uid: 'man', role: Role.member, departments: {'Manufacturing'}),
    'man2': const TicketingUser(uid: 'man2', role: Role.member, departments: {'Manufacturing'}),
    'qa': const TicketingUser(uid: 'qa', role: Role.member, departments: {'Quality'}),
  };
  var minute = 0;
  Future<T> as<T>(String uid, String label, Future<T> Function(TicketingRepository r) action) {
    store
      ..user = uid
      ..label = label;
    final repo = TicketingRepository(
        store: store, user: users[uid]!, clock: () => DateTime.utc(2026, 11, 12, 9, minute++));
    return action(repo);
  }

  // a full job: submit with a first comment, edit, claim (takes stock), a
  // second claimer, comments, one claimer leaves, then defects -> remake
  final due = DateTime.utc(2026, 11, 30);
  final arm = await as('req', 'requester submits a job with a first comment', (r) => r.createJob(
      jobName: 'Left arm for patient A', requestedBy: 'req', dueDate: due, priority: JobPriority.high,
      parts: {'-invFingertip': 5, '-invPalm': 1}, comment: 'Blue, size M'));
  await as('req', 'requester edits name, due date, priority and parts before a claim', (r) => r.editJob(arm.jobId,
      jobName: 'Left arm, patient A', dueDate: DateTime.utc(2026, 12, 2), priority: () => JobPriority.medium,
      parts: {'-invFingertip': 5, '-invPalm': 1, '-invBase': 2}));
  await as('man', 'first claim takes the parts from inventory', (r) => r.claim(arm.jobId));
  await as('man2', 'a second scholar joins', (r) => r.claim(arm.jobId));
  await as('req', 'requester edits the name while in progress', (r) => r.editJob(arm.jobId, jobName: 'Left arm, patient A (rush)'));
  final c1 = await as('req', 'requester comments', (r) => r.addComment(arm.jobId, 'Thnks'));
  final c2 = await as('man2', 'claimer comments', (r) => r.addComment(arm.jobId, 'On it'));
  await as('qa', 'quality comments', (r) => r.addComment(arm.jobId, 'Inspected'));
  await as('req', 'author edits a comment', (r) => r.editComment(c1.id, 'Thanks!'));
  await as('man2', 'author deletes a comment', (r) => r.deleteComment(c2.id));
  await as('man', 'one claimer leaves; parts stay with the job', (r) => r.unclaim(arm.jobId));
  // man2 creates the remake and is added as its claimer, pulling the replacements
  final remake = await as('man2', 'a claimer reports defects: remake ticket created, job closed as remade',
      (r) => r.createRemake(arm.jobId, defects: {
            '-invFingertip': const Defect(count: 1, reason: 'cracked at the joint'),
            '-invBase': const Defect(count: 1),
          }, comment: 'Replacing the cracked fingertip and a warped base'));
  await as('man', 'another scholar joins the remake', (r) => r.claim(remake.jobId));
  await as('man', 'the remake is completed', (r) => r.complete(remake.jobId));

  // submitted on someone's behalf; the last claimer leaves, so everything goes back
  final spare = await as('adm', 'an admin submits a job on behalf of a scholar', (r) => r.createJob(
      jobName: 'Spare hand', requestedBy: 'req', dueDate: due, parts: {'-invFingertip': 2, '-invPalm': 1}));
  await as('req', 'the scholar it is for changes the requester', (r) => r.editJob(spare.jobId, requestedBy: 'man2'));
  await as('man', 'claim the spare job', (r) => r.claim(spare.jobId));
  await as('man', 'last claimer leaves; parts go back', (r) => r.unclaim(spare.jobId));
  await as('man2', 'the new requester cancels the requested job', (r) => r.cancel(spare.jobId));

  // quality finds a defect after completion; the remake waits for stock
  final base = await as('req', 'requester submits a job for the last base', (r) => r.createJob(
      jobName: 'Index finger', requestedBy: 'req', dueDate: due, parts: {'-invBase': 1}));
  await as('man', 'claim takes the last base', (r) => r.claim(base.jobId));
  await as('man', 'complete the index finger', (r) => r.complete(base.jobId));
  // no bases left, so quality's remake waits unclaimed in requested
  final qcRemake = await as('qa', 'quality reports a defect on a completed job',
      (r) => r.createRemake(base.jobId, defects: {'-invBase': const Defect(count: 1, reason: 'bent in QC')}));
  store
    ..user = 'adm'
    ..label = 'the inventory page receives more bases';
  await store.update({'inventory/-invBase/stock': 3});
  await as('man2', 'claim the quality remake once stock is back', (r) => r.claim(qcRemake.jobId));

  // admin actions
  final extra = await as('req', 'requester submits a job an admin will manage', (r) => r.createJob(
      jobName: 'Extra fingertips', requestedBy: 'req', dueDate: due, priority: JobPriority.low, parts: {'-invFingertip': 1}));
  await as('man', 'claim before the admin steps in', (r) => r.claim(extra.jobId));
  await as('adm', 'admin unclaims someone else, returning parts', (r) => r.unclaim(extra.jobId, claimerUid: 'man'));
  await as('man2', 'claim again', (r) => r.claim(extra.jobId));
  await as('man2', 'a claimer adds another scholar to the job', (r) => r.addClaimer(extra.jobId, 'qa'));
  await as('adm', 'admin cancels an in-progress job, returning parts', (r) => r.cancel(extra.jobId));
  await as('adm', 'admin deletes someone else\'s comment', (r) async {
    final comments = await r.commentsForJob(arm.jobId);
    return r.deleteComment(comments.firstWhere((c) => c.author == 'qa').id);
  });

  return store.steps.map((s) => s.toJson()).toList();
}

String fixturesJson(List<Map<String, Object?>> steps) =>
    '${const JsonEncoder.withIndent('  ').convert({'inventory': fixtureInventory, 'writes': steps})}\n';

Future<void> main() async {
  final file = File('rules_test/fixtures/writes.json');
  final steps = await recordWrites();
  file.writeAsStringSync(fixturesJson(steps));
  stdout.writeln('wrote ${steps.length} writes to ${file.path}');
}
