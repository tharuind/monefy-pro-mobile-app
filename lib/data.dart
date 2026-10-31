import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:aes256/aes256.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';
import 'package:uuid/uuid.dart';
import 'private_backup_native.dart'
  if (dart.library.html) 'private_backup_web.dart' as private_backup;

class MoneyEntry {
  final int? id;
  final String? cloudId;
  final int cents;
  final String type;
  final String category;
  final String account;
  final String note;
  final DateTime date;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  MoneyEntry({this.id, this.cloudId, required this.cents, required this.type,
    required this.category, required this.account,
    required this.note, required this.date, DateTime? updatedAt,
    this.deletedAt}) : updatedAt = updatedAt ?? DateTime.now().toUtc();

  factory MoneyEntry.fromMap(Map<String, dynamic> m) => MoneyEntry(
    id: m['id'] as int?, cloudId: m['cloud_id'] as String?,
    cents: m['cents'] as int,
    type: m['type'] as String, category: m['category'] as String,
    account: m['account'] as String, note: (m['note'] ?? '') as String,
    date: DateTime.parse(m['date'] as String),
    updatedAt: DateTime.tryParse(m['updated_at'] as String? ?? '') ??
      DateTime.parse(m['date'] as String).toUtc(),
    deletedAt: DateTime.tryParse(m['deleted_at'] as String? ?? ''),
  );

  Map<String, Object?> toMap() => {
    if (id != null) 'id': id,
    'cloud_id': cloudId,
    'cents': cents, 'type': type, 'category': category,
    'account': account, 'note': note, 'date': date.toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'deleted_at': deletedAt?.toUtc().toIso8601String(),
  };

  Map<String, Object?> toCloudMap(String deviceId) => {
    'id': cloudId,
    'cents': cents, 'type': type, 'category': category,
    'account': account, 'note': note, 'date': date.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'deletedAt': deletedAt?.toUtc().toIso8601String(),
    'deviceId': deviceId,
  };
}

class MoneyDatabase {
  MoneyDatabase._();
  static final instance = MoneyDatabase._();
  Database? _database;
  String? _databaseUid;
  static const _uuid = Uuid();

  Future<Database> get db async {
    if (_database != null) return _database!;
    final uid = _databaseUid;
    if (uid == null) {
      throw StateError('Sign in before opening account data.');
    }
    if (kIsWeb) databaseFactory = databaseFactoryFfiWeb;
    final databaseName = 'mymoney-${uid.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.sqlite';
    final dbPath = kIsWeb ? databaseName :
      p.join(await getDatabasesPath(), databaseName);
    _database = await _openDatabase(dbPath);
    await _prepareLegacyRows(_database!);
    return _database!;
  }

