// preview of the Ticketing page outside lsicompapp: lsicompapp's dark theme, an
// in-memory store with a sample inventory, and sample jobs in every state.
// nothing here touches Firebase. the "Signed in as" menu switches users so
// you can see what each role can do.
//
// run from this folder:  flutter run -d chrome   (or -d web-server)

import 'package:css/css.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:lsi_ticketing/lsi_ticketing.dart';

// sample people (not real scholars)
const Map<String, String> names = {
  'adm': 'Jordan Reyes (admin)',
  'sam': 'Sam Okafor',
  'lee': 'Lee Navarro',
  'kai': 'Kai Patel',
  'qa': 'Morgan Liu (Quality)',
  'ari': 'Ari Chen',
};

const Map<String, TicketingUser> users = {
  'adm': TicketingUser(uid: 'adm', role: Role.admin),
  'sam': TicketingUser(uid: 'sam', role: Role.member, departments: {'Manufacturing'}),
  'lee': TicketingUser(uid: 'lee', role: Role.member, departments: {'Finishing'}),
  'kai': TicketingUser(uid: 'kai', role: Role.member, departments: {'Manufacturing'}),
  'qa': TicketingUser(uid: 'qa', role: Role.member, departments: {'Quality'}),
  'ari': TicketingUser(uid: 'ari', role: Role.member, departments: {'Finishing'}),
};

String nameOf(String uid) => names[uid] ?? 'Unknown';

