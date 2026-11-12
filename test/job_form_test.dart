// the Add Job / Edit job form, on the in-memory store.
// run with: flutter test test/job_form_test.dart

// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lsi_ticketing/lsi_ticketing.dart';

const lee = TicketingUser(uid: 'lee', role: Role.member);
const sam = TicketingUser(uid: 'sam', role: Role.member);
const people = {'lee': 'Lee Navarro', 'sam': 'Sam Okafor', 'kai': 'Kai Patel'};
String nameOf(String uid) => people[uid] ?? 'Unknown';

late MemoryTicketingStore store;
Job? result;

Future<void> openForm(WidgetTester tester, TicketingUser user, {Job? job}) async {
  tester.view.physicalSize = const Size(1280, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  result = null;
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () async => result = await showJobForm(context,
                repository: TicketingRepository(store: store, user: user), nameOf: nameOf, people: people, job: job),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> addPart(WidgetTester tester, String itemId) async {
  await tester.tap(find.byKey(const Key('form-add-part')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key('picker-$itemId')));
  await tester.pumpAndSettle();
}

// stands in for the calendar: sets the due date the way picking a day does
Future<void> pickDueDate(WidgetTester tester, int day) async {
  await tester.tap(find.byKey(const Key('form-due')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('$day'));
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    store = MemoryTicketingStore({
      'inventory': {
        '-tip': {'name': 'Fingertip', 'itemNumber': 'FT-01', 'location': 'Shelf A2', 'stock': 10},
        '-palm': {'name': 'Palm Plate', 'itemNumber': 'LP-02', 'stock': 1},
      },
    });
  });

  testWidgets('shows the fields from the mockup, with * on the required ones', (tester) async {
    await openForm(tester, sam);
    expect(find.text('Request a job'), findsOneWidget);
    for (final label in ['Name', 'Requested by', 'Due date', 'Parts required']) {
      expect(find.textContaining(label), findsWidgets, reason: label);
    }
    expect(find.text('Priority'), findsOneWidget);
    expect(find.text('Comments'), findsOneWidget);
    expect(find.text('MM/DD/YYYY'), findsOneWidget);
    expect(find.text('Sam Okafor (you)'), findsWidgets, reason: 'requested by starts as the signed-in person');
  });

  testWidgets('submitting empty explains each missing field and saves nothing', (tester) async {
    await openForm(tester, sam);
    await tester.tap(find.byKey(const Key('form-submit')));
    await tester.pumpAndSettle();
    expect(find.text('Give the job a name.'), findsOneWidget);
    expect(find.text('Pick a due date.'), findsOneWidget);
    expect(find.text('Add at least one part.'), findsOneWidget);
    expect(store.data['ticketing'], isNull);
  });

  testWidgets('a full request saves the job and its first comment', (tester) async {
    await openForm(tester, sam);
    await tester.enterText(find.byKey(const Key('form-name')), 'Right arm – patient 112');
    await pickDueDate(tester, 28);
    await addPart(tester, '-tip');
    for (var i = 0; i < 2; i++) {
      await tester.ensureVisible(find.byKey(const Key('form-plus--tip')));
      await tester.tap(find.byKey(const Key('form-plus--tip')));
      await tester.pumpAndSettle();
    }
    expect(tester.widget<Text>(find.byKey(const Key('form-qty--tip'))).data, '3');
    expect(find.text('10 on hand'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('form-comment')), 'Blue shell please');
    await tester.ensureVisible(find.byKey(const Key('form-comment')));
    await tester.tap(find.byKey(const Key('form-submit')));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect([result!.jobName, result!.requestedBy, result!.submittedBy], ['Right arm – patient 112', 'sam', 'sam']);
    expect(result!.lines['-tip']!.quantity, 3);
    expect(result!.neededBy.day, 28);
    final repo = TicketingRepository(store: store, user: sam);
    expect((await repo.commentsForJob(result!.jobId)).single.text, 'Blue shell please');
    expect(find.text('Request a job'), findsNothing, reason: 'the form closes after saving');
  });

  testWidgets('warns when a part is short, but still allows the request', (tester) async {
    await openForm(tester, sam);
    await addPart(tester, '-palm');
    await tester.tap(find.byKey(const Key('form-plus--palm')));
    await tester.pump();
    expect(find.textContaining('Only 1 on hand'), findsOneWidget);
  });

  testWidgets('picking the same part again adds one more; parts can be removed', (tester) async {
    await openForm(tester, sam);
    await addPart(tester, '-tip');
    await addPart(tester, '-tip');
    expect(find.text('2'), findsOneWidget);
    await tester.tap(find.byKey(const Key('form-remove--tip')));
    await tester.pump();
    expect(find.byKey(const Key('form-part--tip')), findsNothing);
  });

  testWidgets('the part picker searches by name, number or location', (tester) async {
    await openForm(tester, sam);
    await tester.tap(find.byKey(const Key('form-add-part')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('picker-search')), 'shelf a2');
    await tester.pump();
    expect(find.byKey(const Key('picker--tip')), findsOneWidget);
    expect(find.byKey(const Key('picker--palm')), findsNothing);
  });

  group('editing', () {
    Future<Job> existing({bool claimed = false}) async {
      final j = await TicketingRepository(store: store, user: lee).createJob(
          jobName: 'Left arm', requestedBy: 'lee', dueDate: DateTime.utc(2030, 1, 1), parts: {'-tip': 2});
      if (!claimed) return j;
      return TicketingRepository(store: store, user: sam).claim(j.jobId);
    }

    testWidgets('starts filled in, has no comment box, and saves changes', (tester) async {
      final j = await existing();
      await openForm(tester, lee, job: j);
      expect(find.text('Edit ${j.jobId}'), findsOneWidget);
      expect(find.byKey(const Key('form-comment')), findsNothing);
      expect(find.text('01/01/2030'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('form-name')), 'Left arm v2');
      await tester.ensureVisible(find.byKey(const Key('form-plus--tip')));
      await tester.tap(find.byKey(const Key('form-plus--tip')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('form-submit')));
      await tester.pumpAndSettle();
      expect([result!.jobName, result!.lines['-tip']!.quantity], ['Left arm v2', 3]);
    });

    testWidgets('parts are locked once the job is claimed', (tester) async {
      final j = await existing(claimed: true);
      await openForm(tester, lee, job: j);
      expect(find.textContaining('can\'t change once the job is claimed'), findsOneWidget);
      expect(find.byKey(const Key('form-add-part')), findsNothing);
      expect(find.byKey(const Key('form-plus--tip')), findsNothing);
      await tester.enterText(find.byKey(const Key('form-name')), 'Renamed');
      await tester.tap(find.byKey(const Key('form-submit')));
      await tester.pumpAndSettle();
      expect(result!.jobName, 'Renamed');
    });
  });

  testWidgets('phones get a full-screen form', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showJobForm(context,
                repository: TicketingRepository(store: store, user: sam), nameOf: nameOf, people: people),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(tester.getSize(find.byType(Dialog)).width, 390);
    expect(tester.getSize(find.byKey(const Key('form-submit'))).height, greaterThanOrEqualTo(44));
  });
}
