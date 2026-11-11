// Catálogos del administrador: menú con una sub-pantalla para ciudades, aerolíneas y tipos de avión.
// En cada una se puede agregar y editar. Las ciudades se eligen del mapa o del buscador de ciudades del mundo.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../servicios/api.dart';
import '../servicios/sesion.dart';
import '../utils/comunes.dart';
import '../utils/validaciones.dart';
import 'crear_vuelo.dart' show ResumenAvion;
import 'mapa_mundi.dart';

/// Clases que puede tener un avión, desde la parte delantera.
const _clases = [
  ('FIRST', 'First'),
  ('BUSINESS', 'Business'),
  ('PREMIUM', 'Premium Economy'),
  ('ECONOMY', 'Economy'),
];

/// Configuraciones habituales: asientos por bloque separados por pasillos.
const _configuraciones = ['1-1', '1-2-1', '2-2', '1-2-2', '2-3', '2-2-2', '3-3', '2-3-2', '2-4-2', '3-3-3', '3-4-3'];

/// Muestra el error del servidor por campo y avisa el mensaje general.
Map<String, String> _erroresDe(BuildContext context, ApiError e) {
  avisar(context, e.texto, TipoAviso.error);
  return e.detalle is Map ? (e.detalle as Map).map((k, v) => MapEntry('$k', '$v')) : {};
}

String _vuelos(dynamic n) => n == 1 ? '1 vuelo' : '${n ?? 0} vuelos';

// ======================= Menú de catálogos =======================

class PantallaCatalogos extends StatefulWidget {
  const PantallaCatalogos({super.key, required this.sesion});

  final Sesion sesion;

  @override
  State<PantallaCatalogos> createState() => PantallaCatalogosState();
}

class PantallaCatalogosState extends State<PantallaCatalogos> {
  Map<String, dynamic>? _datos;
  String? _errorCarga;

  Api get _api => widget.sesion.api;

  @override
  void initState() {
    super.initState();
    cargar();
  }

  Future<void> cargar() async {
    try {
      final r = await _api.catalogos();
      if (!mounted) return;
      setState(() {
        _datos = r;
        _errorCarga = null;
      });
    } on ApiError catch (e) {
      if (mounted) setState(() => _errorCarga = e.texto);
    }
  }

  Future<void> _abrir(Widget pantalla) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => pantalla));
    cargar();
  }

  String _ejemplos(List lista, String Function(dynamic) texto) {
    if (_datos == null) return _errorCarga == null ? 'Cargando...' : 'No se pudo cargar';
    if (lista.isEmpty) return 'Ninguno registrado';
    final primeros = lista.take(4).map(texto).join(', ');
    return lista.length > 4 ? '$primeros y ${lista.length - 4} más' : primeros;
  }

  @override
  Widget build(BuildContext context) {
    final d = _datos;
    final ciudades = (d?['ciudades_detalle'] as List?) ?? [];
    final aerolineas = (d?['aerolineas'] as List?) ?? [];
    final aviones = (d?['aviones'] as List?) ?? [];
    return RefreshIndicator(
      onRefresh: cargar,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        Centrado(
          ancho: 900,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Catálogos', style: Theme.of(context).textTheme.titleLarge),
            const Text('Elija un catálogo para ver, agregar o editar sus registros. '
                'Son los datos que se eligen al crear un vuelo.'),
            if (_errorCarga != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_errorCarga!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            const SizedBox(height: 12),
            _OpcionCatalogo(
              icono: Icons.location_city,
              titulo: 'Ciudades',
              cantidad: d == null ? null : ciudades.length,
              detalle: _ejemplos(ciudades, (c) => c['nombre']),
              ayuda: 'Origen y destino de los vuelos. Se eligen del mapa o del buscador de ciudades del mundo.',
              alAbrir: () => _abrir(PantallaCiudades(api: _api)),
            ),
            _OpcionCatalogo(
              icono: Icons.airlines,
              titulo: 'Aerolíneas',
              cantidad: d == null ? null : aerolineas.length,
              detalle: _ejemplos(aerolineas, (a) => '${a['nombre']} (${a['codigo']})'),
              ayuda: 'Nombre y código de 2 caracteres (prefijo del código de sus vuelos).',
              alAbrir: () => _abrir(PantallaAerolineas(api: _api)),
            ),
            _OpcionCatalogo(
              icono: Icons.airplanemode_active,
              titulo: 'Tipos de avión',
              cantidad: d == null ? null : aviones.length,
              detalle: _ejemplos(aviones, (a) => '${a['avion']} (${a['total_asientos']})'),
              ayuda: 'Cabina de cada avión: clases, filas y asientos por fila.',
              alAbrir: () => _abrir(PantallaAviones(api: _api)),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _OpcionCatalogo extends StatelessWidget {
  const _OpcionCatalogo({
    required this.icono,
    required this.titulo,
    required this.cantidad,
    required this.detalle,
    required this.ayuda,
    required this.alAbrir,
  });

  final IconData icono;
  final String titulo, detalle, ayuda;
  final int? cantidad;
  final VoidCallback alAbrir;

  @override
  Widget build(BuildContext context) {
    final esquema = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: alAbrir,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: esquema.primaryContainer,
              child: Icon(icono, color: esquema.onPrimaryContainer),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(cantidad == null ? titulo : '$titulo ($cantidad)',
                    style: Theme.of(context).textTheme.titleMedium),
                Text(ayuda, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 4),
                Text(detalle, maxLines: 1, overflow: TextOverflow.ellipsis),
              ]),
            ),
            const Icon(Icons.chevron_right),
          ]),
        ),
      ),
    );
  }
}

