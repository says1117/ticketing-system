// fields shared by the job form and the remake form, so both look and behave
// the same: a labelled field with an error line, the requester picker, the
// due date, and priority. each takes its value and an onChanged; the form
// that uses it owns the state.

// lsicompapp imports material.dart in all of its pages; staying consistent.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/enums.dart';
import 'page_logic.dart';

// text styles from the app's theme (no hard-coded theme, like lsicompapp)
class FormStyle {
  FormStyle.of(BuildContext context) : theme = Theme.of(context);
  final ThemeData theme;

  static const Color error = Colors.redAccent;

  Color get accent => theme.secondaryHeaderColor;
  TextStyle get text =>
      (theme.primaryTextTheme.bodyMedium ?? theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(fontSize: 14);
  TextStyle get muted => text.copyWith(color: theme.hintColor, fontSize: 13);
}

// "Name *" with a red star, the field, and a red message under it
class LabeledField extends StatelessWidget {
  const LabeledField({super.key, required this.label, required this.child, this.required = false, this.error});

  final String label;
  final Widget child;
  final bool required;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final style = FormStyle.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text.rich(TextSpan(
          text: label,
          style: style.text.copyWith(fontWeight: FontWeight.w600),
          children: [if (required) const TextSpan(text: ' *', style: TextStyle(color: FormStyle.error))],
        )),
        const SizedBox(height: 6),
        child,
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(error!, style: style.text.copyWith(color: FormStyle.error, fontSize: 12)),
          ),
      ]),
    );
  }
}

// a searchable list of scholars. the signed-in person is marked "(you)".
// people is uid -> name; me and value are always offered even if missing.
class RequesterPicker extends StatelessWidget {
  const RequesterPicker({
    super.key,
    required this.people,
    required this.nameOf,
    required this.me,
    required this.value,
    required this.onChanged,
    this.fieldKey = const Key('form-requester'),
  });

  final Map<String, String> people;
  final NameOf nameOf;
  final String me;
  final String value;
  final ValueChanged<String> onChanged;
  final Key fieldKey;

  @override
  Widget build(BuildContext context) {
    final style = FormStyle.of(context);
    final options = {
      ...people,
      me: people[me] ?? nameOf(me),
      value: people[value] ?? nameOf(value),
    };
    final sorted = options.entries.toList()..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));
    return LayoutBuilder(
      builder: (context, box) => DropdownMenu<String>(
        key: fieldKey,
        width: box.maxWidth,
        initialSelection: value,
        enableFilter: true,
        requestFocusOnTap: true,
        textStyle: style.text,
        menuHeight: 320,
        inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder(), isDense: true),
        dropdownMenuEntries: [
          for (final e in sorted) DropdownMenuEntry(value: e.key, label: e.key == me ? '${e.value} (you)' : e.value),
        ],
        onSelected: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }
}

// MM/DD/YYYY with a calendar. the value is a calendar day stored as UTC
// midnight, the same way the job model reads it.
class DueDateField extends StatelessWidget {
  const DueDateField({
    super.key,
    required this.value,
    required this.onChanged,
    this.fieldKey = const Key('form-due'),
  });

  final DateTime? value;
  final ValueChanged<DateTime> onChanged;
  final Key fieldKey;

  Future<void> _pick(BuildContext context) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final current = value == null ? null : DateTime(value!.year, value!.month, value!.day);
    // an existing due date in the past stays pickable
    final first = current != null && current.isBefore(today) ? current : today;
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? today,
      firstDate: first,
      lastDate: DateTime(today.year + 3),
      helpText: 'Due date',
    );
    if (picked != null) onChanged(DateTime.utc(picked.year, picked.month, picked.day));
  }

  @override
  Widget build(BuildContext context) {
    final style = FormStyle.of(context);
    return InkWell(
      key: fieldKey,
      onTap: () => _pick(context),
      borderRadius: BorderRadius.circular(4),
      child: InputDecorator(
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          isDense: true,
          suffixIcon: Icon(Icons.calendar_month_outlined),
        ),
        child: Text(
          value == null ? 'MM/DD/YYYY' : DateFormat('MM/dd/yyyy').format(value!),
          style: value == null ? style.muted : style.text,
        ),
      ),
    );
  }
}

// a "None" choice plus Low / Medium / High. values are strings because a
// null menu value doesn't open reliably on web
class PriorityPicker extends StatelessWidget {
  const PriorityPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.fieldKey = const Key('form-priority'),
  });

  final JobPriority? value;
  final ValueChanged<JobPriority?> onChanged;
  final Key fieldKey;

  @override
  Widget build(BuildContext context) {
    final style = FormStyle.of(context);
    return LayoutBuilder(
      builder: (context, box) => DropdownMenu<String>(
        key: fieldKey,
        width: box.maxWidth,
        initialSelection: value?.name ?? 'none',
        textStyle: style.text,
        inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder(), isDense: true),
        dropdownMenuEntries: [
          const DropdownMenuEntry(value: 'none', label: 'None'),
          for (final p in JobPriority.values) DropdownMenuEntry(value: p.name, label: PageLogic.priorityLabel(p)),
        ],
        onSelected: (v) => onChanged(enumFromName(JobPriority.values, v)),
      ),
    );
  }
}
