// Catálogos del administrador: crear ciudades (origen y destino), aerolíneas y tipos de avión.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../servicios/api.dart';
import '../servicios/sesion.dart';
import '../utils/comunes.dart';
import '../utils/validaciones.dart';
import 'crear_vuelo.dart' show ResumenAvion;

/// Clases que puede tener un avión, desde la parte delantera.
const _clases = [
  ('FIRST', 'First'),
  ('BUSINESS', 'Business'),
  ('PREMIUM', 'Premium Economy'),
  ('ECONOMY', 'Economy'),
];

/// Configuraciones habituales: asientos por bloque separados por pasillos.
const _configuraciones = ['1-1', '1-2-1', '2-2', '1-2-2', '2-3', '2-2-2', '3-3', '2-3-2', '2-4-2', '3-3-3', '3-4-3'];

class PantallaCatalogos extends StatefulWidget {
  const PantallaCatalogos({super.key, required this.sesion});

  final Sesion sesion;

  @override
  State<PantallaCatalogos> createState() => PantallaCatalogosState();
}

class PantallaCatalogosState extends State<PantallaCatalogos> {
  List<String> _ciudades = [];
  Map<String, dynamic> _coordenadas = {};
  List<Map<String, dynamic>> _aerolineas = [];
  List<Map<String, dynamic>> _aviones = [];
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
        _ciudades = (r['ciudades'] as List).cast<String>();
        _coordenadas = (r['coordenadas'] as Map?)?.cast<String, dynamic>() ?? {};
        _aerolineas = (r['aerolineas'] as List).cast<Map<String, dynamic>>();
        _aviones = (r['aviones'] as List).cast<Map<String, dynamic>>();
        _errorCarga = null;
      });
    } on ApiError catch (e) {
      if (mounted) setState(() => _errorCarga = e.texto);
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: cargar,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        Centrado(
          ancho: 900,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Catálogos', style: Theme.of(context).textTheme.titleLarge),
            const Text('Cree las ciudades (sirven de origen y de destino), las aerolíneas y los tipos de avión '
                'que luego se eligen al crear un vuelo.'),
            if (_errorCarga != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_errorCarga!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            const SizedBox(height: 12),
            _TarjetaCiudad(api: _api, ciudades: _ciudades, coordenadas: _coordenadas, alCrear: cargar),
            _TarjetaAerolinea(api: _api, aerolineas: _aerolineas, alCrear: cargar),
            _TarjetaAvion(api: _api, aviones: _aviones, alCrear: cargar),
          ]),
        ),
      ]),
    );
  }
}

/// Muestra el error del servidor por campo y avisa el mensaje general.
Map<String, String> _erroresDe(BuildContext context, ApiError e) {
  avisar(context, e.texto, TipoAviso.error);
  return e.detalle is Map ? (e.detalle as Map).map((k, v) => MapEntry('$k', '$v')) : {};
}

class _Seccion extends StatelessWidget {
  const _Seccion({required this.icono, required this.titulo, required this.formulario, required this.lista});

  final IconData icono;
  final String titulo;
  final Widget formulario;
  final Widget lista;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(icono),
            const SizedBox(width: 8),
            Text(titulo, style: Theme.of(context).textTheme.titleMedium),
          ]),
          const SizedBox(height: 12),
          formulario,
          const Divider(height: 24),
          lista,
        ]),
      ),
    );
  }
}

// ---------- Ciudades ----------

class _TarjetaCiudad extends StatefulWidget {
  const _TarjetaCiudad({required this.api, required this.ciudades, required this.coordenadas, required this.alCrear});

  final Api api;
  final List<String> ciudades;
  final Map<String, dynamic> coordenadas;
  final Future<void> Function() alCrear;

  @override
  State<_TarjetaCiudad> createState() => _TarjetaCiudadState();
}

class _TarjetaCiudadState extends State<_TarjetaCiudad> {
  final _form = GlobalKey<FormState>();
  final _nombre = TextEditingController();
  final _latitud = TextEditingController();
  final _longitud = TextEditingController();
  bool _enviando = false;
  Map<String, String> _errores = {};

  @override
  void dispose() {
    _nombre.dispose();
    _latitud.dispose();
    _longitud.dispose();
    super.dispose();
  }

  String? _validarCoordenada(String? v, double limite, String nombre) {
    if ((v ?? '').isEmpty) {
      final otra = nombre == 'latitud' ? _longitud.text : _latitud.text;
      return otra.isEmpty ? null : 'Escriba también la $nombre';
    }
    final n = double.tryParse(v!);
    if (n == null || n < -limite || n > limite) return 'Entre -$limite y $limite';
    return null;
  }

