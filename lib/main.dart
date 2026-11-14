import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const UcTusApp());

// ───────────────────────── Renkler ─────────────────────────

class Palette {
  static const bg = Color(0xFFE6E9E8); // sayfa arka planı
  static const frame = Color(0xFF7E8482); // klavye gövdesi (gri)
  static const frameEdge = Color(0xFF151515); // gövdenin siyah kenarı
  static const slot = Color(0xFF666B69); // boş hücre
  static const keyBorder = Color(0xFF1B1D1C); // tuşun siyah çerçevesi
  static const uiKey = Color(0xFFC9D6D3); // skor / buton tuşları

  /// Görseldeki mint/çağla yeşili tonundan koyu deniz yeşiline kadar,
  /// her seviye bir öncekinden belirgin şekilde farklı (kontrastlı).
  static const faces = <Color>[
    Color(0xFFE2F2EE), // 3
    Color(0xFFC4E4DC), // 9
    Color(0xFFA5D3C8), // 27
    Color(0xFF84BFB2), // 81
    Color(0xFF5EA897), // 243
    Color(0xFF3F8D7D), // 729
    Color(0xFF2A7062), // 2187
    Color(0xFF1B5148), // 6561
    Color(0xFF103731), // 19683 ve sonrası
  ];

  static Color face(int level) => faces[min(level - 1, faces.length - 1)];

  /// Açık tuşlarda koyu yazı, koyu tuşlarda beyaz yazı.
  static Color text(int level) =>
      level <= 4 ? const Color(0xFF14302A) : const Color(0xFFF4FFFC);
}

Color shade(Color c, double amount) {
  final hsl = HSLColor.fromColor(c);
  return hsl.withLightness((hsl.lightness + amount).clamp(0.0, 1.0)).toColor();
}

// ───────────────────────── Uygulama ─────────────────────────

class UcTusApp extends StatelessWidget {
  const UcTusApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Üç Tuş',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: Palette.bg,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3F8D7D)),
        useMaterial3: true,
      ),
      home: const GameScreen(),
    );
  }
}

// ───────────────────────── Oyun modeli ─────────────────────────

enum Dir { up, down, left, right }

class Tile {
  final int id;
  int level; // değer = 3^level
  int row;
  int col;
  int pop = 0; // birleşme animasyonunu tetikler
  bool dead = false; // başka tuşun içine kayıp silinecek
  int? nextLevel; // kayma bitince uygulanacak yeni seviye

  Tile(this.id, this.level, this.row, this.col);