/// Carga los catálogos para una sub-pantalla.
mixin _CargaCatalogos<T extends StatefulWidget> on State<T> {
  Map<String, dynamic>? datos;
  String? errorCarga;

  Api get api;

  @override
  void initState() {
    super.initState();
    cargar();
  }

  Future<void> cargar() async {
    try {
      final r = await api.catalogos();
      if (!mounted) return;
      setState(() {
        datos = r;
        errorCarga = null;
      });
    } on ApiError catch (e) {
      if (mounted) setState(() => errorCarga = e.texto);
    }
  }

  /// Contenido de la sub-pantalla con su estado de carga.
  Widget cuerpo(List<Widget> Function(Map<String, dynamic> datos) contenido) {
    if (datos == null) {
      return Center(
        child: errorCarga == null
            ? const CircularProgressIndicator()
            : Column(mainAxisSize: MainAxisSize.min, children: [
                Text(errorCarga!),
                const SizedBox(height: 8),
                OutlinedButton(onPressed: cargar, child: const Text('Reintentar')),
              ]),
      );
    }
    return RefreshIndicator(
      onRefresh: cargar,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 88), children: [
        Centrado(
          ancho: 900,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: contenido(datos!)),
        ),
      ]),
    );
  }
}

// ======================= Ciudades =======================

class PantallaCiudades extends StatefulWidget {
  const PantallaCiudades({super.key, required this.api});

  final Api api;

  @override
  State<PantallaCiudades> createState() => _PantallaCiudadesState();
}

class _PantallaCiudadesState extends State<PantallaCiudades> with _CargaCatalogos {
  @override
  Api get api => widget.api;

  List<Map<String, dynamic>> get _ciudades => ((datos?['ciudades_detalle'] as List?) ?? []).cast<Map<String, dynamic>>();

  Future<Map<String, dynamic>?> _elegir({Map<String, dynamic>? actual}) =>
      Navigator.of(context).push<Map<String, dynamic>>(MaterialPageRoute(
        builder: (_) => PantallaElegirCiudad(api: api, existentes: _ciudades, actual: actual),
      ));

  Future<void> _agregar() async {
    final sel = await _elegir();
    if (sel == null || !mounted) return;
    try {
      final r = await api.crearCiudad(sel['ciudad'] as String,
          pais: sel['pais'] as String?,
          latitud: (sel['latitud'] as num).toDouble(),
          longitud: (sel['longitud'] as num).toDouble());
      if (mounted) avisar(context, r['mensaje'] as String);
    } on ApiError catch (e) {
      if (mounted) avisar(context, e.texto, TipoAviso.error);
    }
    await cargar();
  }

