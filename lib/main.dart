import 'dart:math' as math;
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:share_plus/share_plus.dart';

import 'data.dart';

const emerald = Color(0xFF11A676);
const red = Color(0xFFE15C6B);
const colors = <Color>[
  Color(0xFFFBAD4D), Color(0xFF756DDF), Color(0xFF46AADA),
  Color(0xFFE87093), Color(0xFF61BD8E), Color(0xFFB181D7),
  Color(0xFFE0A9A0), Color(0xFF9CA8B4),
];
const expenses = <String>[
  'Food', 'Transport', 'Shopping', 'Bills', 'Health',
  'Education', 'Entertainment', 'Other'
];
const incomes = <String>['Salary', 'Freelance', 'Gift', 'Savings', 'Other'];
const accounts = <String>['Cash', 'Bank', 'Card', 'Other'];
const icons = <String, IconData>{
  'Food': Icons.restaurant, 'Transport': Icons.directions_bus,
  'Shopping': Icons.shopping_bag, 'Bills': Icons.receipt_long,
  'Health': Icons.medical_services, 'Education': Icons.school,
  'Entertainment': Icons.movie, 'Other': Icons.category,
  'Salary': Icons.work, 'Freelance': Icons.laptop,
  'Gift': Icons.card_giftcard, 'Savings': Icons.savings,
};
const vault = FlutterSecureStorage();

String money(int cents) {
  final negative = cents < 0 ? '-' : '';
  final v = cents.abs();
  final units = (v ~/ 100).toString();
  final grouped = units.replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');
  return '${negative}LKR $grouped.${(v % 100).toString().padLeft(2, '0')}';
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyMoneyApp());
}

class MyMoneyApp extends StatelessWidget {
  const MyMoneyApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'MyMoney',
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: emerald),
      scaffoldBackgroundColor: const Color(0xFFF7F9FB),
      appBarTheme: const AppBarTheme(backgroundColor: Color(0xFFF7F9FB)),
      cardTheme: CardThemeData(color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
      inputDecorationTheme: InputDecorationTheme(
        filled: true, fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14))),
    ),
    home: const AppGate(),
  );
}

class AppGate extends StatefulWidget {
  const AppGate({super.key});
  @override
  State<AppGate> createState() => _AppGateState();
}

class _AppGateState extends State<AppGate> with WidgetsBindingObserver {
  bool loading = true;
  bool locked = false;
  final pin = TextEditingController();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      vault.read(key: 'app-pin').then((value) {
        if (mounted && value != null) setState(() => locked = true);
      });
    }
  }
  Future<void> _check() async {
    final existing = await vault.read(key: 'app-pin');
    if (!mounted) return;
    setState(() { locked = existing != null; loading = false; });
  }
  Future<void> _unlock() async {
    final expected = await vault.read(key: 'app-pin');
    if (pin.text == expected) {
      if (mounted) setState(() => locked = false);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Incorrect PIN')));
    }
  }
  Future<void> _biometric() async {
    try {
      final ok = await LocalAuthentication().authenticate(
        localizedReason: 'Unlock your MyMoney records', biometricOnly: true);
      if (ok && mounted) setState(() => locked = false);
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Biometrics unavailable on this phone')));
    }
  }
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    pin.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (!locked) return const MoneyHome();
    return Scaffold(body: SafeArea(child: Center(child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 350),
      child: Padding(padding: const EdgeInsets.all(24), child: Column(
        mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.lock, size: 60, color: emerald),
          const SizedBox(height: 20),
          const Text('Unlock MyMoney', style: TextStyle(fontSize: 27, fontWeight: FontWeight.bold)),
          const SizedBox(height: 20),
          TextField(controller: pin, obscureText: true, keyboardType: TextInputType.number,
            maxLength: 8, decoration: const InputDecoration(labelText: 'App PIN'),
            onSubmitted: (_) => _unlock()),
          FilledButton(onPressed: _unlock, child: const Text('Unlock')),
          TextButton.icon(onPressed: _biometric, icon: const Icon(Icons.fingerprint),
            label: const Text('Unlock with fingerprint')),
        ],
      )),
    ))));
  }
}

