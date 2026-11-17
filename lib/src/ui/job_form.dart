// the Add Job form (the + button), also used to edit a job (the Edit button).
//
//   Name *            text
//   Requested by *    a scholar; starts as the signed-in person
//   Due date *        MM/DD/YYYY with a calendar
//   Priority          Low / Medium / High, optional
//   Parts required *  a box with + that opens the inventory picker; each part
//                     gets a quantity, and shows how many are on hand
//   Comments          optional; saved as the job's first comment (new jobs only)
//
// on a phone it opens full screen with Submit pinned to the bottom; on wider
// screens it's a dialog. returns the saved job, or null if cancelled.

// lsicompapp imports material.dart in all of its pages; staying consistent.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../data/ticketing_repository.dart';
import '../models/enums.dart';
import '../models/inventory_item.dart';
import '../models/job.dart';
import '../rules/permissions.dart';
import 'form_fields.dart';
import 'page_logic.dart';

Future<Job?> showJobForm(
  BuildContext context, {
  required TicketingRepository repository,
  required NameOf nameOf,
  Map<String, String> people = const {},
  Job? job,
}) {
  final phone = MediaQuery.sizeOf(context).width < 600;
  final form = JobForm(repository: repository, nameOf: nameOf, people: people, job: job, fullScreen: phone);
  return showDialog<Job>(
    context: context,
    barrierDismissible: false,
    builder: (_) => phone
        ? Dialog.fullscreen(child: form)
        : Dialog(
            insetPadding: const EdgeInsets.all(24),
            child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 620, maxHeight: 820), child: form),
          ),
  );
}

class JobForm extends StatefulWidget {
  const JobForm({
    super.key,
    required this.repository,
    required this.nameOf,
    this.people = const {},
    this.job,
    this.fullScreen = false,
  });

  final TicketingRepository repository;
  final NameOf nameOf;
  // uid -> name of everyone who can be picked as the requester. the signed-in
  // person (and the job's current requester) are always included.
  final Map<String, String> people;
  // set when editing
  final Job? job;
  final bool fullScreen;

  @override
  State<JobForm> createState() => _JobFormState();
}

class _JobFormState extends State<JobForm> {
  late final TextEditingController _name;
  final TextEditingController _comment = TextEditingController();
  late String _requestedBy;
  DateTime? _due;
  JobPriority? _priority;
  // inventory item id -> quantity, in the order they were added
  final Map<String, int> _parts = {};

  Map<String, InventoryItem> _inventory = {};
  bool _inventoryLoaded = false;
  bool _tried = false;
  bool _saving = false;
  String _error = '';