  Future<void> _editar(Map<String, dynamic> c) async {
    final sel = await _elegir(actual: c);
    if (sel == null || !mounted) return;
    final nombre = sel['ciudad'] as String;
    final vuelos = (c['vuelos'] as num?) ?? 0;
    if (vuelos > 0 && nombre != c['nombre']) {
      final ok = await confirmar(context,
          titulo: 'Cambiar ${c['nombre']} por $nombre',
          mensaje: '${c['nombre']} tiene ${_vuelos(vuelos)}. Esos vuelos pasarán a decir $nombre. ¿Continuar?',
          textoOk: 'Cambiar');
      if (!ok || !mounted) return;
    }
    try {
      final r = await api.editarCiudad(c['id'] as int, nombre,
          pais: sel['pais'] as String?,
          latitud: (sel['latitud'] as num).toDouble(),
          longitud: (sel['longitud'] as num).toDouble());
      if (mounted) avisar(context, r['mensaje'] as String);
    } on ApiError catch (e) {
      if (mounted) avisar(context, e.texto, TipoAviso.error);
    }
    await cargar();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ciudades')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: datos == null ? null : _agregar,
        icon: const Icon(Icons.add_location_alt),
        label: const Text('Agregar ciudad'),
      ),
      body: cuerpo((_) => [
            SizedBox(
              height: 300,
              child: MapaMundi(puntos: [
                for (final c in _ciudades)
                  if (c['latitud'] != null)
                    PuntoMapa(c['nombre'] as String, (c['latitud'] as num).toDouble(), (c['longitud'] as num).toDouble()),
              ]),
            ),
            const SizedBox(height: 4),
            Text('${_ciudades.length} ciudades. Acerque el mapa para ver sus nombres; toque una ciudad de la lista '
                'para editarla.', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Card(
              child: Column(children: [
                for (final c in _ciudades) ...[
                  ListTile(
                    leading: Icon(c['latitud'] == null ? Icons.location_off : Icons.place),
                    title: Text('${c['nombre']}'),
                    subtitle: Text([
                      c['pais'] ?? 'País sin registrar',
                      _vuelos(c['vuelos']),
                      if (c['latitud'] != null) '${c['latitud']}, ${c['longitud']}' else 'sin ubicación',
                    ].join(' · ')),
                    trailing: IconButton(
                      icon: const Icon(Icons.edit),
                      tooltip: 'Editar ${c['nombre']}',
                      onPressed: () => _editar(c),
                    ),
                    onTap: () => _editar(c),
                  ),
                  if (c != _ciudades.last) const Divider(height: 1),
                ],
              ]),
            ),
          ]),
    );
  }
}

/// Elegir una ciudad del mundo: con el buscador (país y ciudad) o tocando el mapa.
/// Devuelve {ciudad, pais, region, latitud, longitud}; no se escriben datos a mano.
class PantallaElegirCiudad extends StatefulWidget {
  const PantallaElegirCiudad({super.key, required this.api, required this.existentes, this.actual});

  final Api api;
  final List<Map<String, dynamic>> existentes;

  /// Ciudad que se está editando (null al agregar).
  final Map<String, dynamic>? actual;

  @override
  State<PantallaElegirCiudad> createState() => _PantallaElegirCiudadState();
}

class _PantallaElegirCiudadState extends State<PantallaElegirCiudad> {
  final _ciudad = TextEditingController();
  final _pais = TextEditingController();
  Timer? _espera;
  int _consulta = 0; // descarta respuestas de búsquedas anteriores
  bool _buscando = false, _consultandoMapa = false;
  List<Map<String, dynamic>> _resultados = [];
  String? _mensaje;
  Map<String, dynamic>? _seleccion;
  PuntoMapa? _enfocar;