class MoneyHome extends StatefulWidget {
  const MoneyHome({super.key});
  @override
  State<MoneyHome> createState() => _MoneyHomeState();
}

class _MoneyHomeState extends State<MoneyHome> {
  List<MoneyEntry> all = [];
  DateTime selected = DateTime(DateTime.now().year, DateTime.now().month);
  bool loading = true;
  String accountFilter = 'All';

  @override
  void initState() { super.initState(); reload(); }
  Future<void> reload() async {
    final data = await MoneyDatabase.instance.list();
    if (mounted) setState(() { all = data; loading = false; });
    // Keeps an encrypted PRIVATE copy while the app is opened/updated.
    // Does not promise background delivery or send email.
    try {
      final enabled = await vault.read(key: 'auto-local-enabled');
      final password = await vault.read(key: 'auto-local-password');
      if (enabled == 'yes' && password != null) {
        await BackupTools.savePrivateLocalCopy(password);
      }
    } catch (_) { /* Database is still usable if backup fails. */ }
  }
  List<MoneyEntry> get shown => all.where((e) =>
    e.date.year == selected.year && e.date.month == selected.month &&
    (accountFilter == 'All' || e.account == accountFilter)).toList();

  void changeMonth(int diff) => setState(() {
    selected = DateTime(selected.year, selected.month + diff);
  });

  Future<void> openEditor({MoneyEntry? entry, String type = 'expense'}) async {
    final changed = await showModalBottomSheet<bool>(
      context: context, isScrollControlled: true, showDragHandle: true,
      builder: (ctx) => EntryEditor(entry: entry, initialType: type));
    if (changed == true) await reload();
  }

