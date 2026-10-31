import 'dart:math' as math;
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

import 'backup_delivery.dart';
import 'cloud_sync.dart';
import 'data.dart';

const emerald = Color(0xFF11A676);
const red = Color(0xFFE15C6B);
const mintBackground = Color(0xFFF0FFF5);
const headerGreen = Color(0xFF55A978);
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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await CloudSyncService.instance.initialize();
  runApp(const MyMoneyApp());
}

class MyMoneyApp extends StatelessWidget {
  const MyMoneyApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'My Money',
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: emerald),
      scaffoldBackgroundColor: mintBackground,
      appBarTheme: const AppBarTheme(
        backgroundColor: headerGreen,
        foregroundColor: Colors.white,
        iconTheme: IconThemeData(color: Colors.white),
      ),
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
    if (state == AppLifecycleState.resumed) {
      CloudSyncService.instance.onResume();
    }
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
        localizedReason: 'Unlock your My Money records', biometricOnly: true);
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
          const Text('Unlock My Money', style: TextStyle(fontSize: 27, fontWeight: FontWeight.bold)),
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
  List<String> customAccounts = [];
  DateTime selected = DateTime(DateTime.now().year, DateTime.now().month);
  bool loading = true;
  String accountFilter = 'All';

  @override
  void initState() {
    super.initState();
    _lastCompletedSync = CloudSyncService.instance.completedSyncs;
    CloudSyncService.instance.addListener(_onSyncChanged);
    reload();
  }
  int _lastCompletedSync = 0;

  void _onSyncChanged() {
    final completed = CloudSyncService.instance.completedSyncs;
    if (completed == _lastCompletedSync) return;
    _lastCompletedSync = completed;
    reload();
  }

  @override
  void dispose() {
    CloudSyncService.instance.removeListener(_onSyncChanged);
    super.dispose();
  }

  Future<void> reload() async {
    final database = MoneyDatabase.instance;
    final data = await database.list();
    final savedAccounts = await database.catalogNames('account');
    if (mounted) setState(() {
      all = data;
      customAccounts = savedAccounts;
      if (accountFilter != 'All' &&
          ![...accounts, ...customAccounts].contains(accountFilter)) {
        accountFilter = 'All';
      }
      loading = false;
    });
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
    final database = MoneyDatabase.instance;
    await database.ensureDefaultCategories(expenses, incomes);
    final catalog = await Future.wait([
      database.catalogNames('account'),
      database.catalogNames('expense_category'),
      database.catalogNames('income_category'),
    ]);
    final changed = await showModalBottomSheet<bool>(
      context: context, isScrollControlled: true, showDragHandle: true,
      builder: (ctx) => EntryEditor(entry: entry, initialType: type,
        extraAccounts: catalog[0], extraExpenses: catalog[1],
        extraIncomes: catalog[2]));
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
      appBar: AppBar(
        toolbarHeight: 68,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('My Money', style: TextStyle(
              fontWeight: FontWeight.w800, fontSize: 21, height: 1.1)),
            Text(accountFilter == 'All' ? 'All accounts' : accountFilter,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400)),
          ],
        ),
        actions: [
          AnimatedBuilder(animation: CloudSyncService.instance, builder: (context, _) {
            final sync = CloudSyncService.instance;
            return IconButton(
              tooltip: sync.status.label,
              onPressed: sync.status == SyncStatus.syncing ? null : sync.syncNow,
              icon: Icon(switch (sync.status) {
                SyncStatus.offline => Icons.cloud_off_outlined,
                SyncStatus.pending => Icons.cloud_upload_outlined,
                SyncStatus.syncing => Icons.sync,
                SyncStatus.synced => Icons.cloud_done_outlined,
              }),
            );
          }),
          IconButton(tooltip: 'Settings and backups',
            onPressed: settings, icon: const Icon(Icons.settings_outlined)),
        ]),
      body: loading ? const Center(child: CircularProgressIndicator()) :
        RefreshIndicator(onRefresh: reload, child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28), children: [
            Row(children: [
              IconButton(
                tooltip: 'Previous month',
                onPressed: () => changeMonth(-1),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(child: Center(child: Text(
                '${_month(selected.month)} ${selected.year}',
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17),
              ))),
              PopupMenuButton<String>(
                tooltip: 'Filter by account',
                initialValue: accountFilter,
                onSelected: (value) => setState(() => accountFilter = value),
                itemBuilder: (context) => ['All', ...accounts, ...customAccounts]
                    .toSet().map((account) => PopupMenuItem(
                      value: account,
                      child: Text(account == 'All' ? 'All accounts' : account),
                    )).toList(),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(190),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 130),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.filter_list, size: 18),
                      const SizedBox(width: 4),
                      Flexible(child: Text(
                        accountFilter == 'All' ? 'All' : accountFilter,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600),
                      )),
                    ]),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Next month',
                onPressed: () => changeMonth(1),
                icon: const Icon(Icons.chevron_right),
              ),
            ]),
            const SizedBox(height: 4),
            SizedBox(
              height: 236,
              child: Center(child: CustomPaint(
                painter: DonutPainter(groups),
                size: const Size(216, 216),
                child: SizedBox(width: 216, height: 216, child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('MONTHLY FLOW', style: TextStyle(
                      fontSize: 9, letterSpacing: 1, color: Colors.black54,
                      fontWeight: FontWeight.w700)),
                    const SizedBox(height: 7),
                    FittedBox(fit: BoxFit.scaleDown, child: Text(
                      '+${money(earned)}', style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700, color: emerald))),
                    const SizedBox(height: 2),
                    FittedBox(fit: BoxFit.scaleDown, child: Text(
                      '-${money(spent)}', style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600, color: red))),
                  ],
                )),
              )),
            ),
            if (groups.isEmpty)
              const Center(child: Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text('Add an expense to see your categories.',
                  style: TextStyle(color: Colors.black54, fontSize: 12)),
              ))
            else
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: groups.entries.map((entry) {
                    final percentage = spent == 0 ? 0 :
                        (entry.value * 100 / spent).round();
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.white.withAlpha(190),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(icons[entry.key] ?? Icons.category,
                          size: 15, color: categoryColor(entry.key)),
                        const SizedBox(width: 5),
                        Text('${entry.key} $percentage%',
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                      ]),
                    );
                  }).toList(),
                ),
              ),
            Container(
              height: 48,
              decoration: BoxDecoration(
                color: headerGreen,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.account_balance_wallet_outlined,
                  size: 18, color: Colors.white),
                const SizedBox(width: 8),
                const Text('Balance', style: TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600)),
                const SizedBox(width: 10),
                Flexible(child: FittedBox(fit: BoxFit.scaleDown,
                  child: Text(money(balance), style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)))),
              ]),
            ),
            const SizedBox(height: 18),
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              _FlowAction(
                label: 'Expense',
                icon: Icons.remove,
                color: red,
                onPressed: () => openEditor(),
              ),
              _FlowAction(
                label: 'Income',
                icon: Icons.add,
                color: emerald,
                onPressed: () => openEditor(type: 'income'),
              ),
            ]),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const Text('Recent transactions',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              Text('${current.length} records',
                style: const TextStyle(color: Colors.black54, fontSize: 12)),
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
    );
  }
}

