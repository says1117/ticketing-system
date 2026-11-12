// the main page's pure rules: tabs, search, sorting and the Log feed.
// run with: flutter test test/page_logic_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:lsi_ticketing/lsi_ticketing.dart';

final t0 = DateTime.utc(2026, 11, 10, 9);
String nameOf(String uid) => const {'req': 'Lee Navarro', 'man': 'Sam Okafor', 'kai': 'Kai Patel'}[uid] ?? 'Unknown';

Job job(String id, {
  String name = 'Arm',
  JobStatus status = JobStatus.requested,
  JobPriority? priority,
  int dueDay = 20,
  int createdHour = 9,
  int? claimedHour,
  List<String> claimers = const [],
  String? remakeOf,
}) =>
    Job(
      jobId: id,
      jobName: name,
      requestedBy: 'req',
      submittedBy: 'req',
      lines: const {'-a': JobLine(itemId: '-a', quantity: 1)},
      claimers: {for (final c in claimers) c: t0},
      status: status,
      neededBy: DateTime.utc(2026, 11, dueDay),
      priority: priority,
      createdAt: DateTime.utc(2026, 11, 10, createdHour),
      updatedAt: t0,
      claimedAt: claimedHour == null ? null : DateTime.utc(2026, 11, 10, claimedHour),
      remakeOf: remakeOf,
    );

List<String> ids(List<Job> jobs) => jobs.map((j) => j.jobId).toList();