  TicketingRepository get repo => widget.repository;
  Job? get job => widget.job;
  bool get editing => job != null;
  // parts can only change before anyone claims the job
  bool get partsLocked => editing && Permissions.canEdit(repo.user, job!, changesParts: true) != null;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: job?.jobName ?? '');
    _requestedBy = job?.requestedBy ?? repo.user.uid;
    _due = job?.neededBy;
    _priority = job?.priority;
    if (job != null) {
      for (final l in job!.lines.values) {
        _parts[l.itemId] = l.quantity;
      }
    }
    repo.listInventory().then((items) {
      if (!mounted) return;
      setState(() {
        _inventory = {for (final i in items) i.id: i};
        _inventoryLoaded = true;
      });
    }, onError: (_) {
      if (mounted) setState(() => _error = 'Couldn\'t load the inventory. Check your connection.');
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _comment.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- styles

  // shared with the remake form (form_fields.dart)
  FormStyle get _style => FormStyle.of(context);
  ThemeData get _theme => _style.theme;
  Color get _accent => _style.accent;
  TextStyle get _text => _style.text;
  TextStyle get _muted => _style.muted;
  static const Color _errorColor = FormStyle.error;

  // ---------------------------------------------------------------- validation

  String? get _nameError => _name.text.trim().isEmpty ? 'Give the job a name.' : null;
  String? get _dueError => _due == null ? 'Pick a due date.' : null;
  String? get _partsError => _parts.isEmpty ? 'Add at least one part.' : null;
  bool get _valid => _nameError == null && _dueError == null && _partsError == null;

  Future<void> _submit() async {
    setState(() {
      _tried = true;
      _error = '';
    });
    if (!_valid || _saving) return;
    setState(() => _saving = true);
    try {
      final Job saved;
      if (editing) {
        saved = await repo.editJob(
          job!.jobId,
          jobName: _name.text,
          requestedBy: _requestedBy,
          dueDate: _due,
          priority: () => _priority,
          parts: partsLocked ? null : Map.of(_parts),
        );
      } else {
        saved = await repo.createJob(
          jobName: _name.text,
          requestedBy: _requestedBy,
          dueDate: _due!,
          priority: _priority,
          parts: Map.of(_parts),
          comment: _comment.text,
        );
      }
      if (mounted) Navigator.of(context).pop(saved);
    } on TicketingException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Something went wrong. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addParts() async {
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => _PartPicker(inventory: _inventory.values.toList(), alreadyAdded: _parts.keys.toSet()),
    );
    if (picked != null) setState(() => _parts[picked] = (_parts[picked] ?? 0) + 1);
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final title = editing ? 'Edit ${job!.jobId}' : 'Request a job';
    final fields = ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        _field('Name', required: true, error: _tried ? _nameError : null, child: TextField(
          key: const Key('form-name'),
          controller: _name,
          style: _text,
          maxLength: TicketingRepository.maxNameLength,
          decoration: const InputDecoration(
            hintText: 'e.g. Left arm – patient 104',
            border: OutlineInputBorder(),
            counterText: '',
            isDense: true,
          ),
          onChanged: (_) => setState(() {}),
        )),
        _field('Requested by', required: true, child: RequesterPicker(
          people: widget.people,
          nameOf: widget.nameOf,
          me: repo.user.uid,
          value: _requestedBy,
          onChanged: (v) => setState(() => _requestedBy = v),
        )),
        _field('Due date', required: true, error: _tried ? _dueError : null, child: DueDateField(
          value: _due,
          onChanged: (v) => setState(() => _due = v),
        )),
        _field('Priority', child: PriorityPicker(
          value: _priority,
          onChanged: (v) => setState(() => _priority = v),
        )),
        _field('Parts required', required: true, error: _tried ? _partsError : null, child: _partsBox()),
        if (!editing)
          _field('Comments', child: TextField(
            key: const Key('form-comment'),
            controller: _comment,
            style: _text,
            minLines: 3,
            maxLines: 6,
            maxLength: 2000,
            decoration: const InputDecoration(
              hintText: 'Anything the people building it should know',
              border: OutlineInputBorder(),
              counterText: '',
            ),
          )),
        if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error, key: const Key('form-error'), style: _text.copyWith(color: _errorColor)),
          ),
      ],
    );

    return Material(
      color: _theme.cardColor,
      borderRadius: widget.fullScreen ? null : BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 8, 8),
          child: Row(children: [
            Expanded(child: Text(title, style: _text.copyWith(fontSize: 20, fontWeight: FontWeight.w700))),
            IconButton(
              tooltip: 'Close',
              icon: const Icon(Icons.close),
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
            ),
          ]),
        ),
        Flexible(child: fields),
        Divider(height: 1, color: _theme.dividerColor),
        // pinned to the bottom so Submit is always reachable on a phone
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
          child: Row(children: [
            Expanded(child: Text('* required', maxLines: 1, overflow: TextOverflow.ellipsis, style: _muted)),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: _accent, minimumSize: const Size(88, 44)),
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              key: const Key('form-submit'),
              style: FilledButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.white,
                minimumSize: const Size(96, 44),
              ),
              onPressed: _saving ? null : _submit,
              child: _saving
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Text(editing ? 'Save' : 'Submit'),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _field(String label, {required Widget child, bool required = false, String? error}) =>
      LabeledField(label: label, required: required, error: error, child: child);

  // ---------------------------------------------------------------- parts

  Widget _partsBox() {
    final lines = [
      for (final e in _parts.entries) _partLine(e.key, e.value),
    ];
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: _tried && _partsError != null ? _errorColor : _theme.dividerColor),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(children: [
        ...lines,
        if (partsLocked)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text('The parts can\'t change once the job is claimed. Unclaim it first.', style: _muted),
          )
        else
          // the box with a + in the middle from the mockup
          InkWell(
            key: const Key('form-add-part'),
            onTap: _inventoryLoaded ? _addParts : null,
            child: SizedBox(
              height: 52,
              child: Center(
                child: _inventoryLoaded
                    ? Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.add_circle_outline, color: _accent),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(_parts.isEmpty ? 'Add a part from inventory' : 'Add another part',
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: _text.copyWith(color: _accent)),
                        ),
                      ])
                    : const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _partLine(String itemId, int quantity) {
    final item = _inventory[itemId];
    final stock = item?.stock;
    final short = stock != null && stock < quantity;
    return Container(
      key: Key('form-part-$itemId'),
      padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: _theme.dividerColor))),
      child: Row(children: [
        PartThumbnail(url: item?.url ?? ''),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item?.name ?? (_inventoryLoaded ? 'No longer in inventory' : '…'),
                maxLines: 1, overflow: TextOverflow.ellipsis, style: _text.copyWith(fontWeight: FontWeight.w600)),
            Text(
              [
                if (item != null && item.itemNumber.isNotEmpty) '#${item.itemNumber}',
                if (item != null && item.location.isNotEmpty) item.location,
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _muted.copyWith(fontSize: 12),
            ),
            if (stock != null)
              Text(
                short ? 'Only $stock on hand. It can\'t be claimed until more arrive.' : '$stock on hand',
                style: _muted.copyWith(fontSize: 12, color: short ? Colors.orangeAccent : null),
              ),
          ]),
        ),
        if (partsLocked)
          Padding(padding: const EdgeInsets.only(right: 12), child: Text('× $quantity', style: _text))
        else ...[
          _stepButton(Icons.remove, 'Fewer', quantity > 1 ? () => setState(() => _parts[itemId] = quantity - 1) : null,
              Key('form-minus-$itemId')),
          SizedBox(
            width: 36,
            child: Text('$quantity', key: Key('form-qty-$itemId'), textAlign: TextAlign.center, style: _text),
          ),
          _stepButton(Icons.add, 'More', () => setState(() => _parts[itemId] = quantity + 1), Key('form-plus-$itemId')),
          _stepButton(Icons.close, 'Remove part', () => setState(() => _parts.remove(itemId)), Key('form-remove-$itemId')),
        ],
      ]),
    );
  }

  Widget _stepButton(IconData icon, String tooltip, VoidCallback? onTap, Key key) => IconButton(
        key: key,
        tooltip: tooltip,
        constraints: const BoxConstraints(minWidth: 40, minHeight: 44),
        icon: Icon(icon, size: 20),
        onPressed: onTap,
      );
}

