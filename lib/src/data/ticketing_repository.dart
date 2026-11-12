import '../models/comment.dart';
import '../models/enums.dart';
import '../models/history_entry.dart';
import '../models/inventory_item.dart';
import '../models/job.dart';
import '../models/json_read.dart';
import '../rules/permissions.dart';
import 'ticketing_store.dart';

// a message to show the user: a validation problem, a permission problem, or a
// save that kept clashing with someone else's
class TicketingException implements Exception {
  TicketingException(this.message);
  final String message;
  @override
  String toString() => message;
}

// every read and write the ticketing page does.
//
// jobs live under ticketing/; parts come from lsicompapp's inventory/{id},
// which this code only reads, apart from changing 'stock' when a job takes or
// gives back parts:
//   first claim      -> takes every part's full quantity (blocked if any is short)
//   create remake    -> defective parts are scrapped (not returned); the job
//                       closes as remade; the new remake ticket pulls the
//                       replacements when it's claimed
//   last unclaim     -> gives back everything the job holds
//   cancel           -> same as last unclaim
//   complete         -> nothing; the parts were taken at claim
//
// each change saves the job, its history row(s) and any stock changes in one
// atomic update. the security rules check the job's rev (so two saves can't
// overwrite each other) and that each stock change exactly matches what the job
// took or gave back. when a save is rejected because something changed
// underneath it, the change is re-read, re-checked and retried.
class TicketingRepository {
  TicketingRepository({
    required this.store,
    required this.user,
    DateTime Function()? clock,
    this.maxAttempts = 3,
  }) : _clock = clock ?? DateTime.now;

  final TicketingStore store;
  final TicketingUser user;
  final DateTime Function() _clock;
  final int maxAttempts;

  static const String jobsPath = 'ticketing/jobs';
  static const String historyPath = 'ticketing/history';
  static const String commentsPath = 'ticketing/comments';
  static const String jobCounterPath = 'ticketing/counters/job';
  static const String inventoryPath = 'inventory';

  static const String conflictMessage =
      'Someone else changed this job or its parts at the same time. Reload and try again.';
  static const int maxNameLength = 100;
  static const int maxReasonLength = 500;

  DateTime get _now => _clock().toUtc();

  // ---------------------------------------------------------------- reads

  Future<Job?> getJob(String jobId) async {
    final raw = await store.read('$jobsPath/$jobId');
    return raw == null ? null : Job.fromJson(jobId, raw);
  }