  @override
  void initState() {
    super.initState();
    final a = widget.actual;
    if (a != null && a['latitud'] != null) {
      _seleccion = {
        'ciudad': a['nombre'],
        'pais': a['pais'],
        'latitud': a['latitud'],
        'longitud': a['longitud'],
      };
      _enfocar = PuntoMapa(a['nombre'] as String, (a['latitud'] as num).toDouble(), (a['longitud'] as num).toDouble());
    }
  }

  @override
  void dispose() {
    _espera?.cancel();
    _ciudad.dispose();
    _pais.dispose();
    super.dispose();
  }

  void _alEscribir() {
    _espera?.cancel();
    if (_ciudad.text.trim().length < 2) {
      setState(() {
        _resultados = [];
        _mensaje = null;
        _buscando = false;
      });
      return;
    }
    setState(() => _buscando = true);
    _espera = Timer(const Duration(milliseconds: 700), _buscar);
  }

  Future<void> _buscar() async {
    final consulta = ++_consulta;
    try {
      final r = await widget.api.buscarCiudades(_ciudad.text.trim(), pais: _pais.text);
      if (!mounted || consulta != _consulta) return;
      final lista = (r['ciudades'] as List).cast<Map<String, dynamic>>();
      setState(() {
        _resultados = lista;
        _mensaje = lista.isEmpty ? 'No se encontraron ciudades; revise el nombre completo de la ciudad o el país' : null;
      });
    } on ApiError catch (e) {
      if (mounted && consulta == _consulta) setState(() => _mensaje = e.texto);
    } finally {
      if (mounted && consulta == _consulta) setState(() => _buscando = false);
    }
  }

  void _elegir(Map<String, dynamic> c) {
    FocusScope.of(context).unfocus();
    setState(() {
      _seleccion = c;
      _resultados = [];
      _enfocar = PuntoMapa(c['ciudad'] as String, (c['latitud'] as num).toDouble(), (c['longitud'] as num).toDouble());
    });
  }

  Future<void> _alTocarMapa(double lat, double lon) async {
    setState(() => _consultandoMapa = true);
    try {
      final r = await widget.api.ciudadEnMapa(double.parse(lat.toStringAsFixed(4)), double.parse(lon.toStringAsFixed(4)));
      if (mounted) setState(() => _seleccion = r);
    } on ApiError catch (e) {
      if (mounted) avisar(context, e.texto, e.status == 404 ? TipoAviso.info : TipoAviso.error);
    } finally {
      if (mounted) setState(() => _consultandoMapa = false);
    }
  }

  /// La ciudad elegida ya está registrada (con otro registro).
  bool get _repetida {
    final s = _seleccion;
    if (s == null) return false;
    final nombre = '${s['ciudad']}'.toLowerCase();
    return widget.existentes.any((e) => e['id'] != widget.actual?['id'] && '${e['nombre']}'.toLowerCase() == nombre);
  }

