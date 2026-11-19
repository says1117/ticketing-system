// live job details. all writes go through the repository so permissions, stock
// reservations and history follow the same rules as the main page.
import 'dart:async';

// lsicompapp imports material.dart in all of its pages; staying consistent.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/ticketing_repository.dart';
import '../models/comment.dart';
import '../models/enums.dart';
import '../models/inventory_item.dart';
import '../models/job.dart';
import '../rules/permissions.dart';
import 'closed_job_logic.dart';
import 'job_form.dart';
import 'page_logic.dart';
import 'remake_form.dart';
import 'remake_logic.dart';

Future<void> showJobPopup(
  BuildContext context, {
  required TicketingRepository repository,
  required NameOf nameOf,
  required String jobId,
  Map<String, String> people = const {},
  void Function(Job)? onEditJob,
  Future<void> Function(Job)? onCreateRemake,
  String notice = '',
}) =>
    showDialog<void>(
      context: context,
      builder: (context) {
        final phone = MediaQuery.sizeOf(context).width < 900;
        final popup = JobPopup(
            repository: repository,
            nameOf: nameOf,
            jobId: jobId,
            people: people,
            onEditJob: onEditJob,
            onCreateRemake: onCreateRemake,
            notice: notice);
        return phone
            ? Dialog.fullscreen(child: popup)
            : Dialog(
                insetPadding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints:
                      const BoxConstraints(maxWidth: 620, maxHeight: 820),
                  child: popup,
                ),
              );
      },
    );

class JobPopup extends StatefulWidget {
  const JobPopup(
      {super.key,
      required this.repository,
      required this.nameOf,
      required this.jobId,
      this.people = const {},
      this.onEditJob,
      this.onCreateRemake,
      this.notice = ''});

  final TicketingRepository repository;
  final NameOf nameOf;
  final String jobId;
  final Map<String, String> people;
  final void Function(Job)? onEditJob;
  // replaces the built-in remake form; permissions still decide if it shows.
  final Future<void> Function(Job)? onCreateRemake;
  // shown in the footer when the popup opens, e.g. the result of a remake
  final String notice;

  @override
  State<JobPopup> createState() => _JobPopupState();
}

class _JobPopupState extends State<JobPopup> {
  final _subscriptions = <StreamSubscription<Object?>>[];
  final _comment = TextEditingController();
  Job? _job;
  List<Comment> _comments = [];
  Map<String, InventoryItem> _inventory = {};
  bool _loaded = false;
  bool _inventoryLoaded = false;
  bool _commentsLoaded = false;
  // a failed job's remake ticket, watched live for the Failure section
  StreamSubscription<Job?>? _remakeSubscription;
  String? _watchedRemakeId;
  Job? _remake;
  bool _remakeLoaded = false;
  bool _busy = false;
  bool _showProgress = false;
  String _error = '';
  String _notice = '';
  String? _editingId;

  TicketingRepository get repo => widget.repository;
  ThemeData get theme => Theme.of(context);
  Color get accent => theme.secondaryHeaderColor;

  @override
  void initState() {
    super.initState();
    _notice = widget.notice;
    void error(Object _) {
      if (mounted) {
        setState(() => _error =
            'Couldn\'t load job details. Close and reopen to try again.');
      }
    }

    _subscriptions.add(repo.watchJob(widget.jobId).listen((job) {
      if (mounted) {
        setState(() {
          _job = job;
          _loaded = true;
        });
        _watchRemake(job?.remadeAs);
      }
    }, onError: error));
    _subscriptions.add(repo.watchInventory().listen((items) {
      if (mounted) {
        setState(() {
          _inventory = {for (final item in items) item.id: item};
          _inventoryLoaded = true;
        });
      }
    }, onError: error));
    _subscriptions
        .add(repo.watchCommentsForJob(widget.jobId).listen((comments) {
      if (mounted) {
        setState(() {
          _comments = comments;
          _commentsLoaded = true;
        });
      }
    }, onError: error));
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _remakeSubscription?.cancel();
    _comment.dispose();
    super.dispose();
  }