  Future<void> settings() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SettingsPage(onRestore: reload)));
    await reload();
  }

  @override
  Widget build(BuildContext context) {
    final current = shown;
    final earned = current.where((e) => e.type == 'income')
        .fold<int>(0, (s, e) => s + e.cents);
    final spent = current.where((e) => e.type == 'expense')
        .fold<int>(0, (s, e) => s + e.cents);
    final balance = all.fold<int>(0,
        (s, e) => s + (e.type == 'income' ? e.cents : -e.cents));
    final groups = <String, int>{};
    for (final e in current.where((e) => e.type == 'expense')) {
      groups[e.category] = (groups[e.category] ?? 0) + e.cents;
    }
    return Scaffold(
      appBar: AppBar(title: const Text('MyMoney', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [IconButton(tooltip: 'Settings and backups',
          onPressed: settings, icon: const Icon(Icons.settings_outlined))]),
      body: loading ? const Center(child: CircularProgressIndicator()) :
        RefreshIndicator(onRefresh: reload, child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 100), children: [
            Card(child: Padding(padding: const EdgeInsets.all(20), child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('TOTAL BALANCE', style: TextStyle(color: Colors.black54, letterSpacing: 1)),
                const SizedBox(height: 7),
                Text(money(balance), style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold)),
                const SizedBox(height: 15),
                Row(children: [
                  Expanded(child: _MiniTotal('Income', earned, emerald, Icons.arrow_downward)),
                  Expanded(child: _MiniTotal('Expenses', spent, red, Icons.arrow_upward)),
                ])
              ],
            ))),
            const SizedBox(height: 12),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              IconButton(onPressed: () => changeMonth(-1), icon: const Icon(Icons.chevron_left)),
              Text('${_month(selected.month)} ${selected.year}',
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
              IconButton(onPressed: () => changeMonth(1), icon: const Icon(Icons.chevron_right)),
              DropdownButton<String>(value: accountFilter, underline: const SizedBox(),
                items: ['All', ...accounts].map((a) => DropdownMenuItem(value: a,
                  child: Text(a))).toList(),
                onChanged: (v) => setState(() => accountFilter = v ?? 'All')),
            ]),
            Card(child: Padding(padding: const EdgeInsets.all(18), child: Column(children: [
              const Text('Spending by category', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 16),
              SizedBox(height: 200, child: Center(child: CustomPaint(
                painter: DonutPainter(groups), size: const Size(186, 186),
                child: SizedBox(width: 186, height: 186, child: Column(
                  mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text(money(spent), textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
                    const Text('This month', style: TextStyle(color: Colors.black54)),
                  ],
                )),
              ))),
              if (groups.isEmpty) const Text('Add your first expense to see the chart.'),
              Wrap(spacing: 12, runSpacing: 8,
                children: groups.keys.map((c) => Row(mainAxisSize: MainAxisSize.min, children: [
                  CircleAvatar(radius: 5, backgroundColor: categoryColor(c)),
                  const SizedBox(width: 5), Text(c, style: const TextStyle(fontSize: 12)),
                ])).toList()),
            ]))),
            const SizedBox(height: 18),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const Text('Transactions', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              Text('${current.length} records', style: const TextStyle(color: Colors.black54)),
            ]),
            const SizedBox(height: 8),
            if (current.isEmpty) const Padding(padding: EdgeInsets.all(30),
              child: Center(child: Text('No transactions for this month.'))),
            ...current.map((e) => Card(child: ListTile(
              leading: CircleAvatar(backgroundColor: categoryColor(e.category).withAlpha(35),
                child: Icon(icons[e.category] ?? Icons.category, color: categoryColor(e.category))),
              title: Text(e.category, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text('${e.account} · ${e.date.day}/${e.date.month}/${e.date.year}'
                  '${e.note.isNotEmpty ? ' · ${e.note}' : ''}', maxLines: 2,
                overflow: TextOverflow.ellipsis),
              trailing: Text('${e.type == 'income' ? '+' : '-'}${money(e.cents)}',
                style: TextStyle(color: e.type == 'income' ? emerald : red,
                  fontWeight: FontWeight.w700)),
              onTap: () => openEditor(entry: e),
            ))),
          ],
        )),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: Row(mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FloatingActionButton.extended(heroTag: 'exp', backgroundColor: red,
            foregroundColor: Colors.white, onPressed: () => openEditor(),
            icon: const Icon(Icons.remove), label: const Text('Expense')),
          const SizedBox(width: 14),
          FloatingActionButton.extended(heroTag: 'inc', backgroundColor: emerald,
            foregroundColor: Colors.white, onPressed: () => openEditor(type: 'income'),
            icon: const Icon(Icons.add), label: const Text('Income')),
        ]),
    );
  }
}

Color categoryColor(String c) {
  final index = expenses.indexOf(c);
  if (index >= 0) return colors[index % colors.length];
  return colors[c.codeUnits.fold<int>(0, (s, n) => s + n) % colors.length];
}

String _month(int m) => const [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December'][m - 1];

class _MiniTotal extends StatelessWidget {
  final String title;
  final int cents;
  final Color color;
  final IconData icon;
  const _MiniTotal(this.title, this.cents, this.color, this.icon);
  @override
  Widget build(BuildContext context) => Row(children: [
    Icon(icon, color: color), const SizedBox(width: 7),
    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
      children: [Text(title, style: const TextStyle(color: Colors.black54)),
        FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft,
          child: Text(money(cents), style: TextStyle(color: color, fontWeight: FontWeight.bold)))])),
  ]);
}