  @override
  Widget build(BuildContext context) {
    final editando = widget.actual != null;
    final s = _seleccion;
    final otras = [
      for (final c in widget.existentes)
        if (c['latitud'] != null && c['id'] != widget.actual?['id'])
          PuntoMapa(c['nombre'] as String, (c['latitud'] as num).toDouble(), (c['longitud'] as num).toDouble()),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(editando ? 'Editar ${widget.actual!['nombre']}' : 'Agregar ciudad')),
      body: Centrado(
        ancho: 1100,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _pais,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'País (opcional)',
                    hintText: 'Ecuador',
                    prefixIcon: Icon(Icons.flag_outlined),
                  ),
                  onChanged: (_) => _alEscribir(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _ciudad,
                  autofocus: !editando,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(
                    labelText: 'Buscar ciudad',
                    hintText: 'Esmeraldas, Lima, París…',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _buscando
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                          )
                        : null,
                  ),
                  onChanged: (_) => _alEscribir(),
                  onSubmitted: (_) => _buscar(),
                ),
              ),
            ]),
          ),
          if (_mensaje != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Text(_mensaje!, style: Theme.of(context).textTheme.bodySmall),
            ),
          if (_resultados.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Card(
                margin: EdgeInsets.zero,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: ListView(shrinkWrap: true, children: [
                    for (final r in _resultados)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.place_outlined),
                        title: Text('${r['ciudad']}'),
                        subtitle: Text([if (r['region'] != null) r['region'], r['pais']].join(', ')),
                        trailing: Text(r['pais'] as String, style: const TextStyle(fontWeight: FontWeight.w600)),
                        onTap: () => _elegir(r),
                      ),
                  ]),
                ),
              ),
            ),
          Expanded(
            key: const ValueKey('mapa'),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
              child: Stack(children: [
                MapaMundi(
                  puntos: otras,
                  seleccionado: s == null
                      ? null
                      : PuntoMapa('${s['ciudad']}', (s['latitud'] as num).toDouble(), (s['longitud'] as num).toDouble()),
                  enfocar: _enfocar,
                  alTocar: _consultandoMapa ? null : _alTocarMapa,
                ),
                if (_consultandoMapa) const Positioned(left: 0, right: 0, top: 0, child: LinearProgressIndicator()),
              ]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text('Busque por nombre o toque el mapa (acérquelo con la rueda, con dos dedos o con +) para elegir '
                'la ciudad más cercana a ese punto.', style: Theme.of(context).textTheme.bodySmall),
          ),
          _PanelSeleccion(
            seleccion: s,
            repetida: _repetida,
            editando: editando,
            alConfirmar: () => Navigator.of(context).pop(s),
          ),
        ]),
      ),
    );
  }
}

class _PanelSeleccion extends StatelessWidget {
  const _PanelSeleccion({required this.seleccion, required this.repetida, required this.editando, required this.alConfirmar});

  final Map<String, dynamic>? seleccion;
  final bool repetida, editando;
  final VoidCallback alConfirmar;

  Widget _dato(String etiqueta, String valor, IconData icono) => SizedBox(
        width: 220,
        child: InputDecorator(
          decoration: InputDecoration(labelText: etiqueta, prefixIcon: Icon(icono), isDense: true),
          child: Text(valor, overflow: TextOverflow.ellipsis),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final s = seleccion;
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: s == null
            ? const Row(children: [
                Icon(Icons.travel_explore),
                SizedBox(width: 10),
                Expanded(child: Text('Aún no ha elegido una ciudad: búsquela o toque el mapa.')),
              ])
            : Wrap(spacing: 12, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
                _dato('País', '${s['pais'] ?? 'Sin registrar'}', Icons.flag),
                _dato('Ciudad', '${s['ciudad']}', Icons.location_city),
                Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  if (s['region'] != null) Text('${s['region']}'),
                  Text('${s['latitud']}, ${s['longitud']}', style: Theme.of(context).textTheme.bodySmall),
                ]),
                if (repetida)
                  Text('${s['ciudad']} ya está registrada',
                      style: TextStyle(color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.w600)),
                FilledButton.icon(
                  onPressed: repetida ? null : alConfirmar,
                  icon: Icon(editando ? Icons.save : Icons.add_location_alt),
                  label: Text(editando ? 'Guardar cambios' : 'Agregar ${s['ciudad']}'),
                ),
              ]),
      ),
    );
  }
}

// ======================= Aerolíneas =======================

class PantallaAerolineas extends StatefulWidget {
  const PantallaAerolineas({super.key, required this.api});

  final Api api;

  @override
  State<PantallaAerolineas> createState() => _PantallaAerolineasState();
}

class _PantallaAerolineasState extends State<PantallaAerolineas> with _CargaCatalogos {
  @override
  Api get api => widget.api;

