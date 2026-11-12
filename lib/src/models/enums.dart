// fixed sets used by the ticketing data. each value is stored in the database as
// its name (e.g. JobStatus.inProgress -> 'inProgress'); the security rules in
// rules/ticketing.rules.json check the same strings, so renaming a value here
// means updating the rules too.

// a job moves requested -> inProgress (first claim) -> completed. if every
// claimer leaves it goes back to requested; the requester or an admin can
// cancel it while it's open. creating a remake from an in-progress or
// completed job closes it as remade. completed, cancelled and remade jobs
// belong on the Log tab.
enum JobStatus { requested, inProgress, completed, cancelled, remade }

// optional on a job; set on the Add Job form
enum JobPriority { low, medium, high }

// admin: OrgStatus.admin in lsicompapp. member: every other active user.
enum Role { member, admin }

enum HistoryType {
  created,
  // the requester (or an admin) changed the job name, requester, parts, due date or priority
  edited,
  claimed,
  unclaimed,
  // parts taken out of inventory for the job (quantityChange = -taken)
  reserved,
  // parts given back to inventory on unclaim or cancel (quantityChange = +returned)
  returned,
  // defective parts reported in a remake; they are not returned to inventory
  // (quantityChange = number scrapped)
  scrapped,
  completed,
  cancelled,
  // the job was closed as remade; 'to' is the new remake ticket's id
  remade,
}

// reads a stored enum name, or returns null when it is missing or unknown so
// old or hand-edited rows don't crash the page
T? enumFromName<T extends Enum>(List<T> values, Object? name) {
  if (name is! String) return null;
  for (final v in values) {
    if (v.name == name) return v;
  }
  return null;
}