class DonutPainter extends CustomPainter {
  final Map<String, int> totals;
  DonutPainter(this.totals);
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 12;
    final paint = Paint()..style = PaintingStyle.stroke..strokeWidth = 19;
    canvas.drawCircle(center, radius, paint..color = const Color(0xFFE8ECF0));
    final sum = totals.values.fold<int>(0, (s, v) => s + v);
    if (sum == 0) return;
    var angle = -math.pi / 2;
    for (final e in totals.entries) {
      final sweep = 2 * math.pi * e.value / sum;
      paint.color = categoryColor(e.key);
      canvas.drawArc(Rect.fromCircle(center: center, radius: radius),
        angle, sweep, false, paint);
      angle += sweep;
    }
  }
  @override
  bool shouldRepaint(covariant DonutPainter old) => true;
}

class EntryEditor extends StatefulWidget {
  final MoneyEntry? entry;
  final String initialType;
  const EntryEditor({super.key, this.entry, required this.initialType});
  @override
  State<EntryEditor> createState() => _EntryEditorState();
}
class _EntryEditorState extends State<EntryEditor> {
  final formKey = GlobalKey<FormState>();
  final amount = TextEditingController();
  final note = TextEditingController();
  late String type, category, account;
  late DateTime date;
  bool saving = false;
  @override
  void initState() {
    super.initState();
    type = widget.entry?.type ?? widget.initialType;
    category = widget.entry?.category ?? (type == 'income' ? incomes.first : expenses.first);
    account = widget.entry?.account ?? 'Cash';
    date = widget.entry?.date ?? DateTime.now();
    final val = widget.entry?.cents;
    if (val != null) amount.text = (val / 100).toStringAsFixed(2);
    note.text = widget.entry?.note ?? '';
  }
  @override
  void dispose() { amount.dispose(); note.dispose(); super.dispose(); }
  Future<void> save() async {
    if (!(formKey.currentState?.validate() ?? false) || saving) return;
    final number = double.tryParse(amount.text.trim());
    if (number == null || !number.isFinite || number <= 0 || number > 100000000000) return;
    setState(() => saving = true);
    try {
      final cents = (number * 100).round();
      await MoneyDatabase.instance.save(MoneyEntry(
        id: widget.entry?.id, cents: cents, type: type, category: category,
        account: account, note: note.text.trim(), date: date));
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to save: $e')));
    } finally { if (mounted) setState(() => saving = false); }
  }
  Future<void> remove() async {
    final confirmed = await showDialog<bool>(context: context,
      builder: (ctx) => AlertDialog(title: const Text('Delete transaction?'),
        content: const Text('This action cannot be undone.'), actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ]));
    if (confirmed == true && widget.entry?.id != null) {
      await MoneyDatabase.instance.delete(widget.entry!.id!);
      if (mounted) Navigator.pop(context, true);
    }
  }
  @override
  Widget build(BuildContext context) {
    final options = type == 'income' ? incomes : expenses;
    return Padding(padding: EdgeInsets.fromLTRB(20, 12, 20,
      MediaQuery.of(context).viewInsets.bottom + 24),
      child: SingleChildScrollView(child: Form(key: formKey, child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.entry == null ? 'Add transaction' : 'Edit transaction',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          SegmentedButton<String>(segments: const [
            ButtonSegment(value: 'expense', label: Text('Expense'), icon: Icon(Icons.remove)),
            ButtonSegment(value: 'income', label: Text('Income'), icon: Icon(Icons.add))],
            selected: {type}, onSelectionChanged: (newType) => setState(() {
              type = newType.first;
              category = type == 'income' ? incomes.first : expenses.first;
            })),
          const SizedBox(height: 14),
          TextFormField(controller: amount, autofocus: widget.entry == null,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            decoration: const InputDecoration(labelText: 'Amount (LKR)'),
            validator: (v) {
              final number = double.tryParse(v ?? '');
              if (number == null || !number.isFinite || number <= 0 || number > 100000000000)
                return 'Enter a valid positive amount';
              return null;
            }),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(value: options.contains(category) ? category : options.first,
            decoration: const InputDecoration(labelText: 'Category'),
            items: options.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
            onChanged: (v) => setState(() => category = v ?? options.first)),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(value: accounts.contains(account) ? account : accounts.first,
            decoration: const InputDecoration(labelText: 'Account'),
            items: accounts.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
            onChanged: (v) => setState(() => account = v ?? accounts.first)),
          const SizedBox(height: 12),
          TextFormField(controller: note, maxLength: 120,
            decoration: const InputDecoration(labelText: 'Note (optional)')),
          OutlinedButton.icon(icon: const Icon(Icons.calendar_month),
            label: Text('${date.day}/${date.month}/${date.year}'),
            onPressed: () async {
              final d = await showDatePicker(context: context, initialDate: date,
                firstDate: DateTime(2000), lastDate: DateTime(2100));
              if (d != null) setState(() => date = d);
            }),
          const SizedBox(height: 12),
          FilledButton(onPressed: saving ? null : save,
            child: Text(saving ? 'Saving...' : 'Save transaction')),
          if (widget.entry != null) TextButton.icon(onPressed: remove,
            icon: const Icon(Icons.delete_outline, color: red),
            label: const Text('Delete', style: TextStyle(color: red))),
        ],
      ))));
  }
}

