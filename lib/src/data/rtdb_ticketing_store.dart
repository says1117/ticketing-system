import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

import '../models/json_read.dart';
import 'ticketing_store.dart';

// TicketingStore on the Realtime Database. in lsicompapp, build it with the
// same 'team' instance the Database wrapper uses:
//
//   RtdbTicketingStore(FirebaseDatabase.instanceFor(
//     app: Firebase.app(),
//     databaseURL: 'https://limbitless-solutions-team.firebaseio.com/',
//   ))
class RtdbTicketingStore implements TicketingStore {
  RtdbTicketingStore(this._db);

  final FirebaseDatabase _db;

  @override
  Future<Object?> read(String path) async {
    final snap = await _db.ref(path).get();
    return snap.exists ? snap.value : null;
  }

  @override
  Future<Map<String, Object?>> queryEqual(String collection, {required String field, required Object value}) async {
    // needs ".indexOn" for field in the rules, or Firebase downloads the whole
    // collection and filters on the device
    final snap = await _db.ref(collection).orderByChild(field).equalTo(value).get();
    return snap.exists ? asJsonMap(snap.value) : {};
  }

  @override
  Stream<Object?> watch(String path) => _db.ref(path).onValue.map((e) => e.snapshot.exists ? e.snapshot.value : null);

  @override
  Future<void> update(Map<String, Object?> values) async {
    try {
      await _db.ref().update(values);
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') throw TicketingWriteRejected(e);
      rethrow;
    }
  }

  @override
  String newKey(String collection) => _db.ref(collection).push().key!;

  @override
  Future<int> nextNumber(String counterPath) async {
    final result = await _db.ref(counterPath).runTransaction((current) {
      return Transaction.success(readInt(current) + 1);
    });
    if (!result.committed) {
      throw TicketingWriteRejected('counter transaction at $counterPath did not commit');
    }
    return readInt(result.snapshot.value);
  }
}
