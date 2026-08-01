/// Detail view for one saved card dump: parsed fields + raw capture, with an
/// optional replay/emulate action for formats Bruce can transmit.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/card_dump.dart';
import '../state/connection_controller.dart';

class CardDetailScreen extends StatefulWidget {
  const CardDetailScreen({super.key, required this.file});

  final CardFile file;

  @override
  State<CardDetailScreen> createState() => _CardDetailScreenState();
}

class _CardDetailScreenState extends State<CardDetailScreen> {
  late final Future<CardDump?> _future;
  bool _replaying = false;

  @override
  void initState() {
    super.initState();
    _future = context.read<ConnectionController>().readDump(widget.file);
  }

  Future<void> _confirmReplay(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Replay / emulate this card?'),
        content: Text(
          'This loads "${widget.file.name}" onto the Cardputer and '
          'transmits it over RF exactly like the original card. Any nearby '
          'reader will see this data as if the physical card were present. '
          'Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Transmit'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    setState(() => _replaying = true);
    final controller = context.read<ConnectionController>();
    final reply = await controller.replay(widget.file);
    if (!mounted) return;
    setState(() => _replaying = false);

    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Device reply'),
        content: SingleChildScrollView(
          child: Text(
            reply ?? controller.error ?? 'No reply received.',
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.file.name)),
      body: FutureBuilder<CardDump?>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final dump = snapshot.data;
          if (dump == null) {
            final controller = context.watch<ConnectionController>();
            return _ErrorMessage(
              text: controller.error ?? 'Could not read this dump.',
            );
          }
          return _DumpView(
            dump: dump,
            replaying: _replaying,
            onReplay:
                dump.format.isReplayable ? () => _confirmReplay(context) : null,
          );
        },
      ),
    );
  }
}

class _DumpView extends StatelessWidget {
  const _DumpView({required this.dump, required this.replaying, this.onReplay});

  final CardDump dump;
  final bool replaying;
  final VoidCallback? onReplay;

  List<CardField> get _highlights => [
        if (dump.uid != null) CardField('UID', dump.uid!),
        if (dump.tagType != null) CardField('Tag type', dump.tagType!),
        if (dump.atqa != null) CardField('ATQA', dump.atqa!),
        if (dump.sak != null) CardField('SAK', dump.sak!),
      ];

  String _rawPreview() {
    final bytes = dump.rawBytes;
    if (bytes != null && bytes.isNotEmpty) {
      final buf = StringBuffer();
      for (var i = 0; i < bytes.length; i++) {
        buf.write(bytes[i].toRadixString(16).padLeft(2, '0').toUpperCase());
        buf.write((i + 1) % 16 == 0 ? '\n' : ' ');
      }
      return buf.toString();
    }
    if (dump.rawText != null && dump.rawText!.isNotEmpty) {
      return dump.rawText!;
    }
    return 'No raw data available.';
  }

  @override
  Widget build(BuildContext context) {
    final highlights = _highlights;

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (highlights.isNotEmpty)
                Card(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final f in highlights)
                          _FieldRow(field: f, emphasize: true),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              Text('Fields', style: Theme.of(context).textTheme.titleMedium),
              const Divider(),
              if (dump.fields.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('No additional fields parsed.'),
                )
              else
                for (final f in dump.fields) _FieldRow(field: f),
              const SizedBox(height: 16),
              if (dump.format.isBinary)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Note: this transport only exposes text reads, so exact '
                    'raw bytes for this binary dump are not available — '
                    'showing the best-effort decoded capture below instead.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontStyle: FontStyle.italic,
                        ),
                  ),
                ),
              ExpansionTile(
                title: const Text('Raw'),
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: SelectableText(
                      _rawPreview(),
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (onReplay != null)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton.icon(
                onPressed: replaying ? null : onReplay,
                icon: replaying
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sensors),
                label: Text(replaying ? 'Transmitting…' : 'Replay / Emulate'),
              ),
            ),
          ),
      ],
    );
  }
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.field, this.emphasize = false});

  final CardField field;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final baseStyle = emphasize
        ? Theme.of(context)
            .textTheme
            .titleSmall
            ?.copyWith(fontWeight: FontWeight.bold)
        : Theme.of(context).textTheme.bodyMedium;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              field.label,
              style: baseStyle?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: SelectableText(field.value, style: baseStyle)),
        ],
      ),
    );
  }
}

class _ErrorMessage extends StatelessWidget {
  const _ErrorMessage({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ),
    );
  }
}
