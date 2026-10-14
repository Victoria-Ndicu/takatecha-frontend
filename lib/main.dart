// Taka Techa EcoPoints - Flutter (Android) recycler app.
// Flow: Splash -> Login / Sign up -> Link bin (scan bin QR) -> Scan bottle
//       -> Result -> Rewards (mock) -> Wallet.
// Backend: Oracle ORDS REST APIs on Autonomous Database (see ApiService).
// Leave ApiService.baseUrl empty to run in DEMO mode with no backend.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';

void main() => runApp(const TakaTechaApp());

// ---------------------------------------------------------------------------
// Brand (taken from the logo)
// ---------------------------------------------------------------------------
class Brand {
  static const black = Color(0xFF000000); // matches the logo background
  static const surface = Color(0xFF141B13);
  static const line = Color(0xFF263224);
  static const green = Color(0xFF5DB946); // bin green: buttons
  static const lime = Color(0xFF9BD443); // lettering: points, highlights
  static const sky = Color(0xFF9DB7EC); // promo badge, scan line
  static const text = Color(0xFFF1F6EC);
  static const muted = Color(0xFF9FAE9A);
  static const logo = 'assets/logo.png';
}

TextStyle head(double size, {Color color = Brand.text}) => GoogleFonts.chakraPetch(
      fontSize: size,
      fontWeight: FontWeight.w700,
      color: color,
    );

// Kenyan mobile numbers: 07xx, 01xx, +2547xx, 2547xx
final phoneRe = RegExp(r'^(\+254|254|0)[17]\d{8}$');

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------
class ScanResult {
  ScanResult({
    required this.points,
    required this.brand,
    required this.product,
    required this.message,
    required this.balance,
    this.promoLabel,
  });

  final int points;
  final String brand;
  final String product;
  final String message;
  final int balance;
  final String? promoLabel;

  bool get recognised => message == 'OK';

  // Expected ORDS JSON: {"points":2,"brand":"..","product":"..","message":"OK",
  //                      "balance":128,"promo":"2x partner promo"}
  factory ScanResult.fromJson(Map<String, dynamic> j) => ScanResult(
        points: (j['points'] ?? 0) as int,
        brand: (j['brand'] ?? '') as String,
        product: (j['product'] ?? 'PET bottle') as String,
        message: (j['message'] ?? '') as String,
        balance: (j['balance'] ?? 0) as int,
        promoLabel: j['promo'] as String?,
      );
}

/// One line in the wallet history: positive = earned, negative = redeemed.
class LedgerEntry {
  LedgerEntry(this.title, this.time, this.points);
  final String title;
  final DateTime time;
  final int points;
}

enum RewardKind { airtime, data, voucher }

class Reward {
  const Reward(this.id, this.kind, this.provider, this.title, this.cost, this.color);
  final String id;
  final RewardKind kind;
  final String provider;
  final String title;
  final int cost;
  final Color color;
}

class RedeemResult {
  RedeemResult(this.balance, this.message);
  final int balance;
  final String message;
}

// MOCK rewards for the hackathon demo. Costs are placeholders.
const rewards = <Reward>[
  Reward('AIR-SAF-20', RewardKind.airtime, 'Safaricom', 'Airtime KES 20', 40, Color(0xFF5DB946)),
  Reward('AIR-SAF-50', RewardKind.airtime, 'Safaricom', 'Airtime KES 50', 100, Color(0xFF5DB946)),
  Reward('AIR-AIR-20', RewardKind.airtime, 'Airtel', 'Airtime KES 20', 40, Color(0xFFEF5350)),
  Reward('AIR-TEL-20', RewardKind.airtime, 'Telkom', 'Airtime KES 20', 40, Color(0xFF42A5F5)),
  Reward('DAT-SAF-250', RewardKind.data, 'Safaricom', '250 MB data bundle', 60, Color(0xFF5DB946)),
  Reward('DAT-AIR-250', RewardKind.data, 'Airtel', '250 MB data bundle', 60, Color(0xFFEF5350)),
  Reward('DAT-TEL-250', RewardKind.data, 'Telkom', '250 MB data bundle', 60, Color(0xFF42A5F5)),
  Reward('VCH-NAI-100', RewardKind.voucher, 'Naivas', 'Supermarket voucher KES 100', 200, Color(0xFFFFCA28)),
  Reward('VCH-QUI-100', RewardKind.voucher, 'Quickmart', 'Supermarket voucher KES 100', 200, Color(0xFFFFA726)),
  Reward('VCH-CAR-100', RewardKind.voucher, 'Carrefour', 'Supermarket voucher KES 100', 200, Color(0xFF64B5F6)),
];

