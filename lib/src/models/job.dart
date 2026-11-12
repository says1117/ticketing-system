import 'enums.dart';
import 'json_read.dart';

// one part on a job: how many are needed, and what the job currently has.
// stored at ticketing/jobs/{jobId}/lines/{inventoryItemId}.
//
// held + scrapped + the item's inventory stock only ever moves together: taking
// parts raises held and lowers stock, giving them back does the reverse, and
// defects reported in a remake move parts from held to scrapped (not back to
// stock). the security rules check that sum on every save.
class JobLine {
  const JobLine({required this.itemId, required this.quantity, this.held = 0, this.scrapped = 0});

  // the inventory/{id} key of the part
  final String itemId;
  // how many the job needs
  final int quantity;
  // good parts the job has taken out of inventory and not given back
  final int held;
  // defective parts reported in a remake (never returned to inventory)
  final int scrapped;

  factory JobLine.fromJson(String itemId, Object? json) {
    final m = asJsonMap(json);
    return JobLine(
      itemId: itemId,
      quantity: readInt(m['quantity']),
      held: readInt(m['held']),
      scrapped: readInt(m['scrapped']),
    );
  }

  Map<String, Object?> toJson() => {'quantity': quantity, 'held': held, 'scrapped': scrapped};

  JobLine copyWith({int? quantity, int? held, int? scrapped}) => JobLine(
        itemId: itemId,
        quantity: quantity ?? this.quantity,
        held: held ?? this.held,
        scrapped: scrapped ?? this.scrapped,
      );
}

// one reported defect on a remake ticket: how many of a part were defective,
// and optionally why
class Defect {
  const Defect({required this.count, this.reason = ''});
  final int count;
  final String reason;

  factory Defect.fromJson(Object? json) {
    final m = asJsonMap(json);
    return Defect(count: readInt(m['count']), reason: readString(m['reason']));
  }

  Map<String, Object?> toJson() => withoutNulls({'count': count, 'reason': reason.isEmpty ? null : reason});
}

// one assembly job, stored at ticketing/jobs/{jobId}. the readable id
// (JOB-0042) is also the database key.
//
// a remake ticket is a job with remakeOf set: its lines are the replacement
// parts to pull, usedParts is the full parts list of the job it replaces, and
// defects says how many of each part were defective and why.
class Job {
  const Job({
    required this.jobId,
    required this.jobName,
    required this.requestedBy,
    required this.submittedBy,
    required this.lines,
    this.claimers = const {},
    required this.status,
    required this.neededBy,
    this.priority,
    required this.createdAt,
    required this.updatedAt,
    this.claimedAt,
    this.completedAt,
    this.rev = 0,
    this.lastHistoryId,
    this.remakeOf,
    this.remadeAs,
    this.usedParts = const {},
    this.defects = const {},
  });

  final String jobId;
  final String jobName;
  // who the job is for. the Add Job form pre-fills the signed-in person and
  // lets them pick another scholar. uids; the page shows names via usersProfile.
  final String requestedBy;
  // who actually submitted the job (always the signed-in person)
  final String submittedBy;
  // keyed by inventory item id
  final Map<String, JobLine> lines;
  // uid -> when they claimed
  final Map<String, DateTime> claimers;
  final JobStatus status;
  // the due date: a calendar day, no time
  final DateTime neededBy;
  // optional
  final JobPriority? priority;
  final DateTime createdAt;
  final DateTime updatedAt;
  // when the job last went from requested to in progress
  final DateTime? claimedAt;
  final DateTime? completedAt;
  // bumped by one on every save; the security rules reject a save whose rev
  // isn't the stored rev + 1, so two people saving at once can't overwrite each other
  final int rev;
  // the history row written together with the last change to this job
  final String? lastHistoryId;
  // on a remake ticket: the job it replaces
  final String? remakeOf;
  // on a job closed as remade: its remake ticket
  final String? remadeAs;
  // on a remake ticket: inventory item id -> quantity the original job used
  final Map<String, int> usedParts;
  // on a remake ticket: inventory item id -> what was defective
  final Map<String, Defect> defects;

  // shown with a Remake label
  bool get isRemake => remakeOf != null;

