// source for rules/ticketing.rules.json, the Realtime Database security rules for
// the ticketing/ node. Realtime Database rules have no functions, so the same
// checks would be pasted dozens of times; they're written once here and
// expanded. the status, history type and department lists come from the Dart
// code, so the rules can't drift from it.
//
// these rules only cover ticketing/. jobs also change inventory/{id}/stock,
// which belongs to the inventory page and keeps whatever rules it has; the
// rule on each job line below makes sure a job's save only moves stock by
// exactly what the job took or gave back.
//
// regenerate after editing:  dart run tool/build_rules.dart
// (test/rules_test.dart fails if the JSON is out of date)

import 'dart:convert';

import 'package:lsi_ticketing/src/models/enums.dart';
import 'package:lsi_ticketing/src/rules/permissions.dart';

const _signedIn = "auth != null";
String _org(String field) => "root.child('users/' + auth.uid + '/orgData/$field').val()";

// an active Limbitless user (the same orgData.active check root_page.dart does)
final _active = "$_signedIn && ${_org('active')} === true";
final _isAdmin = "${_org('status')} === 'OrgStatus.admin'";

// in Quality, Assembly or Production (Permissions.commentDepartments), by
// department or subDepartments
String _inDept() => [
      for (final field in ['department', 'subDepartments'])
        for (final dep in Permissions.commentDepartments) "${_org(field)} === '$dep'"
    ].join(' || ');

String _same(String field) => "newData.child('$field').val() === data.child('$field').val()";
String _sameAll(List<String> fields) => fields.map(_same).join(' && ');
String _regex(Iterable<String> values) => '/^(${values.join('|')})\$/';
String _status(String snapshot) => "$snapshot.child('status').val()";

// rev must go up by exactly one, so a save based on stale data is refused
const _revOk = "((!data.exists() && newData.child('rev').val() === 1) || "
    "(data.exists() && newData.child('rev').val() === data.child('rev').val() + 1))";

// the job must point at a history row that is new in this same update and
// belongs to this job, so the log can't be skipped
const _historyLinked = "newData.child('lastHistoryId').isString() && "
    "!root.child('ticketing/history/' + newData.child('lastHistoryId').val()).exists() && "
    "newData.parent().parent().child('history').child(newData.child('lastHistoryId').val()).child('jobId').val() === \$jobId";

const _isInt = "newData.isNumber() && newData.val() % 1 === 0";
const _isCount = "$_isInt && newData.val() >= 0";
String _isText(int max, {bool allowEmpty = true}) =>
    "newData.isString() && newData.val().length ${allowEmpty ? '>= 0' : '> 0'} && newData.val().length <= $max";

Map<String, Object> _v(String expr) => {'.validate': expr};
final _noOtherFields = {'\$other': _v('false')};

// who submitted it and when never change. the details are what the
// requester edits on the form.
const _identity = ['jobId', 'submittedBy', 'createdAt'];
const _details = ['jobName', 'requestedBy', 'neededBy', 'priority'];

// one part on a job, at ticketing/jobs/$jobId/lines/$itemId. $itemId is the
// part's inventory/{id} key.
Map<String, Object> _line() {
  const jobNew = "newData.parent().parent()";
  const jobOld = "data.parent().parent()";
  // the whole database as it will be after this update
  const dbNew = "newData.parent().parent().parent().parent().parent()";
  const itemExists = "root.child('inventory/' + \$itemId).exists()";
  const stockOld = "root.child('inventory/' + \$itemId + '/stock').val()";
  const stockNew = "$dbNew.child('inventory/' + \$itemId + '/stock').val()";
  const held = "newData.child('held').val()";
  const heldOld = "data.child('held').val()";
  const scrapped = "newData.child('scrapped').val()";
  const scrappedOld = "data.child('scrapped').val()";
  const quantity = "newData.child('quantity').val()";
  const taken = "(($held - $heldOld) + ($scrapped - $scrappedOld))";

  final rules = [
    "newData.hasChildren(['quantity', 'held', 'scrapped'])",
    "$held <= $quantity",
    // a job that isn't working holds nothing; a completed one holds every part
    "(!${_status(jobNew)}.matches(/^(requested|cancelled)\$/) || $held === 0)",
    "(${_status(jobNew)} !== 'completed' || $held === $quantity)",
    // a new line starts empty, for a part that's in inventory, on a job not yet claimed
    "(data.exists() || ($held === 0 && $scrapped === 0 && $itemExists && (!$jobOld.exists() || ${_status(jobOld)} === 'requested')))",
    // quantities only change before a claim
    "(!data.exists() || ${_same('quantity')} || ${_status(jobOld)} === 'requested')",
    // parts are only scrapped when the job closes as remade, and never un-scrapped
    "(!data.exists() || $scrapped === $scrappedOld || (${_status(jobNew)} === 'remade' && $scrapped > $scrappedOld))",
    // stock + held + scrapped stays the same: whatever the job takes comes out
    // of inventory, whatever it gives back goes in, scrapped parts go nowhere
    "(!data.exists() || !$itemExists || $stockNew - $stockOld === 0 - $taken)",
    // and taking parts can't push stock below zero
    "(!data.exists() || !$itemExists || $taken <= 0 || $stockNew >= 0)",
  ];

  return {
    '.validate': rules.join(' && '),
    'quantity': _v('$_isInt && newData.val() > 0'),
    'held': _v(_isCount),
    'scrapped': _v(_isCount),
    ..._noOtherFields,
  };
}

