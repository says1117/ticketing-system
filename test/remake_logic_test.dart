// the remake form's rules, without widgets. run with:
//   flutter test test/remake_logic_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:lsi_ticketing/lsi_ticketing.dart';

// 5 fingertips and 1 palm, all held; a base the job holds none of
Job job({JobStatus status = JobStatus.inProgress}) => Job(
      jobId: 'JOB-0001',
      jobName: 'Left arm',
      requestedBy: 'req',
      submittedBy: 'req',
      neededBy: DateTime.utc(2026, 12),
      lines: const {
        'tip': JobLine(itemId: 'tip', quantity: 5, held: 5),
        'palm': JobLine(itemId: 'palm', quantity: 1, held: 1),
        'base': JobLine(itemId: 'base', quantity: 2, held: 0),
      },
      status: status,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

Job remake(JobStatus status) => Job(
      jobId: 'JOB-0002',
      jobName: 'Left arm',
      requestedBy: 'req',
      submittedBy: 'man',
      neededBy: DateTime.utc(2026, 12),
      lines: const {'tip': JobLine(itemId: 'tip', quantity: 2)},
      status: status,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      remakeOf: 'JOB-0001',
    );

Map<String, InventoryItem> stock(int n) => {'tip': InventoryItem(id: 'tip', name: 'Fingertip', stock: n)};

void main() {
  group('picking faulty parts', () {
    test('nothing picked is the first error', () {
      final d = RemakeDraft(job());
      expect(d.partsError, 'Pick at least one faulty part.');
      expect(d.isValid, isFalse);
    });
    test('ticking a part starts it at 1; ticking again removes it', () {
      final d = RemakeDraft(job())..toggle('tip');
      expect(d.picked['tip']!.count, 1);
      expect(d.isValid, isTrue);
      d.toggle('tip');
      expect(d.isPicked('tip'), isFalse);
    });
    test('a part the job holds none of cannot be picked', () {
      final d = RemakeDraft(job());
      expect(d.canPick('base'), isFalse);
      d.toggle('base');
      expect(d.isPicked('base'), isFalse);
    });
    test('picked order is kept', () {
      final d = RemakeDraft(job())
        ..toggle('palm')
        ..toggle('tip');
      expect(d.picked.keys, ['palm', 'tip']);
    });
  });

  group('counts', () {
    test('the stepper stays between 1 and what the job holds', () {
      final d = RemakeDraft(job())..toggle('tip');
      d.setCount('tip', 9);
      expect(d.picked['tip']!.count, 5);
      d.setCount('tip', 0);
      expect(d.picked['tip']!.count, 1);
    });
    test('a count set out of range directly is reported', () {
      final d = RemakeDraft(job())..toggle('palm');
      d.picked['palm']!.count = 2;
      expect(d.countError('palm'), 'This job only has 1.');
      d.picked['palm']!.count = 0;
      expect(d.countError('palm'), 'Enter at least 1.');
      expect(d.isValid, isFalse);
    });
  });

  group('reasons', () {
    test('optional, trimmed, and at most 500 characters', () {
      final d = RemakeDraft(job())..toggle('tip');
      expect(d.reasonError('tip'), isNull);
      d.setReason('tip', '  cracked at the joint  ');
      expect(d.toDefects()['tip']!.reason, 'cracked at the joint');
      d.setReason('tip', 'x' * 501);
      expect(d.reasonError('tip'), contains('500'));
      expect(d.isValid, isFalse);
      d.setReason('tip', 'x' * 500);
      expect(d.isValid, isTrue);
    });
  });

  test('toDefects is what createRemake takes', () {
    final d = RemakeDraft(job())
      ..toggle('tip')
      ..toggle('palm')
      ..setCount('tip', 2)
      ..setReason('tip', 'bent');
    final defects = d.toDefects();
    expect(defects.keys, ['tip', 'palm']);
    expect([defects['tip']!.count, defects['tip']!.reason], [2, 'bent']);
    expect([defects['palm']!.count, defects['palm']!.reason], [1, '']);
  });

  group('result message', () {
    test('claimed: the parts were taken', () {
      expect(RemakeDraft.outcomeMessage(remake(JobStatus.inProgress), stock(0)),
          contains('You claimed it and the replacement parts were taken'));
    });
    test('waiting: names the short parts', () {
      final m = RemakeDraft.outcomeMessage(remake(JobStatus.requested), stock(1));
      expect(m, contains('Fingertip (need 2, 1 on hand)'));
      expect(m, contains('waiting in Requested'));
    });
    test('waiting with nothing short: someone else got there first', () {
      expect(RemakeDraft.outcomeMessage(remake(JobStatus.requested), stock(10)), contains('claim it from there'));
    });
  });
}
