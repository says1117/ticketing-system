// the main Ticketing page: search, the In-Progress / Requested / Log tabs, a
// sort dropdown, the job lists, and the "+" button for adding a job.
//
// styled after lsicompapp (the SHA Keys page and LiteTable): it only reads
// Theme.of(context), so inside lsicompapp it follows the user's chosen theme.
// wide screens get tables, phones get cards with 44px tap targets.
//
// the + and Edit buttons open the job form (job_form.dart) unless onAddJob /
// onEditJob are given. job rows open the live popup unless onOpenJob is given.

import 'dart:async';

// lsicompapp imports material.dart in all 118 of its pages; staying consistent
// until the app moves to package:material_ui.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/ticketing_repository.dart';
import '../models/comment.dart';
import '../models/enums.dart';
import '../models/history_entry.dart';
import '../models/job.dart';
import '../rules/permissions.dart';
import 'job_form.dart';
import 'job_popup.dart';
import 'page_logic.dart';

class TicketingPage extends StatefulWidget {
  const TicketingPage({
    super.key,
    required this.repository,
    required this.nameOf,
    this.people = const {},
    this.onAddJob,
    this.onOpenJob,
    this.onEditJob,
    this.today,
  });

  final TicketingRepository repository;
  // uid -> display name. in lsicompapp: usersProfile[uid]?['displayName'] ?? 'Unknown'
  final NameOf nameOf;
  // uid -> name of the scholars the Add Job form offers for "Requested by".
  // in lsicompapp: the active users from usersProfile.
  final Map<String, String> people;
  final VoidCallback? onAddJob;
  final void Function(String jobId)? onOpenJob;
  final void Function(Job job)? onEditJob;
  // for tests; defaults to now
  final DateTime Function()? today;

  @override
  State<TicketingPage> createState() => _TicketingPageState();
}

class _TicketingPageState extends State<TicketingPage> {
  // below this width the lists switch from tables to cards
  static const double wideBreakpoint = 900;

  final List<StreamSubscription<Object?>> _subs = [];
  List<Job> _jobs = const [];
  List<HistoryEntry> _history = const [];
  List<Comment> _comments = const [];
  bool _loaded = false;
  String _loadError = '';

  JobTab _tab = JobTab.inProgress;
  LogFilter _logFilter = LogFilter.all;
  bool _logNewestFirst = true;
  final Map<JobTab, JobSort> _sort = {
    JobTab.inProgress: PageLogic.sortsFor(JobTab.inProgress).first,
    JobTab.requested: PageLogic.sortsFor(JobTab.requested).first,
  };
  String _query = '';
  // jobs with an action running, so their buttons can't be pressed twice
  final Set<String> _busy = {};

  TicketingRepository get repo => widget.repository;
  TicketingUser get me => repo.user;

