// checks an export of the team database's inventory/ and users/ against what
// the ticketing code and rules expect. plain Dart, so it can be tested;
// tool/check_live_data.dart is the command line.
//
// why each check matters:
// - the job line rules do arithmetic on inventory/{id}/stock
//   (new - old === 0 - taken), so a stock that is missing, text ("5"), a
//   fraction or negative makes every claim of that part fail.
// - a job can only reserve parts that exist as inventory items.
// - who may do what comes from users/{uid}/orgData: active === true (the
//   boolean, not "true"), status 'OrgStatus.admin', and department or
//   subDepartments spelled exactly as in Permissions.commentDepartments.

import 'package:lsi_ticketing/src/rules/permissions.dart';

import 'findings.dart';

export 'findings.dart';

// the arm parts list for --parts: one name per line, blank lines and
// # comments ignored
List<String> readPartList(String text) => [
      for (final line in text.split('\n'))
        if (line.trim().isNotEmpty && !line.trim().startsWith('#')) line.trim(),
    ];

// [inventory] is the exported inventory/ node: {itemId: {name, stock, ...}}.
// [expectedParts] are names that must exist (matched ignoring case and
// surrounding spaces); a problem with one of those blocks.
List<Finding> checkInventory(
  Object? inventory, {
  List<String> expectedParts = const [],
}) {
  if (inventory is! Map || inventory.isEmpty) {
    return const [
      Finding(
        FindingLevel.blocker,
        'The inventory export is empty or not an object of items. Jobs can '
        'only reserve parts that are inventory items.',
      ),
    ];
  }

  final expected = {for (final p in expectedParts) _key(p): p};
  final byName = <String, List<String>>{};
  final unnamed = <String>[];
  final badStock = <String>[];
  final badExpected = <String>[];
  var outOfStock = 0;

  inventory.forEach((id, item) {
    final m = item is Map ? item : const {};
    final name = m['name'];
    if (name is! String || name.trim().isEmpty) {
      unnamed.add('$id');
    } else {
      byName.putIfAbsent(_key(name), () => []).add(name.trim());
    }
    final label = name is String && name.trim().isNotEmpty
        ? '${name.trim()} ($id)'
        : '$id';
    final problem = _stockProblem(m['stock']);
    if (problem != null) {
      badStock.add('$label: $problem');
      if (name is String && expected.containsKey(_key(name))) {
        badExpected.add('$label: $problem');
      }
    } else if (m['stock'] == 0) {
      outOfStock++;
    }
  });

  final missing = [
    for (final e in expected.entries)
      if (!byName.containsKey(e.key)) e.value,
  ];
  final duplicates = [
    for (final names in byName.values)
      if (names.length > 1) '${names.first} (${names.length} items)',
  ];

  return [
    if (missing.isNotEmpty)
      Finding(
        FindingLevel.blocker,
        'These arm parts are not inventory items, so no job can reserve '
        'them. Add them on the inventory page:\n${_list(missing)}',
      ),
    if (badExpected.isNotEmpty)
      Finding(
        FindingLevel.blocker,
        'These arm parts have a stock the rules can\'t do arithmetic on, so '
        'claiming them would be refused. Fix the stock on the inventory '
        'page:\n${_list(badExpected)}',
      ),
    if (badStock.length > badExpected.length)
      Finding(
        FindingLevel.check,
        'These items have a stock that isn\'t a whole number of 0 or more. '
        'Claiming them would be refused:\n'
        '${_list(badStock.where((s) => !badExpected.contains(s)).toList())}',
      ),
    if (unnamed.isNotEmpty)
      Finding(
        FindingLevel.check,
        'These items have no name, so they show blank in the parts '
        'picker:\n${_list(unnamed)}',
      ),
    if (duplicates.isNotEmpty)
      Finding(
        FindingLevel.check,
        'More than one item has the same name, so a scholar could reserve the '
        'wrong one:\n${_list(duplicates)}',
      ),
    Finding(
      FindingLevel.info,
      '${inventory.length} inventory items, $outOfStock out of stock.',
    ),
  ];
}

