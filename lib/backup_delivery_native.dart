import 'dart:convert';
import 'dart:typed_data';

import 'package:share_plus/share_plus.dart';

Future<void> shareEncryptedBackup({
  required String filename,
  required String contents,
}) async {
  await SharePlus.instance.share(ShareParams(
    files: [XFile.fromData(
      Uint8List.fromList(utf8.encode(contents)),
      name: filename,
      mimeType: 'application/octet-stream',
    )],
    subject: 'My Money encrypted backup',
    text: 'Encrypted My Money backup. Keep the backup password separate and private.',
  ));
}

Future<void> downloadEncryptedBackup({
  required String filename,
  required String contents,
}) async {
  throw UnsupportedError('Direct backup downloads are available on web only.');
}

void openBackupEmailDraft() {
  throw UnsupportedError('Email drafts are opened by the web app only.');
}
