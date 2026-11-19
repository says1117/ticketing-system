// merges the ticketing rules into the team database's existing rules, and
// points out anything in those rules that would stop ticketing working. plain
// Dart, so it can be tested; tool/merge_rules.dart is the command line.
//
// what it looks at, and why:
// - Realtime Database rules cascade: a .read or .write that allows something
//   on a parent node allows it on every child, and a child rule can't take it
//   back. a grant at the root would make the ticketing rules pointless.
// - a job's claim, return and cancel also write inventory/{id}/stock, so
//   something in the existing rules has to let those writes through.
// - rules can't be "run" here (that's rules_test/, in the emulator), so grants
//   it can't judge are listed for a person to check.

import 'dart:convert';

import 'findings.dart';

export 'findings.dart';

class RulesMergeResult {
  const RulesMergeResult({
    required this.merged,
    required this.findings,
    required this.hadComments,
  });

  // the full rules file to publish: {"rules": {...existing..., "ticketing": ...}}
  final Map<String, Object?> merged;
  final List<Finding> findings;
  // the console's rules may have // or /* */ comments; the merged file doesn't
  final bool hadComments;

  bool get hasBlockers => findings.any((f) => f.level == FindingLevel.blocker);
}

// [existingText] is the rules exactly as copied from the console (comments
// allowed). [ticketingRules] is buildTicketingRules() from rules_source.dart.
// throws FormatException when [existingText] isn't a rules file.
RulesMergeResult mergeTicketingRules(
  String existingText,
  Map<String, Object?> ticketingRules,
) {
  final stripped = stripRuleComments(existingText);
  final Object? decoded;
  try {
    decoded = jsonDecode(stripped);
  } on FormatException catch (e) {
    throw FormatException(
        'The existing rules are not valid JSON: ${e.message}');
  }
  if (decoded is! Map || decoded['rules'] is! Map) {
    throw const FormatException(
      'The existing rules must look like {"rules": {...}}. Copy the whole '
      'text from the Realtime Database Rules tab.',
    );
  }
  final ours = (ticketingRules['rules'] as Map)['ticketing'];
  if (ours == null) {
    throw ArgumentError('ticketingRules has no rules.ticketing node');
  }

  final existing = Map<String, Object?>.from(decoded['rules'] as Map);
  final findings = <Finding>[
    ..._cascadeFindings(existing),
    ..._existingTicketingFindings(existing['ticketing'], ours),
    ..._stockFindings(existing),
  ];

  // replaces an older ticketing node in place, or adds it at the end
  final merged = {...existing, 'ticketing': ours};
  return RulesMergeResult(
    merged: {'rules': merged},
    findings: findings,
    hadComments: stripped != existingText,
  );
}

// a grant at the root reaches ticketing/ whatever its own rules say
List<Finding> _cascadeFindings(Map<String, Object?> root) => [
      if (_grants(root['.write']))
        Finding(
          FindingLevel.blocker,
          'The root has ".write": ${jsonEncode(root['.write'])}. Rules '
          'cascade, so this also allows writes anywhere under ticketing/ and '
          'the ticketing rules would protect nothing. Move this grant down to '
          'the nodes that need it before adding ticketing.',
        ),
      if (_grants(root['.read']))
        Finding(
          FindingLevel.check,
          'The root has ".read": ${jsonEncode(root['.read'])}. Rules '
          'cascade, so whoever this allows can also read every job, not just '
          'active members. Confirm that is acceptable.',
        ),
    ];

List<Finding> _existingTicketingFindings(Object? theirs, Object ours) {
  if (theirs == null) return const [];
  if (jsonEncode(theirs) == jsonEncode(ours)) {
    return const [
      Finding(
        FindingLevel.info,
        'The live rules already have this version of the ticketing rules.',
      ),
    ];
  }
  return const [
    Finding(
      FindingLevel.check,
      'The live rules already have a ticketing node, and it differs from '
      'rules/ticketing.rules.json. The merged file replaces it; confirm the '
      'live one was an older copy of ours and not something else.',
    ),
  ];
}

// every rule on the way from the root to inventory/{id}/stock
List<Finding> _stockFindings(Map<String, Object?> root) {
  final inventory = root['inventory'];
  final levels = <String, Map>{'(root)': root};
  if (inventory is Map) {
    levels['inventory'] = inventory;
    for (final entry in inventory.entries) {
      final key = entry.key.toString();
      if (!key.startsWith(r'$') || entry.value is! Map) continue;
      final item = entry.value as Map;
      levels['inventory/$key'] = item;
      if (item['stock'] is Map) {
        levels['inventory/$key/stock'] = item['stock'] as Map;
      }
    }
  }

  final writes = [
    for (final e in levels.entries)
      if (_grants(e.value['.write'])) '${e.key}: ${e.value['.write']}',
  ];
  final validates = [
    for (final e in levels.entries)
      if (e.key != '(root)' && e.value['.validate'] != null)
        '${e.key}: ${e.value['.validate']}',
  ];

  return [
    if (writes.isEmpty)
      const Finding(
        FindingLevel.blocker,
        'Nothing grants ".write" on inventory/{id}/stock. Claiming, returning '
        'and cancelling a job all write stock, so they would be refused. The '
        'inventory page needs this write too; check how it works today.',
      )
    else
      Finding(
        FindingLevel.check,
        'These grant writes to inventory/{id}/stock. Confirm any active '
        'member who claims, returns or cancels a job passes at least one:\n'
        '${writes.map((w) => '    $w').join('\n')}',
      ),
    if (validates.isNotEmpty)
      Finding(
        FindingLevel.check,
        'These .validate rules apply on the way to inventory/{id}/stock. '
        'Confirm a whole-number stock of 0 or more passes them:\n'
        '${validates.map((v) => '    $v').join('\n')}',
      ),
  ];
}

// a rule value that allows something: true, or any expression but "false"
bool _grants(Object? rule) =>
    rule != null && rule != false && rule.toString().trim() != 'false';

// removes // and /* */ comments, leaving anything inside "strings" alone (a
// rule's regex can contain //). the console allows comments; JSON doesn't.
String stripRuleComments(String text) {
  final out = StringBuffer();
  var i = 0;
  while (i < text.length) {
    final c = text[i];
    if (c == '"') {
      final start = i++;
      while (i < text.length && text[i] != '"') {
        if (text[i] == r'\') i++;
        i++;
      }
      i++;
      out.write(text.substring(start, i > text.length ? text.length : i));
    } else if (text.startsWith('//', i)) {
      while (i < text.length && text[i] != '\n') {
        i++;
      }
    } else if (text.startsWith('/*', i)) {
      final end = text.indexOf('*/', i + 2);
      i = end == -1 ? text.length : end + 2;
    } else {
      out.write(c);
      i++;
    }
  }
  return out.toString();
}
