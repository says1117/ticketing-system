import 'dart:async';

import '../models/json_read.dart';
import 'ticketing_store.dart';

// TicketingStore kept in memory, for tests and lsicompapp's DEV_MODE. it copies
// the two security rules the repository depends on for safe concurrent saves,
// and rejects the whole update if either fails:
//   - a job write must carry rev = stored rev + 1 (or rev 1 when new)
//   - for every line of a job, the change in the item's inventory stock must
//     equal -(change in held + change in scrapped), and stock can't go below
//     zero when the job takes parts
class MemoryTicketingStore implements TicketingStore {
  MemoryTicketingStore([Map<String, Object?>? initial]) {
    if (initial != null) _data.addAll(_deepCopy(initial) as Map<String, Object?>);
  }

  final Map<String, Object?> _data = {};
  final _changes = StreamController<void>.broadcast();
  int _keyCounter = 0;

  // runs before each update is applied, so a test can slip in a competing save
  Future<void> Function()? beforeUpdate;

  // number of updates applied, for tests
  int updateCount = 0;

  Map<String, Object?> get data => _deepCopy(_data) as Map<String, Object?>;

  static Object? _deepCopy(Object? v) {
    if (v is Map) return v.map((k, val) => MapEntry(k.toString(), _deepCopy(val)));
    if (v is List) return v.map(_deepCopy).toList();
    return v;
  }

  List<String> _parts(String path) => path.split('/').where((p) => p.isNotEmpty).toList();

  Object? _get(String path) {
    Object? cur = _data;
    for (final p in _parts(path)) {
      if (cur is Map && cur.containsKey(p)) {
        cur = cur[p];
      } else {
        return null;
      }
    }
    return cur;
  }

  void _set(String path, Object? value) {
    final parts = _parts(path);
    Map<String, Object?> cur = _data;
    for (final p in parts.take(parts.length - 1)) {
      final next = cur[p];
      if (next is Map<String, Object?>) {
        cur = next;
      } else {
        final created = <String, Object?>{};
        cur[p] = created;
        cur = created;
      }
    }
    if (value == null) {
      cur.remove(parts.last);
    } else {
      cur[parts.last] = _deepCopy(value);
    }
  }

  @override
  Future<Object?> read(String path) async => _deepCopy(_get(path));

  @override
  Future<Map<String, Object?>> queryEqual(String collection, {required String field, required Object value}) async {
    final all = asJsonMap(_get(collection));
    return Map.fromEntries(all.entries
        .where((e) => asJsonMap(e.value)[field] == value)
        .map((e) => MapEntry(e.key, _deepCopy(e.value))));
  }

  @override
  Stream<Object?> watch(String path) {
    late StreamController<Object?> out;
    StreamSubscription<void>? changes;
    out = StreamController<Object?>(
      onListen: () {
        out.add(_deepCopy(_get(path)));
        changes = _changes.stream.listen((_) => out.add(_deepCopy(_get(path))));
      },
      onCancel: () => changes?.cancel(),
    );
    return out.stream;
  }

  @override
  Future<void> update(Map<String, Object?> values) async {
    if (beforeUpdate != null) {
      final hook = beforeUpdate!;
      beforeUpdate = null;
      await hook();
    }
    final after = MemoryTicketingStore(_data);
    for (final e in values.entries) {
      after._set(e.key, e.value);
    }
    for (final e in values.entries) {
      final parts = _parts(e.key);
      final isJob = parts.length == 3 && parts[0] == 'ticketing' && parts[1] == 'jobs';
      if (!isJob || e.value == null) continue;
      final stored = _get(e.key);
      final newRev = readInt(asJsonMap(e.value)['rev']);
      final expected = stored == null ? 1 : readInt(asJsonMap(stored)['rev']) + 1;
      if (newRev != expected) {
        throw TicketingWriteRejected('rev conflict on ${e.key}: wrote $newRev, expected $expected');
      }
      final oldLines = asJsonMap(asJsonMap(stored)['lines']);
      for (final line in asJsonMap(asJsonMap(e.value)['lines']).entries) {
        final before = asJsonMap(oldLines[line.key]);
        final now = asJsonMap(line.value);
        final taken = (readInt(now['held']) - readInt(before['held'])) + (readInt(now['scrapped']) - readInt(before['scrapped']));
        final stockPath = 'inventory/${line.key}/stock';
        if (_get('inventory/${line.key}') == null) continue;
        final stockBefore = readInt(_get(stockPath));
        final stockAfter = readInt(after._get(stockPath));
        if (stockAfter - stockBefore != -taken) {
          throw TicketingWriteRejected('stock for ${line.key} changed by ${stockAfter - stockBefore}, job took $taken');
        }
        if (taken > 0 && stockAfter < 0) {
          throw TicketingWriteRejected('stock for ${line.key} would go below zero');
        }
      }
    }
    for (final e in values.entries) {
      _set(e.key, e.value);
    }
    updateCount++;
    _changes.add(null);
  }

  @override
  String newKey(String collection) {
    // zero padded so keys sort in creation order, like RTDB push keys
    _keyCounter++;
    return '-k${_keyCounter.toString().padLeft(8, '0')}';
  }

  @override
  Future<int> nextNumber(String counterPath) async {
    final n = readInt(_get(counterPath)) + 1;
    _set(counterPath, n);
    return n;
  }

  Future<void> dispose() => _changes.close();
}
