import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Limpia tu galería',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: const SwipePage(),
      );
}

/// Decisión tomada sobre una foto: keep | delete | album
class _Decision {
  final AssetEntity asset;
  final String type;
  final String? album;
  _Decision(this.asset, this.type, [this.album]);
}

class SwipePage extends StatefulWidget {
  const SwipePage({super.key});

  @override
  State<SwipePage> createState() => _SwipePageState();
}

class _SwipePageState extends State<SwipePage> {
  static const int _pageSize = 60;
  static const double _threshold = 110;

  final List<AssetEntity> _assets = [];
  final List<_Decision> _history = [];
  final Set<String> _seen = {};
  List<String> _albums = [];
  AssetPathEntity? _all;

  int _index = 0;
  int _page = 0;
  bool _hasMore = true;
  bool _loading = false;
  bool _checked = false;
  bool _permitted = false;
  bool _applying = false;
  Offset _drag = Offset.zero;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final ps = await PhotoManager.requestPermissionExtend();
    if (!ps.hasAccess) {
      setState(() {
        _checked = true;
        _permitted = false;
      });
      return;
    }
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: true,
    );
    if (paths.isNotEmpty) _all = paths.first;
    await _loadAlbums();
    await _loadMore();
    if (!mounted) return;
    setState(() {
      _checked = true;
      _permitted = true;
    });
  }

  Future<void> _loadAlbums() async {
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: false,
    );
    _albums = paths.map((p) => p.name).toList();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore || _all == null) return;
    _loading = true;
    final list = await _all!.getAssetListPaged(page: _page, size: _pageSize);
    _page++;
    if (list.length < _pageSize) _hasMore = false;
    final fresh = list.where((a) => !_seen.contains(a.id)).toList();
    _assets.addAll(fresh);
    _loading = false;
    if (fresh.isEmpty && _hasMore) {
      return _loadMore();
    }
    if (mounted) setState(() {});
  }

  // ---------- acciones ----------

  void _record(_Decision d) {
    _history.add(d);
    if (d.type == 'keep') _seen.add(d.asset.id);
    setState(() {
      _index++;
      _drag = Offset.zero;
    });
    if (_assets.length - _index < 10) _loadMore();
  }

  void _keep() => _record(_Decision(_assets[_index], 'keep'));

  void _delete() => _record(_Decision(_assets[_index], 'delete'));

  void _undo() {
    if (_history.isEmpty || _index == 0) return;
    final d = _history.removeLast();
    _seen.remove(d.asset.id);
    setState(() {
      _index--;
      _drag = Offset.zero;
    });
  }

  Future<void> _pickAlbum() async {
    final name = await _chooseAlbum();
    if (name == null) {
      setState(() => _drag = Offset.zero);
      return;
    }
    if (!_albums.contains(name)) _albums.add(name);
    _record(_Decision(_assets[_index], 'album', name));
  }

  void _onRelease() {
    final dx = _drag.dx;
    final dy = _drag.dy;
    if (dx > _threshold && dx.abs() > dy.abs()) {
      _keep();
    } else if (dx < -_threshold && dx.abs() > dy.abs()) {
      _delete();
    } else if (dy < -_threshold) {
      _pickAlbum();
    } else {
      setState(() => _drag = Offset.zero);
    }
  }

  Future<String?> _chooseAlbum() {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('Nuevo álbum'),
              onTap: () async {
                final name = await _askName(ctx);
                if (!ctx.mounted) return;
                if (name != null && name.trim().isNotEmpty) {
                  Navigator.pop(ctx, name.trim());
                }
              },
            ),
            for (final a in _albums)
              ListTile(
                leading: const Icon(Icons.folder),
                title: Text(a),
                onTap: () => Navigator.pop(ctx, a),
              ),
          ],
        ),
      ),
    );
  }

  Future<String?> _askName(BuildContext ctx) {
    final c = TextEditingController();
    return showDialog<String>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        title: const Text('Nombre del álbum'),
        content: TextField(controller: c, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dctx, c.text),
            child: const Text('Crear'),
          ),
        ],
      ),
    );
  }

  /// Aplica todo junto: copia a álbumes y borra (una sola confirmación del sistema)
  Future<void> _apply() async {
    setState(() => _applying = true);
    final idsToDelete = <String>[];
    int moved = 0;
    try {
      for (final d in _history) {
        if (d.type == 'delete') {
          idsToDelete.add(d.asset.id);
        } else if (d.type == 'album') {
          final bytes = await d.asset.originBytes;
          if (bytes == null) continue;
          try {
            final saved = await PhotoManager.editor.saveImage(
              bytes,
              filename: d.asset.title ?? '${d.asset.id}.jpg',
              relativePath: 'Pictures/${d.album}',
            );
            _seen.add(saved.id);
            idsToDelete.add(d.asset.id);
            moved++;
          } catch (_) {}
        }
      }
      if (idsToDelete.isNotEmpty) {
        await PhotoManager.editor.deleteWithIds(idsToDelete);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
    _history.clear();
    _assets.clear();
    _page = 0;
    _index = 0;
    _hasMore = true;
    _loading = false;
    await _loadAlbums();
    await _loadMore();
    if (!mounted) return;
    setState(() => _applying = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Listo: $moved movidas, ${idsToDelete.length - moved} eliminadas')),
    );
  }

  // ---------- interfaz ----------

  @override
  Widget build(BuildContext context) {
    if (!_checked) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_permitted) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Necesito acceso a tus fotos'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: PhotoManager.openSetting,
                child: const Text('Abrir ajustes'),
              ),
            ],
          ),
        ),
      );
    }
    final pending = _history.where((d) => d.type != 'keep').length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Limpia tu galería'),
        actions: [
          TextButton(
            onPressed: (pending == 0 || _applying) ? null : _apply,
            child: Text('Aplicar ($pending)'),
          ),
        ],
      ),
      body: _applying
          ? const Center(child: CircularProgressIndicator())
          : _body(),
    );
  }

  Widget _body() {
    if (_index >= _assets.length) {
      if (_hasMore) {
        if (!_loading) Future.microtask(_loadMore);
        return const Center(child: CircularProgressIndicator());
      }
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '¡No quedan más fotos!\nToca "Aplicar" arriba para confirmar los cambios.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final cur = _assets[_index];
    final next = _index + 1 < _assets.length ? _assets[_index + 1] : null;
    final dx = _drag.dx;
    final dy = _drag.dy;

    return Column(
      children: [
        Expanded(
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (next != null)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: _Photo(next, key: ValueKey('n${next.id}')),
                ),
              GestureDetector(
                onPanUpdate: (d) => setState(() => _drag += d.delta),
                onPanEnd: (_) => _onRelease(),
                child: Transform.translate(
                  offset: _drag,
                  child: Transform.rotate(
                    angle: dx / 1200,
                    child: Stack(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: _Photo(cur, key: ValueKey('c${cur.id}')),
                        ),
                        Positioned(
                          top: 40,
                          left: 40,
                          child: _label('CONSERVAR', Colors.green,
                              dx > 0 ? (dx / 120).clamp(0.0, 1.0).toDouble() : 0.0),
                        ),
                        Positioned(
                          top: 40,
                          right: 40,
                          child: _label('ELIMINAR', Colors.red,
                              dx < 0 ? (-dx / 120).clamp(0.0, 1.0).toDouble() : 0.0),
                        ),
                        Positioned(
                          bottom: 40,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: _label('ÁLBUM', Colors.blue,
                                dy < 0 ? (-dy / 120).clamp(0.0, 1.0).toDouble() : 0.0),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 24, top: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton.filled(
                onPressed: _delete,
                icon: const Icon(Icons.close),
                iconSize: 32,
              ),
              IconButton(
                onPressed: _undo,
                icon: const Icon(Icons.undo),
                iconSize: 28,
              ),
              IconButton(
                onPressed: _pickAlbum,
                icon: const Icon(Icons.folder),
                iconSize: 28,
              ),
              IconButton.filled(
                onPressed: _keep,
                icon: const Icon(Icons.check),
                iconSize: 32,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _label(String text, Color color, double opacity) => Opacity(
        opacity: opacity,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            border: Border.all(color: color, width: 3),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      );
}

/// Muestra una foto (carga la miniatura una sola vez)
class _Photo extends StatefulWidget {
  final AssetEntity asset;
  const _Photo(this.asset, {super.key});

  @override
  State<_Photo> createState() => _PhotoState();
}

class _PhotoState extends State<_Photo> {
  late final Future<Uint8List?> _future =
      widget.asset.thumbnailDataWithSize(const ThumbnailSize(900, 900));

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _future,
      builder: (context, snap) {
        final data = snap.data;
        if (data == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Image.memory(data, fit: BoxFit.contain, gaplessPlayback: true),
        );
      },
    );
  }
}