  int get value => pow(3, level).toInt();
}

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  static const int n = 5; // üçlü birleşme için 5×5
  static const int winLevel = 7; // 3^7 = 2187
  static const int slideMs = 120;

  final _rand = Random();
  final _focus = FocusNode();

  List<Tile> tiles = [];
  int _nextId = 0;
  int score = 0;
  int best = 0;
  bool busy = false;
  bool over = false;
  bool wonShown = false;

  Offset _drag = Offset.zero;

  @override
  void initState() {
    super.initState();
    _loadBest();
    _newGame();
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Future<void> _loadBest() async {
    final p = await SharedPreferences.getInstance();
    if (mounted) setState(() => best = p.getInt('best') ?? 0);
  }

  Future<void> _saveBest() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('best', best);
  }

  void _newGame() {
    setState(() {
      tiles = [];
      score = 0;
      over = false;
      wonShown = false;
      busy = false;
      _spawn();
      _spawn();
    });
  }

  void _spawn() {
    final occupied = {for (final t in tiles) if (!t.dead) t.row * n + t.col};
    final empty = <(int, int)>[];
    for (int r = 0; r < n; r++) {
      for (int c = 0; c < n; c++) {
        if (!occupied.contains(r * n + c)) empty.add((r, c));
      }
    }
    if (empty.isEmpty) return;
    final (r, c) = empty[_rand.nextInt(empty.length)];
    // %90 ihtimalle 3, %10 ihtimalle 9
    tiles.add(Tile(_nextId++, _rand.nextDouble() < 0.9 ? 1 : 2, r, c));
  }

  /// Bir satır/sütundaki k. hücre; k=0 hareket yönündeki kenardır.
  (int, int) _cell(Dir d, int line, int k) => switch (d) {
        Dir.left => (line, k),
        Dir.right => (line, n - 1 - k),
        Dir.up => (k, line),
        Dir.down => (n - 1 - k, line),
      };

  void _move(Dir d) {
    if (busy || over) return;

    final grid = List.generate(n, (_) => List<Tile?>.filled(n, null));
    for (final t in tiles) {
      grid[t.row][t.col] = t;
    }

    bool moved = false;
    int gained = 0;

    for (int l = 0; l < n; l++) {
      final lineTiles = <Tile>[];
      for (int k = 0; k < n; k++) {
        final (r, c) = _cell(d, l, k);
        final t = grid[r][c];
        if (t != null) lineTiles.add(t);
      }

      int pos = 0;
      int i = 0;
      while (i < lineTiles.length) {
        final a = lineTiles[i];
        final (r, c) = _cell(d, l, pos++);
        if (a.row != r || a.col != c) moved = true;
        a.row = r;
        a.col = c;

        // Üç aynı tuş art arda → 3 + 3 + 3 = 9
        if (i + 2 < lineTiles.length &&
            lineTiles[i + 1].level == a.level &&
            lineTiles[i + 2].level == a.level) {
          for (final b in [lineTiles[i + 1], lineTiles[i + 2]]) {
            b.row = r;
            b.col = c;
            b.dead = true;
          }
          a.nextLevel = a.level + 1;
          gained += pow(3, a.level + 1).toInt();
          moved = true;
          i += 3;
        } else {
          i += 1;
        }
      }
    }

    if (!moved) return;

    busy = true;
    setState(() => score += gained);
    if (score > best) {
      best = score;
      _saveBest();
    }

    Future.delayed(const Duration(milliseconds: slideMs + 10), () {
      if (!mounted) return;
      setState(() {
        tiles.removeWhere((t) => t.dead);
        for (final t in tiles) {
          if (t.nextLevel != null) {
            t.level = t.nextLevel!;
            t.nextLevel = null;
            t.pop++;
          }
        }
        _spawn();
        over = !_canMove();
        busy = false;
      });
      if (!wonShown && tiles.any((t) => t.level >= winLevel)) {
        wonShown = true;
        _showWin();
      }
    });
  }

  bool _canMove() {
    if (tiles.length < n * n) return true;
    final grid = List.generate(n, (_) => List<int>.filled(n, 0));
    for (final t in tiles) {
      grid[t.row][t.col] = t.level;
    }
    for (int r = 0; r < n; r++) {
      for (int c = 0; c < n; c++) {
        final v = grid[r][c];
        if (c + 2 < n && grid[r][c + 1] == v && grid[r][c + 2] == v) return true;
        if (r + 2 < n && grid[r + 1][c] == v && grid[r + 2][c] == v) return true;
      }
    }
    return false;
  }

  void _showWin() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Palette.faces[1],
        title: const Text('2187 tuşuna ulaştın! 🎉'),
        content: const Text('İstersen 6561 için devam edebilirsin.'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _newGame();
            },
            child: const Text('Yeni oyun'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Devam et'),
          ),
        ],
      ),
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    Dir? d;
    if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.keyA) d = Dir.left;
    if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.keyD) d = Dir.right;
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.keyW) d = Dir.up;
    if (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.keyS) d = Dir.down;
    if (d == null) return KeyEventResult.ignored;
    _move(d);
    return KeyEventResult.handled;
  }

  void _onPanEnd() {
    final v = _drag;
    _drag = Offset.zero;
    if (v.distance < 24) return;
    if (v.dx.abs() > v.dy.abs()) {
      _move(v.dx > 0 ? Dir.right : Dir.left);
    } else {
      _move(v.dy > 0 ? Dir.down : Dir.up);
    }
  }

  // ───────────────────────── Arayüz ─────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => _drag = Offset.zero,
            onPanUpdate: (d) => _drag += d.delta,
            onPanEnd: (_) => _onPanEnd(),
            child: LayoutBuilder(builder: (context, cons) {
              final w = min(cons.maxWidth - 32, 460.0);
              return Center(
                child: SingleChildScrollView(
                  child: SizedBox(
                    width: w,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _header(),
                        const SizedBox(height: 14),
                        _subHeader(),
                        const SizedBox(height: 16),
                        _board(w),
                        const SizedBox(height: 16),
                        Text(
                          'Kaydır ya da ok tuşlarını kullan',
                          style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Row(
      children: [
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'ÜÇ TUŞ',
                style: TextStyle(
                  fontSize: 38,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.5,
                  color: Color(0xFF1B5148),
                  height: 1,
                ),
              ),
              SizedBox(height: 4),
              Text('3ⁿ  ·  2187\'ye ulaş',
                  style: TextStyle(fontSize: 13, color: Color(0xFF3F5A54))),
            ],
          ),
        ),
        _InfoKey(label: 'SKOR', value: score),
        const SizedBox(width: 8),
        _InfoKey(label: 'EN İYİ', value: best),
      ],
    );
  }

  Widget _subHeader() {
    return Row(
      children: [
        const Expanded(
          child: Text(
            'Aynı üç tuşu yan yana getir: 3 + 3 + 3 = 9',
            style: TextStyle(fontSize: 13.5, color: Color(0xFF2E3B38)),
          ),
        ),
        _PressKey(label: 'Yeni', onTap: _newGame),
      ],
    );
  }

  Widget _board(double boardSize) {
    const edge = 3.0;
    final inner = boardSize - edge * 2;
    final gap = inner * 0.025;
    final tileSize = (inner - gap * (n + 1)) / n;
    double pos(int i) => gap + i * (tileSize + gap);

    // Silinecek tuşlar altta kalsın
    final sorted = [...tiles]..sort((a, b) => (a.dead ? 0 : 1) - (b.dead ? 0 : 1));

    return Container(
      width: boardSize,
      height: boardSize,
      decoration: BoxDecoration(
        color: Palette.frame,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Palette.frameEdge, width: edge),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 10, offset: Offset(0, 4)),
        ],
      ),
      child: Stack(
        children: [
          for (int r = 0; r < n; r++)
            for (int c = 0; c < n; c++)
              Positioned(
                left: pos(c),
                top: pos(r),
                child: Container(
                  width: tileSize,
                  height: tileSize,
                  decoration: BoxDecoration(
                    color: Palette.slot,
                    borderRadius: BorderRadius.circular(tileSize * 0.12),
                    border: Border.all(color: const Color(0xFF4E5250), width: 1),
                  ),
                ),
              ),
          for (final t in sorted)
            AnimatedPositioned(
              key: ValueKey(t.id),
              duration: const Duration(milliseconds: slideMs),
              curve: Curves.easeOut,
              left: pos(t.col),
              top: pos(t.row),
              child: TweenAnimationBuilder<double>(
                key: ValueKey('${t.id}_${t.pop}'),
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 180),
                builder: (_, v, child) {
                  final s = t.pop == 0
                      ? Curves.easeOutBack.transform(v) // yeni tuş belirir
                      : 1 + 0.12 * sin(pi * v); // birleşmede "basılma" zıplaması
                  return Transform.scale(scale: s, child: child);
                },
                child: NumberKey(level: t.level, size: tileSize),
              ),
            ),
          if (over)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xCCE2F2EE),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      'Hamle kalmadı',
                      style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1B5148),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text('Skor: $score',
                        style: const TextStyle(fontSize: 16, color: Color(0xFF2E3B38))),
                    const SizedBox(height: 16),
                    _PressKey(label: 'Tekrar', onTap: _newGame),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ───────────────────────── Tuş görünümü ─────────────────────────