  Future<Database> _openDatabase(String path) => openDatabase(path,
      version: 3, onCreate: (d, version) async {
        await d.execute('''CREATE TABLE entries (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          cloud_id TEXT UNIQUE,
          cents INTEGER NOT NULL,
          type TEXT NOT NULL,
          category TEXT NOT NULL,
          account TEXT NOT NULL,
          note TEXT NOT NULL,
          date TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          deleted_at TEXT
        )''');
        await _createSyncQueue(d);
        await d.execute('CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
        await _createCatalogTable(d);
      }, onUpgrade: (d, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await d.execute('ALTER TABLE entries ADD COLUMN cloud_id TEXT');
          await d.execute('ALTER TABLE entries ADD COLUMN updated_at TEXT');
          await d.execute('ALTER TABLE entries ADD COLUMN deleted_at TEXT');
          await d.execute('CREATE UNIQUE INDEX entries_cloud_id ON entries(cloud_id)');
          await _createSyncQueue(d);
          await d.execute('CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
        }
        if (oldVersion < 3) await _createCatalogTable(d);
      });

  Future<void> activateUser(String uid) async {
    if (uid.isEmpty) throw ArgumentError('A signed-in account is required.');
    if (_databaseUid == uid && _database != null) return;
    await _database?.close();
    _database = null;
    _databaseUid = uid;
    try {
      final d = await db;
      final owner = await d.query('metadata', where: 'key = ?',
        whereArgs: ['owner_uid'], limit: 1);
      if (owner.isEmpty) await _migrateLegacyData(d, uid);
      await bindUser(uid);
    } catch (_) {
      await _database?.close();
      _database = null;
      _databaseUid = null;
      rethrow;
    }
  }

  Future<void> _migrateLegacyData(Database destination, String uid) async {
    if (kIsWeb) databaseFactory = databaseFactoryFfiWeb;
    final oldPath = kIsWeb ? 'mymoney.sqlite' :
      p.join(await getDatabasesPath(), 'mymoney.sqlite');
    if (!await databaseFactory.databaseExists(oldPath)) return;
    final legacy = await _openDatabase(oldPath);
    try {
      await _prepareLegacyRows(legacy);
      final ownerRows = await legacy.query('metadata',
        where: 'key = ?', whereArgs: ['owner_uid'], limit: 1);
      if (ownerRows.isNotEmpty && ownerRows.first['value'] != uid) return;
      final availableTables = (await legacy.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'"))
          .map((row) => row['name'] as String).toSet();
      const tables = ['entries', 'sync_queue', 'metadata', 'catalog_items'];
      await destination.transaction((tx) async {
        for (final table in tables) {
          if (!availableTables.contains(table)) continue;
          for (final row in await legacy.query(table)) {
            await tx.insert(table, row,
              conflictAlgorithm: ConflictAlgorithm.ignore);
          }
        }
      });
    } finally {
      await legacy.close();
    }
  }

  Future<void> deactivateUser() async {
    final activeDatabase = _database;
    _database = null;
    _databaseUid = null;
    await activeDatabase?.close();
  }

  Future<void> _createSyncQueue(DatabaseExecutor d) async {
    await d.execute('''CREATE TABLE sync_queue (
      entity_type TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      operation TEXT NOT NULL,
      payload TEXT NOT NULL,
      queued_at TEXT NOT NULL,
      PRIMARY KEY(entity_type, entity_id)
    )''');
  }

  Future<void> _createCatalogTable(DatabaseExecutor d) async {
    await d.execute('''CREATE TABLE catalog_items (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      name TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleted_at TEXT
    )''');
  }

  Future<void> _prepareLegacyRows(Database d) async {
    final rows = await d.query('entries', where: 'cloud_id IS NULL OR updated_at IS NULL');
    for (final row in rows) {
      final cloudId = row['cloud_id'] as String? ?? _uuid.v4();
      final updatedAt = row['updated_at'] as String? ?? DateTime.now().toUtc().toIso8601String();
      await d.update('entries', {'cloud_id': cloudId, 'updated_at': updatedAt},
        where: 'id = ?', whereArgs: [row['id']]);
    }
  }

  Future<List<MoneyEntry>> list() async {
    final d = await db;
    final rows = await d.query('entries', where: 'deleted_at IS NULL',
      orderBy: 'date DESC, id DESC');
    return rows.map((e) => MoneyEntry.fromMap(e)).toList();
  }

  Future<void> save(MoneyEntry entry) async {
    final d = await db;
    final cloudId = entry.cloudId ?? _uuid.v4();
    final saved = MoneyEntry(id: entry.id, cloudId: cloudId, cents: entry.cents,
      type: entry.type, category: entry.category, account: entry.account,
      note: entry.note, date: entry.date, updatedAt: DateTime.now().toUtc());
    await d.transaction((tx) async {
      final map = saved.toMap()..remove('id');
      await tx.insert('entries', map, conflictAlgorithm: ConflictAlgorithm.replace);
      await _queue(tx, 'transaction', cloudId, 'upsert', saved.toCloudMap(await deviceId(tx)));
    });
  }

  Future<void> delete(int id) async {
    final d = await db;
    await d.transaction((tx) async {
      final rows = await tx.query('entries', where: 'id = ?', whereArgs: [id], limit: 1);
      if (rows.isEmpty) return;
      final existing = MoneyEntry.fromMap(rows.first);
      final updated = DateTime.now().toUtc();
      await tx.update('entries', {'deleted_at': updated.toIso8601String(),
        'updated_at': updated.toIso8601String()}, where: 'id = ?', whereArgs: [id]);
      final deleted = MoneyEntry(id: id, cloudId: existing.cloudId, cents: existing.cents,
        type: existing.type, category: existing.category, account: existing.account,
        note: existing.note, date: existing.date, updatedAt: updated, deletedAt: updated);
      await _queue(tx, 'transaction', existing.cloudId!, 'upsert',
        deleted.toCloudMap(await deviceId(tx)));
    });
  }

  Future<String> deviceId([DatabaseExecutor? executor]) async {
    final d = executor ?? await db;
    final rows = await d.query('metadata', where: 'key = ?', whereArgs: ['device_id'], limit: 1);
    if (rows.isNotEmpty) return rows.first['value'] as String;
    final id = _uuid.v4();
    await d.insert('metadata', {'key': 'device_id', 'value': id},
      conflictAlgorithm: ConflictAlgorithm.ignore);
    final saved = await d.query('metadata', where: 'key = ?', whereArgs: ['device_id'], limit: 1);
    return saved.first['value'] as String;
  }

  Future<void> bindUser(String uid) async {
    final d = await db;
    await d.transaction((tx) async {
      final rows = await tx.query('metadata', where: 'key = ?',
        whereArgs: ['owner_uid'], limit: 1);
      if (rows.isNotEmpty && rows.first['value'] != uid) {
        throw StateError('This device has local data linked to another Google account. '
          'Export a backup and use a separate app profile before switching accounts.');
      }
      if (rows.isEmpty) {
        await tx.insert('metadata', {'key': 'owner_uid', 'value': uid});
      }
    });
  }

  Future<void> _queue(DatabaseExecutor tx, String type, String id,
      String operation, Map<String, Object?> payload) async {
    await tx.insert('sync_queue', {
      'entity_type': type, 'entity_id': id, 'operation': operation,
      'payload': jsonEncode(payload), 'queued_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<int> pendingCount() async => Sqflite.firstIntValue(
    await (await db).rawQuery('SELECT COUNT(*) FROM sync_queue')) ?? 0;

  Future<List<Map<String, Object?>>> pendingOperations() async =>
    (await db).query('sync_queue', orderBy: 'queued_at ASC');

  Future<void> clearPending(String type, String id) async =>
    (await db).delete('sync_queue', where: 'entity_type = ? AND entity_id = ?',
      whereArgs: [type, id]);

  Future<List<MoneyEntry>> listIncludingDeleted() async {
    final rows = await (await db).query('entries', orderBy: 'date DESC, id DESC');
    return rows.map(MoneyEntry.fromMap).toList();
  }

  Future<void> mergeRemoteEntry(Map<String, dynamic> remote) async {
    final cloudId = remote['id'] as String?;
    if (cloudId == null || cloudId.isEmpty) return;
    final data = Map<String, dynamic>.from(remote)
      ..remove('id')
      ..['cloud_id'] = cloudId
      ..['updated_at'] = remote['updatedAt']
      ..['deleted_at'] = remote['deletedAt'];
    final remoteEntry = MoneyEntry.fromMap(data);
    final d = await db;
    final localRows = await d.query('entries', where: 'cloud_id = ?', whereArgs: [cloudId], limit: 1);
    if (localRows.isNotEmpty) {
      final local = MoneyEntry.fromMap(localRows.first);
      if (local.updatedAt.isAfter(remoteEntry.updatedAt) ||
          (local.updatedAt.isAtSameMomentAs(remoteEntry.updatedAt) &&
           (await deviceId()).compareTo(remote['deviceId'] as String? ?? '') > 0)) return;
    }
    final map = remoteEntry.toMap()..remove('id');
    await d.insert('entries', map, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> enqueueAllLocal() async {
    final d = await db;
    final entries = await listIncludingDeleted();
    final device = await deviceId();
    await d.transaction((tx) async {
      for (final entry in entries) {
        final id = entry.cloudId;
        if (id != null) await _queue(tx, 'transaction', id, 'upsert', entry.toCloudMap(device));
      }
      final catalog = await tx.query('catalog_items');
      for (final item in catalog) {
        final id = item['id'] as String;
        await _queue(tx, item['kind'] as String, id, 'upsert', {
          'id': id, 'kind': item['kind'], 'name': item['name'],
          'updatedAt': item['updated_at'], 'deletedAt': item['deleted_at'],
          'deviceId': device,
        });
      }
    });
  }

  Future<List<Map<String, Object?>>> catalogItems(String kind,
      {bool includeDeleted = false}) async =>
    (await db).query('catalog_items',
      where: includeDeleted ? 'kind = ?' : 'kind = ? AND deleted_at IS NULL',
      whereArgs: [kind], orderBy: 'name COLLATE NOCASE');

  Future<List<String>> catalogNames(String kind) async =>
    (await catalogItems(kind)).map((item) => item['name'] as String).toList();

  Future<void> ensureDefaultCategories(
      List<String> expenseNames, List<String> incomeNames) async {
    final d = await db;
    await d.transaction((tx) async {
      final initialized = await tx.query('metadata', where: 'key = ?',
        whereArgs: ['builtin_categories_initialized'], limit: 1);
      if (initialized.isNotEmpty) return;
      const timestamp = '1970-01-01T00:00:00.000Z';
      for (final entry in [
        for (final name in expenseNames) ('expense_category', name),
        for (final name in incomeNames) ('income_category', name),
      ]) {
        final id = 'builtin:${entry.$1}:${entry.$2}';
        final exists = await tx.query('catalog_items', where:
          'id = ? OR (kind = ? AND name = ? AND deleted_at IS NULL)',
          whereArgs: [id, entry.$1, entry.$2], limit: 1);
        if (exists.isEmpty) {
          await tx.insert('catalog_items', {'id': id, 'kind': entry.$1,
            'name': entry.$2, 'updated_at': timestamp, 'deleted_at': null});
        }
      }
      await tx.insert('metadata', {
        'key': 'builtin_categories_initialized', 'value': 'yes',
      });
    });
  }

  Future<void> saveCatalogItem(String kind, String name, {String? id}) async {
    final d = await db;
    final cleaned = name.trim();
    if (cleaned.isEmpty) throw ArgumentError('Name cannot be empty.');
    await d.transaction((tx) async {
      final timestamp = DateTime.now().toUtc().toIso8601String();
      String itemId = id ?? _uuid.v4();
      String? oldName;
      if (id != null) {
        final prior = await tx.query('catalog_items', where: 'id = ?',
          whereArgs: [id], limit: 1);
        if (prior.isEmpty || prior.first['kind'] != kind) {
          throw StateError('This account or category is no longer available.');
        }
        oldName = prior.first['name'] as String;
      }
      if (!['account', 'expense_category', 'income_category'].contains(kind)) {
        throw ArgumentError('Unsupported account or category type.');
      }
      final duplicate = await tx.query('catalog_items', where:
        'kind = ? AND name = ? AND deleted_at IS NULL AND id != ?',
        whereArgs: [kind, cleaned, itemId], limit: 1);
      if (duplicate.isNotEmpty) throw StateError('That name is already in use.');
      await tx.insert('catalog_items', {'id': itemId, 'kind': kind, 'name': cleaned,
        'updated_at': timestamp, 'deleted_at': null},
        conflictAlgorithm: ConflictAlgorithm.replace);
      if (oldName != null && oldName != cleaned) {
        final column = kind == 'account' ? 'account' : 'category';
        final typeClause = kind == 'account' ? '' : ' AND type = ?';
        final filters = <Object?>[oldName];
        if (typeClause.isNotEmpty) {
          filters.add(kind == 'expense_category' ? 'expense' : 'income');
        }
        final where = '$column = ?$typeClause';
        final rows = await tx.query('entries', where: where, whereArgs: filters);
        await tx.update('entries', {column: cleaned, 'updated_at': timestamp},
          where: where, whereArgs: filters);
        final device = await deviceId(tx);
        for (final row in rows) {
          final changed = MoneyEntry.fromMap(row);
          final updated = MoneyEntry(id: changed.id, cloudId: changed.cloudId,
            cents: changed.cents, type: changed.type,
            category: column == 'category' ? cleaned : changed.category,
            account: column == 'account' ? cleaned : changed.account,
            note: changed.note, date: changed.date,
            updatedAt: DateTime.parse(timestamp), deletedAt: changed.deletedAt);
          if (updated.cloudId != null) {
            await _queue(tx, 'transaction', updated.cloudId!, 'upsert',
              updated.toCloudMap(device));
          }
        }
      }
      final device = await deviceId(tx);
      await _queue(tx, kind, itemId, 'upsert', {'id': itemId, 'kind': kind,
        'name': cleaned, 'updatedAt': timestamp, 'deletedAt': null,
        'deviceId': device});
    });
  }

  Future<void> deleteCatalogItem(String kind, String id,
      {String? replacementId}) async {
    final d = await db;
    await d.transaction((tx) async {
      final rows = await tx.query('catalog_items', where: 'id = ? AND kind = ?',
        whereArgs: [id, kind], limit: 1);
      if (rows.isEmpty) return;
      final timestamp = DateTime.now().toUtc().toIso8601String();
      if (kind == 'expense_category' || kind == 'income_category') {
        if (replacementId == null || replacementId == id) {
          throw ArgumentError('Choose another category for existing transactions.');
        }
        final replacementRows = await tx.query('catalog_items',
          where: 'id = ? AND kind = ? AND deleted_at IS NULL',
          whereArgs: [replacementId, kind], limit: 1);
        if (replacementRows.isEmpty) {
          throw StateError('The selected replacement category is no longer available.');
        }
        final sourceName = rows.first['name'] as String;
        final replacementName = replacementRows.first['name'] as String;
        final type = kind == 'expense_category' ? 'expense' : 'income';
        final entries = await tx.query('entries',
          where: 'category = ? AND type = ?',
          whereArgs: [sourceName, type]);
        await tx.update('entries',
          {'category': replacementName, 'updated_at': timestamp},
          where: 'category = ? AND type = ?',
          whereArgs: [sourceName, type]);
        final device = await deviceId(tx);
        for (final row in entries) {
          final entry = MoneyEntry.fromMap(row);
          if (entry.cloudId == null) continue;
          final updated = MoneyEntry(id: entry.id, cloudId: entry.cloudId,
            cents: entry.cents, type: entry.type, category: replacementName,
            account: entry.account, note: entry.note, date: entry.date,
            updatedAt: DateTime.parse(timestamp), deletedAt: entry.deletedAt);
          await _queue(tx, 'transaction', entry.cloudId!, 'upsert',
            updated.toCloudMap(device));
        }
      }
      await tx.update('catalog_items', {'updated_at': timestamp, 'deleted_at': timestamp},
        where: 'id = ?', whereArgs: [id]);
      await _queue(tx, kind, id, 'upsert', {'id': id, 'kind': kind,
        'name': rows.first['name'], 'updatedAt': timestamp,
        'deletedAt': timestamp, 'deviceId': await deviceId(tx)});
    });
  }

  Future<void> mergeRemoteCatalog(Map<String, dynamic> remote) async {
    final id = remote['id'] as String?;
    final kind = remote['kind'] as String?;
    final name = remote['name'] as String?;
    final updatedAt = remote['updatedAt'] as String?;
    if (id == null || !['account', 'expense_category', 'income_category'].contains(kind) ||
        name == null || updatedAt == null) return;
    final d = await db;
    final local = await d.query('catalog_items', where: 'id = ?', whereArgs: [id], limit: 1);
    if (local.isNotEmpty) {
      final localTime = DateTime.tryParse(local.first['updated_at'] as String? ?? '');
      final remoteTime = DateTime.tryParse(updatedAt);
      if (localTime != null && remoteTime != null &&
          (localTime.isAfter(remoteTime) ||
           (localTime.isAtSameMomentAs(remoteTime) &&
            (await deviceId()).compareTo(remote['deviceId'] as String? ?? '') > 0))) return;
    }
    await d.insert('catalog_items', {'id': id, 'kind': kind, 'name': name,
      'updated_at': updatedAt, 'deleted_at': remote['deletedAt']},
      conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String> backupJson() async {
    final items = await listIncludingDeleted();
    final catalog = await (await db).query('catalog_items');
    return jsonEncode({'format': 'mymoney-v2',
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'entries': items.map((e) => e.toMap()).toList(),
      'catalog': catalog});
  }

  Future<void> restoreJson(String jsonString) async {
    final parsed = jsonDecode(jsonString);
    if (parsed is! Map ||
        !['mymoney-v1', 'mymoney-v2'].contains(parsed['format']) ||
        parsed['entries'] is! List) {
      throw const FormatException('Not a My Money backup');
    }
    final safeItems = <MoneyEntry>[];
    final safeCatalog = <Map<String, dynamic>>[];
    for (final v in parsed['entries'] as List) {
      if (v is! Map<String, dynamic>) throw const FormatException('Invalid row');
      final row = MoneyEntry.fromMap(v);
      if (row.cents <= 0 || !['income', 'expense'].contains(row.type) ||
          row.category.isEmpty || row.account.isEmpty) {
        throw const FormatException('Invalid financial record');
      }
      safeItems.add(row);
    }
    if (parsed['format'] == 'mymoney-v2') {
      if (parsed['catalog'] is! List) {
        throw const FormatException('Invalid account/category data');
      }
      for (final value in parsed['catalog'] as List) {
        if (value is! Map<String, dynamic> ||
            value['id'] is! String || value['name'] is! String ||
            (value['name'] as String).trim().isEmpty ||
            !['account', 'expense_category', 'income_category'].contains(value['kind']) ||
            value['updated_at'] is! String ||
            DateTime.tryParse(value['updated_at'] as String) == null ||
            (value['deleted_at'] != null && value['deleted_at'] is! String)) {
          throw const FormatException('Invalid account/category record');
        }
        safeCatalog.add(value);
      }
    }
    final d = await db;
    await d.transaction((tx) async {
      for (final row in safeItems) {
        if (row.cloudId != null) {
          final sameIdentity = await tx.query('entries', where: 'cloud_id = ?',
            whereArgs: [row.cloudId], limit: 1);
          if (sameIdentity.isNotEmpty) continue;
        }
        final restored = MoneyEntry(cloudId: row.cloudId ?? _uuid.v4(), cents: row.cents,
          type: row.type, category: row.category, account: row.account, note: row.note,
          date: row.date, updatedAt: row.updatedAt, deletedAt: row.deletedAt).toMap()
          ..remove('id');
        await tx.insert('entries', restored);
      }
      for (final item in safeCatalog) {
        final sameId = await tx.query('catalog_items', where: 'id = ?',
          whereArgs: [item['id']], limit: 1);
        if (sameId.isNotEmpty) continue;
        final sameName = await tx.query('catalog_items', where:
          'kind = ? AND name = ? AND deleted_at IS NULL',
          whereArgs: [item['kind'], item['name']], limit: 1);
        if (sameName.isNotEmpty) continue;
        await tx.insert('catalog_items', {
          'id': item['id'], 'kind': item['kind'], 'name': item['name'],
          'updated_at': item['updated_at'], 'deleted_at': item['deleted_at'],
        });
      }
    });
    await enqueueAllLocal();
  }
}

class BackupTools {
  // AES-256-GCM, with PBKDF2 key derivation, per aes256 package.
  static Future<String> encryptedText(String plaintext, String passphrase) async {
    if (passphrase.length < 10) throw ArgumentError('Use a password with at least 10 characters');
    return Aes256.encrypt(text: plaintext, passphrase: passphrase);
  }

  static Future<void> restoreText(String ciphertext, String passphrase) async {
    final plaintext = await Aes256.decrypt(encrypted: ciphertext, passphrase: passphrase);
    await MoneyDatabase.instance.restoreJson(plaintext);
  }

  static Future<void> savePrivateLocalCopy(String passphrase) async {
    final encrypted = await Aes256.encrypt(
      text: await MoneyDatabase.instance.backupJson(), passphrase: passphrase);
    await private_backup.savePrivateBackup(encrypted);
  }
}
