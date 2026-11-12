// small readers for values coming back from the Realtime Database. RTDB hands
// back Map<Object?, Object?>, may return a whole number as a double, and has no
// date type, so every model reads through these instead of casting directly.

Map<String, Object?> asJsonMap(Object? value) {
  if (value is Map) {
    return value.map((k, v) => MapEntry(k.toString(), v));
  }
  return const {};
}

String readString(Object? value, [String fallback = '']) =>
    value is String ? value : (value == null ? fallback : value.toString());

String? readOptionalString(Object? value) {
  if (value == null) return null;
  final s = value.toString();
  return s.isEmpty ? null : s;
}

int readInt(Object? value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? fallback;
  return fallback;
}

int? readOptionalInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

bool readBool(Object? value, [bool fallback = false]) =>
    value is bool ? value : fallback;

// dates are stored as UTC ISO 8601 strings, the same as the rest of lsicompapp
DateTime? readDate(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

String? writeDate(DateTime? value) => value?.toUtc().toIso8601String();

// neededBy is a calendar day with no time, stored as YYYY-MM-DD
DateTime? readDay(Object? value) {
  if (value is! String) return null;
  final d = DateTime.tryParse(value);
  return d == null ? null : DateTime.utc(d.year, d.month, d.day);
}

String? writeDay(DateTime? value) {
  if (value == null) return null;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${value.year.toString().padLeft(4, '0')}-${two(value.month)}-${two(value.day)}';
}

// RTDB deletes a key when it is written as null, so optional fields are left out
// of the map rather than stored as null
Map<String, Object?> withoutNulls(Map<String, Object?> map) =>
    Map.fromEntries(map.entries.where((e) => e.value != null));
