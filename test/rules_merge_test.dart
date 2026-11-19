// merging the ticketing rules into the live rules (tool/rules_merge.dart).
// run with: flutter test test/rules_merge_test.dart

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../tool/rules_merge.dart';
import '../tool/rules_source.dart';

void main() {
  final ours = buildTicketingRules();
  final ticketing = (ours['rules'] as Map)['ticketing'];

  // an inventory page that lets signed-in users write
  const inventory = {
    '.read': 'auth != null',
    '\$itemId': {'.write': 'auth != null'},
  };
  String live(Map<String, Object?> rules) => jsonEncode({'rules': rules});
  Iterable<FindingLevel> levels(RulesMergeResult r) =>
      r.findings.map((f) => f.level);

  test('adds ticketing and keeps every existing node as it was', () {
    final r = mergeTicketingRules(
      live({
        'users': {'.read': 'auth != null'},
        'inventory': inventory
      }),
      ours,
    );
    final rules = r.merged['rules'] as Map;
    expect(rules.keys, ['users', 'inventory', 'ticketing']);
    expect(rules['users'], {'.read': 'auth != null'});
    expect(rules['inventory'], inventory);
    expect(jsonEncode(rules['ticketing']), jsonEncode(ticketing));
    expect(r.hasBlockers, isFalse);
  });

  test('a grant at the root blocks; a root read only needs checking', () {
    final write = mergeTicketingRules(
      live({'.write': 'auth != null', 'inventory': inventory}),
      ours,
    );
    expect(write.hasBlockers, isTrue);
    expect(write.findings.first.message, contains('cascade'));

    final read = mergeTicketingRules(
      live({'.read': true, 'inventory': inventory}),
      ours,
    );
    expect(read.hasBlockers, isFalse);
    expect(read.findings.first.level, FindingLevel.check);
    expect(read.findings.first.message, contains('every job'));
  });

  test('a root rule of false grants nothing', () {
    final r = mergeTicketingRules(
      live({'.read': false, '.write': 'false', 'inventory': inventory}),
      ours,
    );
    expect(r.hasBlockers, isFalse);
    expect(r.findings.where((f) => f.message.contains('root')), isEmpty);
  });

  test('no write on inventory/{id}/stock blocks, since claims write stock', () {
    for (final rules in [
      <String, Object?>{},
      {
        'inventory': {'.read': 'auth != null'}
      },
      {
        'inventory': {
          '\$id': {
            'stock': {'.write': false}
          }
        }
      },
    ]) {
      final r = mergeTicketingRules(live(rules), ours);
      expect(r.hasBlockers, isTrue, reason: '$rules');
      expect(r.findings.single.message, contains('inventory/{id}/stock'));
    }
  });

  test('stock grants and validations are listed for a person to check', () {
    final r = mergeTicketingRules(
      live({
        'inventory': {
          '.write': 'auth.uid != null',
          '\$id': {
            '.validate': "newData.hasChildren(['name'])",
            'stock': {'.validate': 'newData.isNumber()'},
          },
        },
      }),
      ours,
    );
    expect(levels(r), [FindingLevel.check, FindingLevel.check]);
    expect(r.findings[0].message, contains('inventory: auth.uid != null'));
    expect(r.findings[1].message,
        contains("inventory/\$id: newData.hasChildren(['name'])"));
    expect(r.findings[1].message,
        contains('inventory/\$id/stock: newData.isNumber()'));
  });

  test('an existing ticketing node is replaced, and said so', () {
    final older = mergeTicketingRules(
      live({
        'ticketing': {'.read': true},
        'inventory': inventory
      }),
      ours,
    );
    expect(jsonEncode((older.merged['rules'] as Map)['ticketing']),
        jsonEncode(ticketing));
    expect(older.findings.first.message, contains('differs'));

    final same = mergeTicketingRules(
      live({'ticketing': ticketing, 'inventory': inventory}),
      ours,
    );
    expect(levels(same), contains(FindingLevel.info));
    expect(same.hasBlockers, isFalse);
  });

  group('the console text', () {
    test('comments are dropped, and reported', () {
      const text = '''
{
  // team database
  "rules": {
    /* inventory page */
    "inventory": { "\$id": { ".write": "auth != null" } }
  }
}''';
      final r = mergeTicketingRules(text, ours);
      expect(r.hadComments, isTrue);
      expect((r.merged['rules'] as Map).keys, ['inventory', 'ticketing']);
      expect(
          mergeTicketingRules(live({'inventory': inventory}), ours).hadComments,
          isFalse);
    });

    test('// inside a rule string is not a comment', () {
      const rule = r"newData.val().matches(/^https?:\/\//)";
      final text = jsonEncode({
        'rules': {
          'links': {'.validate': rule},
          'inventory': inventory,
        },
      });
      expect(stripRuleComments(text), text);
      final r = mergeTicketingRules(text, ours);
      expect(((r.merged['rules'] as Map)['links'] as Map)['.validate'], rule);
    });

    test('anything that is not a rules file is refused with a reason', () {
      Matcher saying(String s) => throwsA(isA<FormatException>()
          .having((e) => e.message, 'message', contains(s)));
      expect(
          () => mergeTicketingRules('{oops', ours), saying('not valid JSON'));
      expect(() => mergeTicketingRules('{}', ours), saying('{"rules"'));
      expect(() => mergeTicketingRules('[]', ours), saying('{"rules"'));
    });
  });
}