// ---------------------------------------------------------------------------
// Session state
// ---------------------------------------------------------------------------
class Session {
  /// Value used when the user skips linking a bin.
  static const noBin = 'NO-BIN';

  static final balance = ValueNotifier<int>(0);
  static final history = ValueNotifier<List<LedgerEntry>>([]);
  static final bin = ValueNotifier<String?>(null); // null = not linked yet
  static String userName = '';
  static String userPhone = '';

  static void recordScan(ScanResult r) {
    balance.value = r.balance;
    if (r.recognised) {
      history.value = [
        LedgerEntry(r.product.isEmpty ? 'PET bottle' : r.product, DateTime.now(), r.points),
        ...history.value,
      ];
    }
  }

  static void recordRedeem(Reward rw, int newBalance) {
    balance.value = newBalance;
    history.value = [
      LedgerEntry('Redeemed: ${rw.provider} ${rw.title}', DateTime.now(), -rw.cost),
      ...history.value,
    ];
  }

  static void reset() {
    balance.value = 0;
    history.value = [];
    bin.value = null;
    userName = '';
    userPhone = '';
    ApiService.token = null;
  }
}

// ---------------------------------------------------------------------------
// Backend: Oracle ORDS (Autonomous Database)
// ---------------------------------------------------------------------------
class ApiService {
  // Example:
  // https://<db-host>.adb.<region>.oraclecloudapps.com/ords/takatecha/api
  static const baseUrl = '';

  static String? token;
  static bool get isDemo => baseUrl.isEmpty;

  static Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  /// POST /login  {"username","password"} -> {"token","name","phone","balance"}
  static Future<bool> login(String username, String password) async {
    if (isDemo) {
      await Future.delayed(const Duration(milliseconds: 500));
      Session.userName = 'Demo user';
      Session.userPhone = phoneRe.hasMatch(username) ? username : '0712345678';
      Session.balance.value = 60; // demo starts with points so rewards can be tried
      return true;
    }
    final r = await http.post(
      Uri.parse('$baseUrl/login'),
      headers: _headers,
      body: jsonEncode({'username': username, 'password': password}),
    );
    if (r.statusCode != 200) return false;
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    token = j['token'] as String?;
    Session.userName = (j['name'] ?? '') as String;
    Session.userPhone = (j['phone'] ?? username) as String;
    Session.balance.value = (j['balance'] ?? 0) as int;
    return token != null;
  }

  /// POST /signup {"name","phone","password","consent","consent_at"}
  ///   -> {"token","name"}   (201 or 200)
  static Future<bool> signup({
    required String name,
    required String phone,
    required String password,
  }) async {
    if (isDemo) {
      await Future.delayed(const Duration(milliseconds: 600));
      Session.userName = name;
      Session.userPhone = phone;
      Session.balance.value = 60;
      return true;
    }
    final r = await http.post(
      Uri.parse('$baseUrl/signup'),
      headers: _headers,
      body: jsonEncode({
        'name': name,
        'phone': phone,
        'password': password,
        'consent': true, // recorded for the Data Protection Act, 2019
        'consent_at': DateTime.now().toUtc().toIso8601String(),
      }),
    );
    if (r.statusCode != 200 && r.statusCode != 201) return false;
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    token = j['token'] as String?;
    Session.userName = (j['name'] ?? name) as String;
    Session.userPhone = phone;
    Session.balance.value = 0;
    return token != null;
  }

