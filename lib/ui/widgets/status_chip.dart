/// Small colored chip summarizing a [BruceLinkState].
library;

import 'package:flutter/material.dart';

import '../../transport/transport.dart';

class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.state});

  final BruceLinkState state;

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (state) {
      BruceLinkState.disconnected => (
          'Disconnected',
          Colors.grey,
          Icons.link_off,
        ),
      BruceLinkState.scanning => (
          'Scanning…',
          Colors.amber,
          Icons.radar,
        ),
      BruceLinkState.connecting => (
          'Connecting…',
          Colors.amber,
          Icons.sync,
        ),
      BruceLinkState.connected => (
          'Connected',
          Colors.greenAccent,
          Icons.bluetooth_connected,
        ),
      BruceLinkState.error => (
          'Error',
          Colors.redAccent,
          Icons.error_outline,
        ),
    };

    return Chip(
      avatar: Icon(icon, size: 18, color: color),
      label: Text(label),
      side: BorderSide(color: color.withValues(alpha: 0.5)),
      backgroundColor: color.withValues(alpha: 0.12),
    );
  }
}
