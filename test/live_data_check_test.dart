// checking the live inventory/ and users/ export (tool/live_data_check.dart).
// run with: flutter test test/live_data_check_test.dart

import 'package:flutter_test/flutter_test.dart';

import '../tool/live_data_check.dart';

void main() {
  List<FindingLevel> levels(List<Finding> f) => f.map((x) => x.level).toList();
  Finding about(List<Finding> f, String text) =>
      f.singleWhere((x) => x.message.contains(text));

  group('inventory', () {
    final good = {
      '-a': {'name': 'Fingertip', 'stock': 12},
      '-b': {'name': 'Palm plate', 'stock': 0},
    };

    test('good items only give a summary', () {
      final f =
          checkInventory(good, expectedParts: ['fingertip ', 'Palm Plate']);
      expect(levels(f), [FindingLevel.info]);
      expect(f.single.message, '2 inventory items, 1 out of stock.');
    });

    test('an empty or missing export blocks', () {
      for (final export in [null, <String, Object>{}, 'oops']) {
        expect(hasBlockers(checkInventory(export)), isTrue, reason: '$export');
      }
    });

    test('a missing arm part blocks', () {
      final f = checkInventory(good, expectedParts: ['Fingertip', 'Wrist']);
      expect(about(f, 'not inventory items').level, FindingLevel.blocker);
      expect(about(f, 'not inventory items').message, contains('    Wrist'));
    });

    test('a stock the rules cannot do arithmetic on is named', () {
      final f = checkInventory({
        '-t': {'name': 'Text', 'stock': '5'},
        '-f': {'name': 'Fraction', 'stock': 1.5},
        '-n': {'name': 'Negative', 'stock': -2},
        '-m': {'name': 'Missing'},
        '-w': {'name': 'Whole', 'stock': 3.0},
      });
      final stock = about(f, 'whole number');
      expect(stock.level, FindingLevel.check);
      expect(stock.message, contains('Text (-t): stock is text ("5")'));
      expect(stock.message, contains('Fraction (-f): stock is a fraction'));
      expect(stock.message, contains('Negative (-n): stock is negative'));
      expect(stock.message, contains('Missing (-m): no stock'));
      expect(stock.message, isNot(contains('Whole')));
    });

    test('a bad stock on an arm part blocks; on other items it is a check', () {
      final f = checkInventory({
        '-a': {'name': 'Fingertip', 'stock': '4'},
        '-b': {'name': 'Glue', 'stock': '1'},
      }, expectedParts: [
        'Fingertip'
      ]);
      expect(
          about(f, 'These arm parts have a stock').level, FindingLevel.blocker);
      expect(about(f, 'These arm parts have a stock').message,
          isNot(contains('Glue')));
      expect(about(f, 'whole number').message, contains('Glue'));
      expect(about(f, 'whole number').message, isNot(contains('Fingertip')));
    });

    test('nameless and same-named items are listed', () {
      final f = checkInventory({
        '-x': {'stock': 1},
        '-a': {'name': 'Fingertip', 'stock': 1},
        '-b': {'name': 'fingertip ', 'stock': 2},
      });
      expect(about(f, 'no name').message, contains('-x'));
      expect(about(f, 'same name').message, contains('Fingertip (2 items)'));
    });

    test('long lists are cut at 15', () {
      final f = checkInventory({
        for (var i = 0; i < 20; i++) '-$i': {'stock': 1},
      });
      expect(about(f, 'no name').message, endsWith('...and 5 more'));
    });

    test('the parts list skips blank lines and comments', () {
      expect(readPartList('# arm\nFingertip\n\n  Palm plate  \n'),
          ['Fingertip', 'Palm plate']);
    });
  });

  group('users', () {
    Map<String, Object> user(Map<String, Object> org) => {'orgData': org};
    final team = {
      'adm': user({'active': true, 'status': 'OrgStatus.admin'}),
      'm': user({
        'active': true,
        'status': 'OrgStatus.assistant',
        'department': 'Manufacturing'
      }),
      'p': user({
        'active': true,
        'status': 'OrgStatus.assistant',
        'department': 'R&D',
        'subDepartments': 'Production'
      }),
      'q': user({
        'active': true,
        'status': 'OrgStatus.associate',
        'department': 'Quality'
      }),
      'gone': user({'active': false, 'department': 'Quality'}),
      'noOrg': {'name': 'x'},
    };

    test('a healthy team only gives a summary', () {
      final f = checkUsers(team);
      expect(levels(f), [FindingLevel.info]);
      expect(
          f.single.message,
          '6 users, 4 active, 1 active admins. Active by comment department: '
          'Quality 1, Manufacturing 1, Production 1.');
    });

    test('no users, or nobody active, blocks', () {
      expect(hasBlockers(checkUsers(null)), isTrue);
      expect(hasBlockers(checkUsers({'gone': team['gone']!})), isTrue);
    });

    test('active stored as text is named, since it counts as inactive', () {
      final f = checkUsers({
        ...team,
        't': user({'active': 'true'})
      });
      expect(about(f, 'as the text').message, contains('    t'));
    });

    test('no admin, or an empty comment department, needs checking', () {
      final f = checkUsers({'m': team['m']!});
      expect(about(f, 'OrgStatus.admin').level, FindingLevel.check);
      expect(about(f, 'check the spelling').message,
          contains('Quality, Production'));
    });

    test('Assembly and wrong capitals are flagged as near misses', () {
      final f = checkUsers({
        ...team,
        'a': user({'active': true, 'department': 'Assembly'}),
        'l': user({'active': true, 'subDepartments': 'manufacturing'}),
        'r': user({'active': true, 'department': 'Research'}),
      });
      final near = about(f, 'meant to be').message;
      expect(near, contains('    Assembly'));
      expect(near, contains('    manufacturing'));
      expect(near, isNot(contains('Research')));
    });

    test('comment department only in otherDepartments is named', () {
      final f = checkUsers({
        ...team,
        'o': user({
          'active': true,
          'status': 'OrgStatus.assistant',
          'department': 'Finishing',
          'otherDepartments': {'-k': 'Quality'},
        }),
      });
      expect(about(f, 'otherDepartments').message, contains('    o'));
    });

    test('a status without the OrgStatus. prefix is named', () {
      final f = checkUsers({
        ...team,
        'x': user({'active': true, 'status': 'admin'}),
      });
      expect(about(f, 'Unexpected').message, contains('    admin'));
    });
  });
}