  /// POST /scan {"barcode","bin_id"} -> ScanResult JSON
  /// The ORDS handler calls the PL/SQL procedure process_scan.
  static Future<ScanResult> scan(String barcode) async {
    if (isDemo) {
      // Demo rule: barcodes ending in an even digit act like a 2-point partner promo.
      await Future.delayed(const Duration(milliseconds: 500));
      final even = int.tryParse(barcode.substring(barcode.length - 1))?.isEven ?? false;
      final pts = even ? 2 : 1;
      return ScanResult(
        points: pts,
        brand: 'Demo brand',
        product: 'Demo PET bottle, 500 ml',
        message: 'OK',
        balance: Session.balance.value + pts,
        promoLabel: even ? '2x partner promo' : null,
      );
    }
    final bin = Session.bin.value;
    final r = await http.post(
      Uri.parse('$baseUrl/scan'),
      headers: _headers,
      body: jsonEncode({
        'barcode': barcode,
        'bin_id': (bin == null || bin == Session.noBin) ? null : bin,
      }),
    );
    if (r.statusCode != 200) {
      throw Exception('Scan failed (${r.statusCode})');
    }
    return ScanResult.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// POST /redeem {"reward_id","phone"} -> {"balance","message"}
  /// MOCK in the hackathon: no real airtime, data or voucher is issued.
  static Future<RedeemResult> redeem(Reward rw, String phone) async {
    if (isDemo) {
      await Future.delayed(const Duration(milliseconds: 600));
      final newBalance = Session.balance.value - rw.cost;
      final msg = rw.kind == RewardKind.voucher
          ? 'Voucher code: TT-${(DateTime.now().millisecondsSinceEpoch % 1000000).toString().padLeft(6, '0')}'
          : 'Sent to $phone (demo only, nothing was actually sent).';
      return RedeemResult(newBalance, msg);
    }
    final r = await http.post(
      Uri.parse('$baseUrl/redeem'),
      headers: _headers,
      body: jsonEncode({'reward_id': rw.id, 'phone': phone}),
    );
    if (r.statusCode != 200) {
      throw Exception('Redeem failed (${r.statusCode})');
    }
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return RedeemResult((j['balance'] ?? 0) as int, (j['message'] ?? 'Done') as String);
  }
}

// ---------------------------------------------------------------------------
// App + theme
// ---------------------------------------------------------------------------
class TakaTechaApp extends StatelessWidget {
  const TakaTechaApp({super.key});

  @override
  Widget build(BuildContext context) {
    final base = ThemeData.dark(useMaterial3: true);
    return MaterialApp(
      title: 'Taka Techa',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        scaffoldBackgroundColor: Brand.black,
        colorScheme: const ColorScheme.dark(
          primary: Brand.green,
          secondary: Brand.lime,
          surface: Brand.surface,
        ),
        textTheme: GoogleFonts.dmSansTextTheme(base.textTheme)
            .apply(bodyColor: Brand.text, displayColor: Brand.text),
      ),
      home: const SplashScreen(),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared widgets
// ---------------------------------------------------------------------------
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({super.key, required this.label, required this.onPressed, this.busy = false});
  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        height: 52,
        child: FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Brand.green,
            foregroundColor: Brand.black,
            disabledBackgroundColor: Brand.line,
            disabledForegroundColor: Brand.muted,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          onPressed: busy ? null : onPressed,
          child: busy
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 3, color: Brand.black),
                )
              : Text(label),
        ),
      );
}

class OutlineButtonX extends StatelessWidget {
  const OutlineButtonX({super.key, required this.label, required this.onPressed});
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        height: 52,
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: Brand.green, width: 2),
            foregroundColor: Brand.lime,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          onPressed: onPressed,
          child: Text(label),
        ),
      );
}

InputDecoration fieldDecoration(String label, {Widget? suffix, String? hint}) => InputDecoration(
      labelText: label,
      hintText: hint,
      hintStyle: const TextStyle(color: Brand.muted),
      labelStyle: const TextStyle(color: Brand.muted),
      suffixIcon: suffix,
      filled: true,
      fillColor: Brand.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Brand.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Brand.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Brand.lime, width: 2),
      ),
    );

class PasswordField extends StatefulWidget {
  const PasswordField({super.key, required this.controller, required this.label});
  final TextEditingController controller;
  final String label;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _hide = true;

  @override
  Widget build(BuildContext context) => TextField(
        controller: widget.controller,
        obscureText: _hide,
        decoration: fieldDecoration(
          widget.label,
          suffix: IconButton(
            tooltip: _hide ? 'Show password' : 'Hide password',
            icon: Icon(_hide ? Icons.visibility_outlined : Icons.visibility_off_outlined, color: Brand.muted),
            onPressed: () => setState(() => _hide = !_hide),
          ),
        ),
      );
}