class SettingsPage extends StatefulWidget {
  final Future<void> Function() onRestore;
  const SettingsPage({super.key, required this.onRestore});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool busy = false;
  bool pinEnabled = false;
  bool autoLocal = false;
  @override
  void initState() { super.initState(); _init(); }
  Future<void> _init() async {
    final pin = await vault.read(key: 'app-pin');
    final backup = await vault.read(key: 'auto-local-enabled');
    if (mounted) setState(() {
      pinEnabled = pin != null;
      autoLocal = backup == 'yes';
    });
  }
  void msg(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)));
  }
  Future<String?> askPassword(String title, {bool confirm = false}) async {
    final controller = TextEditingController();
    final second = TextEditingController();
    final result = await showDialog<String>(context: context, builder: (ctx) =>
      AlertDialog(title: Text(title), content: Column(
        mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: controller, obscureText: true,
            decoration: const InputDecoration(labelText: 'Backup password (10+ characters)')),
          if (confirm) ...[
            const SizedBox(height: 8),
            TextField(controller: second, obscureText: true,
              decoration: const InputDecoration(labelText: 'Confirm password')),
          ],
        ]), actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () {
            if (controller.text.length < 10 ||
              (confirm && controller.text != second.text)) return;
            Navigator.pop(ctx, controller.text);
          }, child: const Text('Continue')),
        ]));
    // Don't persist typed backup passwords unless the user enables local backup.
    // Dialog controllers are intentionally scoped to this one operation.
    return result;
  }
  Future<void> emailBackup() async {
    final password = await askPassword('Encrypt backup', confirm: true);
    if (password == null) return;
    setState(() => busy = true);
    try {
      final json = await MoneyDatabase.instance.backupJson();
      final file = await BackupTools.encryptedFile(json, password);
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path)], subject: 'MyMoney encrypted backup',
        text: 'Encrypted MyMoney backup. Keep the backup password separate and private.'));
      msg('Choose Gmail and send the attached backup to your own address.');
    } catch (e) {
      msg('Backup failed: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
  Future<void> restore() async {
    final pass = await askPassword('Restore encrypted backup');
    if (pass == null) return;
    final file = await FilePicker.pickFile(type: FileType.custom,
      allowedExtensions: ['mymoney']);
    if (file == null || !mounted) return;
    final yes = await showDialog<bool>(context: context, builder: (ctx) =>
      AlertDialog(title: const Text('Replace all transactions?'),
        content: const Text('Restoring replaces all current records. '
          'Before restoring, email yourself a backup of the current records.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Replace & restore')),
        ]));
    if (yes != true) return;
    setState(() => busy = true);
    try {
      final bytes = await file.readAsBytes();
      final tmp = await getTemporaryDirectory();
      final path = File('${tmp.path}/restore-import.mymoney');
      await path.writeAsBytes(bytes, flush: true);
      await BackupTools.restore(path, pass);
      await widget.onRestore();
      msg('Backup successfully restored.');
    } catch (e) {
      msg('Restore failed. Check your password and backup file. ($e)');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
  Future<void> togglePin(bool enable) async {
    if (!enable) {
      final existing = await vault.read(key: 'app-pin');
      final typed = await _askPin('Enter existing PIN to disable lock');
      if (typed == null || typed != existing) { msg('Incorrect PIN'); return; }
      await vault.delete(key: 'app-pin');
    } else {
      final typed = await _askPin('Set a 4–8 digit PIN');
      if (typed == null || !RegExp(r'^\d{4,8}$').hasMatch(typed)) {
        msg('PIN must contain 4–8 digits'); return;
      }
      await vault.write(key: 'app-pin', value: typed);
    }
    if (mounted) setState(() => pinEnabled = enable);
  }
  Future<String?> _askPin(String title) async {
    final input = TextEditingController();
    final result = await showDialog<String>(context: context,
      builder: (ctx) => AlertDialog(title: Text(title),
        content: TextField(controller: input, obscureText: true,
          maxLength: 8, keyboardType: TextInputType.number),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, input.text),
            child: const Text('Confirm')),
        ]));
    return result;
  }
  Future<void> toggleAuto(bool enable) async {
    if (enable) {
      final pass = await askPassword('Password for local automatic copies', confirm: true);
      if (pass == null) return;
      // Saved using Android Keystore-backed encrypted storage.
      // This is a local convenience copy, NOT email delivery.
      await vault.write(key: 'auto-local-password', value: pass);
      await vault.write(key: 'auto-local-enabled', value: 'yes');
      try {
        await BackupTools.savePrivateLocalCopy(pass);
      } catch (e) {
        msg('Local backup failed: $e'); return;
      }
    } else {
      await vault.delete(key: 'auto-local-password');
      await vault.delete(key: 'auto-local-enabled');
    }
    if (mounted) setState(() => autoLocal = enable);
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings & Backup')),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      const Text('BACKUP', style: TextStyle(fontSize: 15, color: emerald,
        fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Card(child: Column(children: [
        ListTile(enabled: !busy, leading: const Icon(Icons.mail_outline),
          title: const Text('Email encrypted backup'),
          subtitle: const Text('Creates an encrypted file and opens Gmail/share sheet.'),
          trailing: const Icon(Icons.chevron_right), onTap: emailBackup),
        const Divider(height: 1),
        ListTile(enabled: !busy, leading: const Icon(Icons.restore),
          title: const Text('Restore encrypted backup'),
          subtitle: const Text('Import .mymoney file received by email.'),
          trailing: const Icon(Icons.chevron_right), onTap: restore),
        const Divider(height: 1),
        SwitchListTile(value: autoLocal, onChanged: busy ? null : toggleAuto,
          title: const Text('Automatic local backup'),
          subtitle: const Text('Encrypted local copy, refreshed when you use the app. Not automatic email.')),
      ])),
      const SizedBox(height: 22),
      const Text('SECURITY', style: TextStyle(fontSize: 15, color: emerald,
        fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Card(child: SwitchListTile(title: const Text('Require app PIN'),
        subtitle: const Text('Allows fingerprint unlock where available.'),
        value: pinEnabled, onChanged: busy ? null : togglePin)),
      const SizedBox(height: 20),
      const Card(child: Padding(padding: EdgeInsets.all(16), child: Text(
        'Privacy: Records stay in your phone’s app database. Backup files are '
        'encrypted with your chosen password. Keep the password safe: we '
        'cannot recover an encrypted backup without it. Automatic Gmail '
        'email delivery is not included in this first version.'))),
      if (busy) const Center(child: Padding(padding: EdgeInsets.all(10),
        child: CircularProgressIndicator())),
    ]),
  );
}