  Future<void> _abrir([Map<String, dynamic>? aerolinea]) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _DialogoAerolinea(api: api, aerolinea: aerolinea),
    );
    if (ok == true) await cargar();
  }

  @override
  Widget build(BuildContext context) {
    final lista = ((datos?['aerolineas'] as List?) ?? []).cast<Map<String, dynamic>>();
    return Scaffold(
      appBar: AppBar(title: const Text('Aerolíneas')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: datos == null ? null : _abrir,
        icon: const Icon(Icons.add),
        label: const Text('Agregar aerolínea'),
      ),
      body: cuerpo((_) => [
            Card(
              child: Column(children: [
                for (final a in lista) ...[
                  ListTile(
                    leading: CircleAvatar(child: Text('${a['codigo']}')),
                    title: Text('${a['nombre']}'),
                    subtitle: Text('Código ${a['codigo']} · ${_vuelos(a['vuelos'])}'),
                    trailing: IconButton(
                      icon: const Icon(Icons.edit),
                      tooltip: 'Editar ${a['nombre']}',
                      onPressed: () => _abrir(a),
                    ),
                    onTap: () => _abrir(a),
                  ),
                  if (a != lista.last) const Divider(height: 1),
                ],
              ]),
            ),
          ]),
    );
  }
}

class _DialogoAerolinea extends StatefulWidget {
  const _DialogoAerolinea({required this.api, this.aerolinea});

  final Api api;
  final Map<String, dynamic>? aerolinea;

  @override
  State<_DialogoAerolinea> createState() => _DialogoAerolineaState();
}

class _DialogoAerolineaState extends State<_DialogoAerolinea> {
  final _form = GlobalKey<FormState>();
  late final _nombre = TextEditingController(text: widget.aerolinea?['nombre'] as String?);
  late final _codigo = TextEditingController(text: widget.aerolinea?['codigo'] as String?);
  bool _enviando = false;
  Map<String, String> _errores = {};

  @override
  void dispose() {
    _nombre.dispose();
    _codigo.dispose();
    super.dispose();
  }

  Future<void> _guardar() async {
    setState(() => _errores = {});
    if (!_form.currentState!.validate()) return;
    setState(() => _enviando = true);
    try {
      final a = widget.aerolinea;
      final r = a == null
          ? await widget.api.crearAerolinea(_nombre.text.trim(), _codigo.text)
          : await widget.api.editarAerolinea(a['id'] as int, _nombre.text.trim(), _codigo.text);
      if (!mounted) return;
      avisar(context, r['mensaje'] as String);
      Navigator.of(context).pop(true);
    } on ApiError catch (e) {
      if (mounted) setState(() => _errores = _erroresDe(context, e));
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.aerolinea;
    final vuelos = (a?['vuelos'] as num?) ?? 0;
    return AlertDialog(
      title: Text(a == null ? 'Agregar aerolínea' : 'Editar ${a['nombre']}'),
      content: SizedBox(
        width: 380,
        child: Form(
          key: _form,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextFormField(
              controller: _nombre,
              maxLength: 60,
              autofocus: true,
              decoration: InputDecoration(labelText: 'Nombre', counterText: '', errorText: _errores['nombre']),
              validator: (v) => (v ?? '').trim().length < 2 ? 'Escriba el nombre de la aerolínea' : null,
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _codigo,
              maxLength: 2,
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [Filtro.formateador((v) => v.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), ''))],
              decoration: InputDecoration(
                labelText: 'Código (2 caracteres)',
                hintText: 'LA',
                counterText: '',
                helperText: 'Prefijo del código de sus vuelos',
                errorText: _errores['codigo'],
              ),
              validator: (v) => (v ?? '').length != 2 ? 'Escriba 2 letras o números' : null,
            ),
            if (vuelos > 0)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text('Tiene ${_vuelos(vuelos)}: tomarán el nombre nuevo. Los vuelos ya creados conservan '
                    'su código; los nuevos usarán el código nuevo.', style: Theme.of(context).textTheme.bodySmall),
              ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _enviando ? null : () => Navigator.of(context).pop(false), child: const Text('Cancelar')),
        FilledButton(
          onPressed: _enviando ? null : _guardar,
          child: Text(_enviando ? 'Guardando...' : (a == null ? 'Agregar' : 'Guardar')),
        ),
      ],
    );
  }
}

// ======================= Aviones =======================

class PantallaAviones extends StatefulWidget {
  const PantallaAviones({super.key, required this.api});

  final Api api;

  @override
  State<PantallaAviones> createState() => _PantallaAvionesState();
}

