// merges rules/ticketing.rules.json into the team database's live rules.
// run from the ticketing/ folder:
//
//   dart run tool/merge_rules.dart live.rules.json
//
// live.rules.json: the whole text of the Realtime Database Rules tab in the
// Firebase console (team database), pasted into a file. keep it out of git.
//
// writes, without publishing anything:
//   build/rules/merged.rules.json   the live rules with ticketing added
//   build/rules/ticketing-node.json just the "ticketing" node, to paste by hand
// and lists what someone has to check. exits with 1 if anything blocks it.

import 'dart:convert';
import 'dart:io';

import 'rules_merge.dart';
import 'rules_source.dart';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/merge_rules.dart <live rules file>');
    exit(64);
  }
  final input = File(args.single);
  if (!input.existsSync()) {
    stderr.writeln('no such file: ${input.path}');
    exit(66);
  }

  final RulesMergeResult result;
  try {
    result =
        mergeTicketingRules(input.readAsStringSync(), buildTicketingRules());
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    exit(65);
  }

  const json = JsonEncoder.withIndent('  ');
  final dir = Directory('build/rules')..createSync(recursive: true);
  final merged = File('${dir.path}/merged.rules.json')
    ..writeAsStringSync('${json.convert(result.merged)}\n');
  final node = File('${dir.path}/ticketing-node.json')
    ..writeAsStringSync(
      '${json.convert((result.merged['rules'] as Map)['ticketing'])}\n',
    );
  stdout
    ..writeln('wrote ${merged.path}')
    ..writeln('wrote ${node.path}');

  if (result.hadComments) {
    stdout.writeln(
      '\nThe live rules have comments, which ${merged.path} drops. To keep '
      'them, paste ${node.path} into the console as "ticketing": {...} instead.',
    );
  }
  printFindings(result.findings);
  if (result.hasBlockers) {
    stdout.writeln('\nDon\'t publish until every BLOCKER is fixed.');
    exit(1);
  }
}
