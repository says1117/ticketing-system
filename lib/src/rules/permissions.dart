import '../models/comment.dart';
import '../models/enums.dart';
import '../models/inventory_item.dart';
import '../models/job.dart';
import '../models/json_read.dart';

// the signed-in person, as the ticketing code sees them
class TicketingUser {
  const TicketingUser({required this.uid, required this.role, this.departments = const {}});
  final String uid;
  final Role role;
  // orgData.department and orgData.subDepartments, used for who may comment
  final Set<String> departments;

  bool get isAdmin => role == Role.admin;

  // builds the user from lsicompapp's users/{uid}/orgData. null for an
  // inactive user, who gets no access.
  static TicketingUser? fromOrgData(String uid, Object? orgData) {
    final role = Permissions.roleFor(orgData: orgData);
    if (role == null) return null;
    return TicketingUser(uid: uid, role: role, departments: Permissions.departmentsOf(orgData));
  }
}

// who may do what. every check here has a matching condition in
// rules/ticketing.rules.json; the rules are what actually protect the data, these
// exist so the page can hide buttons and explain why something is blocked. keep
// the two in step.
//
//   anyone active:   request a job; claim any open job (join if already claimed)
//   the requester:   (the person it's for, or who submitted it) edit or cancel
//                    their open job; parts only before a claim
//   a claimer:       unclaim themselves, complete
//   remakes:         on an in-progress or completed job, the same people who
//                    can comment (below) can report defects, which creates a
//                    remake ticket and closes the job as remade
//   admins:          everything, including unclaiming anyone
//   comments:        admins, the requester and submitter, every claimer, and the Quality,
//                    Assembly and Production departments
//
// the can... methods return a message for the user, or null when allowed.
class Permissions {
  static const String adminStatus = 'OrgStatus.admin';

  // departments whose members may comment on any job. names as stored in
  // orgData.department (see Org.getDEP in lsicompapp). lsicompapp has no
  // Assembly department today; it's listed so it works once one exists.
  static const Set<String> commentDepartments = {'Quality', 'Assembly', 'Production'};

  // OrgStatus.admin is an admin, every other active user is a member. null
  // for an inactive user.
  static Role? roleFor({required Object? orgData}) {
    final org = asJsonMap(orgData);
    if (org['active'] != true) return null;
    return org['status'] == adminStatus ? Role.admin : Role.member;
  }

  // department and subDepartments. otherDepartments is a map with generated
  // keys that the security rules can't search, so it is left out here too.
  static Set<String> departmentsOf(Object? orgData) {
    final org = asJsonMap(orgData);
    return {
      for (final key in ['department', 'subDepartments'])
        if (org[key] is String && (org[key] as String).isNotEmpty) org[key] as String,
    };
  }

  static String? _closedReason(Job j) => j.isClosed ? 'This job is ${j.status.name} and can no longer change.' : null;

  static bool _claimerOrAdmin(TicketingUser user, Job j) => user.isAdmin || j.isClaimedBy(user.uid);

  // the parts that are short, as "Fingertip (need 5, 3 on hand)". stock is the
  // current inventory items by id. empty when everything is there.
  static List<String> shortParts(Job j, Map<String, InventoryItem> stock) => [
        for (final line in j.lines.values)
          if ((stock[line.itemId]?.stock ?? 0) < line.quantity)
            '${stock[line.itemId]?.name ?? 'Unknown part'} (need ${line.quantity}, ${stock[line.itemId]?.stock ?? 0} on hand)',
      ];

  // the first claim takes every part out of inventory, so it needs all of them
  // on hand. joining a job that's already in progress takes nothing.
  static String? canClaim(TicketingUser user, Job j, Map<String, InventoryItem> stock) {
    final closed = _closedReason(j);
    if (closed != null) return closed;
    if (j.isClaimedBy(user.uid)) return 'You already claimed this job.';
    if (j.status == JobStatus.requested) {
      final short = shortParts(j, stock);
      if (short.isNotEmpty) return 'Not enough in inventory: ${short.join(', ')}.';
    }
    return null;
  }

  // a claimer can remove themselves; an admin can remove anyone
  static String? canUnclaim(TicketingUser user, Job j, String claimerUid) {
    final closed = _closedReason(j);
    if (closed != null) return closed;
    if (!j.isClaimedBy(claimerUid)) return 'That person hasn\'t claimed this job.';
    if (claimerUid != user.uid && !user.isAdmin) return 'Only admins can unclaim someone else.';
    return null;
  }

  static String? canComplete(TicketingUser user, Job j) {
    if (j.status != JobStatus.inProgress) return 'Only a job in progress can be completed.';
    if (!_claimerOrAdmin(user, j)) return 'Only people who claimed this job, or an admin, can complete it.';
    return null;
  }

  // the requester changes their job. the parts list can only change before
  // anyone claims it, because claiming takes those parts out of inventory.
  static String? canEdit(TicketingUser user, Job j, {bool changesParts = false}) {
    final closed = _closedReason(j);
    if (closed != null) return closed;
    if (!user.isAdmin && !j.isRequester(user.uid)) return 'Only the person who requested this job, or an admin, can edit it.';
    if (changesParts && j.status != JobStatus.requested) {
      return 'The parts can\'t change once the job is claimed. Unclaim it first.';
    }
    return null;
  }

  static String? canCancel(TicketingUser user, Job j) {
    final closed = _closedReason(j);
    if (closed != null) return closed;
    if (!user.isAdmin && !j.isRequester(user.uid)) return 'Only the person who requested this job, or an admin, can cancel it.';
    return null;
  }

  // reporting defects: creates a remake ticket and closes this job as remade
  static String? canCreateRemake(TicketingUser user, Job j) {
    if (j.status != JobStatus.inProgress && j.status != JobStatus.completed) {
      return 'A remake can be made from a job that is in progress or completed.';
    }
    if (_mayComment(user, j)) return null;
    return 'Only people on this job, admins, and the Quality, Assembly and Production teams can create a remake.';
  }

  static bool _mayComment(TicketingUser user, Job j) =>
      user.isAdmin ||
      j.isRequester(user.uid) ||
      j.isClaimedBy(user.uid) ||
      user.departments.any(commentDepartments.contains);

  static String? canComment(TicketingUser user, Job j) {
    if (_mayComment(user, j)) return null;
    return 'Only people on this job, admins, and the Quality, Assembly and Production teams can comment here.';
  }

  static String? canEditComment(TicketingUser user, Comment c) =>
      c.author == user.uid ? null : 'You can only edit your own comments.';

  static String? canDeleteComment(TicketingUser user, Comment c) =>
      c.author == user.uid || user.isAdmin ? null : 'You can only delete your own comments.';
}