  Future<void> _crear() async {
    _nombre.text = formatearNombre(_nombre.text);
    setState(() => _errores = {});
    if (!_form.currentState!.validate()) return;
    setState(() => _enviando = true);
    try {
      final r = await widget.api.crearCiudad(_nombre.text,
          latitud: double.tryParse(_latitud.text), longitud: double.tryParse(_longitud.text));
      if (!mounted) return;
      avisar(context, r['mensaje'] as String);
      _form.currentState!.reset();
      _nombre.clear();
      _latitud.clear();
      _longitud.clear();
      await widget.alCrear();
    } on ApiError catch (e) {
      if (mounted) setState(() => _errores = _erroresDe(context, e));
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordenada = FilteringTextInputFormatter.allow(RegExp(r'^-?\d{0,3}(\.\d{0,5})?'));
    return _Seccion(
      icono: Icons.location_city,
      titulo: 'Ciudades (origen y destino)',
      formulario: Form(
        key: _form,
        child: Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.start, children: [
          SizedBox(
            width: 260,
            child: TextFormField(
              controller: _nombre,
              maxLength: 60,
              textCapitalization: TextCapitalization.words,
              inputFormatters: [Filtro.formateador(Filtro.nombre)],
              decoration: InputDecoration(labelText: 'Nombre de la ciudad', counterText: '', errorText: _errores['nombre']),
              validator: (v) => (v ?? '').trim().length < 2 ? 'Escriba el nombre de la ciudad' : null,
            ),
          ),
          SizedBox(
            width: 190,
            child: TextFormField(
              controller: _latitud,
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              inputFormatters: [coordenada],
              decoration: InputDecoration(
                  labelText: 'Latitud (opcional)', hintText: '-0.18065', errorText: _errores['latitud']),
              validator: (v) => _validarCoordenada(v, 90, 'latitud'),
            ),
          ),
          SizedBox(
            width: 190,
            child: TextFormField(
              controller: _longitud,
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              inputFormatters: [coordenada],
              decoration: InputDecoration(
                  labelText: 'Longitud (opcional)', hintText: '-78.46784', errorText: _errores['longitud']),
              validator: (v) => _validarCoordenada(v, 180, 'longitud'),
            ),
          ),
          FilledButton.icon(
            onPressed: _enviando ? null : _crear,
            icon: const Icon(Icons.add),
            label: Text(_enviando ? 'Creando...' : 'Crear ciudad'),
          ),
        ]),
      ),
      lista: Wrap(spacing: 8, runSpacing: 8, children: [
        for (final c in widget.ciudades)
          Chip(
            avatar: Icon(widget.coordenadas.containsKey(c) ? Icons.place : Icons.location_off, size: 16),
            label: Text(c),
          ),
      ]),
    );
  }
}

// ---------- Aerolíneas ----------

class _TarjetaAerolinea extends StatefulWidget {
  const _TarjetaAerolinea({required this.api, required this.aerolineas, required this.alCrear});

  final Api api;
  final List<Map<String, dynamic>> aerolineas;
  final Future<void> Function() alCrear;

  @override
  State<_TarjetaAerolinea> createState() => _TarjetaAerolineaState();
}

class _TarjetaAerolineaState extends State<_TarjetaAerolinea> {
  final _form = GlobalKey<FormState>();
  final _nombre = TextEditingController();
  final _codigo = TextEditingController();
  bool _enviando = false;
  Map<String, String> _errores = {};

  @override
  void dispose() {
    _nombre.dispose();
    _codigo.dispose();
    super.dispose();
  }

  Future<void> _crear() async {
    setState(() => _errores = {});
    if (!_form.currentState!.validate()) return;
    setState(() => _enviando = true);
    try {
      final r = await widget.api.crearAerolinea(_nombre.text.trim(), _codigo.text);
      if (!mounted) return;
      avisar(context, r['mensaje'] as String);
      _form.currentState!.reset();
      _nombre.clear();
      _codigo.clear();
      await widget.alCrear();
    } on ApiError catch (e) {
      if (mounted) setState(() => _errores = _erroresDe(context, e));
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _Seccion(
      icono: Icons.airlines,
      titulo: 'Aerolíneas',
      formulario: Form(
        key: _form,
        child: Wrap(spacing: 12, runSpacing: 12, children: [
          SizedBox(
            width: 260,
            child: TextFormField(
              controller: _nombre,
              maxLength: 60,
              decoration: InputDecoration(labelText: 'Nombre', counterText: '', errorText: _errores['nombre']),
              validator: (v) => (v ?? '').trim().length < 2 ? 'Escriba el nombre de la aerolínea' : null,
            ),
          ),
          SizedBox(
            width: 210,
            child: TextFormField(
              controller: _codigo,
              maxLength: 2,
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [Filtro.formateador((v) => v.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), ''))],
              decoration: InputDecoration(
                labelText: 'Código (2 caracteres)',
                hintText: 'LA',
                counterText: '',
                helperText: 'Prefijo de sus vuelos',
                errorText: _errores['codigo'],
              ),
              validator: (v) => (v ?? '').length != 2 ? 'Escriba 2 letras o números' : null,
            ),
          ),
          FilledButton.icon(
            onPressed: _enviando ? null : _crear,
            icon: const Icon(Icons.add),
            label: Text(_enviando ? 'Creando...' : 'Crear aerolínea'),
          ),
        ]),
      ),
      lista: Wrap(spacing: 8, runSpacing: 8, children: [
        for (final a in widget.aerolineas) Chip(label: Text('${a['nombre']} · ${a['codigo']}')),
      ]),
    );
  }
}

