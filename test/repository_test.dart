// the repository against the in-memory store, which also enforces the rev and
// stock rules the security rules do. run with:
//   flutter test test/repository_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:lsi_ticketing/lsi_ticketing.dart';

const requester = TicketingUser(uid: 'req', role: Role.member, departments: {'Finishing'});
const maker = TicketingUser(uid: 'man', role: Role.member, departments: {'Manufacturing'});
const maker2 = TicketingUser(uid: 'man2', role: Role.member, departments: {'Manufacturing'});
const outsider = TicketingUser(uid: 'out', role: Role.member, departments: {'Web Design'});
const qa = TicketingUser(uid: 'qa', role: Role.member, departments: {'Quality'});
const admin = TicketingUser(uid: 'adm', role: Role.admin);

const fingertip = '-invFingertip';
const palm = '-invPalm';

late MemoryTicketingStore store;
late DateTime clockTime;

TicketingRepository repo(TicketingUser user) => TicketingRepository(store: store, user: user, clock: () => clockTime);

Matcher throwsTicketing([Object? message]) => throwsA(
    isA<TicketingException>().having((e) => e.message, 'message', message == null ? anything : contains(message)));

Future<int> stockOf(String itemId) async => (await repo(admin).getInventoryItem(itemId))!.stock;

Future<void> setStock(String itemId, int n) => store.update({'inventory/$itemId/stock': n});

// every job must point at a history row that names it
Future<void> expectLogConsistent() async {
  final data = store.data;
  final history = ((data['ticketing'] as Map?)?['history'] as Map?) ?? {};
  for (final e in (((data['ticketing'] as Map?)?['jobs'] as Map?) ?? {}).entries) {
    final row = history[(e.value as Map)['lastHistoryId']] as Map?;
    expect(row, isNotNull, reason: 'job ${e.key} has no history row');
    expect(row!['jobId'], e.key);
  }
}

final due = DateTime.utc(2026, 12, 1);

Future<Job> armJob({int fingertips = 5, int palms = 1}) => repo(requester).createJob(
      jobName: 'Left arm, patient A',
      requestedBy: 'req',
      dueDate: due,
      parts: {fingertip: fingertips, palm: palms},
    );

