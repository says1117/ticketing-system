// run with: flutter test test/permissions_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:lsi_ticketing/lsi_ticketing.dart';

const requester = TicketingUser(uid: 'req', role: Role.member);
const maker = TicketingUser(uid: 'man', role: Role.member);
const someoneElse = TicketingUser(uid: 'other', role: Role.member);
const admin = TicketingUser(uid: 'adm', role: Role.admin);

Job job({JobStatus status = JobStatus.requested, Map<String, DateTime> claimers = const {}, int held = 0, int quantity = 5}) =>
    Job(
      jobId: 'JOB-0001',
      jobName: 'Arm',
      requestedBy: 'req',
      submittedBy: 'sub',
      neededBy: DateTime.utc(2026, 12),
      lines: {'-a': JobLine(itemId: '-a', quantity: quantity, held: held)},
      claimers: claimers,
      status: status,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

Job inProgress({List<String> by = const ['man'], int held = 5}) =>
    job(status: JobStatus.inProgress, claimers: {for (final u in by) u: DateTime.utc(2026)}, held: held);

Map<String, InventoryItem> stock(int n) => {'-a': InventoryItem(id: '-a', name: 'Fingertip', stock: n)};

void main() {
  group('roleFor and fromOrgData', () {
    test('inactive users get nothing', () {
      expect(Permissions.roleFor(orgData: {'active': false, 'status': 'OrgStatus.admin'}), isNull);
      expect(TicketingUser.fromOrgData('x', null), isNull);
    });
    test('OrgStatus.admin is an admin; everyone else active is a member', () {
      expect(Permissions.roleFor(orgData: {'active': true, 'status': 'OrgStatus.admin'}), Role.admin);
      expect(Permissions.roleFor(orgData: {'active': true, 'status': 'OrgStatus.affiliatedFaculty'}), Role.member);
    });
    test('departments come from department and subDepartments, not otherDepartments', () {
      final u = TicketingUser.fromOrgData('x', {
        'active': true, 'department': 'Finishing', 'subDepartments': 'Quality', 'otherDepartments': {'-a': 'Production'},
      })!;
      expect(u.departments, {'Finishing', 'Quality'});
    });
  });

  group('claim', () {
    test('the first claim needs every part on hand: equal or more is fine', () {
      expect(Permissions.canClaim(maker, job(), stock(5)), isNull);
      expect(Permissions.canClaim(maker, job(), stock(9)), isNull);
    });
    test('short stock blocks the claim and says what is short', () {
      expect(Permissions.canClaim(maker, job(), stock(3)), 'Not enough in inventory: Fingertip (need 5, 3 on hand).');
      expect(Permissions.canClaim(maker, job(), {}), contains('Unknown part'));
    });
    test('anyone can join a job in progress, whatever the stock', () {
      expect(Permissions.canClaim(someoneElse, inProgress(), stock(0)), isNull);
      expect(Permissions.canClaim(requester, inProgress(), stock(0)), isNull);
    });
    test('not twice, and not a closed job', () {
      expect(Permissions.canClaim(maker, inProgress(), stock(9)), contains('already'));
      expect(Permissions.canClaim(maker, job(status: JobStatus.completed), stock(9)), isNotNull);
    });
  });

  group('unclaim', () {
    test('a claimer removes themselves; an admin removes anyone; nobody else', () {
      final j = inProgress(by: ['man', 'man2']);
      expect(Permissions.canUnclaim(maker, j, 'man'), isNull);
      expect(Permissions.canUnclaim(admin, j, 'man2'), isNull);
      expect(Permissions.canUnclaim(maker, j, 'man2'), contains('Only admins'));
      expect(Permissions.canUnclaim(requester, j, 'man'), isNotNull);
      expect(Permissions.canUnclaim(maker, j, 'nobody'), contains('hasn\'t claimed'));
    });
  });

  group('working a job', () {
    test('only claimers and admins complete, and only while in progress', () {
      final j = inProgress();
      expect(Permissions.canComplete(maker, j), isNull);
      expect(Permissions.canComplete(admin, j), isNull);
      expect(Permissions.canComplete(requester, j), isNotNull);
      expect(Permissions.canComplete(admin, job()), isNotNull);
    });
  });

  group('remakes', () {
    test('from an in-progress or completed job, by anyone who can comment on it', () {
      final completed = inProgress().copyWith(status: JobStatus.completed);
      const quality = TicketingUser(uid: 'q', role: Role.member, departments: {'Quality'});
      for (final j in [inProgress(), completed]) {
        for (final u in [admin, requester, maker, quality]) {
          expect(Permissions.canCreateRemake(u, j), isNull, reason: '${u.uid} on ${j.status.name}');
        }
        expect(Permissions.canCreateRemake(someoneElse, j), isNotNull);
      }
    });
    test('not from a requested, cancelled or already remade job', () {
      for (final s in [JobStatus.requested, JobStatus.cancelled, JobStatus.remade]) {
        expect(Permissions.canCreateRemake(admin, job(status: s)), contains('in progress or completed'));
      }
    });
  });

  group('the requester', () {
    test('edits and cancels their own open job, and so does whoever submitted it for them', () {
      const submitter = TicketingUser(uid: 'sub', role: Role.member);
      for (final u in [requester, submitter]) {
        expect(Permissions.canEdit(u, inProgress()), isNull);
        expect(Permissions.canCancel(u, inProgress()), isNull);
        expect(Permissions.canComment(u, inProgress()), isNull);
      }
    });
    test('changes parts only before a claim', () {
      expect(Permissions.canEdit(requester, job(), changesParts: true), isNull);
      expect(Permissions.canEdit(requester, inProgress(), changesParts: true), contains('Unclaim it first'));
      expect(Permissions.canEdit(admin, inProgress(), changesParts: true), isNotNull);
    });
    test('others can\'t; nobody can once it is closed', () {
      expect(Permissions.canEdit(maker, inProgress()), isNotNull);
      expect(Permissions.canCancel(maker, inProgress()), isNotNull);
      expect(Permissions.canCancel(admin, inProgress()), isNull);
      expect(Permissions.canEdit(requester, job(status: JobStatus.completed)), isNotNull);
    });
  });

  group('comments', () {
    test('admins, the requester, every claimer, and Quality, Assembly or Production', () {
      final j = inProgress(by: ['man', 'man2']);
      for (final u in [admin, requester, maker, const TicketingUser(uid: 'man2', role: Role.member)]) {
        expect(Permissions.canComment(u, j), isNull, reason: u.uid);
      }
      for (final dep in ['Quality', 'Assembly', 'Production']) {
        expect(Permissions.canComment(TicketingUser(uid: 'x', role: Role.member, departments: {dep}), j), isNull, reason: dep);
      }
    });
    test('anyone else is refused', () {
      expect(Permissions.canComment(someoneElse, inProgress()), isNotNull);
      expect(Permissions.canComment(const TicketingUser(uid: 'x', role: Role.member, departments: {'Finishing'}), job()), isNotNull);
    });
    test('the author edits; the author or an admin deletes', () {
      final c = Comment(id: 'c', jobId: 'JOB-0001', author: 'req', text: 'hi', timestamp: DateTime.utc(2026));
      expect(Permissions.canEditComment(requester, c), isNull);
      expect(Permissions.canEditComment(admin, c), isNotNull);
      expect(Permissions.canDeleteComment(admin, c), isNull);
      expect(Permissions.canDeleteComment(maker, c), isNotNull);
    });
  });
}