  @override
  void initState() {
    super.initState();
    void onError(Object e) {
      if (mounted) setState(() => _loadError = 'Couldn\'t load jobs. Check your connection and reload the page.');
    }

    _subs.add(repo.watchJobs().listen((v) => setState(() {
          _jobs = v;
          _loaded = true;
        }), onError: onError));
    _subs.add(repo.watchHistory().listen((v) => setState(() => _history = v), onError: onError));
    _subs.add(repo.watchComments().listen((v) => setState(() => _comments = v), onError: onError));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------- styles

  ThemeData get _theme => Theme.of(context);
  Color get _accent => _theme.secondaryHeaderColor;
  TextStyle get _cellStyle =>
      (_theme.primaryTextTheme.bodyMedium ?? _theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(fontSize: 14);
  TextStyle get _mutedStyle => _cellStyle.copyWith(color: _theme.hintColor, fontSize: 13);

  // the year is only shown when it isn't this year, to keep the columns narrow
  String _time(DateTime? t) {
    if (t == null) return '—';
    final local = t.toLocal();
    return DateFormat(local.year == DateTime.now().year ? 'MMM d, h:mm a' : 'MMM d, y, h:mm a').format(local);
  }

  final DateFormat _dayFormat = DateFormat('MMM d, y');
  // due dates are calendar days stored as UTC midnight, so they're not shifted
  String _day(DateTime d) => _dayFormat.format(d);

  void _note(String message) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      // floats to the right of the + button instead of covering it
      ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(92, 0, 16, 16),
      ));
  }

  // ---------------------------------------------------------------- actions

  Future<void> _run(String jobId, Future<Object?> Function() action, String done) async {
    if (_busy.contains(jobId)) return;
    setState(() => _busy.add(jobId));
    try {
      await action();
      _note(done);
    } on TicketingException catch (e) {
      _note(e.message);
    } catch (_) {
      _note('Something went wrong. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _busy.remove(jobId));
    }
  }

  void _claim(Job j) => _run(j.jobId, () => repo.claim(j.jobId), 'Claimed ${j.jobId}. Its parts were taken from inventory.');

  void _openJob(Job j) =>
      widget.onOpenJob != null
          ? widget.onOpenJob!(j.jobId)
          : showJobPopup(context, repository: repo, nameOf: widget.nameOf,
              people: widget.people, jobId: j.jobId, onEditJob: widget.onEditJob);

  Future<void> _addJob() async {
    if (widget.onAddJob != null) return widget.onAddJob!();
    final saved = await showJobForm(context, repository: repo, nameOf: widget.nameOf, people: widget.people);
    if (saved == null || !mounted) return;
    setState(() => _tab = JobTab.requested);
    _note('Requested ${saved.jobId}. It\'s waiting in Requested for someone to claim it.');
  }

  Future<void> _edit(Job j) async {
    final blocked = Permissions.canEdit(me, j);
    if (blocked != null) return _note(blocked);
    if (widget.onEditJob != null) return widget.onEditJob!(j);
    final saved = await showJobForm(context, repository: repo, nameOf: widget.nameOf, people: widget.people, job: j);
    if (saved != null && mounted) _note('Saved ${saved.jobId}.');
  }

  Future<void> _unclaim(Job j) async {
    String? who;
    if (j.isClaimedBy(me.uid)) {
      who = me.uid;
    } else if (me.isAdmin) {
      who = await showDialog<String>(
        context: context,
        builder: (c) => SimpleDialog(
          title: Text('Remove someone from ${j.jobId}'),
          children: [
            for (final uid in j.claimers.keys)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(c, uid),
                child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(widget.nameOf(uid))),
              ),
          ],
        ),
      );
      if (who == null) return;
    } else {
      return _note('Only people who claimed this job, or an admin, can unclaim it.');
    }
    if (!mounted) return;
    final last = j.claimers.length == 1;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(who == me.uid ? 'Unclaim ${j.jobId}?' : 'Remove ${widget.nameOf(who!)}?'),
        content: Text(last
            ? 'Nobody else is on this job, so it goes back to Requested and its parts go back to inventory.'
            : 'The job stays in progress with the other people on it.'),
        actions: [
          TextButton(
            style: TextButton.styleFrom(foregroundColor: _accent),
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _accent, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(c, true),
            child: Text(who == me.uid ? 'Unclaim' : 'Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run(j.jobId, () => repo.unclaim(j.jobId, claimerUid: who),
        last ? '${j.jobId} is back in Requested and its parts were returned.' : 'Removed from ${j.jobId}.');
  }

  // ---------------------------------------------------------------- page

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _theme.canvasColor,
      child: LayoutBuilder(builder: (context, box) {
        final wide = box.maxWidth >= wideBreakpoint;
        return Stack(children: [
          SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(wide ? 0 : 16, 16, wide ? 0 : 16, 0),
              child: Center(
                child: FractionallySizedBox(
                  widthFactor: wide ? 0.9 : 1,
                  child: Column(children: [
                    _searchBar(),
                    const SizedBox(height: 12),
                    _tabsAndSort(wide),
                    if (_tab == JobTab.log) ...[const SizedBox(height: 10), _logFilters()],
                    const SizedBox(height: 12),
                    Expanded(child: _body(wide)),
                  ]),
                ),
              ),
            ),
          ),
          Positioned(left: 20, bottom: 16, child: _addButton()),
        ]);
      }),
    );
  }

  Widget _searchBar() => SizedBox(
        height: 50,
        child: TextField(
          key: const Key('ticketing-search'),
          style: _cellStyle,
          decoration: InputDecoration(
            hintText: _tab == JobTab.log ? 'Search the log...' : 'Search jobs, IDs or people...',
            prefixIcon: const Icon(Icons.search),
            border: const OutlineInputBorder(),
          ),
          onChanged: (v) => setState(() => _query = v),
        ),
      );

  int _count(JobTab t) => switch (t) {
        JobTab.inProgress => _jobs.where((j) => j.status == JobStatus.inProgress).length,
        JobTab.requested => _jobs.where((j) => j.status == JobStatus.requested).length,
        JobTab.log => 0,
      };

  Widget _tabButton(JobTab t, {bool expand = false}) {
    final selected = _tab == t;
    final count = t == JobTab.log ? '' : ' (${_count(t)})';
    final button = Material(
      color: selected ? _accent : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: selected ? _accent : _theme.dividerColor),
      ),
      child: InkWell(
        key: Key('tab-${t.name}'),
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() => _tab = t),
        child: Container(
          constraints: BoxConstraints(minHeight: 44, minWidth: expand ? 0 : 110),
          padding: EdgeInsets.symmetric(horizontal: expand ? 6 : 16),
          alignment: Alignment.center,
          // shrinks the label rather than cutting it off on narrow phones
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              '${PageLogic.tabLabel(t)}$count',
              maxLines: 1,
              style: _cellStyle.copyWith(
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : _cellStyle.color,
              ),
            ),
          ),
        ),
      ),
    );
    return expand ? Expanded(child: button) : button;
  }

  Widget _sortDropdown() {
    final label = Text('Sort by', style: _mutedStyle);
    if (_tab == JobTab.log) {
      return Row(mainAxisSize: MainAxisSize.min, children: [
        label,
        const SizedBox(width: 8),
        DropdownButton<bool>(
          key: const Key('sort-dropdown'),
          value: _logNewestFirst,
          style: _cellStyle,
          underline: const SizedBox(),
          items: const [
            DropdownMenuItem(value: true, child: Text('Newest first')),
            DropdownMenuItem(value: false, child: Text('Oldest first')),
          ],
          onChanged: (v) => setState(() => _logNewestFirst = v ?? true),
        ),
      ]);
    }
    return Row(mainAxisSize: MainAxisSize.min, children: [
      label,
      const SizedBox(width: 8),
      DropdownButton<JobSort>(
        key: const Key('sort-dropdown'),
        value: _sort[_tab],
        style: _cellStyle,
        underline: const SizedBox(),
        items: [
          for (final s in PageLogic.sortsFor(_tab)) DropdownMenuItem(value: s, child: Text(PageLogic.sortLabel(s))),
        ],
        onChanged: (v) => setState(() => _sort[_tab] = v ?? _sort[_tab]!),
      ),
    ]);
  }

  Widget _tabsAndSort(bool wide) {
    if (wide) {
      return Row(children: [
        for (final t in JobTab.values) ...[_tabButton(t), const SizedBox(width: 8)],
        const Spacer(),
        _sortDropdown(),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Row(children: [
        for (final t in JobTab.values) ...[
          _tabButton(t, expand: true),
          if (t != JobTab.values.last) const SizedBox(width: 6),
        ],
      ]),
      _sortDropdown(),
    ]);
  }

  Widget _logFilters() => Align(
        alignment: Alignment.centerLeft,
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          for (final f in LogFilter.values)
            ChoiceChip(
              key: Key('log-${f.name}'),
              label: Text(PageLogic.filterLabel(f)),
              selected: _logFilter == f,
              selectedColor: _accent,
              labelStyle: _cellStyle.copyWith(color: _logFilter == f ? Colors.white : _cellStyle.color),
              showCheckmark: false,
              materialTapTargetSize: MaterialTapTargetSize.padded,
              onSelected: (_) => setState(() => _logFilter = f),
            ),
        ]),
      );

  Widget _addButton() => Tooltip(
        message: 'Request a job',
        child: Material(
          color: _accent,
          shape: const CircleBorder(),
          elevation: 4,
          child: InkWell(
            key: const Key('add-job'),
            customBorder: const CircleBorder(),
            onTap: _addJob,
            child: const SizedBox(width: 56, height: 56, child: Icon(Icons.add, size: 30, color: Colors.white)),
          ),
        ),
      );

  Widget _body(bool wide) {
    if (_loadError.isNotEmpty) {
      return Center(child: Text(_loadError, textAlign: TextAlign.center, style: _cellStyle.copyWith(color: Colors.red)));
    }
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    if (_tab == JobTab.log) return _logList();
    final jobs = PageLogic.jobsFor(_tab, _jobs, query: _query, sort: _sort[_tab]!, nameOf: widget.nameOf);
    final empty = _query.trim().isNotEmpty
        ? 'No jobs match "${_query.trim()}".'
        : (_tab == JobTab.inProgress
            ? 'Nobody is working on a job right now.'
            : 'No jobs are waiting to be claimed. Tap + to request one.');
    if (!wide) return _cards(jobs, empty);
    return _tab == JobTab.inProgress ? _inProgressTable(jobs, empty) : _requestedTable(jobs, empty);
  }

  // ---------------------------------------------------------------- shared bits

  Widget _statusCell(Job j) {
    final today = (widget.today ?? DateTime.now)();
    final overdue = PageLogic.isOverdue(j, today);
    return Text(PageLogic.jobStatusText(j, today),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: overdue ? _cellStyle.copyWith(color: Colors.redAccent, fontWeight: FontWeight.w600) : _cellStyle);
  }

  // name on top; id, Remake label and due date underneath
  Widget _jobNameCell(Job j) {
    final today = (widget.today ?? DateTime.now)();
    final overdue = PageLogic.isOverdue(j, today);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(j.jobName, maxLines: 1, overflow: TextOverflow.ellipsis, style: _cellStyle.copyWith(fontWeight: FontWeight.w600)),
      const SizedBox(height: 2),
      Row(children: [
        if (j.isRemake) ...[_chip('Remake', Colors.deepPurpleAccent), const SizedBox(width: 6)],
        Flexible(
          child: Text(
            overdue ? '${j.jobId} · overdue (due ${_day(j.neededBy)})' : '${j.jobId} · due ${_day(j.neededBy)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _mutedStyle.copyWith(fontSize: 12, color: overdue ? Colors.redAccent : _mutedStyle.color),
          ),
        ),
      ]),
    ]);
  }

  Widget _chip(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.7)),
        ),
        child: Text(text, style: _cellStyle.copyWith(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
      );

  Color _priorityColor(JobPriority? p) => switch (p) {
        JobPriority.high => Colors.redAccent,
        JobPriority.medium => Colors.orangeAccent,
        JobPriority.low => Colors.green,
        null => _theme.hintColor,
      };

  Widget _priority(JobPriority? p) =>
      p == null ? Text('—', style: _mutedStyle) : _chip(PageLogic.priorityLabel(p), _priorityColor(p));

  Widget _iconAction({
    required Key key,
    required IconData icon,
    required String tooltip,
    required bool enabled,
    required VoidCallback onTap,
  }) =>
      Tooltip(
        message: tooltip,
        child: IconButton(
          key: key,
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          icon: Icon(icon, color: enabled ? _cellStyle.color : _theme.disabledColor),
          onPressed: enabled ? onTap : null,
        ),
      );

  // phone cards spell the action out next to the icon
  Widget _labelledAction(Key key, IconData icon, String label, bool enabled, VoidCallback onTap) => TextButton.icon(
        key: key,
        style: TextButton.styleFrom(
          minimumSize: const Size(44, 44),
          foregroundColor: _cellStyle.color,
          disabledForegroundColor: _theme.disabledColor,
        ),
        onPressed: enabled ? onTap : null,
        icon: Icon(icon, size: 20),
        label: Text(label),
      );

  bool _mayUnclaim(Job j) => j.isClaimedBy(me.uid) || me.isAdmin;

  Widget _editButton(Job j) => _iconAction(
        key: Key('edit-${j.jobId}'),
        icon: Icons.edit_outlined,
        tooltip: Permissions.canEdit(me, j) ?? 'Edit job',
        enabled: Permissions.canEdit(me, j) == null && !_busy.contains(j.jobId),
        onTap: () => _edit(j),
      );

  Widget _unclaimButton(Job j) => _iconAction(
        key: Key('unclaim-${j.jobId}'),
        icon: Icons.person_remove_outlined,
        tooltip: _mayUnclaim(j) ? (j.isClaimedBy(me.uid) ? 'Unclaim' : 'Remove someone') : 'Only people on this job or an admin can unclaim',
        enabled: _mayUnclaim(j) && !_busy.contains(j.jobId),
        onTap: () => _unclaim(j),
      );

  Widget _claimButton(Job j) {
    final mine = j.isClaimedBy(me.uid);
    return SizedBox(
      height: 40,
      child: FilledButton(
        key: Key('claim-${j.jobId}'),
        style: FilledButton.styleFrom(backgroundColor: _accent, foregroundColor: Colors.white),
        onPressed: mine || _busy.contains(j.jobId) ? null : () => _claim(j),
        child: _busy.contains(j.jobId)
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : Text(mine ? 'Claimed' : 'Claim'),
      ),
    );
  }

  // ---------------------------------------------------------------- tables (wide)

  Widget _table({
    required List<_Column> columns,
    required List<Job> jobs,
    required List<Widget> Function(Job j) cells,
    required String empty,
  }) {
    final sort = _sort[_tab];
    return Container(
      decoration: BoxDecoration(
        color: _theme.cardColor,
        border: Border.all(color: _theme.dividerColor),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(children: [
            for (final c in columns)
              _sized(
                c,
                InkWell(
                  onTap: c.sort == null ? null : () => setState(() => _sort[_tab] = c.sort!),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Flexible(
                        child: Text(c.label,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: _accent, fontSize: 14, fontWeight: FontWeight.w500)),
                      ),
                      if (c.sort != null && c.sort == sort) Icon(Icons.keyboard_arrow_down, size: 16, color: _accent),
                    ]),
                  ),
                ),
              ),
          ]),
        ),
        Divider(height: 1, color: _theme.dividerColor),
        Expanded(
          child: jobs.isEmpty
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(empty, style: _mutedStyle)))
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 84),
                  itemCount: jobs.length,
                  separatorBuilder: (_, __) => Divider(height: 1, color: _theme.dividerColor),
                  itemBuilder: (_, i) {
                    final j = jobs[i];
                    final row = cells(j);
                    return Material(
                      color: Colors.transparent,
                      child: InkWell(
                        key: Key('row-${j.jobId}'),
                        onTap: () => _openJob(j),
                        hoverColor: _theme.hoverColor,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                          child: Row(children: [
                            for (var c = 0; c < columns.length; c++)
                              _sized(columns[c], Align(alignment: columns[c].align, child: row[c])),
                          ]),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }

  Widget _sized(_Column c, Widget child) =>
      c.width != null ? SizedBox(width: c.width, child: child) : Expanded(flex: c.flex, child: child);

  Widget _text(String s) => Text(s, maxLines: 1, overflow: TextOverflow.ellipsis, style: _cellStyle);

  Widget _inProgressTable(List<Job> jobs, String empty) => _table(
        empty: empty,
        jobs: jobs,
        columns: const [
          _Column('Job Name', flex: 5, sort: JobSort.name),
          _Column('Status', flex: 2),
          _Column('Time Requested', flex: 3, sort: JobSort.timeRequested),
          _Column('Time Claimed', flex: 3, sort: JobSort.timeClaimed),
          _Column('Requested By', flex: 3),
          _Column('Edit', align: Alignment.center, width: 56),
          _Column('Unclaim', align: Alignment.center, width: 72),
        ],
        cells: (j) => [
          _jobNameCell(j),
          _statusCell(j),
          _text(_time(j.createdAt)),
          Tooltip(message: 'Claimed by ${PageLogic.claimersText(j, widget.nameOf)}', child: _text(_time(j.claimedAt))),
          _text(widget.nameOf(j.requestedBy)),
          _editButton(j),
          _unclaimButton(j),
        ],
      );

  Widget _requestedTable(List<Job> jobs, String empty) => _table(
        empty: empty,
        jobs: jobs,
        columns: const [
          _Column('Job Name', flex: 5, sort: JobSort.name),
          _Column('Requested By', flex: 3),
          _Column('Priority', flex: 2, sort: JobSort.priority),
          _Column('Date Requested', flex: 3, sort: JobSort.timeRequested),
          _Column('', align: Alignment.center, width: 110),
        ],
        cells: (j) => [
          _jobNameCell(j),
          _text(widget.nameOf(j.requestedBy)),
          _priority(j.priority),
          _text(_time(j.createdAt)),
          _claimButton(j),
        ],
      );

  // ---------------------------------------------------------------- cards (phone)

  Widget _cards(List<Job> jobs, String empty) {
    if (jobs.isEmpty) return Center(child: Text(empty, textAlign: TextAlign.center, style: _mutedStyle));
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: jobs.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) {
        final j = jobs[i];
        final inProgress = j.status == JobStatus.inProgress;
        return Material(
          color: _theme.cardColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: _theme.dividerColor),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: Key('row-${j.jobId}'),
            onTap: () => _openJob(j),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: _jobNameCell(j)),
                  if (!inProgress) ...[const SizedBox(width: 8), _priority(j.priority)],
                ]),
                const SizedBox(height: 8),
                Text('Requested by ${widget.nameOf(j.requestedBy)} · ${_time(j.createdAt)}', style: _mutedStyle),
                if (inProgress)
                  Text('Claimed by ${PageLogic.claimersText(j, widget.nameOf)} · ${_time(j.claimedAt)}', style: _mutedStyle),
                const SizedBox(height: 4),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  if (inProgress) ...[
                    _labelledAction(Key('edit-${j.jobId}'), Icons.edit_outlined, 'Edit',
                        Permissions.canEdit(me, j) == null && !_busy.contains(j.jobId), () => _edit(j)),
                    const SizedBox(width: 4),
                    _labelledAction(Key('unclaim-${j.jobId}'), Icons.person_remove_outlined, 'Unclaim',
                        _mayUnclaim(j) && !_busy.contains(j.jobId), () => _unclaim(j)),
                  ] else
                    _claimButton(j),
                ]),
              ]),
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------- log

  Widget _logList() {
    final byId = {for (final j in _jobs) j.jobId: j};
    final entries = PageLogic.logEntries(
      history: _history,
      comments: _comments,
      jobs: byId,
      filter: _logFilter,
      query: _query,
      nameOf: widget.nameOf,
      newestFirst: _logNewestFirst,
    );
    if (entries.isEmpty) {
      final empty = _query.trim().isNotEmpty
          ? 'Nothing in the log matches "${_query.trim()}".'
          : switch (_logFilter) {
              LogFilter.all => 'Nothing has happened yet.',
              LogFilter.completed => 'No jobs have been completed yet.',
              LogFilter.failed => 'No jobs have failed.',
            };
      return Center(child: Text(empty, style: _mutedStyle));
    }
    return Container(
      decoration: BoxDecoration(
        color: _theme.cardColor,
        border: Border.all(color: _theme.dividerColor),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListView.separated(
        padding: const EdgeInsets.only(bottom: 84),
        itemCount: entries.length,
        separatorBuilder: (_, __) => Divider(height: 1, color: _theme.dividerColor),
        itemBuilder: (_, i) {
          final e = entries[i];
          final (icon, color) = switch (e.kind) {
            LogKind.completed => (Icons.check_circle_outline, Colors.green),
            LogKind.failed => (Icons.error_outline, Colors.redAccent),
            LogKind.comment => (Icons.chat_bubble_outline, _accent),
            LogKind.other => (Icons.history, _theme.hintColor),
          };
          final job = byId[e.jobId];
          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: job == null ? null : () => _openJob(job),
              child: Container(
                constraints: const BoxConstraints(minHeight: 52),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                child: Row(children: [
                  Icon(icon, color: color, size: 22),
                  const SizedBox(width: 14),
                  Expanded(child: Text(e.text, style: _cellStyle)),
                  const SizedBox(width: 12),
                  Text(_time(e.time), style: _mutedStyle),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Column {
  const _Column(this.label, {this.flex = 1, this.sort, this.align = Alignment.centerLeft, this.width});
  final String label;
  final int flex;
  final JobSort? sort;
  final Alignment align;
  // a fixed width instead of a share of the row (icon buttons)
  final double? width;
}