void main() {
  setUp(() {
    clockTime = DateTime.utc(2026, 11, 12, 9);
    store = MemoryTicketingStore({
      'inventory': {
        fingertip: {'name': 'Fingertip', 'stock': 12, 'threshold': 4},
        palm: {'name': 'Left Palm Plate', 'stock': 3, 'threshold': 1},
      },
    });
  });
  tearDown(() => store.dispose());

  group('popup streams', () {
    test('watchJob emits the initial value, updates and deletion', () async {
      final job = await armJob();
      final events = <Job?>[];
      final subscription = repo(requester).watchJob(job.jobId).listen(events.add);
      await Future<void>.delayed(Duration.zero);
      await repo(maker).claim(job.jobId);
      await Future<void>.delayed(Duration.zero);
      await store.update({'ticketing/jobs/${job.jobId}': null});
      await Future<void>.delayed(Duration.zero);
      expect(events.first!.status, JobStatus.requested);
      expect(events.any((j) => j?.status == JobStatus.inProgress), isTrue);
      expect(events.last, isNull);
      await subscription.cancel();
    });

    test('watchCommentsForJob filters other jobs and reflects edits and deletes', () async {
      final job = await armJob();
      final other = await armJob();
      final events = <List<Comment>>[];
      final subscription = repo(requester).watchCommentsForJob(job.jobId).listen(events.add);
      await Future<void>.delayed(Duration.zero);
      expect(events.single, isEmpty);
      await repo(requester).addComment(other.jobId, 'Other job');
      final comment = await repo(requester).addComment(job.jobId, 'First');
      await Future<void>.delayed(Duration.zero);
      expect(events.last.single.text, 'First');
      await repo(requester).editComment(comment.id, 'Edited');
      await Future<void>.delayed(Duration.zero);
      expect(events.last.single.text, 'Edited');
      await repo(requester).deleteComment(comment.id);
      await Future<void>.delayed(Duration.zero);
      expect(events.last, isEmpty);
      await subscription.cancel();
    });
  });

  group('submit a job', () {
    test('saves name, requester, due date, parts and status, with a history row', () async {
      final j = await armJob();
      expect([j.jobId, j.jobName, j.requestedBy, j.submittedBy, j.neededBy, j.priority, j.status, j.createdAt],
          ['JOB-0001', 'Left arm, patient A', 'req', 'req', due, null, JobStatus.requested, clockTime]);
      expect(j.lines.map((k, v) => MapEntry(k, v.quantity)), {fingertip: 5, palm: 1});
      expect((await repo(admin).getJob(j.jobId))!.toJson(), j.toJson());
      expect((await repo(admin).historyForJob(j.jobId)).single.type, HistoryType.created);
      expect(await stockOf(fingertip), 12, reason: 'submitting takes nothing');
      await expectLogConsistent();
    });

    test('the form\'s comment becomes the first comment, saved with the job', () async {
      final before = store.updateCount;
      final j = await repo(requester).createJob(
          jobName: 'Arm', requestedBy: 'req', dueDate: due, priority: JobPriority.high, parts: {fingertip: 1}, comment: ' Blue please ');
      expect(store.updateCount, before + 1);
      expect(j.priority, JobPriority.high);
      final c = (await repo(admin).commentsForJob(j.jobId)).single;
      expect([c.text, c.author], ['Blue please', 'req']);
    });

    test('submitting on behalf of another scholar records both people', () async {
      final j = await repo(admin).createJob(jobName: 'Arm', requestedBy: 'req', dueDate: due, parts: {fingertip: 1});
      expect([j.requestedBy, j.submittedBy], ['req', 'adm']);
      // the scholar it's for can edit it and hand it to someone else
      expect((await repo(requester).editJob(j.jobId, requestedBy: 'man')).requestedBy, 'man');
      expect((await repo(maker).cancel(j.jobId)).status, JobStatus.cancelled);
    });

    test('job numbers count up', () async {
      expect([(await armJob()).jobId, (await armJob()).jobId], ['JOB-0001', 'JOB-0002']);
    });

    test('rejects a missing name, no parts, bad quantities and unknown parts', () async {
      final r = repo(requester);
      Future<Job> make({String name = 'A', String by = 'req', Map<String, int> parts = const {fingertip: 1}}) =>
          r.createJob(jobName: name, requestedBy: by, dueDate: due, parts: parts);
      await expectLater(make(name: ' '), throwsTicketing('name'));
      await expectLater(make(by: ' '), throwsTicketing('who the job is for'));
      await expectLater(make(parts: {}), throwsTicketing('at least one part'));
      await expectLater(make(parts: {fingertip: 0}), throwsTicketing('at least 1'));
      await expectLater(make(parts: {'-nope': 1}), throwsTicketing('no longer in inventory'));
    });
  });

  group('claim reserves parts', () {
    test('the first claim takes every part out of inventory, in one save', () async {
      final j = await armJob();
      final before = store.updateCount;
      final claimed = await repo(maker).claim(j.jobId);
      expect(store.updateCount, before + 1);
      expect([claimed.status, claimed.claimers.keys.toList(), claimed.claimedAt], [JobStatus.inProgress, ['man'], clockTime]);
      expect(claimed.lines[fingertip]!.held, 5);
      expect([await stockOf(fingertip), await stockOf(palm)], [7, 2]);
      final reserved = (await repo(admin).historyForItem(fingertip)).single;
      expect([reserved.type, reserved.quantityChange, reserved.from, reserved.to], [HistoryType.reserved, -5, '12', '7']);
      await expectLogConsistent();
    });

    test('exactly enough on hand is fine', () async {
      await setStock(fingertip, 5);
      final j = await armJob();
      await repo(maker).claim(j.jobId);
      expect(await stockOf(fingertip), 0);
    });

    test('short stock blocks the claim and nothing changes', () async {
      await setStock(palm, 0);
      final j = await armJob();
      await expectLater(repo(maker).claim(j.jobId), throwsTicketing('Left Palm Plate (need 1, 0 on hand)'));
      expect([await stockOf(fingertip), await stockOf(palm)], [12, 0]);
      expect((await repo(admin).getJob(j.jobId))!.status, JobStatus.requested);
    });

    test('anyone can claim, and others join without taking more parts', () async {
      final j = await armJob();
      await repo(requester).claim(j.jobId);
      final joined = await repo(maker2).claim(j.jobId);
      expect(joined.claimers.keys, unorderedEquals(['req', 'man2']));
      expect(await stockOf(fingertip), 7);
    });

    test('two jobs racing for the last parts: the second sees the new count and is blocked', () async {
      await setStock(fingertip, 6);
      final a = await armJob();
      final b = await armJob();
      // job a takes 5 between b reading the stock and saving
      store.beforeUpdate = () => repo(maker).claim(a.jobId);
      await expectLater(repo(maker2).claim(b.jobId), throwsTicketing('Fingertip (need 5, 1 on hand)'));
      expect(await stockOf(fingertip), 1);
    });

    test('a stock change from the inventory page mid-claim is picked up on retry', () async {
      final j = await armJob();
      store.beforeUpdate = () => setStock(fingertip, 20);
      await repo(maker).claim(j.jobId);
      expect(await stockOf(fingertip), 15);
    });
  });

  group('unclaim', () {
    test('one of several claimers leaves: parts stay with the job', () async {
      final j = await armJob();
      await repo(maker).claim(j.jobId);
      await repo(maker2).claim(j.jobId);
      final left = await repo(maker).unclaim(j.jobId);
      expect([left.status, left.claimers.keys.toList()], [JobStatus.inProgress, ['man2']]);
      expect(await stockOf(fingertip), 7);
    });

    test('the last claimer leaves: the full amount goes back and the job is requested again', () async {
      final j = await armJob();
      await repo(maker).claim(j.jobId);
      final back = await repo(maker).unclaim(j.jobId);
      expect([back.status, back.claimers, back.claimedAt], [JobStatus.requested, isEmpty, isNull]);
      expect([await stockOf(fingertip), await stockOf(palm)], [12, 3]);
      final returned = (await repo(admin).historyForItem(fingertip)).last;
      expect([returned.type, returned.quantityChange], [HistoryType.returned, 5]);
      await expectLogConsistent();
    });

    test('only admins can unclaim someone else', () async {
      final j = await armJob();
      await repo(maker).claim(j.jobId);
      await expectLater(repo(maker2).unclaim(j.jobId, claimerUid: 'man'), throwsTicketing('Only admins'));
      await repo(admin).unclaim(j.jobId, claimerUid: 'man');
      expect(await stockOf(fingertip), 12);
    });
  });

  group('add claimer', () {
    test('a claimer adds a teammate without taking more parts, logged as theirs', () async {
      final j = await armJob();
      await repo(maker).claim(j.jobId);
      final added = await repo(maker).addClaimer(j.jobId, 'qa');
      expect(added.claimers.keys, containsAll(['man', 'qa']));
      expect(await stockOf(fingertip), 7);
      final rows = await repo(admin).historyForJob(j.jobId);
      expect(rows.last.type, HistoryType.claimed);
      expect(rows.last.user, 'man');
      expect(rows.last.to, 'qa');
      await expectLogConsistent();
    });
    test('the added scholar can leave on their own; the job keeps its parts', () async {
      final j = await armJob();
      await repo(maker).claim(j.jobId);
      await repo(maker).addClaimer(j.jobId, 'qa');
      await repo(qa).unclaim(j.jobId);
      expect((await repo(admin).getJob(j.jobId))!.claimers.keys, ['man']);
      expect(await stockOf(fingertip), 7);
    });
    test('not by someone off the job, not before a claim, not twice', () async {
      final j = await armJob();
      await expectLater(repo(admin).addClaimer(j.jobId, 'qa'), throwsTicketing('Claim the job'));
      await repo(maker).claim(j.jobId);
      await expectLater(repo(outsider).addClaimer(j.jobId, 'qa'), throwsTicketing('Only people who claimed'));
      await expectLater(repo(maker).addClaimer(j.jobId, 'man'), throwsTicketing('already on'));
      await expectLater(repo(maker).addClaimer(j.jobId, ' '), throwsTicketing('Choose a scholar'));
    });
  });

  group('remakes', () {
    Future<Job> claimedArm() async {
      final j = await armJob(); // 5 fingertips, 1 palm
      await repo(maker).claim(j.jobId); // fingertip 12 -> 7, palm 3 -> 2
      return j;
    }

    test('creates a Remake ticket from the job and closes the job as remade; the creator claims it', () async {
      final j = await claimedArm();
      final before = store.updateCount;
      final r = await repo(maker).createRemake(j.jobId,
          defects: {fingertip: const Defect(count: 2, reason: ' cracked ')}, comment: 'Two tips cracked');
      expect(store.updateCount, before + 2, reason: 'create + close in one save, then the claim');

      // starts with the same info, ordering only the defective parts, claimed
      // only by the person who created it (the original's claimers aren't carried over)
      expect([r.jobId, r.isRemake, r.remakeOf, r.jobName, r.requestedBy, r.submittedBy, r.neededBy, r.status],
          ['JOB-0002', true, j.jobId, j.jobName, 'req', 'man', due, JobStatus.inProgress]);
      expect(r.claimers.keys, ['man']);
      expect(r.lines.map((k, v) => MapEntry(k, v.quantity)), {fingertip: 2});
      expect(r.usedParts, {fingertip: 5, palm: 1}, reason: 'the full parts list of the original');
      expect([r.defects[fingertip]!.count, r.defects[fingertip]!.reason], [2, 'cracked']);
      expect((await repo(admin).commentsForJob(r.jobId)).single.text, 'Two tips cracked');

      final old = (await repo(admin).getJob(j.jobId))!;
      expect([old.status, old.remadeAs, old.lines[fingertip]!.held, old.lines[fingertip]!.scrapped],
          [JobStatus.remade, r.jobId, 3, 2]);
      expect(await stockOf(fingertip), 5, reason: 'defectives not returned (7), 2 replacements pulled (5)');
      await expectLogConsistent();
    });

    test('the original\'s other claimers are not carried over', () async {
      final j = await claimedArm();
      await repo(maker2).claim(j.jobId);
      final r = await repo(qa).createRemake(j.jobId, defects: {fingertip: const Defect(count: 1)});
      expect(r.claimers.keys, ['qa']);
      expect((await repo(qa).complete(r.jobId)).status, JobStatus.completed);
    });

    test('if a replacement is short, the remake waits unclaimed in requested', () async {
      final j = await claimedArm();
      await setStock(palm, 0);
      final r = await repo(maker).createRemake(j.jobId, defects: {palm: const Defect(count: 1)});
      expect([r.status, r.claimers], [JobStatus.requested, isEmpty]);
      expect((await repo(admin).getJob(j.jobId))!.status, JobStatus.remade, reason: 'the defect is still recorded');
      await setStock(palm, 2); // the inventory page receives more
      expect((await repo(maker2).claim(r.jobId)).status, JobStatus.inProgress);
      expect(await stockOf(palm), 1);
    });

    test('works on a completed job, e.g. a defect found in quality checks', () async {
      final j = await claimedArm();
      await repo(maker).complete(j.jobId);
      final r = await repo(qa).createRemake(j.jobId, defects: {palm: const Defect(count: 1, reason: 'bent in QC')},
          jobName: 'Left arm, patient A (QC remake)', priority: () => JobPriority.high);
      expect([r.jobName, r.priority, r.submittedBy], ['Left arm, patient A (QC remake)', JobPriority.high, 'qa']);
      expect((await repo(admin).getJob(j.jobId))!.status, JobStatus.remade);
    });

    test('a remake can itself be remade, and the chain can be followed', () async {
      final j = await claimedArm();
      final r1 = await repo(maker).createRemake(j.jobId, defects: {fingertip: const Defect(count: 1)});
      final r2 = await repo(maker).createRemake(r1.jobId, defects: {fingertip: const Defect(count: 1)});
      expect((await repo(admin).remakeChain(j.jobId)).map((x) => x.jobId), [r1.jobId, r2.jobId]);
    });

    test('rejects no defects, bad counts, parts not on the job, and more than the job has', () async {
      final j = await claimedArm();
      final r = repo(maker);
      await expectLater(r.createRemake(j.jobId, defects: {}), throwsTicketing('at least one defective part'));
      await expectLater(r.createRemake(j.jobId, defects: {fingertip: const Defect(count: 0)}), throwsTicketing('at least 1'));
      await expectLater(r.createRemake(j.jobId, defects: {'-other': const Defect(count: 1)}), throwsTicketing('isn\'t on this job'));
      await expectLater(r.createRemake(j.jobId, defects: {palm: const Defect(count: 2)}), throwsTicketing('only has 1'));
      expect((await repo(admin).getJob(j.jobId))!.status, JobStatus.inProgress);
    });

    test('not from a requested or closed job, and not by someone off the job', () async {
      final j = await armJob();
      await expectLater(repo(maker).createRemake(j.jobId, defects: {fingertip: const Defect(count: 1)}),
          throwsTicketing('in progress or completed'));
      await repo(maker).claim(j.jobId);
      await expectLater(repo(outsider).createRemake(j.jobId, defects: {fingertip: const Defect(count: 1)}),
          throwsTicketing('Only people on this job'));
      await repo(maker).createRemake(j.jobId, defects: {fingertip: const Defect(count: 1)});
      await expectLater(repo(maker).createRemake(j.jobId, defects: {fingertip: const Defect(count: 1)}),
          throwsTicketing('in progress or completed'));
    });
  });

  group('complete', () {
    test('closes the job; stock doesn\'t change because the parts were taken at claim', () async {
      final j = await armJob();
      await repo(maker).claim(j.jobId);
      final done = await repo(maker).complete(j.jobId);
      expect([done.status, done.completedAt], [JobStatus.completed, clockTime]);
      expect(await stockOf(fingertip), 7);
      await expectLater(repo(maker).unclaim(j.jobId), throwsTicketing('completed'));
    });
  });

  group('requester edits and cancels', () {
    test('changes name, due date, priority and parts before a claim, with a before/after history row', () async {
      final j = await armJob();
      final e = await repo(requester).editJob(j.jobId,
          jobName: 'Right arm', parts: {fingertip: 3}, dueDate: DateTime.utc(2026, 12, 9), priority: () => JobPriority.low);
      expect([e.jobName, e.lines.keys.toList(), e.neededBy, e.priority], ['Right arm', [fingertip], DateTime.utc(2026, 12, 9), JobPriority.low]);
      final row = (await repo(admin).historyForJob(j.jobId)).last;
      expect(row.type, HistoryType.edited);
      expect(row.from, contains('Left arm'));
      expect(row.to, contains('Right arm'));
    });

    test('parts are locked once claimed; name and priority are not', () async {
      final j = await armJob();
      await repo(maker).claim(j.jobId);
      await expectLater(repo(requester).editJob(j.jobId, parts: {fingertip: 1}), throwsTicketing('Unclaim it first'));
      expect((await repo(requester).editJob(j.jobId, priority: () => JobPriority.high)).priority, JobPriority.high);
    });

    test('saving with nothing changed writes nothing', () async {
      final j = await armJob();
      final before = store.updateCount;
      await repo(requester).editJob(j.jobId, jobName: 'Left arm, patient A', parts: {palm: 1, fingertip: 5});
      expect(store.updateCount, before);
    });

    test('cancelling an in-progress job gives the parts back', () async {
      final j = await armJob();
      await repo(maker).claim(j.jobId);
      await expectLater(repo(maker).cancel(j.jobId), throwsTicketing('Only the person who requested'));
      expect((await repo(requester).cancel(j.jobId)).status, JobStatus.cancelled);
      expect(await stockOf(fingertip), 12);
    });
  });

  group('comments', () {
    test('admins, the requester, claimers and Quality can comment; others can\'t', () async {
      final j = await armJob();
      // Finishing isn't a commenting department, so they need to be on the job
      const finishing = TicketingUser(uid: 'fin', role: Role.member, departments: {'Finishing'});
      await expectLater(repo(finishing).addComment(j.jobId, 'hi'), throwsTicketing('Only people on this job'));
      await repo(maker).claim(j.jobId);
      await repo(maker2).claim(j.jobId);
      for (final u in [requester, maker, maker2, qa, admin]) {
        await repo(u).addComment(j.jobId, 'from ${u.uid}');
      }
      await expectLater(repo(outsider).addComment(j.jobId, 'hi'), throwsTicketing('Only people on this job'));
      expect((await repo(admin).commentsForJob(j.jobId)).map((c) => c.author), ['req', 'man', 'man2', 'qa', 'adm']);
    });

    test('the author edits; the author or an admin deletes', () async {
      final j = await armJob();
      final c = await repo(requester).addComment(j.jobId, 'Thnks');
      clockTime = clockTime.add(const Duration(minutes: 5));
      final e = await repo(requester).editComment(c.id, 'Thanks');
      expect([e.text, e.timestamp, e.editedAt], ['Thanks', c.timestamp, clockTime]);
      await expectLater(repo(admin).editComment(c.id, 'x'), throwsTicketing('your own'));
      await expectLater(repo(qa).deleteComment(c.id), throwsTicketing('your own'));
      await repo(admin).deleteComment(c.id);
      expect(await repo(admin).commentsForJob(j.jobId), isEmpty);
    });
  });

  test('live job list updates arrive after a write', () async {
    final seen = <int>[];
    final sub = repo(requester).watchJobs().listen((list) => seen.add(list.length));
    await Future<void>.delayed(Duration.zero);
    await armJob();
    await Future<void>.delayed(Duration.zero);
    expect(seen, [0, 1]);
    await sub.cancel();
  });
}