void main() {
  final jobs = [
    job('JOB-0001', name: 'Left arm', status: JobStatus.inProgress, dueDay: 25, claimedHour: 10, claimers: ['man']),
    job('JOB-0002', name: 'Spare tips', status: JobStatus.inProgress, dueDay: 12, claimedHour: 12, claimers: ['kai']),
    job('JOB-0003', name: 'Right arm', priority: JobPriority.low, dueDay: 15, createdHour: 8),
    job('JOB-0004', name: 'Thumbs', priority: JobPriority.high, dueDay: 30, createdHour: 11),
    job('JOB-0005', name: 'Wrist', dueDay: 14, createdHour: 10),
    job('JOB-0006', name: 'Old arm', status: JobStatus.completed),
    job('JOB-0007', name: 'Failed arm', status: JobStatus.remade),
  ];

  group('tabs', () {
    test('In-Progress shows claimed open jobs; Requested shows unclaimed ones; closed jobs show on neither', () {
      expect(ids(PageLogic.jobsFor(JobTab.inProgress, jobs, query: '', sort: JobSort.dueDate, nameOf: nameOf)),
          ['JOB-0002', 'JOB-0001']);
      expect(ids(PageLogic.jobsFor(JobTab.requested, jobs, query: '', sort: JobSort.dueDate, nameOf: nameOf)),
          ['JOB-0005', 'JOB-0003', 'JOB-0004']);
    });

    test('each job tab offers its sorts, due date first', () {
      expect(PageLogic.sortsFor(JobTab.inProgress).first, JobSort.dueDate);
      expect(PageLogic.sortsFor(JobTab.requested), contains(JobSort.priority));
      expect(PageLogic.sortsFor(JobTab.log), isEmpty);
    });
  });

  group('sorting', () {
    List<String> requested(JobSort s) =>
        ids(PageLogic.jobsFor(JobTab.requested, jobs, query: '', sort: s, nameOf: nameOf));

    test('priority puts high first and no priority last', () {
      expect(requested(JobSort.priority), ['JOB-0004', 'JOB-0003', 'JOB-0005']);
    });
    test('time requested is newest first', () {
      expect(requested(JobSort.timeRequested), ['JOB-0004', 'JOB-0005', 'JOB-0003']);
    });
    test('job name is alphabetical', () {
      expect(requested(JobSort.name), ['JOB-0003', 'JOB-0004', 'JOB-0005']);
    });
    test('time claimed is most recent first', () {
      expect(ids(PageLogic.jobsFor(JobTab.inProgress, jobs, query: '', sort: JobSort.timeClaimed, nameOf: nameOf)),
          ['JOB-0002', 'JOB-0001']);
    });
  });

  group('search', () {
    test('matches name, id, requester and claimers, ignoring case and word order', () {
      final j = jobs.first;
      for (final q in ['left', 'JOB-0001', 'lee', 'okafor', 'arm left', '  ']) {
        expect(PageLogic.matches(j, q, nameOf), isTrue, reason: q);
      }
      expect(PageLogic.matches(j, 'kai', nameOf), isFalse);
    });
  });

  test('overdue means open and past the due day', () {
    final today = DateTime(2026, 11, 13, 15);
    expect(PageLogic.isOverdue(job('a', dueDay: 12), today), isTrue);
    expect(PageLogic.isOverdue(job('a', dueDay: 13), today), isFalse, reason: 'due today is not overdue');
    expect(PageLogic.isOverdue(job('a', dueDay: 1, status: JobStatus.completed), today), isFalse);
  });

  group('Log feed', () {
    HistoryEntry h(String id, HistoryType type, String user, int hour, {String job = 'JOB-0001', String? from, String? to}) =>
        HistoryEntry(id: id, jobId: job, type: type, user: user, timestamp: DateTime.utc(2026, 11, 10, hour), from: from, to: to);

    final history = [
      h('1', HistoryType.created, 'req', 8),
      h('2', HistoryType.reserved, 'man', 9),
      h('3', HistoryType.claimed, 'man', 9, to: 'man'),
      h('4', HistoryType.completed, 'man', 12),
      h('5', HistoryType.remade, 'kai', 13, to: 'JOB-0008'),
      h('6', HistoryType.unclaimed, 'adm', 14, from: 'kai'),
    ];
    final comments = [Comment(id: 'c', jobId: 'JOB-0001', author: 'kai', text: 'hi', timestamp: DateTime.utc(2026, 11, 10, 11))];
    final byId = {'JOB-0001': job('JOB-0001', name: 'Left arm')};
    List<LogEntry> feed(LogFilter f, {String q = '', bool newest = true}) => PageLogic.logEntries(
        history: history, comments: comments, jobs: byId, filter: f, query: q, nameOf: nameOf, newestFirst: newest);

    test('All reads as sentences, newest first, with comments and without per-part stock rows', () {
      expect(feed(LogFilter.all).map((e) => e.text), [
        'Unknown removed Kai Patel from JOB-0001 "Left arm"',
        'Kai Patel marked JOB-0001 "Left arm" as failed (remake JOB-0008)',
        'Sam Okafor marked JOB-0001 "Left arm" as complete',
        'Kai Patel commented on JOB-0001 "Left arm"',
        'Sam Okafor claimed JOB-0001 "Left arm"',
        'Lee Navarro requested JOB-0001 "Left arm"',
      ]);
    });
    test('Completed and Failed show only those events', () {
      expect(feed(LogFilter.completed).single.kind, LogKind.completed);
      expect(feed(LogFilter.failed).single.text, contains('as failed'));
    });
    test('search and oldest-first', () {
      expect(feed(LogFilter.all, q: 'commented').single.kind, LogKind.comment);
      expect(feed(LogFilter.all, newest: false).first.text, contains('requested'));
    });
    test('a remake ticket\'s creation says so', () {
      final remake = {'JOB-0008': job('JOB-0008', name: 'Left arm', remakeOf: 'JOB-0001')};
      final rows = PageLogic.logEntries(
          history: [h('9', HistoryType.created, 'kai', 13, job: 'JOB-0008')],
          comments: const [], jobs: remake, filter: LogFilter.all, query: '', nameOf: nameOf);
      expect(rows.single.text, 'Kai Patel created remake JOB-0008 "Left arm"');
    });
  });
}
