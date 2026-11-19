// what the job popup shows for each status, and the failure details of a job
// that was remade. plain Dart so it can be unit tested; the popup only
// displays what this says.
//
// a closed job keeps its claimers and lines, so the popup reads them the
// same way for every status; only the headings and the closing date differ.
// a failed (remade) job's failure details live on its remake ticket, which
// remadeAs points to: the remake's createdAt is when it failed, and its
// defects are the parts that failed and why.

import '../models/enums.dart';
import '../models/job.dart';

class FailureDetails {
  const FailureDetails({required this.remakeId, required this.failedAt, required this.defects});

  final String remakeId;
  final DateTime failedAt;
  // inventory item id -> how many failed and why
  final Map<String, Defect> defects;

  // null unless remake really is the ticket that replaced original (remadeAs
  // and remakeOf point at each other), so a wrong or missing job never shows
  // someone else's defects
  static FailureDetails? of(Job original, Job? remake) {
    if (original.status != JobStatus.remade || remake == null) return null;
    if (original.remadeAs != remake.jobId || remake.remakeOf != original.jobId) return null;
    return FailureDetails(remakeId: remake.jobId, failedAt: remake.createdAt, defects: remake.defects);
  }

  int get partsFailed => defects.values.fold(0, (sum, d) => sum + d.count);
}

class ClosedJobLogic {
  // the people on the job: who is working on it while open, who worked on it after
  static String peopleHeading(Job j) => j.isOpen ? 'Claimed by' : 'Scholars';

  static String partsHeading(Job j) => switch (j.status) {
        JobStatus.requested => 'Parts required',
        JobStatus.inProgress => 'Parts needed',
        JobStatus.completed || JobStatus.remade => 'Parts used',
        // cancel returns everything the job held to inventory
        JobStatus.cancelled => 'Parts requested (returned to inventory)',
      };

  // the date a closed job closed, with its label. null for open jobs, and for
  // a failed job whose remake hasn't loaded yet. a cancel is a job's last
  // save, so updatedAt is when it was cancelled.
  static (String, DateTime)? closedOn(Job j, FailureDetails? failure) => switch (j.status) {
        JobStatus.completed => j.completedAt == null ? null : ('Date completed', j.completedAt!),
        JobStatus.remade => failure == null ? null : ('Date failed', failure.failedAt),
        JobStatus.cancelled => ('Date cancelled', j.updatedAt),
        JobStatus.requested || JobStatus.inProgress => null,
      };

  // "Fingertip × 2: cracked at the joint". partName turns an item id into a
  // name; the reason is left off when none was given.
  static List<String> failureLines(FailureDetails f, String Function(String itemId) partName) => [
        for (final e in f.defects.entries)
          '${partName(e.key)} × ${e.value.count}${e.value.reason.isEmpty ? '' : ': ${e.value.reason}'}',
      ];
}
