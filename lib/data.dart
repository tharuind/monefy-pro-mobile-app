import 'dart:convert';
import 'dart:io';

import 'package:aes256/aes256.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class MoneyEntry {
  final int? id;
  final int cents;
  final String type;
  final String category;
  final String account;
  final String note;
  final DateTime date;

  MoneyEntry({this.id, required this.cents, required this.type,
    required this.category, required this.account,
    required this.note, required this.date});

  factory MoneyEntry.fromMap(Map<String, dynamic> m) => MoneyEntry(
    id: m['id'] as int?, cents: m['cents'] as int,
    type: m['type'] as String, category: m['category'] as String,
    account: m['account'] as String, note: (m['note'] ?? '') as String,
    date: DateTime.parse(m['date'] as String),
  );

  Map<String, Object?> toMap() => {
    if (id != null) 'id': id,
    'cents': cents, 'type': type, 'category': category,
    'account': account, 'note': note, 'date': date.toIso8601String(),
  };
}

class MoneyDatabase {
  MoneyDatabase._();
  static final instance = MoneyDatabase._();
  Database? _database;

  Future<Database> get db async {
    if (_database != null) return _database!;
    final dir = await getDatabasesPath();
    _database = await openDatabase(p.join(dir, 'mymoney.sqlite'),
      version: 1, onCreate: (d, version) async {
        await d.execute('''CREATE TABLE entries (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          cents INTEGER NOT NULL,
          type TEXT NOT NULL,
          category TEXT NOT NULL,
          account TEXT NOT NULL,
          note TEXT NOT NULL,
          date TEXT NOT NULL
        )''');
      });
    return _database!;
  }

  Future<List<MoneyEntry>> list() async {
    final d = await db;
    final rows = await d.query('entries', orderBy: 'date DESC, id DESC');
    return rows.map((e) => MoneyEntry.fromMap(e)).toList();
  }

  Future<void> save(MoneyEntry entry) async {
    final d = await db;
    if (entry.id == null) {
      await d.insert('entries', entry.toMap());
    } else {
      await d.update('entries', entry.toMap(), where: 'id = ?', whereArgs: [entry.id]);
    }
  }

  Future<void> delete(int id) async {
    final d = await db;
    await d.delete('entries', where: 'id = ?', whereArgs: [id]);
  }

  Future<String> backupJson() async {
    final items = await list();
    return jsonEncode({'format': 'mymoney-v1',
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'entries': items.map((e) => e.toMap()).toList()});
  }

  Future<void> restoreJson(String jsonString) async {
    final parsed = jsonDecode(jsonString);
    if (parsed is! Map || parsed['format'] != 'mymoney-v1' || parsed['entries'] is! List) {
      throw const FormatException('Not a MyMoney backup');
    }
    // Validate the complete payload BEFORE replacing any financial records.
    final safeItems = <MoneyEntry>[];
    for (final v in parsed['entries'] as List) {
      if (v is! Map<String, dynamic>) throw const FormatException('Invalid row');
      final row = MoneyEntry.fromMap(v);
      if (row.cents <= 0 || !['income', 'expense'].contains(row.type) ||
          row.category.isEmpty || row.account.isEmpty) {
        throw const FormatException('Invalid financial record');
      }
      safeItems.add(row);
    }
    final d = await db;
    await d.transaction((tx) async {
      await tx.delete('entries');
      for (final row in safeItems) {
        final map = row.toMap()..remove('id');
        await tx.insert('entries', map);
      }
    });
  }
}

class BackupTools {
  // AES-256-GCM, with PBKDF2 key derivation, per aes256 package.
  static Future<File> encryptedFile(String plaintext, String passphrase) async {
    if (passphrase.length < 10) throw ArgumentError('Use a password with at least 10 characters');
    final encrypted = await Aes256.encrypt(text: plaintext, passphrase: passphrase);
    final dir = await getTemporaryDirectory();
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final file = File(p.join(dir.path, 'MyMoney-$timestamp.mymoney'));
    return file.writeAsString(encrypted, flush: true);
  }

  static Future<void> restore(File file, String passphrase) async {
    final ciphertext = await file.readAsString();
    final plaintext = await Aes256.decrypt(encrypted: ciphertext, passphrase: passphrase);
    if (plaintext == null) throw const FormatException("Incorrect backup password or invalid backup");
    await MoneyDatabase.instance.restoreJson(plaintext);
  }

  static Future<void> savePrivateLocalCopy(String passphrase) async {
    final encrypted = await Aes256.encrypt(
      text: await MoneyDatabase.instance.backupJson(), passphrase: passphrase);
    final dir = await getApplicationSupportDirectory();
    await File(p.join(dir.path, 'last-backup.mymoney')).writeAsString(encrypted, flush: true);
  }
}