class _FlowAction extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;
  const _FlowAction({
    required this.label,
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Add $label',
    child: InkWell(
      onTap: onPressed,
      customBorder: const CircleBorder(),
      child: SizedBox(
        width: 100,
        child: Column(children: [
          Container(
            width: 78,
            height: 78,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withAlpha(150),
              border: Border.all(color: color.withAlpha(190), width: 3),
            ),
            child: Icon(icon, size: 36, color: color),
          ),
          const SizedBox(height: 5),
          Text(label, style: TextStyle(
            color: color, fontWeight: FontWeight.w700, fontSize: 12)),
        ]),
      ),
    ),
  );
}

Color categoryColor(String c) {
  final index = expenses.indexOf(c);
  if (index >= 0) return colors[index % colors.length];
  return colors[c.codeUnits.fold<int>(0, (s, n) => s + n) % colors.length];
}

String _month(int m) => const [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December'][m - 1];

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
  final List<String> extraAccounts;
  final List<String> extraExpenses;
  final List<String> extraIncomes;
  const EntryEditor({super.key, this.entry, required this.initialType,
    this.extraAccounts = const [], this.extraExpenses = const [],
    this.extraIncomes = const []});
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
  List<String> get accountOptions {
    final result = [...accounts, ...widget.extraAccounts];
    if (widget.entry != null && !result.contains(widget.entry!.account)) {
      result.add(widget.entry!.account);
    }
    return result.toSet().toList();
  }
  List<String> get categoryOptions {
    final result = type == 'income'
        ? [...widget.extraIncomes]
        : [...widget.extraExpenses];
    if (widget.entry != null && widget.entry!.type == type &&
        !result.contains(widget.entry!.category)) {
      result.add(widget.entry!.category);
    }
    return result.toSet().toList();
  }
  @override
  void initState() {
    super.initState();
    type = widget.entry?.type ?? widget.initialType;
    category = widget.entry?.category ??
        (type == 'income' ? widget.extraIncomes.first : widget.extraExpenses.first);
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
        id: widget.entry?.id, cloudId: widget.entry?.cloudId,
        cents: cents, type: type, category: category,
        account: account, note: note.text.trim(), date: date));
      await CloudSyncService.instance.localChanged();
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
      await CloudSyncService.instance.localChanged();
      if (mounted) Navigator.pop(context, true);
    }
  }
  @override
  Widget build(BuildContext context) {
    final options = categoryOptions;
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
              category = type == 'income'
                  ? widget.extraIncomes.first : widget.extraExpenses.first;
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
          DropdownButtonFormField<String>(value: accountOptions.contains(account) ? account : accountOptions.first,
            decoration: const InputDecoration(labelText: 'Account'),
            items: accountOptions.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
            onChanged: (v) => setState(() => account = v ?? accountOptions.first)),
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
      final encrypted = await BackupTools.encryptedText(json, password);
      final filename = 'My-Money-${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}.mymoney';
      if (kIsWeb) {
        await downloadEncryptedBackup(filename: filename, contents: encrypted);
        if (!mounted) return;
        final openEmail = await showDialog<bool>(context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Encrypted backup downloaded'),
            content: const Text(
              'Your .mymoney file is saved in Downloads. Attach it to the email '
              'draft; the browser cannot attach files automatically. Keep the '
              'backup password separate and private.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Close')),
              FilledButton.icon(
                onPressed: () {
                  openBackupEmailDraft();
                  Navigator.pop(ctx, true);
                },
                icon: const Icon(Icons.email_outlined),
                label: const Text('Open email'),
              ),
            ],
          ));
        if (openEmail == true) {
          openBackupEmailDraft();
          msg('Attach the downloaded .mymoney file before sending.');
        }
      } else {
        await shareEncryptedBackup(filename: filename, contents: encrypted);
        msg('Choose Gmail and send the attached backup to your own address.');
      }
    } catch (e) {
      msg('Backup failed: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
  Future<void> restore() async {
    final pass = await askPassword('Restore encrypted backup');
    if (pass == null) return;
    final files = await FilePicker.pickFiles(type: FileType.custom,
      allowedExtensions: ['mymoney']);
    if (files.isEmpty || !mounted) return;
    final yes = await showDialog<bool>(context: context, builder: (ctx) =>
      AlertDialog(title: const Text('Merge backup records?'),
        content: const Text('Backup records are added without clearing existing '
          'transactions, accounts, or categories. Keep a separate backup too.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Merge & restore')),
        ]));
    if (yes != true) return;
    setState(() => busy = true);
    try {
      final bytes = await files.single.readAsBytes();
      await BackupTools.restoreText(utf8.decode(bytes), pass);
      await CloudSyncService.instance.localChanged();
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
  Future<void> signIn() async {
    setState(() => busy = true);
    try {
      await CloudSyncService.instance.signInWithGoogle();
      await widget.onRestore();
      final sync = CloudSyncService.instance;
      msg(sync.status == SyncStatus.synced
          ? 'Google account connected. All changes are synced.'
          : 'Google account connected · ${sync.status.label}'
            '${sync.errorMessage == null ? '' : ': ${sync.errorMessage}'}');
    } catch (e) {
      msg('Google sign-in or sync failed: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
  Future<void> manageCatalog(String kind, String title) async {
    final name = TextEditingController();
    final database = MoneyDatabase.instance;
    if (kind == 'expense_category' || kind == 'income_category') {
      await database.ensureDefaultCategories(expenses, incomes);
    }
    var items = await database.catalogItems(kind);
    if (!mounted) return;
    await showDialog<void>(context: context, builder: (dialogContext) =>
      StatefulBuilder(builder: (context, setDialogState) => AlertDialog(
        title: Text(title),
        content: SizedBox(width: 420, child: Column(
          mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Expanded(child: TextField(controller: name, maxLength: 32,
                decoration: const InputDecoration(hintText: 'Name'))),
              IconButton(tooltip: 'Add', icon: const Icon(Icons.add_circle),
                onPressed: () async {
                  try {
                    await database.saveCatalogItem(kind, name.text);
                    name.clear();
                    items = await database.catalogItems(kind);
                    setDialogState(() {});
                    await CloudSyncService.instance.localChanged();
                  } catch (e) { msg('Could not add item: $e'); }
                }),
            ]),
            const SizedBox(height: 8),
            SizedBox(height: 250, child: items.isEmpty
              ? const Center(child: Text('No items yet.'))
              : ListView.separated(itemCount: items.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final item = items[index];
                  final id = item['id'] as String;
                  final itemName = item['name'] as String;
                  return ListTile(dense: true, title: Text(itemName),
                    trailing: Wrap(children: [
                      IconButton(tooltip: 'Rename', icon: const Icon(Icons.edit_outlined),
                        onPressed: () async {
                          final controller = TextEditingController(text: itemName);
                          final renamed = await showDialog<String>(context: context,
                            builder: (ctx) => AlertDialog(title: const Text('Rename'),
                              content: TextField(controller: controller, autofocus: true),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(ctx),
                                  child: const Text('Cancel')),
                                FilledButton(onPressed: () => Navigator.pop(ctx, controller.text),
                                  child: const Text('Save')),
                              ]));
                          if (renamed == null) return;
                          try {
                            await database.saveCatalogItem(kind, renamed, id: id);
                            items = await database.catalogItems(kind);
                            setDialogState(() {});
                            await CloudSyncService.instance.localChanged();
                          } catch (e) { msg('Could not rename item: $e'); }
                        }),
                      IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline, color: red),
                        onPressed: () async {
                          try {
                            String? replacementId;
                            if (kind == 'expense_category' ||
                                kind == 'income_category') {
                              final replacements = items.where(
                                (candidate) => candidate['id'] != id).toList();
                              if (replacements.isEmpty) return;
                              replacementId = await showDialog<String>(
                                context: context,
                                builder: (ctx) {
                                  var selectedId =
                                      replacements.first['id'] as String;
                                  return StatefulBuilder(
                                    builder: (ctx, setChoiceState) =>
                                      AlertDialog(
                                        title: const Text('Move transactions'),
                                        content: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              'Choose a category for existing '
                                              '${kind == 'expense_category' ? 'expenses' : 'income'} '
                                              'in "$itemName". Then the old category will be deleted.',
                                            ),
                                            const SizedBox(height: 12),
                                            DropdownButtonFormField<String>(
                                              value: selectedId,
                                              items: [
                                                for (final replacement
                                                    in replacements)
                                                  DropdownMenuItem(
                                                    value: replacement['id']
                                                        as String,
                                                    child: Text(replacement[
                                                        'name'] as String),
                                                  ),
                                              ],
                                              onChanged: (value) {
                                                if (value != null) {
                                                  setChoiceState(() =>
                                                      selectedId = value);
                                                }
                                              },
                                            ),
                                          ],
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(ctx),
                                            child: const Text('Cancel'),
                                          ),
                                          FilledButton(
                                            onPressed: () =>
                                                Navigator.pop(ctx, selectedId),
                                            child: const Text('Move & delete'),
                                          ),
                                        ],
                                      ),
                                  );
                                },
                              );
                              if (replacementId == null) return;
                            }
                            await database.deleteCatalogItem(kind, id,
                              replacementId: replacementId);
                            items = await database.catalogItems(kind);
                            setDialogState(() {});
                            await CloudSyncService.instance.localChanged();
                          } catch (e) { msg('Could not delete item: $e'); }
                        }),
                    ]));
                })),
          ])),
        actions: [TextButton(onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Done'))],
      )));
    name.dispose();
  }
  Future<void> signOut() async {
    setState(() => busy = true);
    try {
      await CloudSyncService.instance.signOut();
      msg('Signed out. Your local records remain on this device.');
    } catch (e) {
      msg('Unable to sign out: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
  Future<void> syncNow() async {
    setState(() => busy = true);
    try {
      await CloudSyncService.instance.syncNow();
      await widget.onRestore();
      final sync = CloudSyncService.instance;
      msg(sync.status == SyncStatus.synced
          ? 'All changes are synced.' : sync.errorMessage ?? sync.status.label);
    } catch (e) {
      msg('Sync failed: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings & Backup')),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      const Text('CLOUD SYNC', style: TextStyle(fontSize: 15, color: emerald,
        fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Card(child: AnimatedBuilder(animation: CloudSyncService.instance,
        builder: (context, _) {
          final sync = CloudSyncService.instance;
          final signedInUser = sync.user;
          return Column(children: [
            ListTile(leading: Icon(signedInUser == null
                ? Icons.account_circle_outlined : Icons.verified_user_outlined),
              title: Text(signedInUser?.email ?? 'Google account'),
                subtitle: Text(sync.errorMessage ??
                  (signedInUser == null
                    ? 'Sign in with the same Google account on each device to sync your data.'
                    : 'Same-account sync · ${sync.status.label}')),
              trailing: const Icon(Icons.chevron_right),
              enabled: !busy,
              onTap: signedInUser == null ? signIn : signOut),
            const Divider(height: 1),
            ListTile(enabled: !busy, leading: const Icon(Icons.sync),
              title: const Text('Sync now'),
              subtitle: const Text('Wait for the status to show Synced.'),
              trailing: const Icon(Icons.chevron_right), onTap: syncNow),
          ]);
        })),
      const SizedBox(height: 22),
      const Text('ACCOUNTS & CATEGORIES', style: TextStyle(fontSize: 15, color: emerald,
        fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Card(child: Column(children: [
        for (final item in const [
          ('account', 'Manage custom accounts'),
          ('expense_category', 'Manage expense categories'),
          ('income_category', 'Manage income categories'),
        ])
          ListTile(leading: const Icon(Icons.tune),
            title: Text(item.$2), trailing: const Icon(Icons.chevron_right),
            onTap: busy ? null : () => manageCatalog(item.$1, item.$2)),
      ])),
      const SizedBox(height: 22),
      const Text('BACKUP', style: TextStyle(fontSize: 15, color: emerald,
        fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Card(child: Column(children: [
        ListTile(enabled: !busy, leading: const Icon(Icons.mail_outline),
          title: const Text('Email encrypted backup'),
          subtitle: Text(kIsWeb
            ? 'Downloads an encrypted file and opens an email draft. Attach the file before sending.'
            : 'Creates an encrypted file and opens the share sheet. Choose Gmail to send it.'),
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
