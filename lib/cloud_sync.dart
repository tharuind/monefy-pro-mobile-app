import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'data.dart';
import 'firebase_options.dart';

enum SyncStatus { offline, pending, syncing, synced }

extension SyncStatusLabel on SyncStatus {
  String get label => switch (this) {
    SyncStatus.offline => 'Offline',
    SyncStatus.pending => 'Pending Sync',
    SyncStatus.syncing => 'Syncing',
    SyncStatus.synced => 'Synced',
  };
}

class CloudSyncService extends ChangeNotifier {
  CloudSyncService._();
  static final instance = CloudSyncService._();

  SyncStatus status = SyncStatus.pending;
  String? errorMessage;
  int completedSyncs = 0;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  StreamSubscription<User?>? _authSubscription;
  bool _configured = false;
  bool _online = true;
  bool _running = false;
  Completer<void>? _syncInFlight;

  User? get user => _configured ? FirebaseAuth.instance.currentUser : null;

  Future<void> initialize() async {
    try {
      _online = (await Connectivity().checkConnectivity())
          .any((result) => result != ConnectivityResult.none);
      _connectivitySubscription = Connectivity().onConnectivityChanged.listen(
        (results) {
          _online = results.any((result) => result != ConnectivityResult.none);
          if (_configured && _online) {
            unawaited(syncNow());
          } else {
            unawaited(_updateLocalStatus());
          }
        }, onError: (Object error) {
          errorMessage = 'Could not monitor network state: $error';
          notifyListeners();
        });
      FirebaseOptions? options = DefaultFirebaseOptions.currentPlatform;
      if (options == null) {
        errorMessage = 'Configure Firebase to enable account sign-in and cloud sync.';
        await _updateLocalStatus();
        notifyListeners();
        return;
      }
      if (Firebase.apps.isEmpty) await Firebase.initializeApp(options: options);
      if (kIsWeb) {
        await FirebaseFirestore.instance.enablePersistence(
          const PersistenceSettings(synchronizeTabs: true));
      }
      _configured = true;
      _authSubscription = FirebaseAuth.instance.authStateChanges().listen((signedInUser) {
        if (signedInUser == null) {
          unawaited(_updateLocalStatus());
        } else {
          unawaited(_queueAndSyncForUser(signedInUser.uid).catchError((Object error) {
            errorMessage = '$error';
            status = SyncStatus.pending;
            notifyListeners();
          }));
        }
      });
      status = !_online ? SyncStatus.offline :
        (await MoneyDatabase.instance.pendingCount() > 0 ||
         (await MoneyDatabase.instance.list()).isNotEmpty
          ? SyncStatus.pending : SyncStatus.synced);
      notifyListeners();
      if (_online && user != null) unawaited(syncNow());
    } catch (error) {
      errorMessage = 'Cloud sync initialization failed: $error';
      status = _online ? SyncStatus.pending : SyncStatus.offline;
      notifyListeners();
    }
  }

