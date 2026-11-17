// the remake ("failure") form, opened from the job popup's Create remake.
//
//   Name *            starts as the job's name
//   Requested by *    starts as the job's requester
//   Due date *        starts as the job's due date
//   Priority          starts as the job's priority
//   Faulty parts *    which of the job's parts failed, how many, and why
//   Comments          optional; the remake's first comment
//
// the rules (counts, reasons, messages) live in remake_logic.dart. on a phone
// it opens full screen with the buttons pinned to the bottom, like the job
// form. returns the saved remake, or null if cancelled.

// lsicompapp imports material.dart in all of its pages; staying consistent.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../data/ticketing_repository.dart';
import '../models/enums.dart';
import '../models/inventory_item.dart';
import '../models/job.dart';
import 'form_fields.dart';
import 'job_form.dart' show PartThumbnail;
import 'page_logic.dart';
import 'remake_logic.dart';

Future<Job?> showRemakeForm(
  BuildContext context, {
  required TicketingRepository repository,
  required NameOf nameOf,
  required Job job,
  Map<String, String> people = const {},
}) {
  final phone = MediaQuery.sizeOf(context).width < 600;
  final form = RemakeForm(repository: repository, nameOf: nameOf, people: people, job: job, fullScreen: phone);
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

class RemakeForm extends StatefulWidget {
  const RemakeForm({
    super.key,
    required this.repository,
    required this.nameOf,
    required this.job,
    this.people = const {},
    this.fullScreen = false,
  });

  final TicketingRepository repository;
  final NameOf nameOf;
  // the job that failed
  final Job job;
  // uid -> name of everyone who can be picked as the requester
  final Map<String, String> people;
  final bool fullScreen;

  @override
  State<RemakeForm> createState() => _RemakeFormState();
}

class _RemakeFormState extends State<RemakeForm> {
  late final TextEditingController _name;
  late String _requestedBy;
  late DateTime _due;
  JobPriority? _priority;
  late final RemakeDraft _draft;

  // for part names, photos and locations
  Map<String, InventoryItem> _inventory = {};
  bool _inventoryLoaded = false;
  String _error = '';

  final TextEditingController _comment = TextEditingController();
  // errors only show after the first Submit, so an untouched form isn't red
  bool _tried = false;
  bool _saving = false;

  TicketingRepository get repo => widget.repository;
  Job get job => widget.job;

  @override
  void initState() {
    super.initState();
    // everything starts as the failed job's details; all of it can change
    _name = TextEditingController(text: job.jobName);
    _requestedBy = job.requestedBy;
    _due = job.neededBy;
    _priority = job.priority;
    _draft = RemakeDraft(job);
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

  bool get _valid => _nameError == null && _draft.isValid;

  // checks the form, then makes the remake. the repository scraps the faulty
  // parts, closes this job as Failed, creates the remake and tries to claim it
  // for you. the form closes with the remake; what happens next (the message
  // and opening the remake) is up to whoever opened the form.
  Future<void> _submit() async {
    setState(() {
      _tried = true;
      _error = '';
    });
    if (!_valid || _saving) {
      if (!_valid) setState(() => _error = 'Fix the fields marked in red.');
      return;
    }
    setState(() => _saving = true);
    try {
      final remake = await repo.createRemake(
        job.jobId,
        defects: _draft.toDefects(),
        jobName: _name.text,
        requestedBy: _requestedBy,
        dueDate: _due,
        priority: () => _priority,
        comment: _comment.text,
      );
      if (mounted) Navigator.of(context).pop(remake);
    } on TicketingException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Something went wrong. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? get _nameError => _name.text.trim().isEmpty ? 'Give the remake a name.' : null;

  @override
  Widget build(BuildContext context) {
    final style = FormStyle.of(context);
    final fields = ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        Text(
          'The faulty parts are scrapped and ${job.jobId} closes as Failed. '
          'The remake asks for replacements and is claimed by you if they\'re in stock.',
          style: style.muted,
        ),
        LabeledField(
          label: 'Name',
          required: true,
          error: _tried ? _nameError : null,
          child: TextField(
            key: const Key('remake-name'),
            controller: _name,
            style: style.text,
            maxLength: TicketingRepository.maxNameLength,
            decoration: const InputDecoration(border: OutlineInputBorder(), counterText: '', isDense: true),
            onChanged: (_) => setState(() {}),
          ),
        ),
        LabeledField(
          label: 'Requested by',
          required: true,
          child: RequesterPicker(
            fieldKey: const Key('remake-requester'),
            people: widget.people,
            nameOf: widget.nameOf,
            me: repo.user.uid,
            value: _requestedBy,
            onChanged: (v) => setState(() => _requestedBy = v),
          ),
        ),
        LabeledField(
          label: 'Due date',
          required: true,
          child: DueDateField(
            fieldKey: const Key('remake-due'),
            value: _due,
            onChanged: (v) => setState(() => _due = v),
          ),
        ),
        LabeledField(
          label: 'Priority',
          child: PriorityPicker(
            fieldKey: const Key('remake-priority'),
            value: _priority,
            onChanged: (v) => setState(() => _priority = v),
          ),
        ),
        LabeledField(
          label: 'Faulty parts',
          required: true,
          error: _tried ? _draft.partsError : null,
          child: _faultyParts(style),
        ),
        LabeledField(
          label: 'Comments',
          child: TextField(
            key: const Key('remake-comment'),
            controller: _comment,
            style: style.text,
            minLines: 3,
            maxLines: 6,
            maxLength: 2000,
            decoration: const InputDecoration(
              hintText: 'Anything the people building the remake should know',
              border: OutlineInputBorder(),
              counterText: '',
            ),
          ),
        ),
      ],
    );

    return Material(
      color: style.theme.cardColor,
      borderRadius: widget.fullScreen ? null : BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 8, 8),
          child: Row(children: [
            Expanded(
              child: Text('Create remake of ${job.jobId}',
                  style: style.text.copyWith(fontSize: 20, fontWeight: FontWeight.w700)),
            ),
            IconButton(
              key: const Key('remake-close'),
              tooltip: 'Close',
              icon: const Icon(Icons.close),
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
            ),
          ]),
        ),
        Flexible(child: fields),
        Divider(height: 1, color: style.theme.dividerColor),
        // pinned to the bottom so the button is always reachable on a phone
        // the error sits here, not in the list, so it's visible wherever you've scrolled
        if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(_error, key: const Key('remake-error'), style: style.text.copyWith(color: FormStyle.error)),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
          child: Row(children: [
            Expanded(child: Text('* required', maxLines: 1, overflow: TextOverflow.ellipsis, style: style.muted)),
            TextButton(
              key: const Key('remake-cancel'),
              style: TextButton.styleFrom(foregroundColor: style.accent, minimumSize: const Size(88, 44)),
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            // Flexible so the longer label fits a phone
            Flexible(
              child: FilledButton(
                key: const Key('remake-submit'),
                style: FilledButton.styleFrom(
                  backgroundColor: style.accent,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(96, 44),
                ),
                onPressed: _saving ? null : _submit,
                child: _saving
                    ? const SizedBox(
                        width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Create remake', maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
          ]),
        ),
      ]),
    );
  }

  // ---------------------------------------------------------------- faulty parts

  // one row per part on the job. ticking a part shows its count and reason.
  Widget _faultyParts(FormStyle style) => Container(
        decoration: BoxDecoration(
          border: Border.all(color: _tried && _draft.partsError != null ? FormStyle.error : style.theme.dividerColor),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(children: [
          for (final line in job.lines.values) _partRow(style, line),
        ]),
      );

  Widget _partRow(FormStyle style, JobLine line) {
    final id = line.itemId;
    final item = _inventory[id];
    final picked = _draft.isPicked(id);
    final canPick = _draft.canPick(id);
    final part = _draft.picked[id];
    final max = _draft.maxFor(id);
    final isLast = line == job.lines.values.last;
    return Container(
      key: Key('remake-part-$id'),
      decoration: BoxDecoration(
        border: isLast ? null : Border(bottom: BorderSide(color: style.theme.dividerColor)),
      ),
      child: Column(children: [
        // tapping anywhere on the row ticks it, a bigger target than the box
        InkWell(
          onTap: canPick ? () => setState(() => _draft.toggle(id)) : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
            child: Row(children: [
              Checkbox(
                key: Key('remake-pick-$id'),
                value: picked,
                activeColor: style.accent,
                onChanged: canPick ? (_) => setState(() => _draft.toggle(id)) : null,
              ),
              PartThumbnail(url: item?.url ?? ''),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(item?.name ?? (_inventoryLoaded ? 'No longer in inventory' : '…'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: style.text.copyWith(fontWeight: FontWeight.w600)),
                  Text(
                    [
                      if (item != null && item.itemNumber.isNotEmpty) '#${item.itemNumber}',
                      canPick ? 'this job has $max' : 'none held, nothing to scrap',
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style.muted.copyWith(fontSize: 12),
                  ),
                ]),
              ),
              if (picked) ...[
                _stepButton(
                    Icons.remove,
                    'Fewer',
                    part!.count > 1 ? () => setState(() => _draft.setCount(id, part.count - 1)) : null,
                    Key('remake-minus-$id')),
                SizedBox(
                  width: 32,
                  child:
                      Text('${part.count}', key: Key('remake-qty-$id'), textAlign: TextAlign.center, style: style.text),
                ),
                _stepButton(
                    Icons.add,
                    'More',
                    part.count < max ? () => setState(() => _draft.setCount(id, part.count + 1)) : null,
                    Key('remake-plus-$id')),
              ],
            ]),
          ),
        ),
        if (picked)
          Padding(
            padding: const EdgeInsets.fromLTRB(52, 0, 12, 10),
            child: TextFormField(
              key: Key('remake-reason-$id'),
              initialValue: part!.reason,
              style: style.text,
              minLines: 1,
              maxLines: 3,
              maxLength: TicketingRepository.maxReasonLength,
              decoration: InputDecoration(
                hintText: 'What went wrong? (optional)',
                border: const OutlineInputBorder(),
                isDense: true,
                errorText: _draft.reasonError(id),
              ),
              onChanged: (v) => setState(() => _draft.setReason(id, v)),
            ),
          ),
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
