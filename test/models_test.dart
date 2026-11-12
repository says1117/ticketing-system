// run with: flutter test test/models_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:lsi_ticketing/lsi_ticketing.dart';

final t0 = DateTime.utc(2026, 11, 12, 14, 30);

Job makeJob() => Job(
      jobId: 'JOB-0042',
      jobName: 'Left arm, patient A',
      requestedBy: 'req',
      submittedBy: 'adm',
      lines: const {
        '-a': JobLine(itemId: '-a', quantity: 5, held: 4, scrapped: 2),
        '-b': JobLine(itemId: '-b', quantity: 1, held: 1),
      },
      claimers: {'man': t0, 'man2': t0.add(const Duration(minutes: 5))},
      status: JobStatus.inProgress,
      neededBy: DateTime.utc(2026, 11, 30),
      priority: JobPriority.high,
      createdAt: t0,
      updatedAt: t0,
      claimedAt: t0,
      rev: 3,
      lastHistoryId: 'h9',
    );

void main() {
  group('Job', () {
    test('round trips through toJson and fromJson', () {
      final j = makeJob();
      final copy = Job.fromJson(j.jobId, j.toJson());
      expect(copy.toJson(), j.toJson());
      expect(copy.lines['-a']!.scrapped, 2);
      expect(copy.claimers.keys, unorderedEquals(['man', 'man2']));
      expect(copy.neededBy, DateTime.utc(2026, 11, 30));
      expect([copy.submittedBy, copy.priority], ['adm', JobPriority.high]);
      expect(copy.isRequester('req') && copy.isRequester('adm'), isTrue);
    });

    test('stores status by name, dates as strings, and leaves out empty optional fields', () {
      final json = makeJob().toJson();
      expect(json['status'], 'inProgress');
      expect(json['priority'], 'high');
      expect(makeJob().copyWith(priority: () => null).toJson().containsKey('priority'), isFalse);
      expect(json['neededBy'], '2026-11-30');
      expect((json['claimers'] as Map)['man'], '2026-11-12T14:30:00.000Z');
      expect(json.containsKey('completedAt'), isFalse);
      final unclaimed = makeJob().copyWith(claimers: const {}, claimedAt: () => null).toJson();
      expect(unclaimed.containsKey('claimers'), isFalse);
      expect(unclaimed.containsKey('claimedAt'), isFalse);
    });

    test('reads whole numbers that come back as doubles', () {
      final j = Job.fromJson('JOB-0001', {
        'lines': {'-a': {'quantity': 5.0, 'held': 5.0, 'scrapped': 0.0}},
        'status': 'requested',
      });
      expect(j.lines['-a']!.quantity, 5);
    });

    test('remake fields round trip, and a remake is labelled as one', () {
      final r = Job(
        jobId: 'JOB-0043', jobName: 'Left arm, patient A', requestedBy: 'req', submittedBy: 'qa',
        lines: const {'-a': JobLine(itemId: '-a', quantity: 2)}, status: JobStatus.requested,
        neededBy: DateTime.utc(2026, 11, 30), createdAt: t0, updatedAt: t0,
        remakeOf: 'JOB-0042', usedParts: const {'-a': 5, '-b': 1},
        defects: const {'-a': Defect(count: 2, reason: 'cracked')},
      );
      final copy = Job.fromJson(r.jobId, r.toJson());
      expect(copy.toJson(), r.toJson());
      expect([copy.isRemake, copy.remakeOf, copy.usedParts, copy.defects['-a']!.reason], [true, 'JOB-0042', {'-a': 5, '-b': 1}, 'cracked']);
      expect(makeJob().isRemake, isFalse);
      expect(makeJob().toJson().containsKey('defects'), isFalse);
      expect(const Defect(count: 1).toJson().containsKey('reason'), isFalse);
      expect(makeJob().copyWith(status: JobStatus.remade).isClosed, isTrue);
    });

    test('claimers', () {
      final j = makeJob();
      expect(j.isClaimedBy('man2'), isTrue);
      expect(j.isClaimedBy('req'), isFalse);
      expect(j.isOpen, isTrue);
      expect(j.copyWith(status: JobStatus.cancelled).isClosed, isTrue);
    });

    test('formats readable ids', () {
      expect(Job.formatId(42), 'JOB-0042');
      expect(Job.formatId(12345), 'JOB-12345');
    });
  });

  group('InventoryItem', () {
    test('reads the inventory page\'s fields', () {
      final i = InventoryItem.fromJson('-a', {
        'name': 'Fingertip', 'itemNumber': 'FT-01', 'stock': 3, 'threshold': 4,
        'url': 'https://drive/x', 'location': 'Shelf B', 'onOrder': 0, 'owner': 'someone',
      });
      expect([i.name, i.itemNumber, i.stock, i.url, i.location], ['Fingertip', 'FT-01', 3, 'https://drive/x', 'Shelf B']);
      expect(i.needsReorder, isTrue, reason: 'same rule as the inventory page: stock <= threshold');
      expect(InventoryItem.fromJson('-b', {'stock': 5, 'threshold': 4}).needsReorder, isFalse);
    });
  });

  group('HistoryEntry', () {
    test('round trips, with an optional item', () {
      final h = HistoryEntry(id: 'h1', jobId: 'JOB-0001', itemId: '-a', type: HistoryType.reserved,
          from: '12', to: '7', quantityChange: -5, user: 'man', timestamp: t0);
      expect(HistoryEntry.fromJson('h1', h.toJson()).toJson(), h.toJson());
      final noItem = HistoryEntry(id: 'h2', jobId: 'JOB-0001', type: HistoryType.claimed, to: 'man', user: 'man', timestamp: t0);
      expect(noItem.toJson().containsKey('itemId'), isFalse);
    });
  });

  group('Comment', () {
    test('round trips and records edits', () {
      final c = Comment(id: 'c1', jobId: 'JOB-0001', author: 'req', text: 'hi', timestamp: t0);
      expect(Comment.fromJson('c1', c.toJson()).toJson(), c.toJson());
      final e = c.edited('hello', t0.add(const Duration(minutes: 1)));
      expect([e.text, e.timestamp, e.editedAt], ['hello', t0, t0.add(const Duration(minutes: 1))]);
    });
  });
}