  // newest first
  static List<Job> jobsFrom(Object? raw) {
    final list = asJsonMap(raw).entries.map((e) => Job.fromJson(e.key, e.value)).toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  static List<InventoryItem> inventoryFrom(Object? raw) {
    final list = asJsonMap(raw).entries.map((e) => InventoryItem.fromJson(e.key, e.value)).toList();
    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  static List<HistoryEntry> historyFrom(Map<String, Object?> raw) {
    final list = raw.entries.map((e) => HistoryEntry.fromJson(e.key, e.value)).toList();
    list.sort((a, b) {
      final c = a.timestamp.compareTo(b.timestamp);
      return c != 0 ? c : a.id.compareTo(b.id);
    });
    return list;
  }

  static List<Comment> commentsFrom(Map<String, Object?> raw) {
    final list = raw.entries.map((e) => Comment.fromJson(e.key, e.value)).toList();
    list.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return list;
  }

  Stream<List<Job>> watchJobs() => store.watch(jobsPath).map(jobsFrom);

  // everything in the change log and every comment, live, for the Log tab.
  // fine at trial size; past a few thousand rows this should page or limit.
  Stream<List<HistoryEntry>> watchHistory() => store.watch(historyPath).map((raw) => historyFrom(asJsonMap(raw)));
  Stream<List<Comment>> watchComments() => store.watch(commentsPath).map((raw) => commentsFrom(asJsonMap(raw)));
  Future<List<Job>> listJobs() async => jobsFrom(await store.read(jobsPath));

  // the whole inventory, for the part picker; the inventory page loads it the same way
  Stream<List<InventoryItem>> watchInventory() => store.watch(inventoryPath).map(inventoryFrom);
  Future<List<InventoryItem>> listInventory() async => inventoryFrom(await store.read(inventoryPath));

  Future<InventoryItem?> getInventoryItem(String itemId) async {
    final raw = await store.read('$inventoryPath/$itemId');
    return raw == null ? null : InventoryItem.fromJson(itemId, raw);
  }

  // the current inventory record for each part on the job; missing items are left out
  Future<Map<String, InventoryItem>> stockFor(Job job) async {
    final out = <String, InventoryItem>{};
    for (final id in job.lines.keys) {
      final item = await getInventoryItem(id);
      if (item != null) out[id] = item;
    }
    return out;
  }

  Future<List<HistoryEntry>> historyForJob(String jobId) async =>
      historyFrom(await store.queryEqual(historyPath, field: 'jobId', value: jobId));

  // where an inventory item went: every job that took, returned or scrapped it
  Future<List<HistoryEntry>> historyForItem(String itemId) async =>
      historyFrom(await store.queryEqual(historyPath, field: 'itemId', value: itemId));

  Future<List<Comment>> commentsForJob(String jobId) async =>
      commentsFrom(await store.queryEqual(commentsPath, field: 'jobId', value: jobId));

  // ---------------------------------------------------------------- helpers

  Future<Job> _requireJob(String jobId) async =>
      await getJob(jobId) ?? (throw TicketingException('Job $jobId was not found.'));

  void _check(String? reason) {
    if (reason != null) throw TicketingException(reason);
  }

  HistoryEntry _history(HistoryType type, Job j, {String? itemId, String? from, String? to, int? quantityChange}) =>
      HistoryEntry(
        id: store.newKey(historyPath),
        jobId: j.jobId,
        itemId: itemId,
        type: type,
        from: from,
        to: to,
        quantityChange: quantityChange,
        user: user.uid,
        timestamp: _now,
      );

  // the next version of a job: rev + 1, stamped, pointing at its last history row
  Job _next(Job j, List<HistoryEntry> rows) =>
      j.copyWith(rev: j.rev + 1, updatedAt: _now, lastHistoryId: rows.last.id);

  Map<String, Object?> _save(Job next, List<HistoryEntry> rows, [Map<String, int> stock = const {}]) => {
        '$jobsPath/${next.jobId}': next.toJson(),
        for (final h in rows) '$historyPath/${h.id}': h.toJson(),
        // exact new values, not increments: the rules compare them with the
        // stock at save time, so a stale read is refused and retried
        for (final e in stock.entries) '$inventoryPath/${e.key}/stock': e.value,
      };

  // runs attempt, and runs it again (re-reading everything) if the database
  // rejected the save because the data changed in between
  Future<T> _retrying<T>(Future<T> Function() attempt) async {
    for (var i = 1;; i++) {
      try {
        return await attempt();
      } on TicketingWriteRejected {
        if (i >= maxAttempts) throw TicketingException(conflictMessage);
      }
    }
  }

  // checks a parts list from the add-job form: whole quantities above zero, and
  // every part in inventory. returns the lines, with nothing held yet.
  Future<Map<String, JobLine>> _newLines(Map<String, int> parts) async {
    if (parts.isEmpty) throw TicketingException('Add at least one part.');
    final lines = <String, JobLine>{};
    for (final e in parts.entries) {
      if (e.value <= 0) throw TicketingException('Each part needs a quantity of at least 1.');
      if (await getInventoryItem(e.key) == null) throw TicketingException('A part on this job is no longer in inventory.');
      lines[e.key] = JobLine(itemId: e.key, quantity: e.value);
    }
    return lines;
  }

  String _checkName(String name) {
    final n = name.trim();
    if (n.isEmpty) throw TicketingException('Give the job a name.');
    if (n.length > maxNameLength) throw TicketingException('Job names must be $maxNameLength characters or fewer.');
    return n;
  }

  // gives back everything the job holds. returns the new lines, the stock
  // values to save and a 'returned' history row per part.
  Future<(Map<String, JobLine>, Map<String, int>, List<HistoryEntry>)> _returnAll(Job j) async {
    final lines = <String, JobLine>{};
    final stock = <String, int>{};
    final rows = <HistoryEntry>[];
    for (final line in j.lines.values) {
      lines[line.itemId] = line.copyWith(held: 0);
      if (line.held == 0) continue;
      final item = await getInventoryItem(line.itemId);
      // an item deleted from the inventory page has nowhere to go back to
      if (item == null) continue;
      stock[line.itemId] = item.stock + line.held;
      rows.add(_history(HistoryType.returned, j, itemId: line.itemId,
          from: '${item.stock}', to: '${item.stock + line.held}', quantityChange: line.held));
    }
    return (lines, stock, rows);
  }

  // ---------------------------------------------------------------- jobs

  // the Add Job form. requestedBy is who the job is for (the form pre-fills
  // the signed-in person; any active scholar can be picked); the signed-in
  // person is saved as submittedBy. parts maps inventory item id -> quantity.
  // a non-empty comment is saved as the job's first comment, in the same save.
  Future<Job> createJob({
    required String jobName,
    required String requestedBy,
    required DateTime dueDate,
    JobPriority? priority,
    required Map<String, int> parts,
    String comment = '',
  }) async {
    final name = _checkName(jobName);
    if (requestedBy.trim().isEmpty) throw TicketingException('Choose who the job is for.');
    final firstComment = comment.trim().isEmpty ? null : _checkComment(comment);
    final lines = await _newLines(parts);

    // the number is taken before the save; if the save then fails that number
    // is skipped rather than reused
    final jobId = Job.formatId(await store.nextNumber(jobCounterPath));
    final now = _now;
    var job = Job(
      jobId: jobId,
      jobName: name,
      requestedBy: requestedBy.trim(),
      submittedBy: user.uid,
      lines: lines,
      status: JobStatus.requested,
      neededBy: dueDate,
      priority: priority,
      createdAt: now,
      updatedAt: now,
    );
    final created = _history(HistoryType.created, job, to: name);
    job = job.copyWith(rev: 1, lastHistoryId: created.id);
    final c = firstComment == null
        ? null
        : Comment(id: store.newKey(commentsPath), jobId: jobId, author: user.uid, text: firstComment, timestamp: now);
    try {
      await store.update({..._save(job, [created]), if (c != null) '$commentsPath/${c.id}': c.toJson()});
    } on TicketingWriteRejected {
      throw TicketingException(
          'The job could not be saved. Check that you are signed in and that the requester is an active scholar.');
    }
    return job;
  }

  // the requester, submitter or an admin changes the job. pass only what
  // changes; priority takes a function so it can be cleared (() => null).
  // parts replaces the whole parts list and is only allowed before a claim.
  Future<Job> editJob(String jobId, {
    String? jobName,
    String? requestedBy,
    DateTime? dueDate,
    JobPriority? Function()? priority,
    Map<String, int>? parts,
  }) async {
    final name = jobName == null ? null : _checkName(jobName);
    if (requestedBy != null && requestedBy.trim().isEmpty) throw TicketingException('Choose who the job is for.');
    return _retrying(() async {
      final j = await _requireJob(jobId);
      final newLines = parts == null ? null : await _newLines(parts);
      final changesParts = newLines != null && _describeParts(newLines) != _describeParts(j.lines);
      _check(Permissions.canEdit(user, j, changesParts: changesParts));
      final changed = j.copyWith(
        jobName: name,
        requestedBy: requestedBy?.trim(),
        neededBy: dueDate,
        priority: priority,
        lines: changesParts ? newLines : null,
      );
      final before = _describe(j);
      final after = _describe(changed);
      if (before == after) return j;
      final rows = [_history(HistoryType.edited, j, from: before, to: after)];
      final next = _next(changed, rows);
      await store.update(_save(next, rows));
      return next;
    });
  }

  static String _describeParts(Map<String, JobLine> lines) =>
      (lines.values.map((l) => '${l.quantity} x ${l.itemId}').toList()..sort()).join(', ');

  static String _describe(Job j) => [
        'name ${j.jobName}',
        'for ${j.requestedBy}',
        'due ${j.neededBy.toIso8601String().substring(0, 10)}',
        'priority ${j.priority?.name ?? '-'}',
        'parts ${_describeParts(j.lines)}',
      ].join('; ');

  // the first claim takes every part out of inventory (blocked if any is
  // short); later claimers just join the job
  Future<Job> claim(String jobId) => _retrying(() async {
        final j = await _requireJob(jobId);
        final stock = await stockFor(j);
        _check(Permissions.canClaim(user, j, stock));
        final now = _now;
        final claimers = {...j.claimers, user.uid: now};

        if (j.status == JobStatus.inProgress) {
          final rows = [_history(HistoryType.claimed, j, to: user.uid)];
          final next = _next(j.copyWith(claimers: claimers), rows);
          await store.update(_save(next, rows));
          return next;
        }

        final rows = <HistoryEntry>[];
        final newStock = <String, int>{};
        final lines = <String, JobLine>{};
        for (final line in j.lines.values) {
          final have = stock[line.itemId]!.stock;
          newStock[line.itemId] = have - line.quantity;
          lines[line.itemId] = line.copyWith(held: line.quantity);
          rows.add(_history(HistoryType.reserved, j, itemId: line.itemId,
              from: '$have', to: '${have - line.quantity}', quantityChange: -line.quantity));
        }
        rows.add(_history(HistoryType.claimed, j, to: user.uid));
        final next = _next(
            j.copyWith(claimers: claimers, lines: lines, status: JobStatus.inProgress, claimedAt: () => now), rows);
        await store.update(_save(next, rows, newStock));
        return next;
      });

  // a claimer leaves (claimerUid defaults to the signed-in user; admins can
  // remove anyone). when the last claimer leaves, the job goes back to
  // requested and everything it holds goes back to inventory.
  Future<Job> unclaim(String jobId, {String? claimerUid}) {
    final who = claimerUid ?? user.uid;
    return _retrying(() async {
      final j = await _requireJob(jobId);
      _check(Permissions.canUnclaim(user, j, who));
      final claimers = {...j.claimers}..remove(who);
      final left = _history(HistoryType.unclaimed, j, from: who);

      if (claimers.isNotEmpty) {
        final next = _next(j.copyWith(claimers: claimers), [left]);
        await store.update(_save(next, [left]));
        return next;
      }

      final (lines, stock, returned) = await _returnAll(j);
      final rows = [...returned, left];
      final next = _next(
          j.copyWith(claimers: const {}, lines: lines, status: JobStatus.requested, claimedAt: () => null), rows);
      await store.update(_save(next, rows, stock));
      return next;
    });
  }

  // reports defects on an in-progress or completed job. creates a remake
  // ticket (a new job labelled Remake) and closes this job as remade, in one
  // save. the remake starts with this job's name, requester, due date and
  // priority unless they're given; its parts order is the defective parts,
  // which are scrapped on this job and never returned to inventory.
  //
  // the person creating the remake then claims it, which pulls the
  // replacements from inventory. that's a second save, because one save can't
  // both scrap and take the same part under the stock rule. if any replacement
  // is short (or the claim fails), the remake stays unclaimed in requested and
  // whoever claims it later pulls the parts. check the returned job's status
  // to tell which.
  //
  // defects maps inventory item id -> how many were defective and why.
  Future<Job> createRemake(String jobId, {
    required Map<String, Defect> defects,
    String? jobName,
    String? requestedBy,
    DateTime? dueDate,
    JobPriority? Function()? priority,
    String comment = '',
  }) async {
    if (defects.isEmpty) throw TicketingException('Select at least one defective part.');
    for (final d in defects.values) {
      if (d.count <= 0) throw TicketingException('Each defective part needs a count of at least 1.');
      if (d.reason.trim().length > maxReasonLength) {
        throw TicketingException('Reasons must be $maxReasonLength characters or fewer.');
      }
    }
    final name = jobName == null ? null : _checkName(jobName);
    final firstComment = comment.trim().isEmpty ? null : _checkComment(comment);

    _check(Permissions.canCreateRemake(user, await _requireJob(jobId)));
    // taken once, before any retry
    final remakeId = Job.formatId(await store.nextNumber(jobCounterPath));

    return _retrying(() async {
      final j = await _requireJob(jobId);
      _check(Permissions.canCreateRemake(user, j));
      final now = _now;

      final cleaned = <String, Defect>{};
      final rows = <HistoryEntry>[];
      final lines = {...j.lines};
      final remakeLines = <String, JobLine>{};
      for (final e in defects.entries) {
        final line = j.lines[e.key] ?? (throw TicketingException('A defective part isn\'t on this job.'));
        if (e.value.count > line.held) {
          throw TicketingException('This job only has ${line.held} of one of the defective parts.');
        }
        if (await getInventoryItem(e.key) == null) {
          throw TicketingException('A defective part is no longer in inventory, so it can\'t be reordered.');
        }
        cleaned[e.key] = Defect(count: e.value.count, reason: e.value.reason.trim());
        lines[e.key] = line.copyWith(held: line.held - e.value.count, scrapped: line.scrapped + e.value.count);
        remakeLines[e.key] = JobLine(itemId: e.key, quantity: e.value.count);
        rows.add(_history(HistoryType.scrapped, j, itemId: e.key,
            from: '${line.scrapped}', to: '${line.scrapped + e.value.count}', quantityChange: e.value.count));
      }
      rows.add(_history(HistoryType.remade, j, from: j.status.name, to: remakeId));
      final closed = _next(j.copyWith(lines: lines, status: JobStatus.remade, remadeAs: remakeId), rows);

      final given = requestedBy?.trim() ?? '';
      var remake = Job(
        jobId: remakeId,
        jobName: name ?? j.jobName,
        requestedBy: given.isNotEmpty ? given : j.requestedBy,
        submittedBy: user.uid,
        lines: remakeLines,
        status: JobStatus.requested,
        neededBy: dueDate ?? j.neededBy,
        priority: priority != null ? priority() : j.priority,
        createdAt: now,
        updatedAt: now,
        remakeOf: j.jobId,
        usedParts: {for (final l in j.lines.values) l.itemId: l.quantity},
        defects: cleaned,
      );
      final created = _history(HistoryType.created, remake, from: j.jobId, to: remake.jobName);
      remake = remake.copyWith(rev: 1, lastHistoryId: created.id);
      final c = firstComment == null
          ? null
          : Comment(id: store.newKey(commentsPath), jobId: remakeId, author: user.uid, text: firstComment, timestamp: now);

      await store.update({
        ..._save(closed, rows),
        ..._save(remake, [created]),
        if (c != null) '$commentsPath/${c.id}': c.toJson(),
      });
      return remake;
    }).then((remake) async {
      try {
        return await claim(remake.jobId);
      } on TicketingException {
        // short stock, or someone else got there first: it waits in requested
        return await getJob(remake.jobId) ?? remake;
      }
    });
  }

  // jobs made to replace this one, oldest first, by following remadeAs
  Future<List<Job>> remakeChain(String jobId) async {
    final out = <Job>[];
    var next = (await getJob(jobId))?.remadeAs;
    while (next != null && out.length < 50) {
      final j = await getJob(next);
      if (j == null) break;
      out.add(j);
      next = j.remadeAs;
    }
    return out;
  }

  // the arm is built. the parts were already taken at claim, so stock doesn't change.
  Future<Job> complete(String jobId) => _retrying(() async {
        final j = await _requireJob(jobId);
        _check(Permissions.canComplete(user, j));
        final rows = [_history(HistoryType.completed, j, from: j.status.name, to: JobStatus.completed.name)];
        final next = _next(j.copyWith(status: JobStatus.completed, completedAt: _now), rows);
        await store.update(_save(next, rows));
        return next;
      });

  // the requester or an admin closes the job. anything it holds goes back to inventory.
  Future<Job> cancel(String jobId) => _retrying(() async {
        final j = await _requireJob(jobId);
        _check(Permissions.canCancel(user, j));
        final (lines, stock, returned) = await _returnAll(j);
        final rows = [...returned, _history(HistoryType.cancelled, j, from: j.status.name, to: JobStatus.cancelled.name)];
        final next = _next(j.copyWith(lines: lines, status: JobStatus.cancelled), rows);
        await store.update(_save(next, rows, stock));
        return next;
      });

  // ---------------------------------------------------------------- comments

  Future<Comment> addComment(String jobId, String text) async {
    final body = _checkComment(text);
    _check(Permissions.canComment(user, await _requireJob(jobId)));
    final c = Comment(id: store.newKey(commentsPath), jobId: jobId, author: user.uid, text: body, timestamp: _now);
    await _writeComment(c.id, c.toJson(), 'saved');
    return c;
  }

  // the author changes their comment's text
  Future<Comment> editComment(String commentId, String text) async {
    if (text.trim().isEmpty) throw TicketingException('A comment can\'t be empty. Delete it instead.');
    final body = _checkComment(text);
    final c = await _requireComment(commentId);
    _check(Permissions.canEditComment(user, c));
    if (c.text == body) return c;
    final next = c.edited(body, _now);
    await _writeComment(commentId, next.toJson(), 'saved');
    return next;
  }

  // the author, or an admin, removes a comment
  Future<void> deleteComment(String commentId) async {
    final c = await _requireComment(commentId);
    _check(Permissions.canDeleteComment(user, c));
    await _writeComment(commentId, null, 'deleted');
  }

  String _checkComment(String text) {
    final body = text.trim();
    if (body.isEmpty) throw TicketingException('Write a comment first.');
    if (body.length > Comment.maxLength) {
      throw TicketingException('Comments must be ${Comment.maxLength} characters or fewer.');
    }
    return body;
  }

  Future<Comment> _requireComment(String commentId) async {
    final raw = await store.read('$commentsPath/$commentId');
    if (raw == null) throw TicketingException('That comment was deleted.');
    return Comment.fromJson(commentId, raw);
  }

  Future<void> _writeComment(String id, Object? value, String verb) async {
    try {
      await store.update({'$commentsPath/$id': value});
    } on TicketingWriteRejected {
      throw TicketingException('The comment could not be $verb. Check that you are signed in and try again.');
    }
  }
}