Map<String, Object> _jobs() {
  const open = "(data.child('status').val() === 'requested' || data.child('status').val() === 'inProgress')";
  const wasClaimer = "data.child('claimers').child(auth.uid).exists()";
  const isClaimer = "newData.child('claimers').child(auth.uid).exists()";
  final fixed = _sameAll([..._identity, ..._details]);

  // submittedBy is the signed-in person; requestedBy can be any active scholar
  // (checked on the requestedBy field below)
  final create = "(!data.exists() && newData.child('submittedBy').val() === auth.uid && "
      "newData.child('status').val() === 'requested' && !newData.child('claimers').exists() && "
      "!newData.child('claimedAt').exists() && !newData.child('completedAt').exists())";

  // admins may change anything but who submitted it and when
  final adminEdit = "(data.exists() && $_isAdmin && ${_sameAll(_identity)})";

  // anyone joins: the first claim moves the job to in progress
  final join = "(!$wasClaimer && $isClaimer && $fixed && newData.child('status').val() === 'inProgress')";
  // a claimer leaves; if they were the last one the job goes back to requested
  // (the status/claimers check in .validate makes sure which)
  final leave = "($wasClaimer && !$isClaimer && $fixed && newData.child('status').val().matches(/^(requested|inProgress)\$/))";
  // a claimer works the job: defects, missing parts, complete. not cancel.
  final work = "($wasClaimer && $isClaimer && $fixed && newData.child('status').val().matches(/^(inProgress|completed)\$/))";
  // the requester or submitter edits the name, requester, due date, priority
  // and parts (lines only allow this before a claim), or cancels
  final requesterEdit = "((data.child('requestedBy').val() === auth.uid || data.child('submittedBy').val() === auth.uid) && "
      "${_sameAll([..._identity, 'claimedAt'])} && "
      "(${_same('status')} || newData.child('status').val() === 'cancelled'))";

  final memberEdit = "(data.exists() && $open && ($join || $leave || $work || $requesterEdit))";

  // reporting defects closes an in-progress or completed job as remade. it
  // must name the remake ticket made in the same update, which points back.
  // allowed for the same people who can comment on the job.
  final mayRemake = "($_isAdmin || data.child('requestedBy').val() === auth.uid || "
      "data.child('submittedBy').val() === auth.uid || $wasClaimer || ${_inDept()})";
  final remake = "(data.exists() && data.child('status').val().matches(/^(inProgress|completed)\$/) && "
      "newData.child('status').val() === 'remade' && $mayRemake && "
      "${_sameAll([..._identity, ..._details, 'claimedAt', 'completedAt'])} && "
      "newData.parent().child(newData.child('remadeAs').val()).child('remakeOf').val() === \$jobId)";

  return {
    '.indexOn': ['status', 'requestedBy', 'createdAt'],
    '\$jobId': {
      // no deletes: closed jobs stay for the Log tab
      '.write': "$_active && newData.exists() && ($create || $adminEdit || $memberEdit || $remake)",
      '.validate': [
        "newData.hasChildren(['jobId', 'jobName', 'requestedBy', 'submittedBy', 'neededBy', 'lines', 'status', "
            "'createdAt', 'updatedAt', 'rev', 'lastHistoryId'])",
        "\$jobId.matches(/^JOB-[0-9]{4,}\$/) && newData.child('jobId').val() === \$jobId",
        _revOk,
        _historyLinked,
        // in progress means someone has it; requested means nobody does
        "(newData.child('status').val() !== 'inProgress' || newData.child('claimers').exists())",
        "(newData.child('status').val() !== 'requested' || !newData.child('claimers').exists())",
        "(newData.child('status').val() !== 'completed' || newData.child('completedAt').exists())",
        "(newData.child('status').val() !== 'remade' || newData.child('remadeAs').exists())",
        // a remake ticket's original must be closed as remade, pointing back at it
        "(!newData.child('remakeOf').exists() || "
            "newData.parent().child(newData.child('remakeOf').val()).child('remadeAs').val() === \$jobId)",
      ].join(' && '),
      'jobId': _v('newData.isString()'),
      'jobName': _v(_isText(100, allowEmpty: false)),
      // who it's for: unchanged, or an active scholar
      'requestedBy': _v("newData.isString() && (newData.val() === data.val() || "
          "root.child('users/' + newData.val() + '/orgData/active').val() === true)"),
      'submittedBy': _v('newData.isString()'),
      'priority': _v('newData.isString() && newData.val().matches(${_regex(JobPriority.values.map((e) => e.name))})'),
      'lines': {'\$itemId': _line()},
      // uid -> when they claimed. nobody but an admin adds someone else.
      'claimers': {
        '\$uid': _v("newData.isString() && (newData.val() === data.val() || \$uid === auth.uid || $_isAdmin)"),
      },
      'status': _v('newData.isString() && newData.val().matches(${_regex(JobStatus.values.map((e) => e.name))})'),
      'neededBy': _v("newData.isString() && newData.val().matches(/^[0-9]{4}-[0-9]{2}-[0-9]{2}\$/)"),
      'createdAt': _v('newData.isString()'),
      'updatedAt': _v('newData.isString()'),
      'claimedAt': _v('newData.isString()'),
      'completedAt': _v('newData.isString()'),
      'rev': _v(_isCount),
      'lastHistoryId': _v('newData.isString()'),
      // set when a remake ticket is created, then never changed
      'remakeOf': _v("newData.isString() && (!$_jobExisted || newData.val() === data.val())"),
      'remadeAs': _v("newData.isString() && (!data.exists() || newData.val() === data.val())"),
      'usedParts': {
        '\$itemId': _v("$_isCount && (!$_jobExisted || newData.val() === data.val())"),
      },
      'defects': {
        '\$itemId': {
          '.validate': "newData.hasChildren(['count']) && (!$_jobExisted || "
              "(${_sameAll(['count', 'reason'])}))",
          'count': _v('$_isInt && newData.val() > 0'),
          'reason': _v(_isText(500)),
          ..._noOtherFields,
        },
      },
      ..._noOtherFields,
    },
  };
}