  // follows the job's remadeAs. it's set once, when the job fails, which can
  // happen while this popup is open, so the watch starts whenever it appears.
  void _watchRemake(String? remakeId) {
    if (remakeId == _watchedRemakeId) return;
    _remakeSubscription?.cancel();
    _watchedRemakeId = remakeId;
    _remake = null;
    _remakeLoaded = false;
    if (remakeId == null) return;
    _remakeSubscription = repo.watchJob(remakeId).listen((remake) {
      if (mounted) {
        setState(() {
          _remake = remake;
          _remakeLoaded = true;
        });
      }
    }, onError: (Object _) {
      if (mounted) setState(() => _remakeLoaded = true);
    });
  }

  String _time(DateTime? value) => value == null
      ? '—'
      : DateFormat('MMM d, y, h:mm a').format(value.toLocal());

  Future<void> _run(Future<void> Function() action, String notice,
      {bool showProgress = true}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _showProgress = showProgress;
      _error = '';
      _notice = '';
    });
    try {
      await action();
      if (mounted) setState(() => _notice = notice);
    } on TicketingException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'Something went wrong. Check your connection and try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String message, String action) async =>
      await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                title: Text(title),
                content: Text(message),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Keep')),
                  TextButton(
                      key: const Key('popup-confirm'),
                      style: TextButton.styleFrom(
                          foregroundColor: accent,
                          minimumSize: const Size(44, 44)),
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(action)),
                ],
              )) ??
      false;

  Future<void> _unclaim(Job job, String uid) async {
    final last = job.claimers.length == 1;
    if (!await _confirm(
            'Unclaim ${widget.nameOf(uid)}?',
            last
                ? 'Nobody else is on this job. It returns to Requested and its parts go back to inventory.'
                : 'The job stays in progress with the other claimers.',
            'Unclaim') ||
        !mounted) {
      return;
    }
    await _run(() async {
      await repo.unclaim(job.jobId, claimerUid: uid);
    },
        last
            ? 'Returned to Requested. Parts were returned to inventory.'
            : 'Removed ${widget.nameOf(uid)} from the job.');
  }

  Future<void> _chooseUnclaim(Job job) async {
    var uid = repo.user.uid;
    if (repo.user.isAdmin) {
      final picked = await showDialog<String>(
          context: context,
          builder: (context) => SimpleDialog(
                title: const Text('Choose a claimer to remove'),
                children: [
                  for (final claimer in job.claimers.keys)
                    SimpleDialogOption(
                        key: Key('popup-unclaim-$claimer'),
                        onPressed: () => Navigator.pop(context, claimer),
                        child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(widget.nameOf(claimer)))),
                ],
              ));
      if (picked == null || !mounted) return;
      uid = picked;
    }
    await _unclaim(job, uid);
  }

  // claimers bring teammates onto the job. people is every active scholar;
  // there can be many, so the list is searchable.
  Future<void> _addClaimer(Job job) async {
    final choices = (widget.people.entries
        .where((e) => !job.isClaimedBy(e.key))
        .toList()
      ..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase())));
    var query = '';
    final picked = await showDialog<String>(
        context: context,
        builder: (context) => StatefulBuilder(builder: (context, setDialog) {
              final shown = choices
                  .where((e) => e.value
                      .toLowerCase()
                      .contains(query.trim().toLowerCase()))
                  .toList();
              return AlertDialog(
                title: const Text('Add a scholar to this job'),
                content: SizedBox(
                    width: 400,
                    height: 360,
                    child: Column(children: [
                      TextField(
                          key: const Key('popup-add-claimer-search'),
                          autofocus: true,
                          decoration: const InputDecoration(
                              hintText: 'Search by name',
                              prefixIcon: Icon(Icons.search)),
                          onChanged: (v) => setDialog(() => query = v)),
                      const SizedBox(height: 8),
                      Expanded(
                          child: shown.isEmpty
                              ? const Center(
                                  child: Text('No other scholars match.'))
                              : ListView(children: [
                                  for (final e in shown)
                                    ListTile(
                                        key: Key('popup-add-claimer-${e.key}'),
                                        minVerticalPadding: 12,
                                        title: Text(e.value),
                                        onTap: () =>
                                            Navigator.pop(context, e.key)),
                                ])),
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close')),
                ],
              );
            }));
    if (picked == null || !mounted) return;
    await _run(() async {
      await repo.addClaimer(job.jobId, picked);
    }, 'Added ${widget.nameOf(picked)} to the job.');
  }

  Future<void> _cancel(Job job) async {
    if (!await _confirm(
            'Cancel ${job.jobId}?',
            job.status == JobStatus.inProgress
                ? 'This closes the job and returns all its held parts to inventory.'
                : 'This closes the request. No parts have been taken from inventory.',
            'Cancel job') ||
        !mounted) {
      return;
    }
    await _run(() async {
      await repo.cancel(job.jobId);
    }, 'Job cancelled. Any held parts were returned to inventory.');
  }

  Future<void> _complete(Job job) async {
    if (!await _confirm(
            'Complete ${job.jobId}?',
            'Mark the assembly as completed. Its parts stay with the arm; inventory does not change.',
            'Complete') ||
        !mounted) {
      return;
    }
    await _run(() async {
      await repo.complete(job.jobId);
    }, 'Job completed.');
  }

  Future<void> _edit(Job job) async {
    if (widget.onEditJob != null) {
      widget.onEditJob!(job);
      return;
    }
    await _run(() async {
      await showJobForm(context,
          repository: repo,
          nameOf: widget.nameOf,
          people: widget.people,
          job: job);
    }, '', showProgress: false);
  }

  // the remake form by default; onCreateRemake replaces it. after saving,
  // this popup (now a Failed job) closes and the remake's popup opens with
  // the result: claimed by you, or waiting in Requested and what's short.
  Future<void> _createRemake(Job job) async {
    if (widget.onCreateRemake != null) return widget.onCreateRemake!(job);
    final remake = await showRemakeForm(context,
        repository: repo,
        nameOf: widget.nameOf,
        people: widget.people,
        job: job);
    if (remake == null || !mounted) return;
    // the navigator outlives this popup, so the next one opens from it
    final navigator = Navigator.of(context);
    var message = 'Created remake ${remake.jobId}.';
    try {
      message = RemakeDraft.outcomeMessage(remake, await repo.stockFor(remake));
    } catch (_) {
      // the remake is saved either way; its popup shows the live state
    }
    if (!mounted) return;
    navigator.pop();
    showJobPopup(navigator.context,
        repository: repo,
        nameOf: widget.nameOf,
        people: widget.people,
        jobId: remake.jobId,
        onEditJob: widget.onEditJob,
        notice: message);
  }

  void _related(String id) => showJobPopup(context,
      repository: repo,
      nameOf: widget.nameOf,
      people: widget.people,
      jobId: id,
      onEditJob: widget.onEditJob,
      onCreateRemake: widget.onCreateRemake);

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 8),
        child: Text(text,
            style: theme.textTheme.titleSmall
                ?.copyWith(color: accent, fontWeight: FontWeight.w600)),
      );

  Widget _field(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              style:
                  theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
          const SizedBox(height: 2),
          Text(value),
        ]),
      );

  Widget _button(String label, String key, VoidCallback action,
          {String? reason}) =>
      Tooltip(
        message: reason ?? label,
        child: TextButton(
            key: Key(key),
            style: TextButton.styleFrom(
                foregroundColor: accent, minimumSize: const Size(44, 44)),
            onPressed: _busy || reason != null ? null : action,
            child: Text(label)),
      );

  Widget _parts(Map<String, int> parts) => Column(children: [
        for (final entry in parts.entries)
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child:
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                PartThumbnail(url: _inventory[entry.key]?.url ?? ''),
                const SizedBox(width: 12),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(_inventory[entry.key]?.name ??
                          'Unavailable part (${entry.key})'),
                      Text('#${_inventory[entry.key]?.itemNumber ?? '—'}',
                          style: theme.textTheme.bodySmall),
                      Text(
                          'Location: ${_inventory[entry.key]?.location.isNotEmpty == true ? _inventory[entry.key]!.location : '—'}',
                          style: theme.textTheme.bodySmall),
                    ])),
                const SizedBox(width: 8),
                Text('× ${entry.value}'),
              ])),
      ]);

  Widget _commentsSection(Job job) {
    final reason = Permissions.canComment(repo.user, job);
    final editing = _editingId != null;
    // an author's existing comment remains editable even if job membership changes.
    final canWrite = editing || reason == null;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _heading('Comments'),
      if (!_commentsLoaded)
        const LinearProgressIndicator()
      else if (_comments.isEmpty)
        const Text('No comments yet.'),
      for (final comment in _comments)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.nameOf(comment.author),
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            Text(
                '${_time(comment.timestamp)}${comment.editedAt == null ? '' : ' (edited)'}',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            SelectableText(comment.text),
            Wrap(children: [
              if (Permissions.canEditComment(repo.user, comment) == null)
                _button('Edit comment', 'comment-edit-${comment.id}', () {
                  setState(() {
                    _editingId = comment.id;
                    _comment.text = comment.text;
                  });
                }),
              if (Permissions.canDeleteComment(repo.user, comment) == null)
                _button('Delete comment', 'comment-delete-${comment.id}',
                    () async {
                  if (!await _confirm('Delete comment?',
                          'This removes the comment permanently.', 'Delete') ||
                      !mounted) {
                    return;
                  }
                  await _run(() async {
                    await repo.deleteComment(comment.id);
                    if (mounted && _editingId == comment.id) {
                      _editingId = null;
                      _comment.clear();
                    }
                  }, 'Comment deleted.');
                }),
            ]),
          ]),
        ),
      if (canWrite) ...[
        const SizedBox(height: 8),
        TextField(
            key: const Key('popup-comment'),
            controller: _comment,
            enabled: !_busy,
            minLines: 2,
            maxLines: 5,
            maxLength: Comment.maxLength,
            decoration: InputDecoration(
                labelText: editing ? 'Edit your comment' : 'Add a comment',
                border: const OutlineInputBorder()),
            onChanged: (_) => setState(() {})),
        Wrap(children: [
          _button(
              editing ? 'Save comment' : 'Post comment', 'popup-post-comment',
              () async {
            final text = _comment.text;
            final id = _editingId;
            await _run(() async {
              if (id == null) {
                await repo.addComment(job.jobId, text);
              } else {
                await repo.editComment(id, text);
              }
              if (mounted) {
                _comment.clear();
                _editingId = null;
              }
            }, editing ? 'Comment saved.' : 'Comment posted.');
          },
              reason: _comment.text.trim().isEmpty
                  ? 'Write a comment first.'
                  : null),
          if (editing)
            _button('Discard edit', 'popup-discard-comment', () {
              setState(() {
                _editingId = null;
                _comment.clear();
              });
            }),
        ]),
      ] else
        Padding(padding: const EdgeInsets.only(top: 8), child: Text(reason)),
    ]);
  }

  Widget _details(Job job) => ListView(
        key: const Key('popup-details'),
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        children: [
          Text(job.jobId, style: theme.textTheme.bodySmall),
          _field('Status', PageLogic.statusLabel(job.status)),
          if (job.isRemake) ...[
            _heading('Remake'),
            Align(
                alignment: Alignment.centerLeft,
                child: _button('Remake of ${job.remakeOf}', 'popup-remake-of',
                    () => _related(job.remakeOf!))),
          ],
          if (job.remadeAs != null)
            Align(
                alignment: Alignment.centerLeft,
                child: _button('Remade as ${job.remadeAs}', 'popup-remade-as',
                    () => _related(job.remadeAs!))),
          _field('Requested by', widget.nameOf(job.requestedBy)),
          _field('Date requested', _time(job.createdAt)),
          _field('Due date', DateFormat('MMM d, y').format(job.neededBy)),
          _field('Priority', PageLogic.priorityLabel(job.priority)),
          if (job.status != JobStatus.requested) ...[
            // "Claimed by" while open, "Scholars" once closed (closed_job_logic.dart)
            _heading(ClosedJobLogic.peopleHeading(job)),
            if (job.claimers.isEmpty)
              Text(job.isOpen ? 'No claimers.' : 'Nobody was on this job.'),
            for (final uid in job.claimers.keys)
              Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(widget.nameOf(uid))),
            if (job.status == JobStatus.inProgress &&
                Permissions.canAddClaimer(repo.user, job, '') == null)
              Align(
                  alignment: Alignment.centerLeft,
                  child: _button('Add scholar', 'popup-add-claimer',
                      () => _addClaimer(job),
                      reason: widget.people.keys.every(job.isClaimedBy)
                          ? 'Everyone on the scholar list is already on this job.'
                          : null)),
            _field('Date claimed', _time(job.claimedAt)),
          ],
          // when it closed. a failed job's date comes from its remake ticket
          if (ClosedJobLogic.closedOn(job, FailureDetails.of(job, _remake))
              case (final label, final date))
            _field(label, _time(date)),
          _heading(ClosedJobLogic.partsHeading(job)),
          if (!_inventoryLoaded)
            const LinearProgressIndicator()
          else
            _parts({
              for (final line in job.lines.values) line.itemId: line.quantity
            }),
          if (job.isRemake) ...[
            _heading('Parts used by the original'),
            _parts(job.usedParts),
            _heading('Defects'),
            for (final defect in job.defects.entries)
              Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                      '${_inventory[defect.key]?.name ?? defect.key} × ${defect.value.count}\n${defect.value.reason.isEmpty ? 'No reason provided.' : defect.value.reason}')),
          ],
          if (job.status == JobStatus.remade) _failureSection(job),
          _commentsSection(job),
        ],
      );

  // what failed and why, from the remake ticket (see FailureDetails)
  Widget _failureSection(Job job) {
    final failure = FailureDetails.of(job, _remake);
    return Column(
        key: const Key('popup-failure'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _heading('Failure'),
          if (failure != null) ...[
            _field('Parts failed', '${failure.partsFailed}'),
            for (final line in ClosedJobLogic.failureLines(failure,
                (id) => _inventory[id]?.name ?? 'Unavailable part ($id)'))
              Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(line)),
          ] else if (!_remakeLoaded && job.remadeAs != null)
            const LinearProgressIndicator()
          else
            Text(
                'The failure details are on remake ${job.remadeAs ?? '(unknown)'}, which couldn\'t be found.'),
        ]);
  }

  Widget _actions(Job job) => Wrap(spacing: 8, runSpacing: 4, children: [
        if (job.isOpen && !job.isClaimedBy(repo.user.uid))
          _button(
              'Claim',
              'popup-claim',
              () => _run(() async {
                    await repo.claim(job.jobId);
                  },
                      job.status == JobStatus.requested
                          ? 'Job claimed. Parts were taken from inventory.'
                          : 'You joined this job.'),
              reason: !_inventoryLoaded
                  ? 'Loading inventory.'
                  : Permissions.canClaim(repo.user, job, _inventory)),
        if (job.status == JobStatus.inProgress &&
            job.claimers.keys.any(
                (uid) => Permissions.canUnclaim(repo.user, job, uid) == null))
          _button('Unclaim', 'popup-unclaim', () => _chooseUnclaim(job)),
        if (Permissions.canComplete(repo.user, job) == null)
          _button('Complete', 'popup-complete', () => _complete(job)),
        if (Permissions.canCreateRemake(repo.user, job) == null)
          _button('Create remake', 'popup-create-remake',
              () => _run(() => _createRemake(job), '', showProgress: false)),
        if (Permissions.canEdit(repo.user, job) == null)
          _button('Edit', 'popup-edit', () => _edit(job)),
        if (Permissions.canCancel(repo.user, job) == null)
          _button('Cancel job', 'popup-cancel', () => _cancel(job)),
      ]);

  @override
  Widget build(BuildContext context) {
    final job = _job;
    final short = job?.status == JobStatus.requested && _inventoryLoaded
        ? Permissions.shortParts(job!, _inventory)
        : <String>[];
    return Material(
        color: theme.cardColor,
        child: SafeArea(
            child: Column(children: [
          Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 8, 8),
              child: Row(children: [
                Expanded(
                    child: Text(job?.jobName ?? 'Job details',
                        style: theme.textTheme.titleLarge,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis)),
                IconButton(
                    key: const Key('popup-close'),
                    tooltip: 'Close',
                    constraints:
                        const BoxConstraints(minWidth: 44, minHeight: 44),
                    onPressed: _busy ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close)),
              ])),
          Expanded(
              child: job != null
                  ? _details(job)
                  : Center(
                      child: _loaded
                          ? const Text('This job was not found.')
                          : _error.isEmpty
                              ? const CircularProgressIndicator()
                              : const SizedBox.shrink())),
          const Divider(height: 1),
          Padding(
              key: const Key('popup-footer'),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_error.isNotEmpty)
                      Text(_error,
                          key: const Key('popup-error'),
                          style: TextStyle(color: theme.colorScheme.error)),
                    if (_notice.isNotEmpty)
                      Text(_notice, key: const Key('popup-notice')),
                    if (short.isNotEmpty)
                      Text('Not enough in inventory: ${short.join(', ')}.',
                          key: const Key('popup-short-stock')),
                    if (_busy && _showProgress) const LinearProgressIndicator(),
                    if (job != null) _actions(job),
                  ])),
        ])));
  }
}
