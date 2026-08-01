/// Maps a [CardDumpFormat] to a representative icon for list rows.
library;

import 'package:flutter/material.dart';

import '../../models/card_dump.dart';

IconData iconForFormat(CardDumpFormat format) => switch (format) {
      CardDumpFormat.bruceRfid => Icons.nfc,
      CardDumpFormat.flipperNfc => Icons.contactless,
      CardDumpFormat.binary => Icons.memory,
      CardDumpFormat.lf125 => Icons.podcasts,
      CardDumpFormat.srix => Icons.credit_card,
      CardDumpFormat.scanLog => Icons.list_alt,
      CardDumpFormat.unknown => Icons.insert_drive_file_outlined,
    };

class FormatIcon extends StatelessWidget {
  const FormatIcon({super.key, required this.format});

  final CardDumpFormat format;

  @override
  Widget build(BuildContext context) {
    return Icon(iconForFormat(format));
  }
}
