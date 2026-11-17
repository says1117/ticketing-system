// the remake form, built up step by step. run with:
//   flutter test test/remake_form_test.dart
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lsi_ticketing/lsi_ticketing.dart';

const claimer = TicketingUser(uid: 'maker', role: Role.member);
const requester = TicketingUser(uid: 'req', role: Role.member);
const names = {'req': 'Lee', 'maker': 'Sam'};
late MemoryTicketingStore store;
TicketingRepository as(TicketingUser user) => TicketingRepository(store: store, user: user);

// an in-progress job: 2 fingertips and a palm, high priority, due Jan 2 2030
Future<Job> claimedJob() async {
  final job = await as(requester).createJob(
      jobName: 'Left arm', requestedBy: 'req', dueDate: DateTime.utc(2030, 1, 2), priority: JobPriority.high,
      parts: {'tip': 2, 'palm': 1});
  return as(claimer).claim(job.jobId);
}

Future<void> openPopup(WidgetTester tester, String jobId, {Size size = const Size(1280, 1000)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                  onPressed: () => showJobPopup(context,
                      repository: as(claimer), nameOf: (id) => names[id] ?? id, people: names, jobId: jobId),
                  child: const Text('open'))))));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

// the form is a lazy list, so a field must be scrolled into view to exist
Future<void> type(WidgetTester tester, String key, String text) async {
  final field = find.byKey(Key(key));
  final list = find.descendant(of: find.byType(RemakeForm), matching: find.byType(Scrollable)).first;
  // scroll back to the top first, then down until it appears
  await tester.drag(list, const Offset(0, 2000));
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(field, 100, scrollable: list);
  await tester.enterText(find.byKey(Key(key)), text);
  await tester.pump();
}