Future<MemoryTicketingStore> sampleStore() async {
  final store = MemoryTicketingStore({
    'inventory': {
      '-fingertip': {'name': 'Fingertip', 'itemNumber': 'FT-01', 'stock': 40, 'threshold': 10, 'location': 'Shelf A2'},
      '-indexBase': {'name': 'Index Base', 'itemNumber': 'IB-03', 'stock': 12, 'threshold': 4, 'location': 'Shelf A3'},
      '-palmL': {'name': 'Left Palm Plate', 'itemNumber': 'LP-02', 'stock': 6, 'threshold': 2, 'location': 'Shelf B1'},
      '-palmR': {'name': 'Right Palm Plate', 'itemNumber': 'RP-02', 'stock': 1, 'threshold': 2, 'location': 'Shelf B1'},
      '-thumb': {'name': 'Thumb Assembly', 'itemNumber': 'TA-07', 'stock': 8, 'threshold': 3, 'location': 'Shelf B4'},
      '-wrist': {'name': 'Wrist Rotator', 'itemNumber': 'WR-11', 'stock': 5, 'threshold': 2, 'location': 'Cabinet 2'},
    },
  });

  // sample history spread over the last few days
  var clock = DateTime.now().toUtc().subtract(const Duration(days: 4, hours: 3));
  TicketingRepository as(String uid) => TicketingRepository(store: store, user: users[uid]!, clock: () => clock);
  void later(int minutes) => clock = clock.add(Duration(minutes: minutes));
  final today = DateTime.now();
  DateTime inDays(int d) => DateTime.utc(today.year, today.month, today.day).add(Duration(days: d));

  final a = await as('lee').createJob(
      jobName: 'Left arm – patient 104', requestedBy: 'lee', dueDate: inDays(6), priority: JobPriority.high,
      parts: {'-fingertip': 5, '-indexBase': 2, '-palmL': 1, '-thumb': 1}, comment: 'Blue shell, size M.');
  later(90);
  await as('sam').claim(a.jobId);
  later(30);
  await as('kai').claim(a.jobId);
  final note = await as('sam').addComment(a.jobId, 'Assembly started.');
  later(5);
  await as('sam').editComment(note.id, 'Assembly started. Check thumb alignment before completing.');
  later(200);

  final b = await as('ari').createJob(
      jobName: 'Spare fingertips for demo hand', requestedBy: 'ari', dueDate: inDays(-1), priority: JobPriority.low,
      parts: {'-fingertip': 4});
  later(60);
  await as('kai').claim(b.jobId);
  later(300);

  final c = await as('adm').createJob(
      jobName: 'Right arm – patient 98', requestedBy: 'lee', dueDate: inDays(3), priority: JobPriority.medium,
      parts: {'-fingertip': 5, '-palmR': 2, '-wrist': 1});
  later(45);
  await as('lee').createJob(
      jobName: 'Wrist upgrade – patient 87', requestedBy: 'lee', dueDate: inDays(10),
      parts: {'-wrist': 1, '-thumb': 1});
  later(120);
  await as('ari').createJob(
      jobName: 'Thumb replacements', requestedBy: 'ari', dueDate: inDays(2), priority: JobPriority.high,
      parts: {'-thumb': 2});
  later(500);

  // a finished job, and one that failed QC and was remade
  final d = await as('lee').createJob(
      jobName: 'Left arm – patient 91', requestedBy: 'lee', dueDate: inDays(-2), priority: JobPriority.medium,
      parts: {'-fingertip': 5, '-indexBase': 2, '-palmL': 1});
  later(30);
  await as('sam').claim(d.jobId);
  later(600);
  await as('sam').complete(d.jobId);
  later(240);
  await as('qa').addComment(d.jobId, 'Two fingertips cracked at the joint during QC.');
  later(10);
  await as('qa').createRemake(d.jobId,
      defects: {'-fingertip': const Defect(count: 2, reason: 'cracked at the joint')},
      jobName: 'Left arm – patient 91 (remake)');
  later(180);

  final e = await as('ari').createJob(
      jobName: 'Index fingers for clinic kit', requestedBy: 'ari', dueDate: inDays(-3),
      parts: {'-indexBase': 2, '-fingertip': 2});
  later(20);
  await as('kai').claim(e.jobId);
  later(400);
  await as('kai').complete(e.jobId);
  later(60);
  await as('lee').addComment(c.jobId, 'Right palm plates are short. Can someone check the next order?');
  // holds the only right palm plate. a remake of that palm can't be claimed,
  // so it shows the "waiting in Requested" result; remaking its thumb shows
  // the "claimed" one.
  final f = await as('sam').createJob(
      jobName: 'Right hand – patient 77', requestedBy: 'lee', dueDate: inDays(4), priority: JobPriority.medium,
      parts: {'-palmR': 1, '-thumb': 1});
  later(15);
  await as('sam').claim(f.jobId);
  later(30);
  final cancelled = await as('ari').createJob(
      jobName: 'Clinic spare arm – cancelled', requestedBy: 'ari', dueDate: inDays(7),
      parts: {'-thumb': 1});
  later(10);
  await as('ari').cancel(cancelled.jobId);
  return store;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await sampleStore();
  runApp(PreviewApp(store: store));
}

class PreviewApp extends StatefulWidget {
  const PreviewApp({super.key, required this.store});
  final MemoryTicketingStore store;

  @override
  State<PreviewApp> createState() => _PreviewAppState();
}

class _PreviewAppState extends State<PreviewApp> {
  String _uid = 'sam';

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ticketing preview',
      debugShowCheckedModeBanner: false,
      theme: CSS.darkTheme,
      home: Scaffold(
        appBar: AppBar(
          backgroundColor: CSS.darkTheme.cardColor,
          title: const Text('Ticketing (preview, sample data)', style: TextStyle(fontSize: 16)),
          actions: [
            const Text('Signed in as  ', style: TextStyle(fontSize: 13)),
            DropdownButton<String>(
              value: _uid,
              underline: const SizedBox(),
              items: [for (final e in names.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
              onChanged: (v) => setState(() => _uid = v ?? _uid),
            ),
            const SizedBox(width: 16),
          ],
        ),
        body: TicketingPage(
          key: ValueKey(_uid),
          repository: TicketingRepository(store: widget.store, user: users[_uid]!),
          nameOf: nameOf,
          people: {for (final e in names.entries) e.key: e.value},
        ),
      ),
    );
  }
}