class _PantallaAvionesState extends State<PantallaAviones> with _CargaCatalogos {
  @override
  Api get api => widget.api;

  Future<void> _abrir([Map<String, dynamic>? avion]) async {
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => PantallaEditorAvion(api: api, avion: avion),
    ));
    if (ok == true) await cargar();
  }

  @override
  Widget build(BuildContext context) {
    final lista = ((datos?['aviones'] as List?) ?? []).cast<Map<String, dynamic>>();
    return Scaffold(
      appBar: AppBar(title: const Text('Tipos de avión')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: datos == null ? null : _abrir,
        icon: const Icon(Icons.add),
        label: const Text('Agregar avión'),
      ),
      body: cuerpo((_) => [
            for (final a in lista)
              Card(
                child: InkWell(
                  onTap: a['id'] == null ? null : () => _abrir(a),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(children: [
                      Expanded(child: ResumenAvion(avion: a)),
                      const SizedBox(width: 8),
                      Column(children: [
                        IconButton(
                          icon: const Icon(Icons.edit),
                          tooltip: 'Editar ${a['avion']}',
                          onPressed: a['id'] == null ? null : () => _abrir(a),
                        ),
                        Text(_vuelos(a['vuelos']), style: Theme.of(context).textTheme.bodySmall),
                      ]),
                    ]),
                  ),
                ),
              ),
          ]),
    );
  }
}

class _ClaseAvion {
  _ClaseAvion(this.clase, this.nombre);

  final String clase;
  final String nombre;
  bool incluida = false;
  final filas = TextEditingController();
  String configuracion = '3-3';

  int get asientosPorFila => configuracion.split('-').fold(0, (s, b) => s + int.parse(b));
  int get total => incluida ? (int.tryParse(filas.text) ?? 0) * asientosPorFila : 0;
}

/// Agregar o editar un tipo de avión. Si el avión ya tiene vuelos solo se cambia el nombre.
class PantallaEditorAvion extends StatefulWidget {
  const PantallaEditorAvion({super.key, required this.api, this.avion});

  final Api api;
  final Map<String, dynamic>? avion;

  @override
  State<PantallaEditorAvion> createState() => _PantallaEditorAvionState();
}

class _PantallaEditorAvionState extends State<PantallaEditorAvion> {
  final _form = GlobalKey<FormState>();
  late final _nombre = TextEditingController(text: widget.avion?['avion'] as String?);
  late final List<_ClaseAvion> _clasesAvion = [for (final (c, n) in _clases) _ClaseAvion(c, n)];
  bool _enviando = false;
  Map<String, String> _errores = {};

  int get _vuelosDelAvion => (widget.avion?['vuelos'] as num?)?.toInt() ?? 0;
  bool get _cabinaBloqueada => _vuelosDelAvion > 0;

  @override
  void initState() {
    super.initState();
    final actuales = {
      for (final c in ((widget.avion?['clases'] as List?) ?? []).cast<Map<String, dynamic>>()) c['clase']: c,
    };
    for (final c in _clasesAvion) {
      final actual = actuales[c.clase];
      if (widget.avion != null) {
        c.incluida = actual != null;
        c.filas.text = actual == null ? '' : '${actual['filas']}';
        c.configuracion = actual?['configuracion'] as String? ?? '2-2';
      } else {
        c.incluida = c.clase == 'ECONOMY';
        c.filas.text = c.clase == 'ECONOMY' ? '20' : '';
        c.configuracion = c.clase == 'ECONOMY' ? '3-3' : '2-2';
      }
    }
  }

  @override
  void dispose() {
    _nombre.dispose();
    for (final c in _clasesAvion) {
      c.filas.dispose();
    }
    super.dispose();
  }

  int get _total => _clasesAvion.fold(0, (s, c) => s + c.total);

