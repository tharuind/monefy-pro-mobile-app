import 'dart:html' as html;

Future<void> savePrivateBackup(String encrypted) async {
  html.window.localStorage['mymoney-last-backup'] = encrypted;
}
