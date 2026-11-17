// the live popup against the real repository and in-memory stock rules.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lsi_ticketing/lsi_ticketing.dart';

const requester = TicketingUser(uid: 'req', role: Role.member);
const claimer = TicketingUser(uid: 'maker', role: Role.member);
const admin = TicketingUser(uid: 'admin', role: Role.admin);
const quality =
    TicketingUser(uid: 'qa', role: Role.member, departments: {'Quality'});
const outsider = TicketingUser(uid: 'out', role: Role.member);
const names = {
  'req': 'Lee',
  'maker': 'Sam',
  'admin': 'Jordan',
  'qa': 'Morgan',
  'out': 'Ari'
};
late MemoryTicketingStore store;
TicketingRepository as(TicketingUser user) =>
    TicketingRepository(store: store, user: user);
Future<Job> create() => as(requester).createJob(
    jobName: 'Left arm',
    requestedBy: 'req',
    dueDate: DateTime.utc(2030, 1, 2),
    priority: JobPriority.high,
    parts: {'tip': 2});

Future<void> open(WidgetTester tester, TicketingUser user, String jobId,
    {Size size = const Size(1280, 1000),
    Future<void> Function(Job)? remake}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                  onPressed: () => showJobPopup(context,
                      repository: as(user),
                      nameOf: (id) => names[id] ?? id,
                      people: names,
                      jobId: jobId,
                      onCreateRemake: remake),
                  child: const Text('open'))))));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => store = MemoryTicketingStore({
        'inventory': {
          'tip': {
            'name': 'Fingertip',
            'itemNumber': 'FT-01',
            'location': 'Shelf A2',
            'stock': 10,
          }
        }
      }));
  tearDown(() => store.dispose());

  testWidgets('requested fields and default page opening', (tester) async {
    final job = await create();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: TicketingPage(
                repository: as(requester),
                nameOf: (id) => names[id] ?? id,
                people: names))));
    await tester.pumpAndSettle();
    await tap(tester, 'tab-requested');
    await tester.tap(find.text('Left arm'));
    await tester.pumpAndSettle();
    expect(find.byType(JobPopup), findsOneWidget);
    for (final text in [
      'Requested by',
      'Date requested',
      'Due date',
      'Priority',
      'High',
      'Jan 2, 2030',
      'Parts required',
      'Fingertip',
      '#FT-01',
      'Location: Shelf A2',
      '× 2'
    ]) {
      expect(find.text(text), findsWidgets, reason: text);
    }
    expect(find.text(job.jobId), findsWidgets);
    expect(find.byKey(const Key('popup-claim')), findsOneWidget);
  });

  for (final user in [admin, requester, claimer, quality, outsider]) {
    testWidgets('in-progress permissions for ${user.uid}', (tester) async {
      final job = await create();
      await as(claimer).claim(job.jobId);
      await open(tester, user, job.jobId);
      final mayManage = user == admin || user == requester;
      expect(find.byKey(const Key('popup-edit')),
          mayManage ? findsOneWidget : findsNothing);
      expect(find.byKey(const Key('popup-cancel')),
          mayManage ? findsOneWidget : findsNothing);
      final mayComplete = user == admin || user == claimer;
      expect(find.byKey(const Key('popup-complete')),
          mayComplete ? findsOneWidget : findsNothing);
      expect(find.byKey(const Key('popup-unclaim')),
          mayComplete ? findsOneWidget : findsNothing);
      expect(find.byKey(const Key('popup-create-remake')),
          user == outsider ? findsNothing : findsOneWidget);
      expect(find.text('Claimed by'), findsOneWidget);
      expect(find.text('Sam'), findsOneWidget);
      expect(find.text('Date claimed'), findsOneWidget);
      await tester.drag(
          find.byKey(const Key('popup-details')), const Offset(0, -1000));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('popup-comment')),
          user == outsider ? findsNothing : findsOneWidget);
    });
  }

  testWidgets('stock shortage blocks claim and restocking updates it live',
      (tester) async {
    final job = await create();
    await store.update({'inventory/tip/stock': 1});
    await open(tester, outsider, job.jobId);
    expect(
        find.textContaining('Fingertip (need 2, 1 on hand)'), findsOneWidget);
    expect(
        tester
            .widget<TextButton>(find.byKey(const Key('popup-claim')))
            .onPressed,
        isNull);
    await store.update({'inventory/tip/stock': 2});
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('popup-short-stock')), findsNothing);
    await tap(tester, 'popup-claim');
    expect(
        (await as(outsider).getJob(job.jobId))!.status, JobStatus.inProgress);
    expect((await as(outsider).getInventoryItem('tip'))!.stock, 0);
    expect(find.text('Claimed by'), findsOneWidget);
  });

  testWidgets('other users claiming and commenting update the open popup',
      (tester) async {
    final job = await create();
    await open(tester, requester, job.jobId);
    await as(claimer).claim(job.jobId);
    await as(quality).addComment(job.jobId, 'Checked the parts.');
    await tester.pumpAndSettle();
    expect(find.text('Sam'), findsOneWidget);
    await tester.drag(
        find.byKey(const Key('popup-details')), const Offset(0, -1000));
    await tester.pumpAndSettle();
    expect(find.text('Checked the parts.'), findsOneWidget);
    expect(find.text('Morgan'), findsOneWidget);
  });

  testWidgets('comment add, edit and delete persist with edited indicator',
      (tester) async {
    final job = await create();
    await open(tester, requester, job.jobId);
    await tester.ensureVisible(find.byKey(const Key('popup-comment')));
    await tester.enterText(
        find.byKey(const Key('popup-comment')), 'Blue shell.');
    await tester.pumpAndSettle();
    await tap(tester, 'popup-post-comment');
    final comment = (await as(requester).commentsForJob(job.jobId)).single;
    await tap(tester, 'comment-edit-${comment.id}');
    await tester.enterText(
        find.byKey(const Key('popup-comment')), 'Green shell.');
    await tester.pump();
    await tap(tester, 'popup-post-comment');
    expect((await as(requester).commentsForJob(job.jobId)).single.text,
        'Green shell.');
    expect(find.textContaining('(edited)'), findsOneWidget);
    await tap(tester, 'comment-delete-${comment.id}');
    await tap(tester, 'popup-confirm');
    expect(await as(requester).commentsForJob(job.jobId), isEmpty);
  });

  testWidgets('admin can delete another author comment but cannot edit it',
      (tester) async {
    final job = await create();
    final comment =
        await as(requester).addComment(job.jobId, 'Keep the shell.');
    await open(tester, admin, job.jobId);
    await tester.drag(
        find.byKey(const Key('popup-details')), const Offset(0, -1000));
    await tester.pumpAndSettle();
    expect(find.byKey(Key('comment-edit-${comment.id}')), findsNothing);
    expect(find.byKey(Key('comment-delete-${comment.id}')), findsOneWidget);
  });

  testWidgets('admin chooses a claimer; last unclaim returns parts',
      (tester) async {
    final job = await create();
    await as(claimer).claim(job.jobId);
    await open(tester, admin, job.jobId);
    await tap(tester, 'popup-unclaim');
    await tap(tester, 'popup-unclaim-maker');
    expect(find.textContaining('parts go back to inventory'), findsOneWidget);
    await tap(tester, 'popup-confirm');
    expect((await as(admin).getJob(job.jobId))!.status, JobStatus.requested);
    expect((await as(admin).getInventoryItem('tip'))!.stock, 10);
  });

  testWidgets('a claimer adds a teammate from the searchable scholar list',
      (tester) async {
    final job = await create();
    await as(claimer).claim(job.jobId);
    await open(tester, claimer, job.jobId);
    await tap(tester, 'popup-add-claimer');
    // claimers already on the job aren't offered
    expect(find.byKey(const Key('popup-add-claimer-maker')), findsNothing);
    await tester.enterText(
        find.byKey(const Key('popup-add-claimer-search')), 'mor');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('popup-add-claimer-req')), findsNothing);
    await tap(tester, 'popup-add-claimer-qa');
    expect(find.text('Added Morgan to the job.'), findsOneWidget);
    expect((await as(admin).getJob(job.jobId))!.claimers.keys,
        containsAll(['maker', 'qa']));
    expect((await as(admin).getInventoryItem('tip'))!.stock, 8);
  });

  testWidgets('only claimers and admins see Add scholar', (tester) async {
    final job = await create();
    await as(claimer).claim(job.jobId);
    await open(tester, requester, job.jobId);
    expect(find.byKey(const Key('popup-add-claimer')), findsNothing);
  });

  testWidgets('complete confirms and retains reserved stock', (tester) async {
    final job = await create();
    await as(claimer).claim(job.jobId);
    await open(tester, claimer, job.jobId);
    await tap(tester, 'popup-complete');
    expect((await as(claimer).getJob(job.jobId))!.status, JobStatus.inProgress);
    await tap(tester, 'popup-confirm');
    expect(find.text('Completed'), findsOneWidget);
    expect((await as(claimer).getInventoryItem('tip'))!.stock, 8);
    expect(find.byKey(const Key('popup-create-remake')), findsOneWidget);
    expect(find.byKey(const Key('popup-edit')), findsNothing);
  });

  testWidgets('cancel confirms and returns stock, leaving no job actions',
      (tester) async {
    final job = await create();
    await as(claimer).claim(job.jobId);
    await open(tester, requester, job.jobId);
    await tap(tester, 'popup-cancel');
    expect(find.textContaining('returns all its held parts'), findsOneWidget);
    await tap(tester, 'popup-confirm');
    expect(find.text('Cancelled'), findsOneWidget);
    expect((await as(requester).getInventoryItem('tip'))!.stock, 10);
    for (final key in [
      'popup-cancel',
      'popup-edit',
      'popup-claim',
      'popup-complete',
      'popup-create-remake'
    ]) {
      expect(find.byKey(Key(key)), findsNothing);
    }
  });

  testWidgets('remade links open the remake with used parts and defects',
      (tester) async {
    final job = await create();
    await as(claimer).claim(job.jobId);
    final remake = await as(quality).createRemake(job.jobId,
        defects: {'tip': const Defect(count: 1, reason: 'Cracked joint')});
    await open(tester, quality, job.jobId);
    expect(find.byKey(const Key('popup-create-remake')), findsNothing);
    await tap(tester, 'popup-remade-as');
    expect(find.text('Remake'), findsOneWidget);
    expect(find.text('Remake of ${job.jobId}'), findsOneWidget);
    expect(find.text(remake.jobId), findsOneWidget);
    await tester.drag(
        find.byKey(const Key('popup-details')).last, const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.text('Parts used by the original'), findsOneWidget);
    expect(find.textContaining('Cracked joint'), findsOneWidget);
  });

  testWidgets('edit opens the existing form and updates the live job',
      (tester) async {
    final job = await create();
    await open(tester, requester, job.jobId);
    await tap(tester, 'popup-edit');
    await tester.enterText(
        find.byKey(const Key('form-name')), 'Left arm updated');
    await tap(tester, 'form-submit');
    expect(find.byType(JobForm), findsNothing);
    expect(find.text('Left arm updated'), findsOneWidget);
  });

  testWidgets('repository errors remain visible and preserve the comment draft',
      (tester) async {
    final job = await create();
    await open(tester, requester, job.jobId);
    await tester.ensureVisible(find.byKey(const Key('popup-comment')));
    await tester.enterText(
        find.byKey(const Key('popup-comment')), 'Keep this draft');
    await tester.pump();
    store.beforeUpdate = () async {
      throw TicketingException('Connection lost. Try again.');
    };
    await tap(tester, 'popup-post-comment');
    expect(find.text('Connection lost. Try again.'), findsOneWidget);
    expect(find.text('Keep this draft'), findsOneWidget);
    expect(await as(requester).commentsForJob(job.jobId), isEmpty);
    await tap(tester, 'popup-post-comment');
    expect((await as(requester).commentsForJob(job.jobId)).single.text,
        'Keep this draft');
  });

  testWidgets('completed remake callback is permission gated', (tester) async {
    final job = await create();
    await as(claimer).claim(job.jobId);
    await as(claimer).complete(job.jobId);
    Job? selected;
    await open(tester, quality, job.jobId, remake: (job) async {
      selected = job;
    });
    await tap(tester, 'popup-create-remake');
    expect(selected?.jobId, job.jobId);
    expect(find.byKey(const Key('popup-complete')), findsNothing);
    expect(find.byKey(const Key('popup-claim')), findsNothing);
  });

  testWidgets('missing job has a close button', (tester) async {
    await open(tester, requester, 'missing');
    expect(find.text('This job was not found.'), findsOneWidget);
    await tap(tester, 'popup-close');
    expect(find.byType(JobPopup), findsNothing);
  });

  testWidgets(
      'phone and tablet are fullscreen with actions pinned while scrolling',
      (tester) async {
    final job = await create();
    await open(tester, requester, job.jobId, size: const Size(390, 844));
    expect(tester.getSize(find.byType(Dialog)).width, 390);
    final button = find.byKey(const Key('popup-claim'));
    final before = tester.getTopLeft(button);
    await tester.drag(
        find.byKey(const Key('popup-details')), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(button), before);
    expect(tester.getSize(button).height, greaterThanOrEqualTo(44));
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(800, 1000);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(Dialog)).width, 800);
  });
}
