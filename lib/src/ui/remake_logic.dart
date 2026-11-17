// the rules behind the remake ("failure") form: which of the job's parts are
// marked faulty, how many, and why. plain Dart so it can be unit tested; the
// form widget only displays what this says.
//
// the repository checks all of this again on save. these exist so the form
// can explain a problem next to the field instead of after a round trip.

import '../data/ticketing_repository.dart';
import '../models/enums.dart';
import '../models/inventory_item.dart';
import '../models/job.dart';
import '../rules/permissions.dart';

// one part the user has marked faulty
class FaultyPart {
  FaultyPart({this.count = 1, this.reason = ''});
  int count;
  String reason;
}

class RemakeDraft {
  RemakeDraft(this.job);

  final Job job;

  // inventory item id -> what the user entered, in the order they were picked
  final Map<String, FaultyPart> picked = {};

  // a faulty count can't be more than the job holds right now. a completed
  // or in-progress job holds every part, so this is normally the quantity.
  int maxFor(String itemId) => job.lines[itemId]?.held ?? 0;

  // a part the job holds none of can't be faulty (nothing to scrap)
  bool canPick(String itemId) => maxFor(itemId) > 0;

  bool isPicked(String itemId) => picked.containsKey(itemId);

  void toggle(String itemId) {
    if (picked.remove(itemId) != null) return;
    if (canPick(itemId)) picked[itemId] = FaultyPart();
  }

  // the stepper calls this; values outside 1..max are pulled back in range
  void setCount(String itemId, int count) {
    final part = picked[itemId];
    if (part == null) return;
    part.count = count.clamp(1, maxFor(itemId));
  }

  void setReason(String itemId, String reason) => picked[itemId]?.reason = reason;

  // ---------------------------------------------------------------- validation

  String? get partsError => picked.isEmpty ? 'Pick at least one faulty part.' : null;

  String? countError(String itemId) {
    final part = picked[itemId];
    if (part == null) return null;
    final max = maxFor(itemId);
    if (part.count < 1) return 'Enter at least 1.';
    if (part.count > max) return 'This job only has $max.';
    return null;
  }

  String? reasonError(String itemId) {
    final part = picked[itemId];
    if (part == null) return null;
    const max = TicketingRepository.maxReasonLength;
    return part.reason.trim().length > max ? 'Keep the reason to $max characters or fewer.' : null;
  }

  bool get isValid =>
      partsError == null && picked.keys.every((id) => countError(id) == null && reasonError(id) == null);

  // what createRemake takes
  Map<String, Defect> toDefects() => {
        for (final e in picked.entries) e.key: Defect(count: e.value.count, reason: e.value.reason.trim()),
      };

  // ---------------------------------------------------------------- after saving

  // createRemake claims the remake for its creator when the replacements are
  // on hand. stock is the inventory as it is now (stockFor(remake)).
  static String outcomeMessage(Job remake, Map<String, InventoryItem> stock) {
    if (remake.status == JobStatus.inProgress) {
      return 'Created remake ${remake.jobId}. You claimed it and the replacement parts were taken from inventory.';
    }
    final short = Permissions.shortParts(remake, stock);
    if (short.isEmpty) {
      // the claim lost a race (someone else took the parts or the job first)
      return 'Created remake ${remake.jobId}. It\'s waiting in Requested; claim it from there.';
    }
    return 'Created remake ${remake.jobId}. Not enough in inventory to claim it: ${short.join(', ')}. '
        'It\'s waiting in Requested until the parts arrive.';
  }
}
