import 'json_read.dart';

// a read-only view of one item on lsicompapp's inventory page, stored at
// inventory/{id} in the 'team' database. that page owns these records; the
// ticketing code only reads them and changes 'stock' when a job takes or gives
// back parts. field names match InventoryItem in lsicompapp's
// src/packages/inventory/helper.dart.
class InventoryItem {
  const InventoryItem({
    required this.id,
    required this.name,
    this.itemNumber = '',
    required this.stock,
    this.threshold = 0,
    this.url = '',
    this.location = '',
  });

  final String id;
  final String name;
  final String itemNumber;
  final int stock;
  // the inventory page shows "Repurchase Needed" at or below this
  final int threshold;
  // photo, uploaded by the inventory page to Google Drive
  final String url;
  final String location;

  // same test the inventory page uses for its "Repurchase Needed" status
  bool get needsReorder => stock <= threshold;

  factory InventoryItem.fromJson(String id, Object? json) {
    final m = asJsonMap(json);
    return InventoryItem(
      id: id,
      name: readString(m['name']),
      itemNumber: readString(m['itemNumber']),
      stock: readInt(m['stock']),
      threshold: readInt(m['threshold']),
      url: readString(m['url']),
      location: readString(m['location']),
    );
  }
}