// ---------- Aviones ----------

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

class _TarjetaAvion extends StatefulWidget {
  const _TarjetaAvion({required this.api, required this.aviones, required this.alCrear});

  final Api api;
  final List<Map<String, dynamic>> aviones;
  final Future<void> Function() alCrear;

  @override
  State<_TarjetaAvion> createState() => _TarjetaAvionState();
}

class _TarjetaAvionState extends State<_TarjetaAvion> {
  final _form = GlobalKey<FormState>();
  final _nombre = TextEditingController();
  late final List<_ClaseAvion> _clasesAvion = [for (final (c, n) in _clases) _ClaseAvion(c, n)];
  bool _enviando = false;
  Map<String, String> _errores = {};

  @override
  void initState() {
    super.initState();
    _reiniciar();
  }

  void _reiniciar() {
    for (final c in _clasesAvion) {
      c.incluida = c.clase == 'ECONOMY';
      c.filas.text = c.clase == 'ECONOMY' ? '20' : '';
      c.configuracion = c.clase == 'ECONOMY' ? '3-3' : '2-2';
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

  Future<void> _crear() async {
    setState(() => _errores = {});
    if (!_form.currentState!.validate()) return;
    final incluidas = _clasesAvion.where((c) => c.incluida).toList();
    if (incluidas.isEmpty) {
      avisar(context, 'Incluya al menos una clase', TipoAviso.error);
      return;
    }
    setState(() => _enviando = true);
    try {
      final r = await widget.api.crearAvion(_nombre.text.trim(), [
        for (final c in incluidas) {'clase': c.clase, 'filas': int.parse(c.filas.text), 'configuracion': c.configuracion}
      ]);
      if (!mounted) return;
      avisar(context, r['mensaje'] as String);
      _form.currentState!.reset();
      _nombre.clear();
      setState(_reiniciar);
      await widget.alCrear();
    } on ApiError catch (e) {
      if (mounted) setState(() => _errores = _erroresDe(context, e));
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _Seccion(
      icono: Icons.airplanemode_active,
      titulo: 'Tipos de avión',
      formulario: Form(
        key: _form,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 320,
            child: TextFormField(
              controller: _nombre,
              maxLength: 60,
              decoration: InputDecoration(
                  labelText: 'Nombre del avión', hintText: 'Airbus A321neo', counterText: '', errorText: _errores['nombre']),
              validator: (v) => (v ?? '').trim().length < 2 ? 'Escriba el nombre del avión' : null,
            ),
          ),
          const SizedBox(height: 8),
          const Text('Clases de la cabina (desde la parte delantera). La configuración son los asientos de cada '
              'bloque separados por pasillos: 3-3 son 6 asientos por fila con un pasillo.'),
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
                    onChanged: (v) => setState(() {
                      c.incluida = v ?? false;
                      if (c.incluida && c.filas.text.isEmpty) c.filas.text = '3';
                    }),
                  ),
                ),
                SizedBox(
                  width: 110,
                  child: TextFormField(
                    controller: c.filas,
                    enabled: c.incluida,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(2)],
                    decoration: const InputDecoration(labelText: 'Filas'),
                    onChanged: (_) => setState(() {}),
                    validator: (v) {
                      if (!c.incluida) return null;
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
                    items: [for (final cf in _configuraciones) DropdownMenuItem(value: cf, child: Text(cf))],
                    onChanged: c.incluida ? (v) => setState(() => c.configuracion = v!) : null,
                  ),
                ),
                if (c.incluida) Text('${c.total} asientos'),
              ]),
            ),
          if (_errores['clases'] != null)
            Text(_errores['clases']!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          const SizedBox(height: 4),
          Row(children: [
            Text('Total: $_total asientos', style: const TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            FilledButton.icon(
              onPressed: _enviando ? null : _crear,
              icon: const Icon(Icons.add),
              label: Text(_enviando ? 'Creando...' : 'Crear avión'),
            ),
          ]),
        ]),
      ),
      lista: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final a in widget.aviones)
          Padding(padding: const EdgeInsets.only(bottom: 8), child: ResumenAvion(avion: a)),
      ]),
    );
  }
}
