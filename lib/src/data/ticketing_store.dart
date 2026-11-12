// the few database operations the repository needs. paths are from the root of
// the 'team' Realtime Database (e.g. 'ticketing/jobs/JOB-0042',
// 'inventory/-Nabc/stock'), so one update can change a job and the inventory
// stock it takes at the same time.
//
// RtdbTicketingStore talks to Firebase; MemoryTicketingStore keeps everything in
// a map for tests and for lsicompapp's DEV_MODE.
abstract class TicketingStore {
  // the value at path, or null when nothing is there
  Future<Object?> read(String path);

  // children of collection whose child field equals value, keyed by id
  Future<Map<String, Object?>> queryEqual(String collection, {required String field, required Object value});

  // the value at path now and every time it changes
  Stream<Object?> watch(String path);

  // writes every path in one atomic call: either all of them are saved or none
  // are. a null value deletes that path. throws TicketingWriteRejected when the
  // security rules refuse it, which includes a stale rev (someone else saved
  // the same job first) or inventory stock that changed since it was read.
  Future<void> update(Map<String, Object?> values);

  // a new unique, time-ordered key for a child of collection
  String newKey(String collection);

  // atomically adds one to the number at counterPath and returns the new number
  Future<int> nextNumber(String counterPath);
}

// the database refused a write: either a permission problem or, more often, a
// conflict because the data changed since it was read
class TicketingWriteRejected implements Exception {
  TicketingWriteRejected([this.cause]);
  final Object? cause;
  @override
  String toString() => 'TicketingWriteRejected($cause)';
}