// [users] is the exported users/ node: {uid: {orgData: {...}, ...}}. only
// orgData is read, and only counts and uids are reported.
List<Finding> checkUsers(Object? users) {
  if (users is! Map || users.isEmpty) {
    return const [
      Finding(
        FindingLevel.blocker,
        'The users export is empty or not an object of users. Only users with '
        'orgData.active === true can use Ticketing.',
      ),
    ];
  }

  var active = 0;
  var admins = 0;
  final textActive = <String>[];
  final perDept = {for (final d in Permissions.commentDepartments) d: 0};
  final nearMisses = <String>{};
  final onlyOther = <String>[];
  final statuses = <String, int>{};

  users.forEach((uid, user) {
    final org = user is Map && user['orgData'] is Map
        ? user['orgData'] as Map
        : const {};
    if (org['active'] is String && org['active'] == 'true') {
      textActive.add('$uid');
    }
    if (org['active'] != true) return;
    active++;
    final status = '${org['status']}';
    statuses[status] = (statuses[status] ?? 0) + 1;
    if (org['status'] == Permissions.adminStatus) admins++;

    final depts = Permissions.departmentsOf(org);
    for (final d in depts) {
      if (perDept.containsKey(d)) {
        perDept[d] = perDept[d]! + 1;
      } else if (_nearMiss(d)) {
        nearMisses.add(d);
      }
    }
    final others = org['otherDepartments'];
    if (!depts.any(Permissions.commentDepartments.contains) &&
        others is Map &&
        others.values.any(Permissions.commentDepartments.contains)) {
      onlyOther.add('$uid');
    }
  });

  final empty = [
    for (final e in perDept.entries)
      if (e.value == 0) e.key,
  ];
  final odd = statuses.keys
      .where((s) => s != Permissions.adminStatus && !s.startsWith('OrgStatus.'))
      .toList();

  return [
    if (active == 0)
      const Finding(
        FindingLevel.blocker,
        'No user has orgData.active === true, so nobody could use Ticketing.',
      ),
    if (textActive.isNotEmpty)
      Finding(
        FindingLevel.check,
        'These users have active stored as the text "true", not the boolean. '
        'The app and the rules treat them as inactive:\n${_list(textActive)}',
      ),
    if (admins == 0 && active > 0)
      Finding(
        FindingLevel.check,
        'No active user has status ${Permissions.adminStatus}, so nobody can '
        'unclaim someone else or edit or cancel other people\'s jobs.',
      ),
    if (empty.isNotEmpty && active > 0)
      Finding(
        FindingLevel.check,
        'No active user has department or subDepartments set to '
        '${empty.join(', ')}. Members of these departments can comment on any '
        'job; check the spelling in orgData.',
      ),
    if (nearMisses.isNotEmpty)
      Finding(
        FindingLevel.check,
        'These departments are meant to be '
        '${Permissions.commentDepartments.join(', ')} (Assembly is now '
        'Manufacturing) but don\'t match exactly, so their members can\'t '
        'comment:\n'
        '${_list(nearMisses.toList())}',
      ),
    if (onlyOther.isNotEmpty)
      Finding(
        FindingLevel.check,
        'These users are in ${Permissions.commentDepartments.join(', ')} only '
        'through otherDepartments. The nav shows them Ticketing, but they '
        'can\'t comment, because the rules can\'t search otherDepartments:\n'
        '${_list(onlyOther)}',
      ),
    if (odd.isNotEmpty)
      Finding(
        FindingLevel.check,
        'Unexpected orgData.status values (lsicompapp stores '
        '"OrgStatus.<name>"); these users count as members:\n${_list(odd)}',
      ),
    Finding(
      FindingLevel.info,
      '${users.length} users, $active active, $admins active admins. Active '
      'by comment department: '
      '${perDept.entries.map((e) => '${e.key} ${e.value}').join(', ')}.',
    ),
  ];
}

// a whole number of 0 or more, as the rules' arithmetic needs
String? _stockProblem(Object? stock) {
  if (stock == null) return 'no stock';
  if (stock is String) return 'stock is text ("$stock")';
  if (stock is! num) return 'stock is ${stock.runtimeType}';
  if (stock is double && stock != stock.roundToDouble()) {
    return 'stock is a fraction ($stock)';
  }
  if (stock < 0) return 'stock is negative ($stock)';
  return null;
}

String _key(String name) => name.trim().toLowerCase();

// "manufacturing", "Quality " or the old "Assembly" name
bool _nearMiss(String dept) =>
    dept.trim().toLowerCase() == 'assembly' ||
    Permissions.commentDepartments
        .any((d) => d.toLowerCase() == dept.trim().toLowerCase());

// one per line, at most 15, then a count of the rest
String _list(List<String> items) {
  const max = 15;
  final shown = items.take(max).map((i) => '    $i').join('\n');
  return items.length > max
      ? '$shown\n    ...and ${items.length - max} more'
      : shown;
}
