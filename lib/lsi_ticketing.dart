// ticketing data layer: jobs that reserve parts from lsicompapp's inventory,
// with history, comments and the permission rules.
library;

export 'src/data/memory_ticketing_store.dart';
export 'src/data/rtdb_ticketing_store.dart';
export 'src/data/ticketing_repository.dart';
export 'src/data/ticketing_store.dart';
export 'src/models/comment.dart';
export 'src/models/enums.dart';
export 'src/models/history_entry.dart';
export 'src/models/inventory_item.dart';
export 'src/models/job.dart';
export 'src/rules/permissions.dart';
export 'src/ui/page_logic.dart';
export 'src/ui/ticketing_page.dart';
export 'src/ui/job_form.dart';
export 'src/ui/job_popup.dart';
