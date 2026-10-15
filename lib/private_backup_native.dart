import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<void> savePrivateBackup(String encrypted) async {
  final directory = await getApplicationSupportDirectory();
  await File(p.join(directory.path, 'last-backup.mymoney'))
      .writeAsString(encrypted, flush: true);
}