void showMessage(BuildContext context, String m) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

/// Corner brackets drawn over a camera preview.
Widget cameraCorner(Alignment a) {
  final top = a.y < 0, left = a.x < 0;
  const side = BorderSide(color: Brand.lime, width: 4);
  return Align(
    alignment: a,
    child: Container(
      margin: const EdgeInsets.all(28),
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        border: Border(
          top: top ? side : BorderSide.none,
          bottom: top ? BorderSide.none : side,
          left: left ? side : BorderSide.none,
          right: left ? BorderSide.none : side,
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// 1. Splash: the logo
// ---------------------------------------------------------------------------
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..forward();
  late final Animation<double> _fade = CurvedAnimation(parent: _c, curve: Curves.easeOut);
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 2400), () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => const LoginScreen(),
          transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
        ),
      );
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    return Scaffold(
      backgroundColor: Brand.black,
      body: Center(
        child: FadeTransition(
          opacity: _fade,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.92, end: 1).animate(_fade),
            child: Image.asset(Brand.logo, width: w * 0.7, fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 2. Login
// ---------------------------------------------------------------------------
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_user.text.trim().isEmpty || _pass.text.isEmpty) {
      showMessage(context, 'Enter your phone number or email and your password.');
      return;
    }
    setState(() => _busy = true);
    try {
      final ok = await ApiService.login(_user.text.trim(), _pass.text);
      if (!mounted) return;
      if (ok) {
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const HomeShell()));
      } else {
        showMessage(context, 'Wrong phone, email or password. Check them and try again.');
      }
    } catch (_) {
      if (mounted) showMessage(context, 'Could not reach the server. Check your connection.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Image.asset(Brand.logo, width: 200, height: 200, fit: BoxFit.cover),
              const SizedBox(height: 12),
              Text('Scan. Recycle. Earn.', style: head(28), textAlign: TextAlign.center),
              const SizedBox(height: 8),
              const Text('Return PET bottles and collect EcoPoints.',
                  style: TextStyle(color: Brand.muted), textAlign: TextAlign.center),
              const SizedBox(height: 28),
              TextField(
                controller: _user,
                keyboardType: TextInputType.emailAddress,
                decoration: fieldDecoration('Phone number or email'),
              ),
              const SizedBox(height: 16),
              PasswordField(controller: _pass, label: 'Password'),
              const SizedBox(height: 24),
              PrimaryButton(label: 'Log in', onPressed: _login, busy: _busy),
              const SizedBox(height: 16),
              OutlineButtonX(
                label: 'Create an account',
                onPressed: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => const SignupScreen())),
              ),
              if (ApiService.isDemo)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: Text('Demo mode: any login works.',
                      style: TextStyle(color: Brand.muted, fontSize: 12)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 3. Sign up (with consent, for the Data Protection Act, 2019)
// ---------------------------------------------------------------------------
class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _pass = TextEditingController();
  final _confirm = TextEditingController();
  bool _consent = false;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _pass.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    final phone = _phone.text.trim();
    if (name.length < 2) return showMessage(context, 'Enter your name.');
    if (!phoneRe.hasMatch(phone)) {
      return showMessage(context, 'Enter a valid Kenyan phone number, like 0712345678.');
    }
    if (_pass.text.length < 8) return showMessage(context, 'Use a password of at least 8 characters.');
    if (_pass.text != _confirm.text) return showMessage(context, 'The two passwords do not match.');
    if (!_consent) return showMessage(context, 'Please agree to the privacy terms to continue.');

    setState(() => _busy = true);
    try {
      final ok = await ApiService.signup(name: name, phone: phone, password: _pass.text);
      if (!mounted) return;
      if (ok) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const HomeShell()),
          (route) => false,
        );
      } else {
        showMessage(context, 'We could not create the account. That phone number may already be in use.');
      }
    } catch (_) {
      if (mounted) showMessage(context, 'Could not reach the server. Check your connection.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showPrivacy() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Brand.surface,
        title: Text('Privacy notice', style: head(20)),
        content: const Text(
          'We collect your name, phone number and recycling activity (scans and points) to run '
          'EcoPoints and to understand what packaging is returned.\n\n'
          'Collection data shown to partners is aggregated and does not name you.\n\n'
          'You can ask us to correct or delete your data at any time. This follows '
          "Kenya's Data Protection Act, 2019.",
          style: TextStyle(color: Brand.muted),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Brand.black,
        foregroundColor: Brand.text,
        elevation: 0,
        title: Text('Create account', style: head(20)),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            children: [
              Image.asset(Brand.logo, width: 96, height: 96, fit: BoxFit.cover),
              const SizedBox(height: 16),
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: fieldDecoration('Full name'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: fieldDecoration('Phone number', hint: '0712345678'),
              ),
              const SizedBox(height: 16),
              PasswordField(controller: _pass, label: 'Password (8+ characters)'),
              const SizedBox(height: 16),
              PasswordField(controller: _confirm, label: 'Confirm password'),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Checkbox(
                    value: _consent,
                    activeColor: Brand.green,
                    checkColor: Brand.black,
                    onChanged: (v) => setState(() => _consent = v ?? false),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text.rich(
                        TextSpan(
                          style: const TextStyle(color: Brand.muted, fontSize: 14),
                          children: [
                            const TextSpan(
                                text: 'I agree that Taka Techa may collect and use my name, phone number '
                                    'and recycling activity to run EcoPoints. '),
                            WidgetSpan(
                              alignment: PlaceholderAlignment.baseline,
                              baseline: TextBaseline.alphabetic,
                              child: GestureDetector(
                                onTap: _showPrivacy,
                                child: const Text('Read the privacy notice',
                                    style: TextStyle(color: Brand.sky, fontSize: 14)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              PrimaryButton(label: 'Create account', onPressed: _submit, busy: _busy),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 4. Home shell with bottom navigation (Scan / Rewards / Wallet)
// ---------------------------------------------------------------------------
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final Widget page;
    switch (_index) {
      case 0:
        // Cameras are only built while the Scan tab is showing.
        page = ScanTab(onViewWallet: () => setState(() => _index = 2));
        break;
      case 1:
        page = const RewardsScreen();
        break;
      default:
        page = const WalletScreen();
    }
    return Scaffold(
      body: SafeArea(child: page),
      bottomNavigationBar: NavigationBar(
        backgroundColor: Brand.black,
        indicatorColor: Brand.surface,
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.qr_code_scanner, color: Brand.muted),
            selectedIcon: Icon(Icons.qr_code_scanner, color: Brand.lime),
            label: 'Scan',
          ),
          NavigationDestination(
            icon: Icon(Icons.card_giftcard_outlined, color: Brand.muted),
            selectedIcon: Icon(Icons.card_giftcard, color: Brand.lime),
            label: 'Rewards',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_balance_wallet_outlined, color: Brand.muted),
            selectedIcon: Icon(Icons.account_balance_wallet, color: Brand.lime),
            label: 'Wallet',
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 5. Scan tab: link a bin (QR), then scan bottles
// ---------------------------------------------------------------------------
class ScanTab extends StatelessWidget {
  const ScanTab({super.key, required this.onViewWallet});
  final VoidCallback onViewWallet;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String?>(
        valueListenable: Session.bin,
        builder: (_, bin, __) =>
            bin == null ? const BinCheckInScreen() : ScanScreen(binId: bin, onViewWallet: onViewWallet),
      );
}

/// Step 1: scan the QR code on the bin. Expected QR text: TT-BIN-<id>
class BinCheckInScreen extends StatefulWidget {
  const BinCheckInScreen({super.key});

  @override
  State<BinCheckInScreen> createState() => _BinCheckInScreenState();
}

class _BinCheckInScreenState extends State<BinCheckInScreen> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onCode(String code) {
    if (_handled) return;
    if (!code.startsWith('TT-BIN-')) {
      showMessage(context, 'That QR code is not a Taka Techa bin.');
      return;
    }
    _handled = true;
    Session.bin.value = code;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Link to a bin', style: head(26)),
          const SizedBox(height: 8),
          const Text('Scan the QR code on the bin to start your session.',
              style: TextStyle(color: Brand.muted)),
          const SizedBox(height: 16),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  MobileScanner(
                    controller: _controller,
                    onDetect: (capture) {
                      if (capture.barcodes.isEmpty) return;
                      final code = capture.barcodes.first.rawValue;
                      if (code != null && code.isNotEmpty) _onCode(code);
                    },
                  ),
                  cameraCorner(Alignment.topLeft),
                  cameraCorner(Alignment.topRight),
                  cameraCorner(Alignment.bottomLeft),
                  cameraCorner(Alignment.bottomRight),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (ApiService.isDemo)
            OutlineButtonX(label: 'Demo: link Bin TT-BIN-001', onPressed: () => Session.bin.value = 'TT-BIN-001'),
          Center(
            child: TextButton(
              onPressed: () => Session.bin.value = Session.noBin,
              child: const Text('Skip, no bin nearby', style: TextStyle(color: Brand.sky)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Step 2: scan the bottle barcode.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key, required this.binId, required this.onViewWallet});
  final String binId;
  final VoidCallback onViewWallet;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.ean13, BarcodeFormat.ean8, BarcodeFormat.upcA, BarcodeFormat.upcE],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _busy = false;
  bool _torch = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _handle(String code) async {
    if (_busy) return;
    _busy = true;
    try {
      await _controller.stop();
      final result = await ApiService.scan(code);
      Session.recordScan(result);
      if (!mounted) return;
      final goWallet = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => ResultScreen(result: result)),
      );
      if (!mounted) return;
      if (goWallet == true) {
        widget.onViewWallet();
        return;
      }
      await _controller.start();
    } catch (_) {
      if (mounted) {
        showMessage(context, 'That scan did not go through. Try again.');
        await _controller.start();
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _toggleTorch() async {
    await _controller.toggleTorch();
    setState(() => _torch = !_torch);
  }

  @override
  Widget build(BuildContext context) {
    final linked = widget.binId != Session.noBin;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Scan a bottle', style: head(26))),
              InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () => Session.bin.value = null,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Brand.surface,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: Brand.line),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.delete_outline, size: 16, color: linked ? Brand.lime : Brand.muted),
                      const SizedBox(width: 6),
                      Text(linked ? widget.binId : 'No bin',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text('Point the camera at the barcode on a PET bottle.',
              style: TextStyle(color: Brand.muted)),
          const SizedBox(height: 16),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  MobileScanner(
                    controller: _controller,
                    onDetect: (capture) {
                      if (capture.barcodes.isEmpty) return;
                      final code = capture.barcodes.first.rawValue;
                      if (code != null && code.isNotEmpty) _handle(code);
                    },
                  ),
                  cameraCorner(Alignment.topLeft),
                  cameraCorner(Alignment.topRight),
                  cameraCorner(Alignment.bottomLeft),
                  cameraCorner(Alignment.bottomRight),
                  Center(
                    child: Container(height: 3, margin: const EdgeInsets.symmetric(horizontal: 44), color: Brand.sky),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          OutlineButtonX(label: _torch ? 'Torch on' : 'Torch off', onPressed: _toggleTorch),
          if (ApiService.isDemo) ...[
            const SizedBox(height: 8),
            // Demo mode only (emulators have no real camera). Hidden once baseUrl is set.
            TextButton(
              onPressed: () => _handle('6001234567890'),
              child: const Text('Demo scan (no camera)', style: TextStyle(color: Brand.sky)),
            ),
          ],
          const SizedBox(height: 8),
          const Center(
            child: Text('Hold steady in good light. Each bottle earns EcoPoints.',
                style: TextStyle(color: Brand.muted, fontSize: 13), textAlign: TextAlign.center),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 6. Result
// ---------------------------------------------------------------------------
class ResultScreen extends StatelessWidget {
  const ResultScreen({super.key, required this.result});
  final ScanResult result;

  @override
  Widget build(BuildContext context) {
    final ok = result.recognised;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(ok ? 'Scan recorded' : 'Not recognised yet', style: head(26)),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
                decoration: BoxDecoration(color: Brand.surface, borderRadius: BorderRadius.circular(24)),
                child: Column(
                  children: [
                    CircleAvatar(
                      radius: 32,
                      backgroundColor: ok ? Brand.green : Brand.line,
                      child: Icon(ok ? Icons.check : Icons.help_outline,
                          size: 34, color: ok ? Brand.black : Brand.text),
                    ),
                    const SizedBox(height: 12),
                    if (ok) ...[
                      Text('+${result.points}', style: head(64, color: Brand.lime)),
                      const Text('EcoPoints earned', style: TextStyle(fontSize: 16)),
                      if (result.promoLabel != null) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(color: Brand.sky, borderRadius: BorderRadius.circular(999)),
                          child: Text(result.promoLabel!,
                              style: const TextStyle(
                                  color: Brand.black, fontWeight: FontWeight.w700, fontSize: 13)),
                        ),
                      ],
                    ] else
                      const Text(
                        'We have sent this barcode for review. No points were added.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Brand.muted),
                      ),
                  ],
                ),
              ),
              if (ok) ...[
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: Brand.surface, borderRadius: BorderRadius.circular(16)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Product', style: TextStyle(color: Brand.muted, fontSize: 13)),
                      const SizedBox(height: 4),
                      Text(result.brand.isEmpty ? result.product : result.brand,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text(result.product, style: const TextStyle(color: Brand.muted, fontSize: 14)),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('New balance', style: TextStyle(color: Brand.muted)),
                  Text('${result.balance} EcoPoints', style: head(20, color: Brand.lime)),
                ],
              ),
              const Spacer(),
              PrimaryButton(label: 'Scan another', onPressed: () => Navigator.of(context).pop(false)),
              const SizedBox(height: 12),
              OutlineButtonX(label: 'View wallet', onPressed: () => Navigator.of(context).pop(true)),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 7. Rewards (MOCK): airtime, data bundles, supermarket vouchers
// ---------------------------------------------------------------------------
class RewardsScreen extends StatefulWidget {
  const RewardsScreen({super.key});

  @override
  State<RewardsScreen> createState() => _RewardsScreenState();
}

class _RewardsScreenState extends State<RewardsScreen> {
  RewardKind? _filter; // null = all

  static const _labels = {
    RewardKind.airtime: 'Airtime',
    RewardKind.data: 'Data',
    RewardKind.voucher: 'Vouchers',
  };

  Future<void> _open(Reward rw) async {
    final res = await showModalBottomSheet<RedeemResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Brand.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => RedeemSheet(reward: rw),
    );
    if (res == null || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Brand.surface,
        title: Text('Redeemed', style: head(20, color: Brand.lime)),
        content: Text('${rw.provider} ${rw.title}\n\n${res.message}\n\nNew balance: ${res.balance} EcoPoints',
            style: const TextStyle(color: Brand.text)),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = rewards.where((r) => _filter == null || r.kind == _filter).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Rewards', style: head(26)),
          const SizedBox(height: 8),
          ValueListenableBuilder<int>(
            valueListenable: Session.balance,
            builder: (_, v, __) => Text('You have $v EcoPoints',
                style: const TextStyle(color: Brand.lime, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 4),
          const Text('Demo rewards only. Real airtime, data and vouchers will be connected with partners later.',
              style: TextStyle(color: Brand.muted, fontSize: 13)),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _chip('All', _filter == null, () => setState(() => _filter = null)),
                for (final k in RewardKind.values)
                  _chip(_labels[k]!, _filter == k, () => setState(() => _filter = k)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ValueListenableBuilder<int>(
              valueListenable: Session.balance,
              builder: (_, bal, __) => ListView.separated(
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) => _card(items[i], bal),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          label: Text(label),
          selected: selected,
          onSelected: (_) => onTap(),
          selectedColor: Brand.green,
          backgroundColor: Brand.surface,
          side: const BorderSide(color: Brand.line),
          labelStyle: TextStyle(
            color: selected ? Brand.black : Brand.text,
            fontWeight: FontWeight.w700,
          ),
          showCheckmark: false,
        ),
      );

  Widget _card(Reward rw, int balance) {
    final short = rw.cost - balance;
    return Material(
      color: Brand.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _open(rw),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: rw.color, width: 2),
                ),
                child: Text(rw.provider.substring(0, 1), style: head(22, color: rw.color)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(rw.provider, style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text(rw.title, style: const TextStyle(color: Brand.muted, fontSize: 14)),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('${rw.cost} pts', style: head(18, color: short > 0 ? Brand.muted : Brand.lime)),
                  if (short > 0)
                    Text('Need $short more', style: const TextStyle(color: Brand.muted, fontSize: 12)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class RedeemSheet extends StatefulWidget {
  const RedeemSheet({super.key, required this.reward});
  final Reward reward;

  @override
  State<RedeemSheet> createState() => _RedeemSheetState();
}

class _RedeemSheetState extends State<RedeemSheet> {
  late final TextEditingController _phone = TextEditingController(text: Session.userPhone);
  bool _busy = false;
  String? _error;

  bool get _needsPhone => widget.reward.kind != RewardKind.voucher;

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  Future<void> _redeem() async {
    final rw = widget.reward;
    final phone = _phone.text.trim();
    if (_needsPhone && !phoneRe.hasMatch(phone)) {
      setState(() => _error = 'Enter a valid Kenyan phone number.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await ApiService.redeem(rw, phone);
      Session.recordRedeem(rw, res.balance);
      if (mounted) Navigator.of(context).pop(res);
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Could not redeem right now. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final rw = widget.reward;
    final short = rw.cost - Session.balance.value;
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 24, 24, 24 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${rw.provider} ${rw.title}', style: head(20)),
          const SizedBox(height: 4),
          Text('${rw.cost} EcoPoints  |  Your balance: ${Session.balance.value}',
              style: const TextStyle(color: Brand.muted)),
          const SizedBox(height: 16),
          if (_needsPhone) ...[
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: fieldDecoration('Send to this number'),
            ),
            const SizedBox(height: 12),
          ] else ...[
            const Text('Your voucher code will appear after you redeem.',
                style: TextStyle(color: Brand.muted)),
            const SizedBox(height: 12),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_error!, style: const TextStyle(color: Color(0xFFFF8A80))),
            ),
          if (short > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text('You need $short more EcoPoints. Scan more bottles to unlock this.',
                  style: const TextStyle(color: Brand.muted)),
            ),
          PrimaryButton(
            label: 'Redeem for ${rw.cost} points',
            onPressed: short > 0 ? null : _redeem,
            busy: _busy,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 8. Wallet (with profile and log out)
// ---------------------------------------------------------------------------
class WalletScreen extends StatelessWidget {
  const WalletScreen({super.key});

  String _when(DateTime t) {
    final now = DateTime.now();
    final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final today = t.year == now.year && t.month == now.month && t.day == now.day;
    return today ? 'Today, $hm' : '${t.day}/${t.month}, $hm';
  }

  void _logout(BuildContext context) {
    Session.reset();
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Wallet', style: head(26))),
              IconButton(
                tooltip: 'Log out',
                icon: const Icon(Icons.logout, color: Brand.muted),
                onPressed: () => _logout(context),
              ),
            ],
          ),
          if (Session.userName.isNotEmpty)
            Text('${Session.userName}  |  ${Session.userPhone}',
                style: const TextStyle(color: Brand.muted, fontSize: 14)),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
            decoration: BoxDecoration(color: Brand.surface, borderRadius: BorderRadius.circular(24)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('EcoPoints balance', style: TextStyle(color: Brand.muted, fontSize: 14)),
                ValueListenableBuilder<int>(
                  valueListenable: Session.balance,
                  builder: (_, v, __) => Text('$v', style: head(56, color: Brand.lime)),
                ),
                const Text('Redeem points in the Rewards tab.',
                    style: TextStyle(color: Brand.muted, fontSize: 14)),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text('History', style: head(18)),
          const SizedBox(height: 8),
          Expanded(
            child: ValueListenableBuilder<List<LedgerEntry>>(
              valueListenable: Session.history,
              builder: (_, items, __) {
                if (items.isEmpty) {
                  return const Center(
                    child: Text('No activity yet. Scan your first PET bottle.',
                        style: TextStyle(color: Brand.muted)),
                  );
                }
                return ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const Divider(color: Brand.line, height: 1),
                  itemBuilder: (_, i) {
                    final s = items[i];
                    final earned = s.points > 0;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(s.title, style: const TextStyle(fontWeight: FontWeight.w500)),
                                Text(_when(s.time), style: const TextStyle(color: Brand.muted, fontSize: 13)),
                              ],
                            ),
                          ),
                          Text(earned ? '+${s.points}' : '${s.points}',
                              style: head(20, color: earned ? Brand.lime : Brand.sky)),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}