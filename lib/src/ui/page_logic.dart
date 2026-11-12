// pure rules for the main Ticketing page: which jobs go on which tab, search,
// sorting, and the sentences on the Log tab. nothing in here touches widgets
// or Firebase, so it's unit tested directly (test/page_logic_test.dart).

import '../models/comment.dart';
import '../models/enums.dart';
import '../models/history_entry.dart';
import '../models/job.dart';

enum JobTab { inProgress, requested, log }

// the chips under the Log tab
enum LogFilter { all, completed, failed }

enum JobSort { dueDate, priority, timeRequested, timeClaimed, name }

// turns a uid into a display name (lsicompapp: usersProfile[uid]['displayName'])
typedef NameOf = String Function(String uid);

class PageLogic {
  static String tabLabel(JobTab t) => switch (t) {
        JobTab.inProgress => 'In-Progress',
        JobTab.requested => 'Requested',
        JobTab.log => 'Log',
      };

  static String filterLabel(LogFilter f) => switch (f) {
        LogFilter.all => 'All',
        LogFilter.completed => 'Completed',
        LogFilter.failed => 'Failed',
      };

  static String sortLabel(JobSort s) => switch (s) {
        JobSort.dueDate => 'Due date',
        JobSort.priority => 'Priority',
        JobSort.timeRequested => 'Time requested',
        JobSort.timeClaimed => 'Time claimed',
        JobSort.name => 'Job name',
      };

  // the sorts offered on each job tab; the first is the default
  static List<JobSort> sortsFor(JobTab t) => switch (t) {
        JobTab.inProgress => const [JobSort.dueDate, JobSort.timeClaimed, JobSort.timeRequested, JobSort.priority, JobSort.name],
        JobTab.requested => const [JobSort.dueDate, JobSort.priority, JobSort.timeRequested, JobSort.name],
        JobTab.log => const [],
      };

  static String statusLabel(JobStatus s) => switch (s) {
        JobStatus.requested => 'Requested',
        JobStatus.inProgress => 'In progress',
        JobStatus.completed => 'Completed',
        JobStatus.cancelled => 'Cancelled',
        JobStatus.remade => 'Failed',
      };

  static String priorityLabel(JobPriority? p) => switch (p) {
        null => '—',
        JobPriority.low => 'Low',
        JobPriority.medium => 'Medium',
        JobPriority.high => 'High',
      };

  // past its due date and not finished. today is the local calendar day.
  static bool isOverdue(Job j, DateTime today) {
    final day = DateTime.utc(today.year, today.month, today.day);
    return j.isOpen && j.neededBy.isBefore(day);
  }

  // search matches the job id, name, requester and claimers, ignoring case
  static bool matches(Job j, String query, NameOf nameOf) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final haystack = [
      j.jobId,
      j.jobName,
      nameOf(j.requestedBy),
      for (final uid in j.claimers.keys) nameOf(uid),
    ].join(' ').toLowerCase();
    return q.split(RegExp(r'\s+')).every(haystack.contains);
  }

  static int _priorityRank(JobPriority? p) => switch (p) {
        JobPriority.high => 0,
        JobPriority.medium => 1,
        JobPriority.low => 2,
        null => 3,
      };

  // the jobs for In-Progress or Requested, searched and sorted. ties fall back
  // to the job id so the order never jumps around.
  static List<Job> jobsFor(JobTab tab, List<Job> jobs, {
    required String query,
    required JobSort sort,
    required NameOf nameOf,
  }) {
    final status = tab == JobTab.inProgress ? JobStatus.inProgress : JobStatus.requested;
    final list = jobs.where((j) => j.status == status && matches(j, query, nameOf)).toList();
    int cmp(Job a, Job b) {
      final far = DateTime.utc(9999);
      final c = switch (sort) {
        JobSort.dueDate => a.neededBy.compareTo(b.neededBy),
        JobSort.priority => _priorityRank(a.priority).compareTo(_priorityRank(b.priority)),
        JobSort.timeRequested => b.createdAt.compareTo(a.createdAt),
        JobSort.timeClaimed => (b.claimedAt ?? far).compareTo(a.claimedAt ?? far),
        JobSort.name => a.jobName.toLowerCase().compareTo(b.jobName.toLowerCase()),
      };
      return c != 0 ? c : a.jobId.compareTo(b.jobId);
    }

    list.sort(cmp);
    return list;
  }

  static String claimersText(Job j, NameOf nameOf) =>
      j.claimers.isEmpty ? '—' : j.claimers.keys.map(nameOf).join(', ');

  // ---------------------------------------------------------------- Log tab

  // the Log tab's rows, newest first: what people did, as sentences.
  // completed = jobs marked complete; failed = jobs closed as remade.
  static List<LogEntry> logEntries({
    required List<HistoryEntry> history,
    required List<Comment> comments,
    required Map<String, Job> jobs,
    required LogFilter filter,
    required String query,
    required NameOf nameOf,
    bool newestFirst = true,
  }) {
    String jobRef(String id) {
      final name = jobs[id]?.jobName;
      return name == null || name.isEmpty ? id : '$id "$name"';
    }

    final entries = <LogEntry>[];
    for (final h in history) {
      final who = nameOf(h.user);
      final kind = switch (h.type) {
        HistoryType.completed => LogKind.completed,
        HistoryType.remade => LogKind.failed,
        _ => LogKind.other,
      };
      if (filter == LogFilter.completed && kind != LogKind.completed) continue;
      if (filter == LogFilter.failed && kind != LogKind.failed) continue;
      final text = switch (h.type) {
        HistoryType.created => jobs[h.jobId]?.isRemake == true
            ? '$who created remake ${jobRef(h.jobId)}'
            : '$who requested ${jobRef(h.jobId)}',
        HistoryType.edited => '$who edited ${jobRef(h.jobId)}',
        HistoryType.claimed => h.to != null && h.to != h.user
            ? '$who added ${nameOf(h.to!)} to ${jobRef(h.jobId)}'
            : '$who claimed ${jobRef(h.jobId)}',
        HistoryType.unclaimed => h.from != null && h.from != h.user
            ? '$who removed ${nameOf(h.from!)} from ${jobRef(h.jobId)}'
            : '$who unclaimed ${jobRef(h.jobId)}',
        HistoryType.completed => '$who marked ${jobRef(h.jobId)} as complete',
        HistoryType.cancelled => '$who cancelled ${jobRef(h.jobId)}',
        HistoryType.remade => '$who marked ${jobRef(h.jobId)} as failed (remake ${h.to ?? ''})',
        // per-part stock rows are shown on the job, not in the feed
        HistoryType.reserved || HistoryType.returned || HistoryType.scrapped => null,
      };
      if (text == null) continue;
      entries.add(LogEntry(jobId: h.jobId, text: text, time: h.timestamp, kind: kind));
    }
    if (filter == LogFilter.all) {
      for (final c in comments) {
        entries.add(LogEntry(
          jobId: c.jobId,
          text: '${nameOf(c.author)} commented on ${jobRef(c.jobId)}',
          time: c.timestamp,
          kind: LogKind.comment,
        ));
      }
    }
    final q = query.trim().toLowerCase();
    final shown = q.isEmpty ? entries : entries.where((e) => e.text.toLowerCase().contains(q)).toList();
    shown.sort((a, b) => newestFirst ? b.time.compareTo(a.time) : a.time.compareTo(b.time));
    return shown;
  }
}

enum LogKind { completed, failed, comment, other }

class LogEntry {
  const LogEntry({required this.jobId, required this.text, required this.time, required this.kind});
  final String jobId;
  final String text;
  final DateTime time;
  final LogKind kind;
}
