import 'dart:async';
import 'dart:html' as html;

Future<void> shareEncryptedBackup({
  required String filename,
  required String contents,
}) async {
  await downloadEncryptedBackup(filename: filename, contents: contents);
}

Future<void> downloadEncryptedBackup({
  required String filename,
  required String contents,
}) async {
  final blob = html.Blob([contents], 'application/octet-stream');
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: url)
    ..download = filename
    ..click();
  unawaited(Future<void>.delayed(const Duration(seconds: 1), () {
    html.Url.revokeObjectUrl(url);
  }));
}

void openBackupEmailDraft() {
  final uri = Uri(
    scheme: 'mailto',
    queryParameters: {
      'subject': 'My Money encrypted backup',
      'body': 'Attach the downloaded My Money .mymoney backup file. '
          'Keep its password separate and private.',
    },
  );
  html.AnchorElement(href: uri.toString())
    ..target = '_blank'
    ..click();
}