/// Klavye tuşu kabuğu: siyah çerçeve → koyu yan yüzey (sağ ve alt kalın,
/// ışık sol üstten geliyormuş gibi) → açık üst yüzey.
class KeyCapShell extends StatelessWidget {
  final double width;
  final double height;
  final Color face;
  final Widget child;

  const KeyCapShell({
    super.key,
    required this.width,
    required this.height,
    required this.face,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final r = min(width, height);
    final side = shade(face, -0.18);

    return Container(
      width: width,
      height: height,
      padding: EdgeInsets.all(max(1.5, r * 0.025)),
      decoration: BoxDecoration(
        color: Palette.keyBorder,
        borderRadius: BorderRadius.circular(r * 0.12),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 3, offset: Offset(1, 2)),
        ],
      ),
      child: Container(
        padding: EdgeInsets.fromLTRB(r * 0.045, r * 0.03, r * 0.085, r * 0.10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(r * 0.10),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [shade(side, 0.07), shade(side, -0.05)],
          ),
        ),
        child: Container(
          padding: EdgeInsets.all(r * 0.07),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(r * 0.08),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [shade(face, 0.05), face],
            ),
            border: Border.all(color: shade(face, 0.10), width: 1),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Sayılı oyun tuşu: üst solda değer, alt solda "3ⁿ" (Home/End yazıları gibi).
class NumberKey extends StatelessWidget {
  final int level;
  final double size;

  const NumberKey({super.key, required this.level, required this.size});

  static const _sup = ['⁰', '¹', '²', '³', '⁴', '⁵', '⁶', '⁷', '⁸', '⁹'];

  String _power(int l) => '3${l.toString().split('').map((d) => _sup[int.parse(d)]).join()}';

  double _fontScale(int value) {
    final digits = value.toString().length;
    if (digits <= 2) return 0.36;
    if (digits == 3) return 0.30;
    if (digits == 4) return 0.25;
    return 0.20;
  }

  @override
  Widget build(BuildContext context) {
    final value = pow(3, level).toInt();
    final tc = Palette.text(level);

    return KeyCapShell(
      width: size,
      height: size,
      face: Palette.face(level),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.topLeft,
              child: Text(
                '$value',
                style: TextStyle(
                  color: tc,
                  fontSize: size * _fontScale(value),
                  fontWeight: FontWeight.w600,
                  height: 1,
                ),
              ),
            ),
          ),
          Text(
            _power(level),
            style: TextStyle(color: tc.withAlpha(190), fontSize: size * 0.14, height: 1),
          ),
        ],
      ),
    );
  }
}

class _InfoKey extends StatelessWidget {
  final String label;
  final int value;

  const _InfoKey({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return KeyCapShell(
      width: 84,
      height: 58,
      face: Palette.uiKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 9.5, fontWeight: FontWeight.w700, color: Color(0xFF3F5A54))),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text('$value',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF14302A))),
          ),
        ],
      ),
    );
  }
}

/// Basınca hafifçe çöken buton tuşu.
class _PressKey extends StatefulWidget {
  final String label;
  final VoidCallback onTap;

  const _PressKey({required this.label, required this.onTap});

  @override
  State<_PressKey> createState() => _PressKeyState();
}

class _PressKeyState extends State<_PressKey> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) {
        setState(() => _down = false);
        widget.onTap();
      },
      child: AnimatedScale(
        scale: _down ? 0.93 : 1,
        duration: const Duration(milliseconds: 80),
        child: KeyCapShell(
          width: 92,
          height: 46,
          face: Palette.faces[4],
          child: Center(
            child: Text(
              widget.label,
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}
