// the main page as a widget, on the in-memory store.
// run with: flutter test test/ticketing_page_test.dart

// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lsi_ticketing/lsi_ticketing.dart';

const lee = TicketingUser(uid: 'lee', role: Role.member);
const sam = TicketingUser(uid: 'sam', role: Role.member);
const admin = TicketingUser(uid: 'adm', role: Role.admin);
String nameOf(String uid) => const {'lee': 'Lee Navarro', 'sam': 'Sam Okafor', 'adm': 'Jordan Reyes'}[uid] ?? 'Unknown';

late MemoryTicketingStore store;

Future<void> seed() async {
  store = MemoryTicketingStore({
    'inventory': {
      '-tip': {'name': 'Fingertip', 'stock': 10},
      '-palm': {'name': 'Palm Plate', 'stock': 1},
    },
  });
  final r = TicketingRepository(store: store, user: lee);
  final due = DateTime.utc(2030, 1, 1);
  final a = await r.createJob(jobName: 'Left arm', requestedBy: 'lee', dueDate: due, parts: {'-tip': 5});
  await TicketingRepository(store: store, user: sam).claim(a.jobId);
  await r.createJob(jobName: 'Thumbs', requestedBy: 'lee', dueDate: due, priority: JobPriority.high, parts: {'-tip': 2});
  await r.createJob(jobName: 'Two palms', requestedBy: 'lee', dueDate: due, parts: {'-palm': 2});
}

Future<void> pumpPage(WidgetTester tester, TicketingUser user, {Size size = const Size(1280, 800)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: TicketingPage(repository: TicketingRepository(store: store, user: user), nameOf: nameOf),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async => seed());

  testWidgets('opens on In-Progress with counts on the tabs', (tester) async {
    await pumpPage(tester, sam);
    expect(find.text('In-Progress (1)'), findsOneWidget);
    expect(find.text('Requested (2)'), findsOneWidget);
    expect(find.text('Left arm'), findsOneWidget);
    expect(find.text('Thumbs'), findsNothing);
    for (final h in ['Job Name', 'Status', 'Time Requested', 'Time Claimed', 'Requested By', 'Edit', 'Unclaim']) {
      expect(find.text(h), findsOneWidget, reason: h);
    }
  });

  testWidgets('Requested shows priority and a Claim button that moves the job', (tester) async {
    await pumpPage(tester, sam);
    await tester.tap(find.byKey(const Key('tab-requested')));
    await tester.pumpAndSettle();
    expect(find.text('High'), findsOneWidget);
    await tester.tap(find.byKey(const Key('claim-JOB-0002')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Claimed JOB-0002'), findsOneWidget);
    expect(find.text('In-Progress (2)'), findsOneWidget);
  });

  testWidgets('a short-stock claim explains what is missing', (tester) async {
    await pumpPage(tester, sam);
    await tester.tap(find.byKey(const Key('tab-requested')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('claim-JOB-0003')));
    await tester.pumpAndSettle();
    expect(find.text('Not enough in inventory: Palm Plate (need 2, 1 on hand).'), findsOneWidget);
    expect(find.text('Requested (2)'), findsOneWidget);
  });

  testWidgets('unclaim asks first, then sends the job back to Requested', (tester) async {
    await pumpPage(tester, sam);
    await tester.tap(find.byKey(const Key('unclaim-JOB-0001')));
    await tester.pumpAndSettle();
    expect(find.textContaining('its parts go back to inventory'), findsOneWidget);
    await tester.tap(find.text('Unclaim').last);
    await tester.pumpAndSettle();
    expect(find.text('In-Progress (0)'), findsOneWidget);
    expect(find.text('Requested (3)'), findsOneWidget);
  });

  testWidgets('edit and unclaim are only enabled for the right people', (tester) async {
    await pumpPage(tester, lee); // requester, not a claimer
    IconButton button(String key) => tester.widget<IconButton>(find.byKey(Key(key)));
    expect(button('edit-JOB-0001').onPressed, isNotNull);
    expect(button('unclaim-JOB-0001').onPressed, isNull);
  });

  testWidgets('search filters the list', (tester) async {
    await pumpPage(tester, sam);
    await tester.tap(find.byKey(const Key('tab-requested')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('ticketing-search')), 'thumb');
    await tester.pumpAndSettle();
    expect(find.text('Thumbs'), findsOneWidget);
    expect(find.text('Two palms'), findsNothing);
  });

  testWidgets('Log shows the feed with All / Completed / Failed filters', (tester) async {
    await pumpPage(tester, admin);
    await tester.tap(find.byKey(const Key('tab-log')));
    await tester.pumpAndSettle();
    expect(find.text('Sam Okafor claimed JOB-0001 "Left arm"'), findsOneWidget);
    await tester.tap(find.byKey(const Key('log-completed')));
    await tester.pumpAndSettle();
    expect(find.text('No jobs have been completed yet.'), findsOneWidget);
  });

  // part 2 end to end: row -> popup -> remake form -> remake popup -> Log
  testWidgets('a remake made from the page closes the job as Failed in the Log', (tester) async {
    await pumpPage(tester, sam);
    await tester.tap(find.byKey(const Key('row-JOB-0001')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('popup-create-remake')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('remake-pick--tip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('remake-submit')));
    await tester.pumpAndSettle();
    expect(find.textContaining('You claimed it'), findsOneWidget);
    await tester.tap(find.byKey(const Key('popup-close')));
    await tester.pumpAndSettle();

    // the remake replaced the original on In-Progress
    expect(find.text('Remake'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tab-log')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('log-failed')));
    await tester.pumpAndSettle();
    expect(find.text('Sam Okafor marked JOB-0001 "Left arm" as failed (remake JOB-0004)'), findsOneWidget);
  });

  testWidgets('phones get cards with labelled buttons', (tester) async {
    await pumpPage(tester, sam, size: const Size(390, 844));
    expect(find.text('Job Name'), findsNothing, reason: 'no table header on phones');
    expect(find.text('Left arm'), findsOneWidget);
    expect(find.text('Unclaim'), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('unclaim-JOB-0001'))).height, greaterThanOrEqualTo(44));
  });

  testWidgets('the + button calls onAddJob', (tester) async {
    var added = 0;
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TicketingPage(
          repository: TicketingRepository(store: store, user: sam),
          nameOf: nameOf,
          onAddJob: () => added++,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add-job')));
    expect(added, 1);
  });
}
