import 'enums.dart';
import 'json_read.dart';

// one row of the change log, stored at ticketing/history/{pushId}. rows are
// append only: the rules let nobody edit or delete one.
//
// itemId is set on rows about one part (reserved, returned, scrapped).
// quantityChange is the change to that item's inventory stock for reserved
// (negative) and returned (positive), and the number of parts for scrapped.
class HistoryEntry {
  const HistoryEntry({
    required this.id,
    required this.jobId,
    this.itemId,
    required this.type,
    this.from,
    this.to,
    this.quantityChange,
    required this.user,
    required this.timestamp,
  });

  final String id;
  final String jobId;
  final String? itemId;
  final HistoryType type;
  final String? from;
  final String? to;
  final int? quantityChange;
  // uid of whoever made the change
  final String user;
  final DateTime timestamp;

  factory HistoryEntry.fromJson(String id, Object? json) {
    final m = asJsonMap(json);
    return HistoryEntry(
      id: id,
      jobId: readString(m['jobId']),
      itemId: readOptionalString(m['itemId']),
      type: enumFromName(HistoryType.values, m['type']) ?? HistoryType.edited,
      from: readOptionalString(m['from']),
      to: readOptionalString(m['to']),
      quantityChange: readOptionalInt(m['quantityChange']),
      user: readString(m['user']),
      timestamp: readDate(m['timestamp']) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }

  Map<String, Object?> toJson() => withoutNulls({
        'jobId': jobId,
        'itemId': itemId,
        'type': type.name,
        'from': from,
        'to': to,
        'quantityChange': quantityChange,
        'user': user,
        'timestamp': writeDate(timestamp),
      });
}