  Future<void> _guardar() async {
    setState(() => _errores = {});
    if (!_form.currentState!.validate()) return;
    final incluidas = _clasesAvion.where((c) => c.incluida).toList();
    if (incluidas.isEmpty) {
      avisar(context, 'Incluya al menos una clase', TipoAviso.error);
      return;
    }
    final clases = [
      for (final c in incluidas) {'clase': c.clase, 'filas': int.parse(c.filas.text), 'configuracion': c.configuracion}
    ];
    setState(() => _enviando = true);
    try {
      final a = widget.avion;
      final r = a == null
          ? await widget.api.crearAvion(_nombre.text.trim(), clases)
          : await widget.api.editarAvion(a['id'] as int, _nombre.text.trim(), _cabinaBloqueada ? null : clases);
      if (!mounted) return;
      avisar(context, r['mensaje'] as String);
      Navigator.of(context).pop(true);
    } on ApiError catch (e) {
      if (mounted) setState(() => _errores = _erroresDe(context, e));
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editando = widget.avion != null;
    final bloqueada = _cabinaBloqueada;
    return Scaffold(
      appBar: AppBar(title: Text(editando ? 'Editar ${widget.avion!['avion']}' : 'Agregar avión')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Centrado(
          ancho: 900,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _form,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(
                    width: 360,
                    child: TextFormField(
                      controller: _nombre,
                      maxLength: 60,
                      decoration: InputDecoration(
                          labelText: 'Nombre del avión',
                          hintText: 'Airbus A321neo',
                          counterText: '',
                          errorText: _errores['nombre']),
                      validator: (v) => (v ?? '').trim().length < 2 ? 'Escriba el nombre del avión' : null,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (bloqueada)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text('Este avión tiene ${_vuelos(_vuelosDelAvion)}: solo se puede cambiar el nombre '
                          '(sus vuelos tomarán el nombre nuevo). La cabina no se cambia para no mover asientos ya '
                          'vendidos.'),
                    )
                  else
                    const Text('Clases de la cabina (desde la parte delantera). La configuración son los asientos de '
                        'cada bloque separados por pasillos: 3-3 son 6 asientos por fila con un pasillo.'),
                  const SizedBox(height: 8),
                  for (final c in _clasesAvion)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                        SizedBox(
                          width: 190,
                          child: CheckboxListTile(
                            value: c.incluida,
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                            title: Text(c.nombre),
                            onChanged: bloqueada
                                ? null
                                : (v) => setState(() {
                                      c.incluida = v ?? false;
                                      if (c.incluida && c.filas.text.isEmpty) c.filas.text = '3';
                                    }),
                          ),
                        ),
                        SizedBox(
                          width: 110,
                          child: TextFormField(
                            controller: c.filas,
                            enabled: c.incluida && !bloqueada,
                            keyboardType: TextInputType.number,
                            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(2)],
                            decoration: const InputDecoration(labelText: 'Filas'),
                            onChanged: (_) => setState(() {}),
                            validator: (v) {
                              if (!c.incluida || bloqueada) return null;
                              final n = int.tryParse(v ?? '');
                              return n == null || n < 1 || n > 60 ? '1 a 60' : null;
                            },
                          ),
                        ),
                        SizedBox(
                          width: 140,
                          child: DropdownButtonFormField<String>(
                            initialValue: c.configuracion,
                            isExpanded: true,
                            decoration: const InputDecoration(labelText: 'Configuración'),
                            items: [
                              for (final cf in {..._configuraciones, c.configuracion})
                                DropdownMenuItem(value: cf, child: Text(cf)),
                            ],
                            onChanged: c.incluida && !bloqueada ? (v) => setState(() => c.configuracion = v!) : null,
                          ),
                        ),
                        if (c.incluida) Text('${c.total} asientos'),
                      ]),
                    ),
                  if (_errores['clases'] != null)
                    Text(_errores['clases']!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  const SizedBox(height: 4),
                  Wrap(spacing: 16, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    Text('Total: $_total asientos', style: const TextStyle(fontWeight: FontWeight.bold)),
                    FilledButton.icon(
                      onPressed: _enviando ? null : _guardar,
                      icon: Icon(editando ? Icons.save : Icons.add),
                      label: Text(_enviando ? 'Guardando...' : (editando ? 'Guardar cambios' : 'Agregar avión')),
                    ),
                  ]),
                ]),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