  bool get isOpen => status == JobStatus.requested || status == JobStatus.inProgress;
  bool get isClosed => !isOpen;
  bool isClaimedBy(String uid) => claimers.containsKey(uid);
  // the requester and the submitter can both edit or cancel the job
  bool isRequester(String uid) => requestedBy == uid || submittedBy == uid;

  static String formatId(int number) => 'JOB-${number.toString().padLeft(4, '0')}';

  factory Job.fromJson(String id, Object? json) {
    final m = asJsonMap(json);
    final created = readDate(m['createdAt']) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    return Job(
      jobId: id,
      jobName: readString(m['jobName']),
      requestedBy: readString(m['requestedBy']),
      submittedBy: readString(m['submittedBy'], readString(m['requestedBy'])),
      lines: {
        for (final e in asJsonMap(m['lines']).entries) e.key: JobLine.fromJson(e.key, e.value),
      },
      claimers: {
        for (final e in asJsonMap(m['claimers']).entries)
          if (readDate(e.value) != null) e.key: readDate(e.value)!,
      },
      status: enumFromName(JobStatus.values, m['status']) ?? JobStatus.requested,
      neededBy: readDay(m['neededBy']) ?? created,
      priority: enumFromName(JobPriority.values, m['priority']),
      createdAt: created,
      updatedAt: readDate(m['updatedAt']) ?? created,
      claimedAt: readDate(m['claimedAt']),
      completedAt: readDate(m['completedAt']),
      rev: readInt(m['rev']),
      lastHistoryId: readOptionalString(m['lastHistoryId']),
      remakeOf: readOptionalString(m['remakeOf']),
      remadeAs: readOptionalString(m['remadeAs']),
      usedParts: {for (final e in asJsonMap(m['usedParts']).entries) e.key: readInt(e.value)},
      defects: {for (final e in asJsonMap(m['defects']).entries) e.key: Defect.fromJson(e.value)},
    );
  }

  Map<String, Object?> toJson() => withoutNulls({
        'jobId': jobId,
        'jobName': jobName,
        'requestedBy': requestedBy,
        'submittedBy': submittedBy,
        'lines': {for (final l in lines.values) l.itemId: l.toJson()},
        'claimers': claimers.isEmpty ? null : {for (final e in claimers.entries) e.key: writeDate(e.value)},
        'status': status.name,
        'neededBy': writeDay(neededBy),
        'priority': priority?.name,
        'createdAt': writeDate(createdAt),
        'updatedAt': writeDate(updatedAt),
        'claimedAt': writeDate(claimedAt),
        'completedAt': writeDate(completedAt),
        'rev': rev,
        'lastHistoryId': lastHistoryId,
        'remakeOf': remakeOf,
        'remadeAs': remadeAs,
        'usedParts': usedParts.isEmpty ? null : usedParts,
        'defects': defects.isEmpty ? null : {for (final e in defects.entries) e.key: e.value.toJson()},
      });

  // nullable fields take a function so they can be cleared: claimedAt: () => null
  Job copyWith({
    String? jobName,
    String? requestedBy,
    Map<String, JobLine>? lines,
    Map<String, DateTime>? claimers,
    JobStatus? status,
    DateTime? neededBy,
    JobPriority? Function()? priority,
    DateTime? updatedAt,
    DateTime? Function()? claimedAt,
    DateTime? completedAt,
    int? rev,
    String? lastHistoryId,
    String? remadeAs,
  }) =>
      Job(
        jobId: jobId,
        jobName: jobName ?? this.jobName,
        requestedBy: requestedBy ?? this.requestedBy,
        submittedBy: submittedBy,
        lines: lines ?? this.lines,
        claimers: claimers ?? this.claimers,
        status: status ?? this.status,
        neededBy: neededBy ?? this.neededBy,
        priority: priority != null ? priority() : this.priority,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        claimedAt: claimedAt != null ? claimedAt() : this.claimedAt,
        completedAt: completedAt ?? this.completedAt,
        rev: rev ?? this.rev,
        lastHistoryId: lastHistoryId ?? this.lastHistoryId,
        remakeOf: remakeOf,
        remadeAs: remadeAs ?? this.remadeAs,
        usedParts: usedParts,
        defects: defects,
      );
}
