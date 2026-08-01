/// Landing screen: pick a transport, scan, connect.
///
/// Flow: pick BLE/USB -> Scan -> tap a discovered device -> connect() ->
/// push [CardsScreen] (which itself offers a Console action in its AppBar).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/connection_controller.dart';
import '../transport/transport.dart';
import 'cards_screen.dart';
import 'widgets/status_chip.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  TransportKind _selectedKind = TransportKind.ble;

  Future<void> _scan(ConnectionController controller) async {
    await controller.startScan(_selectedKind);
  }

  Future<void> _connect(
    BuildContext context,
    ConnectionController controller,
    BruceDevice device,
  ) async {
    await controller.connect(device);
    if (!context.mounted) return;
    if (controller.isConnected) {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const CardsScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ConnectionController>();

    return Scaffold(
      appBar: AppBar(title: const Text('Bruce Companion')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<TransportKind>(
                segments: const [
                  ButtonSegment(
                    value: TransportKind.ble,
                    label: Text('BLE'),
                    icon: Icon(Icons.bluetooth),
                  ),
                  ButtonSegment(
                    value: TransportKind.usb,
                    label: Text('USB-C'),
                    icon: Icon(Icons.usb),
                  ),
                ],
                selected: {_selectedKind},
                onSelectionChanged: controller.busy
                    ? null
                    : (s) => setState(() => _selectedKind = s.first),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  StatusChip(state: controller.linkState),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: controller.busy ? null : () => _scan(controller),
                    icon: controller.busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.search),
                    label: const Text('Scan'),
                  ),
                ],
              ),
              if (controller.error != null) ...[
                const SizedBox(height: 8),
                Text(
                  controller.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 12),
              Expanded(
                child: controller.discovered.isEmpty
                    ? Center(
                        child: Text(
                          controller.busy
                              ? 'Scanning…'
                              : 'No devices found yet. Tap Scan.',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      )
                    : ListView.separated(
                        itemCount: controller.discovered.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final device = controller.discovered[i];
                          return ListTile(
                            leading: Icon(
                              device.kind == TransportKind.ble
                                  ? Icons.bluetooth
                                  : Icons.usb,
                            ),
                            title: Text(device.name),
                            subtitle: Text(device.id),
                            trailing: device.rssi != null
                                ? Text('${device.rssi} dBm')
                                : null,
                            onTap: controller.busy
                                ? null
                                : () => _connect(context, controller, device),
                          );
                        },
                      ),
              ),
              const Divider(),
              Text(
                'BLE: enable Config → Advanced → Toggle BLE API on the Cardputer.\n'
                'USB: needs a USB-C ↔ USB-C data cable.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
