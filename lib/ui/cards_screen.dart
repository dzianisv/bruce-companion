/// Card-backup browser: lists `/BruceRFID` (or a subdirectory).
///
/// `dir == null` means the shared top-level listing, backed by
/// `controller.cards` / `refreshCards()`. A non-null `dir` (reached by
/// tapping a folder row) uses a local, independent fetch via
/// `controller.listDir` so drilling into subfolders never clobbers the
/// cached root snapshot — kept intentionally simple for v1.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/card_dump.dart';
import '../state/connection_controller.dart';
import 'card_detail_screen.dart';
import 'console_screen.dart';
import 'widgets/format_icon.dart';

class CardsScreen extends StatefulWidget {
  const CardsScreen({super.key, this.dir, this.title});

  final String? dir;
  final String? title;

  @override
  State<CardsScreen> createState() => _CardsScreenState();
}

class _CardsScreenState extends State<CardsScreen> {
  bool get _isRoot => widget.dir == null;

  List<CardFile>? _subFiles;
  bool _subLoading = false;
  String? _subError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final controller = context.read<ConnectionController>();
    if (_isRoot) {
      await controller.refreshCards();
      return;
    }
    setState(() {
      _subLoading = true;
      _subError = null;
    });
    try {
      final files = await controller.listDir(widget.dir!);
      if (!mounted) return;
      setState(() => _subFiles = files);
    } catch (e) {
      if (!mounted) return;
      setState(() => _subError = e.toString());
    } finally {
      if (mounted) setState(() => _subLoading = false);
    }
  }

  void _openFile(CardFile file) {
    if (file.isDir) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => CardsScreen(dir: file.path, title: file.name),
      ));
    } else {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => CardDetailScreen(file: file),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ConnectionController>();
    final files = _isRoot ? controller.cards : (_subFiles ?? const <CardFile>[]);
    final loading = _isRoot ? controller.busy : _subLoading;
    final error = _isRoot ? controller.error : _subError;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? 'Card Backups'),
        actions: [
          IconButton(
            icon: const Icon(Icons.terminal),
            tooltip: 'Console',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ConsoleScreen()),
            ),
          ),
          if (_isRoot)
            IconButton(
              icon: const Icon(Icons.link_off),
              tooltip: 'Disconnect',
              onPressed: () async {
                await controller.disconnect();
                if (context.mounted) {
                  Navigator.of(context).popUntil((r) => r.isFirst);
                }
              },
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _buildBody(controller, files, loading, error),
      ),
    );
  }

  Widget _buildBody(
    ConnectionController controller,
    List<CardFile> files,
    bool loading,
    String? error,
  ) {
    if (!controller.isConnected) {
      return const _CenterMessage(text: 'Not connected.');
    }
    if (loading && files.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (error != null && files.isEmpty) {
      return _CenterMessage(text: error, isError: true);
    }
    if (files.isEmpty) {
      return const _CenterMessage(text: 'No saved cards found in this folder.');
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: files.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final f = files[i];
        return ListTile(
          leading: f.isDir ? const Icon(Icons.folder) : FormatIcon(format: f.format),
          title: Text(f.name),
          subtitle: Text(f.isDir ? 'Folder' : f.format.label),
          trailing: f.size != null ? Text('${f.size} B') : null,
          onTap: () => _openFile(f),
        );
      },
    );
  }
}

class _CenterMessage extends StatelessWidget {
  const _CenterMessage({required this.text, this.isError = false});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: isError ? Theme.of(context).colorScheme.error : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
