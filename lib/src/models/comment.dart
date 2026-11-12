import 'json_read.dart';

// a comment on a job, stored at ticketing/comments/{pushId}. the author can
// edit or delete it; an admin can delete it.
class Comment {
  const Comment({
    required this.id,
    required this.jobId,
    required this.author,
    required this.text,
    required this.timestamp,
    this.editedAt,
  });

  static const int maxLength = 2000;

  final String id;
  final String jobId;
  final String author;
  final String text;
  final DateTime timestamp;
  // set when the author changes the text
  final DateTime? editedAt;

  factory Comment.fromJson(String id, Object? json) {
    final m = asJsonMap(json);
    return Comment(
      id: id,
      jobId: readString(m['jobId']),
      author: readString(m['author']),
      text: readString(m['text']),
      timestamp: readDate(m['timestamp']) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      editedAt: readDate(m['editedAt']),
    );
  }

  Map<String, Object?> toJson() => withoutNulls({
        'jobId': jobId,
        'author': author,
        'text': text,
        'timestamp': writeDate(timestamp),
        'editedAt': writeDate(editedAt),
      });

  Comment edited(String newText, DateTime when) =>
      Comment(id: id, jobId: jobId, author: author, text: newText, timestamp: timestamp, editedAt: when);
}