// true when the job was already saved before this update
const _jobExisted = "root.child('ticketing/jobs/' + \$jobId).exists()";

Map<String, Object> _history() => {
      '.indexOn': ['jobId', 'itemId'],
      '\$historyId': {
        // append only, and always in the writer's own name
        '.write': "$_active && !data.exists() && newData.exists()",
        '.validate': "newData.hasChildren(['jobId', 'type', 'user', 'timestamp']) && newData.child('user').val() === auth.uid",
        'jobId': _v('newData.isString()'),
        'itemId': _v('newData.isString()'),
        'type': _v('newData.isString() && newData.val().matches(${_regex(HistoryType.values.map((e) => e.name))})'),
        'from': _v(_isText(2000)),
        'to': _v(_isText(2000)),
        'quantityChange': _v(_isInt),
        'user': _v('newData.isString()'),
        'timestamp': _v('newData.isString()'),
        ..._noOtherFields,
      },
    };

Map<String, Object> _comments() {
  const mine = "data.child('author').val() === auth.uid";
  // a new comment: admins, the requester or submitter, any claimer, or someone
  // in a commenting department (Permissions.commentDepartments). the job is
  // read as it will be after this update, so the Add Job form can save the
  // job and its first comment together.
  const job = "newData.parent().parent().child('jobs').child(newData.child('jobId').val())";
  final inDept = _inDept();
  final mayComment = "($_isAdmin || $job.child('requestedBy').val() === auth.uid || "
      "$job.child('submittedBy').val() === auth.uid || "
      "$job.child('claimers').child(auth.uid).exists() || $inDept)";
  final add = "(!data.exists() && newData.exists() && $mayComment)";
  // the author changes the text (and editedAt), nothing else
  final edit = "(data.exists() && newData.exists() && $mine && ${_sameAll(['author', 'jobId', 'timestamp'])})";
  final remove = "(data.exists() && !newData.exists() && ($mine || $_isAdmin))";
  return {
    '.indexOn': ['jobId'],
    '\$commentId': {
      '.write': "$_active && ($add || $edit || $remove)",
      // not run on delete
      '.validate': "newData.hasChildren(['jobId', 'author', 'text', 'timestamp']) && newData.child('author').val() === auth.uid && "
          "$job.exists()",
      'jobId': _v('newData.isString()'),
      'author': _v('newData.isString()'),
      'text': _v(_isText(2000, allowEmpty: false)),
      'timestamp': _v('newData.isString()'),
      'editedAt': _v('newData.isString()'),
      ..._noOtherFields,
    },
  };
}

Map<String, Object> buildTicketingRules() => {
      'rules': {
        'ticketing': {
          '.read': _active,
          // job numbers: each new job adds exactly one
          'counters': {
            'job': {
              '.write': _active,
              '.validate': "newData.isNumber() && ((!data.exists() && newData.val() === 1) || "
                  "(data.exists() && newData.val() === data.val() + 1))",
            },
            ..._noOtherFields,
          },
          'jobs': _jobs(),
          'history': _history(),
          'comments': _comments(),
          ..._noOtherFields,
        },
      },
    };

String ticketingRulesJson() => '${const JsonEncoder.withIndent('  ').convert(buildTicketingRules())}\n';