Future<void> tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => store = MemoryTicketingStore({
        'inventory': {
          'tip': {'name': 'Fingertip', 'itemNumber': 'FT-01', 'stock': 10},
          'palm': {'name': 'Left Palm Plate', 'itemNumber': 'LP-02', 'stock': 3},
        }
      }));
  tearDown(() => store.dispose());

  testWidgets('Create remake opens the form with the job\'s details filled in', (tester) async {
    final job = await claimedJob();
    await openPopup(tester, job.jobId);
    await tap(tester, 'popup-create-remake');
    expect(find.text('Create remake of ${job.jobId}'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const Key('remake-name'))).controller!.text, 'Left arm');
    expect(find.descendant(of: find.byKey(const Key('remake-requester')), matching: find.text('Lee')), findsWidgets);
    expect(find.text('01/02/2030'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('remake-priority')), matching: find.text('High')), findsWidgets);
  });

  testWidgets('Cancel closes the form and changes nothing', (tester) async {
    final job = await claimedJob();
    await openPopup(tester, job.jobId);
    await tap(tester, 'popup-create-remake');
    await tap(tester, 'remake-cancel');
    expect(find.byKey(const Key('remake-name')), findsNothing);
    expect((await as(claimer).getJob(job.jobId))!.status, JobStatus.inProgress);
  });

  testWidgets('phones get a full-screen form', (tester) async {
    final job = await claimedJob();
    await openPopup(tester, job.jobId, size: const Size(390, 844));
    await tap(tester, 'popup-create-remake');
    expect(find.byType(RemakeForm), findsOneWidget);
    expect(tester.getSize(find.byType(RemakeForm)).width, 390);
  });

  group('faulty parts', () {
    Future<void> openForm(WidgetTester tester) async {
      final job = await claimedJob();
      await openPopup(tester, job.jobId);
      await tap(tester, 'popup-create-remake');
    }

    String qty(WidgetTester tester, String id) => tester.widget<Text>(find.byKey(Key('remake-qty-$id'))).data!;
    bool enabled(WidgetTester tester, String key) => tester.widget<IconButton>(find.byKey(Key(key))).onPressed != null;

    testWidgets('lists every part on the job with what the job has, nothing ticked', (tester) async {
      await openForm(tester);
      // the popup behind the form lists the parts too
      Finder inForm(String text) => find.descendant(of: find.byType(RemakeForm), matching: find.text(text));
      expect(inForm('Fingertip'), findsOneWidget);
      expect(inForm('Left Palm Plate'), findsOneWidget);
      expect(find.text('#FT-01 · this job has 2'), findsOneWidget);
      expect(find.byKey(const Key('remake-qty-tip')), findsNothing);
      expect(find.byKey(const Key('remake-reason-tip')), findsNothing);
    });

    testWidgets('ticking shows a count from 1 up to what the job has, and a reason', (tester) async {
      await openForm(tester);
      await tap(tester, 'remake-pick-tip');
      expect(qty(tester, 'tip'), '1');
      expect(enabled(tester, 'remake-minus-tip'), isFalse);
      await tap(tester, 'remake-plus-tip');
      expect(qty(tester, 'tip'), '2');
      expect(enabled(tester, 'remake-plus-tip'), isFalse, reason: 'the job only has 2');
      await type(tester, 'remake-reason-tip', 'cracked at the joint');
      await tester.pump();
      expect(find.text('cracked at the joint'), findsOneWidget);
    });

    testWidgets('tapping the row ticks it; unticking hides the count and clears the reason', (tester) async {
      await openForm(tester);
      await tap(tester, 'remake-part-palm');
      expect(qty(tester, 'palm'), '1');
      expect(enabled(tester, 'remake-plus-palm'), isFalse, reason: 'the job only has 1');
      await type(tester, 'remake-reason-palm', 'warped');
      await tap(tester, 'remake-pick-palm');
      expect(find.byKey(const Key('remake-qty-palm')), findsNothing);
      await tap(tester, 'remake-pick-palm');
      expect(find.text('warped'), findsNothing);
    });

    testWidgets('fits a phone with a part ticked', (tester) async {
      final job = await claimedJob();
      await openPopup(tester, job.jobId, size: const Size(390, 844));
      await tap(tester, 'popup-create-remake');
      await tap(tester, 'remake-pick-tip');
      expect(tester.takeException(), isNull);
    });
  });

  group('saving', () {
    Future<Job> openForm(WidgetTester tester) async {
      final job = await claimedJob();
      await openPopup(tester, job.jobId);
      await tap(tester, 'popup-create-remake');
      return job;
    }

    testWidgets('nothing ticked: says so and saves nothing', (tester) async {
      final job = await openForm(tester);
      await tap(tester, 'remake-submit');
      expect(find.text('Pick at least one faulty part.'), findsOneWidget);
      expect(find.text('Fix the fields marked in red.'), findsOneWidget);
      expect(find.byType(RemakeForm), findsOneWidget, reason: 'the form stays open');
      expect((await as(claimer).getJob(job.jobId))!.status, JobStatus.inProgress);
    });

    testWidgets('an empty name is refused', (tester) async {
      await openForm(tester);
      await type(tester, 'remake-name', '  ');
      await tap(tester, 'remake-pick-tip');
      await tap(tester, 'remake-submit');
      expect(find.text('Give the remake a name.'), findsOneWidget);
      expect(find.byType(RemakeForm), findsOneWidget);
    });

    testWidgets('errors clear once fixed and the remake saves with everything entered', (tester) async {
      final job = await openForm(tester);
      await tap(tester, 'remake-submit');
      await tap(tester, 'remake-pick-tip');
      await tap(tester, 'remake-plus-tip');
      await type(tester, 'remake-reason-tip', 'cracked at the joint');
      await type(tester, 'remake-name', 'Left arm (remake)');
      await type(tester, 'remake-comment', 'Check the new batch first');
      await tester.pump();
      expect(find.text('Pick at least one faulty part.'), findsNothing);
      await tap(tester, 'remake-submit');
      expect(find.byType(RemakeForm), findsNothing, reason: 'the form closes after saving');

      final original = (await as(claimer).getJob(job.jobId))!;
      expect(original.status, JobStatus.remade);
      final remake = (await as(claimer).getJob(original.remadeAs!))!;
      expect(remake.jobName, 'Left arm (remake)');
      expect(remake.remakeOf, job.jobId);
      expect(remake.lines.keys, ['tip']);
      expect([remake.defects['tip']!.count, remake.defects['tip']!.reason], [2, 'cracked at the joint']);
      expect(remake.status, JobStatus.inProgress, reason: 'in stock, so claimed by the creator');
      expect(remake.claimers.keys, ['maker']);
      expect((await as(claimer).commentsForJob(remake.jobId)).single.text, 'Check the new batch first');
    });

    testWidgets('a refusal from the repository shows in the footer and keeps the form open', (tester) async {
      final job = await openForm(tester);
      // the requester cancels the job while the form is open
      await tester.runAsync(() => as(requester).cancel(job.jobId));
      await tap(tester, 'remake-pick-tip');
      await tap(tester, 'remake-submit');
      expect(find.byKey(const Key('remake-error')), findsOneWidget);
      expect(find.textContaining('in progress or completed'), findsOneWidget);
      expect(find.byType(RemakeForm), findsOneWidget);
    });
  });

  group('after saving', () {
    String notice(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('popup-notice'))).data!;

    testWidgets('in stock: the remake opens, claimed by you, and says so', (tester) async {
      final job = await claimedJob();
      await openPopup(tester, job.jobId);
      await tap(tester, 'popup-create-remake');
      await tap(tester, 'remake-pick-tip');
      await tap(tester, 'remake-submit');

      final original = (await as(claimer).getJob(job.jobId))!;
      final remakeId = original.remadeAs!;
      // only one popup is open, and it's the remake's
      expect(find.byType(JobPopup), findsOneWidget);
      expect(tester.widget<JobPopup>(find.byType(JobPopup)).jobId, remakeId);
      expect(notice(tester),
          'Created remake $remakeId. You claimed it and the replacement parts were taken from inventory.');
      expect(find.text('Remake of ${job.jobId}'), findsOneWidget);
    });

    testWidgets('short: the remake opens waiting in Requested and names what is short', (tester) async {
      final job = await claimedJob();
      await openPopup(tester, job.jobId);
      // the last fingertips go elsewhere while the form is open
      await tester.runAsync(() => store.update({'inventory/tip/stock': 0}));
      await tap(tester, 'popup-create-remake');
      await tap(tester, 'remake-pick-tip');
      await tap(tester, 'remake-submit');

      final remakeId = (await as(claimer).getJob(job.jobId))!.remadeAs!;
      expect(tester.widget<JobPopup>(find.byType(JobPopup)).jobId, remakeId);
      expect(notice(tester), contains('Fingertip (need 1, 0 on hand)'));
      expect(notice(tester), contains('waiting in Requested'));
      expect((await as(claimer).getJob(remakeId))!.status, JobStatus.requested);
      // the Claim button explains the shortage too
      expect(find.byKey(const Key('popup-short-stock')), findsOneWidget);
    });

    testWidgets('cancelling the form leaves the original popup open', (tester) async {
      final job = await claimedJob();
      await openPopup(tester, job.jobId);
      await tap(tester, 'popup-create-remake');
      await tap(tester, 'remake-cancel');
      expect(tester.widget<JobPopup>(find.byType(JobPopup)).jobId, job.jobId);
      expect(find.byKey(const Key('popup-notice')), findsNothing);
    });
  });
}
