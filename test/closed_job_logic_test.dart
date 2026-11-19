// headings, closing dates and failure details for the job popup, without
// widgets. run with:  flutter test test/closed_job_logic_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:lsi_ticketing/lsi_ticketing.dart';

final created = DateTime.utc(2026, 11, 10, 9);
final updated = DateTime.utc(2026, 11, 12, 15);

Job job(JobStatus status, {DateTime? completedAt, String? remadeAs, String id = 'JOB-0001'}) => Job(
      jobId: id,
      jobName: 'Left arm',
      requestedBy: 'req',
      submittedBy: 'req',
      neededBy: DateTime.utc(2026, 12),
      lines: const {'tip': JobLine(itemId: 'tip', quantity: 5, held: 5)},
      claimers: {'man': created},
      status: status,
      createdAt: created,
      updatedAt: updated,
      completedAt: completedAt,
      remadeAs: remadeAs,
    );

final failedAt = DateTime.utc(2026, 11, 13, 10);

Job remake({String id = 'JOB-0002', String remakeOf = 'JOB-0001'}) => Job(
      jobId: id,
      jobName: 'Left arm',
      requestedBy: 'req',
      submittedBy: 'qa',
      neededBy: DateTime.utc(2026, 12),
      lines: const {'tip': JobLine(itemId: 'tip', quantity: 2), 'palm': JobLine(itemId: 'palm', quantity: 1)},
      status: JobStatus.requested,
      createdAt: failedAt,
      updatedAt: failedAt,
      remakeOf: remakeOf,
      defects: const {'tip': Defect(count: 2, reason: 'cracked at the joint'), 'palm': Defect(count: 1)},
    );

void main() {
  group('FailureDetails', () {
    final failed = job(JobStatus.remade, remadeAs: 'JOB-0002');

    test('comes from the remake: when it was made, and its defects', () {
      final f = FailureDetails.of(failed, remake())!;
      expect(f.remakeId, 'JOB-0002');
      expect(f.failedAt, failedAt);
      expect(f.defects.keys, ['tip', 'palm']);
      expect(f.partsFailed, 3);
    });
    test('none until the remake has loaded', () {
      expect(FailureDetails.of(failed, null), isNull);
    });
    test('none when the jobs do not point at each other', () {
      expect(FailureDetails.of(failed, remake(id: 'JOB-0003')), isNull, reason: 'not the remadeAs job');
      expect(FailureDetails.of(failed, remake(remakeOf: 'JOB-0009')), isNull, reason: 'a remake of something else');
    });
    test('none for a job that did not fail', () {
      expect(FailureDetails.of(job(JobStatus.completed, remadeAs: 'JOB-0002'), remake()), isNull);
    });
  });

  test('headings follow the status', () {
    expect([for (final s in JobStatus.values) ClosedJobLogic.peopleHeading(job(s))],
        ['Claimed by', 'Claimed by', 'Scholars', 'Scholars', 'Scholars']);
    expect(ClosedJobLogic.partsHeading(job(JobStatus.requested)), 'Parts required');
    expect(ClosedJobLogic.partsHeading(job(JobStatus.inProgress)), 'Parts needed');
    expect(ClosedJobLogic.partsHeading(job(JobStatus.completed)), 'Parts used');
    expect(ClosedJobLogic.partsHeading(job(JobStatus.remade)), 'Parts used');
    expect(ClosedJobLogic.partsHeading(job(JobStatus.cancelled)), contains('returned to inventory'));
  });

  group('closedOn', () {
    test('completed, failed and cancelled each have their own date', () {
      final done = DateTime.utc(2026, 11, 11);
      expect(ClosedJobLogic.closedOn(job(JobStatus.completed, completedAt: done), null), ('Date completed', done));
      final failed = job(JobStatus.remade, remadeAs: 'JOB-0002');
      expect(ClosedJobLogic.closedOn(failed, FailureDetails.of(failed, remake())), ('Date failed', failedAt));
      expect(ClosedJobLogic.closedOn(job(JobStatus.cancelled), null), ('Date cancelled', updated));
    });
    test('nothing for open jobs, or a failure that has not loaded', () {
      expect(ClosedJobLogic.closedOn(job(JobStatus.inProgress), null), isNull);
      expect(ClosedJobLogic.closedOn(job(JobStatus.requested), null), isNull);
      expect(ClosedJobLogic.closedOn(job(JobStatus.remade, remadeAs: 'JOB-0002'), null), isNull);
    });
  });

  test('failure lines name the part, the count, and the reason when there is one', () {
    final failed = job(JobStatus.remade, remadeAs: 'JOB-0002');
    final names = {'tip': 'Fingertip', 'palm': 'Left Palm Plate'};
    expect(ClosedJobLogic.failureLines(FailureDetails.of(failed, remake())!, (id) => names[id]!),
        ['Fingertip × 2: cracked at the joint', 'Left Palm Plate × 1']);
  });
}
