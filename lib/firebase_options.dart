import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// Public Firebase app identifiers are supplied at build time; never put service
/// account keys or other private credentials in this file.
class DefaultFirebaseOptions {
  static FirebaseOptions? get currentPlatform {
    if (const String.fromEnvironment('FIREBASE_CONFIGURED') != 'true') return null;
    final apiKey = const String.fromEnvironment('FIREBASE_API_KEY');
    final appId = switch (defaultTargetPlatform) {
      TargetPlatform.android => const String.fromEnvironment('FIREBASE_ANDROID_APP_ID'),
      TargetPlatform.iOS => const String.fromEnvironment('FIREBASE_IOS_APP_ID'),
      _ => const String.fromEnvironment('FIREBASE_WEB_APP_ID'),
    };
    final projectId = const String.fromEnvironment('FIREBASE_PROJECT_ID');
    final senderId = const String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
    if (apiKey.isEmpty || appId.isEmpty || projectId.isEmpty || senderId.isEmpty) {
      return null;
    }
    if (kIsWeb) {
      return FirebaseOptions(apiKey: apiKey, appId: appId, projectId: projectId,
        messagingSenderId: senderId,
        authDomain: const String.fromEnvironment('FIREBASE_AUTH_DOMAIN'));
    }
    return FirebaseOptions(apiKey: apiKey, appId: appId, projectId: projectId,
      messagingSenderId: senderId,
      iosBundleId: defaultTargetPlatform == TargetPlatform.iOS
          ? const String.fromEnvironment('FIREBASE_IOS_BUNDLE_ID') : null);
  }
}
