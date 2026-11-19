// checks the team database's live inventory/ and users/ before ticketing goes
// live. run from the ticketing/ folder:
//
//   dart run tool/check_live_data.dart --inventory inventory.json \
//       --users users.json --parts arm_parts.txt
//
// inventory.json, users.json: Export JSON of each node from the Realtime
// Database Data tab in the Firebase console (team database). users.json holds
// personal data: keep both outside this repo and delete them afterwards.
// arm_parts.txt (optional): the arm part names that must exist, one per line.
//
// reads only; changes nothing. exits with 1 if anything blocks going live.

import 'dart:convert';
import 'dart:io';

import 'live_data_check.dart';

void main(List<String> args) {
  final files = <String, String>{};
  for (var i = 0; i < args.length; i += 2) {
    final flag = args[i];
    if (!const ['--inventory', '--users', '--parts'].contains(flag) ||
        i + 1 >= args.length) {
      _usage();
    }
    files[flag.substring(2)] = args[i + 1];
  }
  if (!files.containsKey('inventory') && !files.containsKey('users')) _usage();

  final findings = <Finding>[];
  if (files['inventory'] != null) {
    final parts = files['parts'] == null
        ? const <String>[]
        : readPartList(_read(files['parts']!));
    stdout.writeln('inventory: ${files['inventory']}'
        '${parts.isEmpty ? ' (no --parts list, so no arm parts are required)' : ', ${parts.length} arm parts required'}');
    findings.addAll(
      checkInventory(_json(files['inventory']!), expectedParts: parts),
    );
  }
  if (files['users'] != null) {
    stdout.writeln('users: ${files['users']}');
    findings.addAll(checkUsers(_json(files['users']!)));
  }

  printFindings(findings);
  if (hasBlockers(findings)) {
    stdout.writeln('\nDon\'t go live until every BLOCKER is fixed.');
    exit(1);
  }
}

String _read(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('no such file: $path');
    exit(66);
  }
  return file.readAsStringSync();
}

Object? _json(String path) {
  try {
    return jsonDecode(_read(path));
  } on FormatException catch (e) {
    stderr.writeln('$path is not valid JSON: ${e.message}');
    exit(65);
  }
}

Never _usage() {
  stderr.writeln(
    'usage: dart run tool/check_live_data.dart [--inventory <file>] '
    '[--users <file>] [--parts <file>]',
  );
  exit(64);
}