// the inventory item's photo, or a placeholder when there's none or it won't load
class PartThumbnail extends StatelessWidget {
  const PartThumbnail({super.key, required this.url, this.size = 40});
  final String url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Theme.of(context).canvasColor,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(Icons.precision_manufacturing_outlined, size: size * 0.55, color: Theme.of(context).hintColor),
    );
    if (url.isEmpty) return placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(url, width: size, height: size, fit: BoxFit.cover, errorBuilder: (_, __, ___) => placeholder),
    );
  }
}

// searchable list of inventory items; returns the picked item's id
class _PartPicker extends StatefulWidget {
  const _PartPicker({required this.inventory, required this.alreadyAdded});
  final List<InventoryItem> inventory;
  final Set<String> alreadyAdded;

  @override
  State<_PartPicker> createState() => _PartPickerState();
}

class _PartPickerState extends State<_PartPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = (theme.primaryTextTheme.bodyMedium ?? theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(fontSize: 14);
    final muted = text.copyWith(color: theme.hintColor, fontSize: 12);
    final q = _query.trim().toLowerCase();
    final items = widget.inventory
        .where((i) => q.isEmpty || '${i.name} ${i.itemNumber} ${i.location}'.toLowerCase().contains(q))
        .toList();
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 600),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
            child: Row(children: [
              Expanded(child: Text('Add a part', style: text.copyWith(fontSize: 18, fontWeight: FontWeight.w700))),
              IconButton(tooltip: 'Close', icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            child: TextField(
              key: const Key('picker-search'),
              autofocus: true,
              style: text,
              decoration: const InputDecoration(
                hintText: 'Search by name, part # or location',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Flexible(
            child: items.isEmpty
                ? Padding(padding: const EdgeInsets.all(24), child: Text('No parts match "$_query".', style: muted))
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: items.length,
                    itemBuilder: (_, i) {
                      final item = items[i];
                      final added = widget.alreadyAdded.contains(item.id);
                      return ListTile(
                        key: Key('picker-${item.id}'),
                        minTileHeight: 56,
                        leading: PartThumbnail(url: item.url),
                        title: Text(item.name, style: text.copyWith(fontWeight: FontWeight.w600)),
                        subtitle: Text(
                          [
                            if (item.itemNumber.isNotEmpty) '#${item.itemNumber}',
                            if (item.location.isNotEmpty) item.location,
                            '${item.stock} on hand',
                          ].join(' · '),
                          style: muted.copyWith(color: item.stock == 0 ? Colors.orangeAccent : null),
                        ),
                        trailing: added ? Text('Added (+1)', style: muted) : null,
                        onTap: () => Navigator.pop(context, item.id),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }
}
