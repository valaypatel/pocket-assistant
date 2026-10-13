part of 'main.dart';

// Where a note was recorded, made visible: a small badge on each note, and a filter on the
// Notes page. The source comes from the recording's file name (see noteSourceOf).

const noteSourceAll = 'All';

/// Whether a note belongs under a filter choice: 'All', 'Phone' or 'Circuit'.
bool noteMatchesSource(CircuitNote note, String filter) =>
    filter == noteSourceAll || note.source == filter;

/// A small round badge for the corner of a note's icon: a phone for a recording made on the
/// phone, the Circuit mark for one made on the board. Decorative; the note's text says
/// the same in words.
class NoteSourceBadge extends StatelessWidget {
  const NoteSourceBadge({super.key, required this.source, this.size = 19});

  final String source;
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: context.sc.bg,
        shape: BoxShape.circle,
        border: Border.all(color: context.sc.line),
      ),
      child: Center(
        child: source == 'Phone'
            ? Icon(
                LucideIcons.smartphone,
                size: size * .62,
                color: context.sc.ink,
              )
            : ScDeviceMark(size: size * .74),
      ),
    ),
  );
}

/// The row of choices above the notes: All, Phone, Circuit, each with how many notes it has.
class NoteSourceFilter extends StatelessWidget {
  const NoteSourceFilter({
    super.key,
    required this.selected,
    required this.counts,
    required this.onChanged,
  });

  final String selected;

  /// Notes per choice: keys 'All', 'Phone', 'Circuit'.
  final Map<String, int> counts;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final choice in const [noteSourceAll, 'Phone', 'Circuit'])
        _SourcePill(
          label: choice,
          count: counts[choice] ?? 0,
          selected: selected == choice,
          onTap: () => onChanged(choice),
        ),
    ],
  );
}

class _SourcePill extends StatelessWidget {
  const _SourcePill({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final foreground = selected ? context.sc.bg : context.sc.ink;
    return Semantics(
      button: true,
      selected: selected,
      label: '$label, $count ${count == 1 ? 'note' : 'notes'}',
      excludeSemantics: true,
      child: Material(
        color: selected ? context.sc.ink : context.sc.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 13),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (label == 'Phone') ...[
                    Icon(LucideIcons.smartphone, size: 15, color: foreground),
                    const SizedBox(width: 6),
                  ] else if (label == 'Circuit') ...[
                    const ScDeviceMark(size: 17),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    '$label $count',
                    style: TextStyle(
                      color: foreground,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