  Future<void> signInWithGoogle() async {
    if (!_configured) throw StateError('Firebase is not configured. Follow the setup steps in README.md.');
    if (kIsWeb) {
      await FirebaseAuth.instance.signInWithPopup(GoogleAuthProvider());
    } else {
      final clientId = DefaultFirebaseOptions.googleServerClientId;
      if (clientId.isEmpty) {
        throw StateError('Google sign-in is not configured. Set FIREBASE_WEB_CLIENT_ID '
            'to the Firebase project Web OAuth client ID.');
      }
      final googleUser = await GoogleSignIn(
        serverClientId: clientId, scopes: const ['email']).signIn();
      if (googleUser == null) throw StateError('Google sign-in was cancelled.');
      final auth = await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: auth.accessToken, idToken: auth.idToken);
      await FirebaseAuth.instance.signInWithCredential(credential);
    }
    try {
      await _queueAndSyncForUser(FirebaseAuth.instance.currentUser!.uid);
    } catch (_) {
      if (!kIsWeb) await GoogleSignIn().signOut();
      await FirebaseAuth.instance.signOut();
      rethrow;
    }
  }

  Future<void> _queueAndSyncForUser(String uid) async {
    await MoneyDatabase.instance.bindUser(uid);
    await MoneyDatabase.instance.enqueueAllLocal();
    await syncNow();
  }

  Future<void> signOut() async {
    if (!_configured) return;
    if (!kIsWeb) await GoogleSignIn().signOut();
    await FirebaseAuth.instance.signOut();
    status = await MoneyDatabase.instance.pendingCount() > 0
        ? SyncStatus.pending : SyncStatus.synced;
    notifyListeners();
  }

  Future<void> onResume() async {
    _online = (await Connectivity().checkConnectivity())
        .any((result) => result != ConnectivityResult.none);
    if (_configured) {
      await syncNow();
    } else {
      await _updateLocalStatus();
    }
  }

  Future<void> _updateLocalStatus() async {
    final count = await MoneyDatabase.instance.pendingCount();
    status = !_online ? SyncStatus.offline :
      (count > 0 || !_configured ? SyncStatus.pending : SyncStatus.synced);
    notifyListeners();
  }

  Future<void> localChanged() async {
    final count = await MoneyDatabase.instance.pendingCount();
    if (!_configured || user == null) {
      status = !_online ? SyncStatus.offline :
        (count > 0 || (await MoneyDatabase.instance.list()).isNotEmpty
          ? SyncStatus.pending : SyncStatus.synced);
      notifyListeners();
      return;
    }
    status = count > 0 ? SyncStatus.pending : SyncStatus.synced;
    notifyListeners();
    if (_online) unawaited(syncNow());
  }

  Future<void> syncNow() async {
    if (!_configured) {
      status = _online ? SyncStatus.pending : SyncStatus.offline;
      notifyListeners();
      return;
    }
    final pendingCount = await MoneyDatabase.instance.pendingCount();
    final currentUser = user;
    if (!_online) {
      status = SyncStatus.offline;
      notifyListeners();
      return;
    }
    if (currentUser == null) {
      status = pendingCount > 0 || (await MoneyDatabase.instance.list()).isNotEmpty
          ? SyncStatus.pending : SyncStatus.synced;
      notifyListeners();
      return;
    }
    try {
      await MoneyDatabase.instance.bindUser(currentUser.uid);
    } catch (error) {
      errorMessage = '$error';
      status = SyncStatus.pending;
      notifyListeners();
      return;
    }
    if (_running) {
      await _syncInFlight?.future;
      return;
    }
    _running = true;
    final inFlight = Completer<void>();
    _syncInFlight = inFlight;
    status = SyncStatus.syncing;
    errorMessage = null;
    notifyListeners();
    try {
      final database = MoneyDatabase.instance;
      final deviceId = await database.deviceId();
      final userDocument = FirebaseFirestore.instance
          .collection('users').doc(currentUser.uid);
      for (final operation in await database.pendingOperations()) {
        final entityType = operation['entity_type'] as String;
        final collectionName = switch (entityType) {
          'transaction' => 'transactions',
          'account' => 'accounts',
          'expense_category' || 'income_category' => 'categories',
          _ => throw StateError('Unsupported pending sync type: $entityType'),
        };
        final id = operation['entity_id'] as String;
        final payload = Map<String, dynamic>.from(
          jsonDecode(operation['payload'] as String) as Map);
        final reference = userDocument.collection(collectionName).doc(id);
        var cloudWon = false;
        await FirebaseFirestore.instance.runTransaction((transaction) async {
          final snapshot = await transaction.get(reference);
          if (snapshot.exists && _preferRemote(snapshot.data()!, payload, deviceId)) {
            cloudWon = true;
            return;
          }
          transaction.set(reference, payload);
        });
        if (cloudWon) {
          final remote = await reference.get();
          if (remote.exists) {
            if (entityType == 'transaction') {
              await database.mergeRemoteEntry({'id': remote.id, ...remote.data()!});
            } else {
              await database.mergeRemoteCatalog({'id': remote.id, ...remote.data()!});
            }
          }
        }
        await database.clearPending(entityType, id);
      }
      final remoteEntries = await userDocument.collection('transactions').get();
      for (final document in remoteEntries.docs) {
        await database.mergeRemoteEntry({'id': document.id, ...document.data()});
      }
      for (final collectionName in ['accounts', 'categories']) {
        final remoteCatalog = await userDocument.collection(collectionName).get();
        for (final document in remoteCatalog.docs) {
          await database.mergeRemoteCatalog({'id': document.id, ...document.data()});
        }
      }
      completedSyncs++;
      status = await database.pendingCount() == 0
          ? SyncStatus.synced : SyncStatus.pending;
    } catch (error) {
      errorMessage = 'Sync did not complete: $error';
      status = SyncStatus.pending;
    } finally {
      _running = false;
      _syncInFlight = null;
      inFlight.complete();
      notifyListeners();
    }
  }

  bool _preferRemote(Map<String, dynamic> remote, Map<String, dynamic> local,
      String localDeviceId) {
    final remoteTime = DateTime.tryParse(remote['updatedAt'] as String? ?? '');
    final localTime = DateTime.tryParse(local['updatedAt'] as String? ?? '');
    if (remoteTime == null || localTime == null) return false;
    if (remoteTime.isAfter(localTime)) return true;
    if (remoteTime.isBefore(localTime)) return false;
    final remoteDevice = remote['deviceId'] as String? ?? '';
    return remoteDevice.compareTo(localDeviceId) > 0;
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    _authSubscription?.cancel();
    super.dispose();
  }
}
