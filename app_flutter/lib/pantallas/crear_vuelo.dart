// Crear vuelos: solo la ve el administrador (usuario con rol ADMIN).
// Se elige origen, destino, aerolínea y tipo de avión de los catálogos (pestaña Catálogos),
// la fecha y hora de salida y de llegada, y el precio base (Economy).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../servicios/api.dart';
import '../servicios/sesion.dart';
import '../utils/buscador.dart';
import '../utils/comunes.dart';
import '../utils/validaciones.dart';
import 'asientos.dart';

class PantallaCrearVuelo extends StatefulWidget {
  const PantallaCrearVuelo({super.key, required this.sesion});

  final Sesion sesion;

  @override
  State<PantallaCrearVuelo> createState() => PantallaCrearVueloState();
}

class PantallaCrearVueloState extends State<PantallaCrearVuelo> {
  final _form = GlobalKey<FormState>();
  final _precio = TextEditingController();
  List<String> _ciudades = [];
  Map<String, dynamic> _coordenadas = {};
  bool _llegadaManual = false; // el administrador eligió la llegada a mano (no se reemplaza sola)
  List<Map<String, dynamic>> _aerolineas = [];
  List<Map<String, dynamic>> _aviones = [];
  String? _origen, _destino, _aerolinea, _avion;
  DateTime? _salida, _llegada;
  bool _enviando = false;
  String? _errorCarga;
  Map<String, dynamic>? _creado;
  Map<String, dynamic> _erroresServidor = {};
  int _version = 0; // reinicia los selectores al limpiar el formulario

  Api get _api => widget.sesion.api;

  @override
  void initState() {
    super.initState();
    cargar();
  }

  @override
  void dispose() {
    _precio.dispose();
    super.dispose();
  }

  /// Catálogos actuales (pueden haber cambiado en la pestaña Catálogos).
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
        // Si un valor elegido ya no existe se descarta
        if (!_ciudades.contains(_origen)) _origen = null;
        if (!_ciudades.contains(_destino)) _destino = null;
        if (!_aerolineas.any((a) => a['nombre'] == _aerolinea)) _aerolinea = null;
        if (!_aviones.any((a) => a['avion'] == _avion)) _avion = null;
      });
    } on ApiError catch (e) {
      if (mounted) setState(() => _errorCarga = e.texto);
    }
  }

  /// Distancia en km entre origen y destino (fórmula del haversine), si ambas ciudades tienen coordenadas.
  double? get _distanciaKm {
    final a = _coordenadas[_origen] as List?, b = _coordenadas[_destino] as List?;
    if (a == null || b == null || _origen == _destino) return null;
    double rad(num g) => g * math.pi / 180;
    final dLat = rad(b[0] - a[0]), dLon = rad(b[1] - a[1]);
    final h = math.pow(math.sin(dLat / 2), 2) +
        math.cos(rad(a[0])) * math.cos(rad(b[0])) * math.pow(math.sin(dLon / 2), 2);
    return 2 * 6371 * math.asin(math.sqrt(h));
  }

  /// Duración sugerida: crucero a 800 km/h más 30 minutos de despegue y aterrizaje, redondeada a 5 minutos.
  Duration? get _duracionSugerida {
    final km = _distanciaKm;
    if (km == null) return null;
    final minutos = (km / 800 * 60 + 30).clamp(25, 20 * 60);
    return Duration(minutes: (minutos / 5).round() * 5);
  }

  /// Propone la llegada según la duración sugerida (si el administrador no la eligió a mano).
  void _proponerLlegada({bool forzar = false}) {
    final sugerida = _duracionSugerida;
    if (_salida == null || sugerida == null || (_llegadaManual && !forzar)) return;
    _llegada = _salida!.add(sugerida);
    _llegadaManual = false;
  }

  String _textoDuracion(Duration d) =>
      '${d.inHours > 0 ? '${d.inHours}h ' : ''}${(d.inMinutes % 60).toString().padLeft(2, '0')}m';

  Map<String, dynamic>? get _avionElegido =>
      _avion == null ? null : _aviones.firstWhere((a) => a['avion'] == _avion);

  String _iso(DateTime d) => d.toIso8601String().substring(0, 16);

  String _mostrar(DateTime? d) => d == null ? 'Elegir' : fechaHora(_iso(d));

  Future<DateTime?> _elegirFechaHora(DateTime? actual, DateTime minimo) async {
    final base = actual ?? minimo;
    final fecha = await showDatePicker(
      context: context,
      initialDate: base.isBefore(minimo) ? minimo : base,
      firstDate: DateTime(minimo.year, minimo.month, minimo.day),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      helpText: 'Fecha',
    );
    if (fecha == null || !mounted) return null;
    final hora = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(base), helpText: 'Hora');
    if (hora == null) return null;
    return DateTime(fecha.year, fecha.month, fecha.day, hora.hour, hora.minute);
  }

  Future<void> _elegirSalida() async {
    final d = await _elegirFechaHora(_salida, DateTime.now().add(const Duration(hours: 1)));
    if (d == null) return;
    setState(() {
      final anterior = _salida;
      _salida = d;
      if (_duracionSugerida != null && !_llegadaManual) {
        _proponerLlegada();
      } else if (_llegada != null && anterior != null && _llegada!.isAfter(anterior)) {
        _llegada = d.add(_llegada!.difference(anterior)); // se conserva la duración elegida
      } else if (_llegada == null || !_llegada!.isAfter(d)) {
        _llegada = d.add(const Duration(hours: 1));
      }
    });
  }

  Future<void> _elegirLlegada() async {
    final d = await _elegirFechaHora(_llegada, _salida ?? DateTime.now());
    if (d != null) {
      setState(() {
        _llegada = d;
        _llegadaManual = true;
      });
    }
  }

  String? _errorFechas() {
    if (_salida == null) return 'Elija la fecha y hora de salida';
    if (!_salida!.isAfter(DateTime.now())) return 'La salida debe ser una fecha y hora futura';
    if (_llegada == null) return 'Elija la fecha y hora de llegada';
    final minutos = _llegada!.difference(_salida!).inMinutes;
    if (minutos < 20 || minutos > 20 * 60) return 'La llegada debe ser entre 20 minutos y 20 horas después de la salida';
    return null;
  }

  bool _mostrarErrorFechas = false;

  Future<void> _crear() async {
    setState(() {
      _erroresServidor = {};
      _mostrarErrorFechas = true;
    });
    final fechasOk = _errorFechas() == null;
    if (!_form.currentState!.validate() || !fechasOk) return;
    final avion = _avionElegido!;
    final ok = await confirmar(context,
        titulo: 'Crear vuelo $_origen – $_destino',
        mensaje: '$_aerolinea · ${avion['avion']} (${avion['total_asientos']} asientos)\n'
            'Salida ${_mostrar(_salida)} · Llegada ${_mostrar(_llegada)}\n'
            'Precio base Economy ${dinero(double.parse(_precio.text))}',
        textoOk: 'Crear vuelo');
    if (!ok || !mounted) return;
    setState(() => _enviando = true);
    try {
      final r = await _api.crearVuelo({
        'origen': _origen!,
        'destino': _destino!,
        'aerolinea': _aerolinea!,
        'avion': _avion!,
        'fecha_salida': _iso(_salida!),
        'fecha_llegada': _iso(_llegada!),
        'precio': double.parse(_precio.text),
      });
      if (!mounted) return;
      avisar(context, r['mensaje'] as String);
      setState(() => _creado = r['vuelo'] as Map<String, dynamic>);
      widget.sesion.vuelosCambiados.value++; // la búsqueda de vuelos se actualiza sola
    } on ApiError catch (e) {
      if (!mounted) return;
      avisar(context, e.texto, TipoAviso.error);
      if (e.detalle is Map) setState(() => _erroresServidor = Map<String, dynamic>.from(e.detalle as Map));
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  void _limpiar() {
    _form.currentState?.reset();
    _precio.clear();
    setState(() {
      _origen = _destino = _aerolinea = _avion = null;
      _salida = _llegada = null;
      _llegadaManual = false;
      _creado = null;
      _erroresServidor = {};
      _mostrarErrorFechas = false;
      _version++;
    });
  }

  /// Distancia y duración sugerida entre origen y destino.
  Widget _sugerencia() {
    final sugerida = _duracionSugerida!;
    final actual = _salida != null && _llegada != null ? _llegada!.difference(_salida!) : null;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
        const Icon(Icons.straighten, size: 18),
        Text('$_origen – $_destino ≈ ${_distanciaKm!.round()} km · duración sugerida ${_textoDuracion(sugerida)}'
            '${_salida == null ? ' (elija la salida y la llegada se calcula sola)' : ''}'),
        if (_salida != null && actual != sugerida)
          TextButton(
            onPressed: () => setState(() => _proponerLlegada(forzar: true)),
            child: const Text('Usar la duración sugerida'),
          ),
      ]),
    );
  }

  Widget _selector({
    required String etiqueta,
    required String campo,
    required String? valor,
    required List<(String, String)> opciones, // (valor, texto)
    required void Function(String?) alCambiar,
    String? Function(String?)? validar,
    String? excluir,
    IconData icono = Icons.search,
    String Function(String) filtro = Filtro.busqueda,
  }) {
    // Buscador: al escribir se muestran las 5 opciones más parecidas (no se despliega toda la lista)
    return SizedBox(
      width: 340,
      child: CampoBuscador(
        key: ValueKey('$campo-$_version'),
        etiqueta: etiqueta,
        icono: icono,
        filtro: filtro,
        opciones: opciones,
        valor: valor,
        excluir: excluir,
        errorText: _erroresServidor[campo] as String?,
        validar: (v) => v == null ? 'Busque y elija ${etiqueta.toLowerCase()}' : validar?.call(v),
        alCambiar: (v) => setState(() => alCambiar(v)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final avion = _avionElegido;
    final precio = double.tryParse(_precio.text);
    final errorFechas = _mostrarErrorFechas ? _errorFechas() : null;
    final errorFechasServidor = (_erroresServidor['fecha_salida'] ?? _erroresServidor['fecha_llegada']) as String?;
    final ciudades = [for (final c in _ciudades) (c, c)];
    return RefreshIndicator(
      onRefresh: cargar,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        Centrado(
          ancho: 760,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _form,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text('Crear vuelo', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 4),
                  const Text('Complete todos los datos. Las ciudades, aerolíneas y aviones se crean en la pestaña '
                      'Catálogos. El mapa de asientos del vuelo será el del avión elegido.'),
                  if (_errorCarga != null) ...[
                    const SizedBox(height: 8),
                    Text(_errorCarga!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    TextButton(onPressed: cargar, child: const Text('Reintentar')),
                  ],
                  const SizedBox(height: 14),
                  Wrap(spacing: 12, runSpacing: 12, children: [
                    _selector(
                        etiqueta: 'Origen',
                        campo: 'origen',
                        valor: _origen,
                        opciones: ciudades,
                        icono: Icons.flight_takeoff,
                        alCambiar: (v) {
                          _origen = v;
                          _proponerLlegada();
                        }),
                    _selector(
                      etiqueta: 'Destino',
                      campo: 'destino',
                      valor: _destino,
                      opciones: ciudades,
                      icono: Icons.flight_land,
                      excluir: _origen,
                      alCambiar: (v) {
                        _destino = v;
                        _proponerLlegada();
                      },
                      validar: (v) => v == _origen ? 'El destino debe ser distinto del origen' : null,
                    ),
                    _selector(
                      etiqueta: 'Aerolínea',
                      campo: 'aerolinea',
                      valor: _aerolinea,
                      opciones: [for (final a in _aerolineas) (a['nombre'] as String, '${a['nombre']} (${a['codigo']})')],
                      alCambiar: (v) => _aerolinea = v,
                    ),
                    _selector(
                      etiqueta: 'Tipo de avión',
                      campo: 'avion',
                      valor: _avion,
                      opciones: [
                        for (final a in _aviones) (a['avion'] as String, '${a['avion']} · ${a['total_asientos']} asientos')
                      ],
                      filtro: Filtro.busquedaAlfanumerica, // los modelos llevan números (A320, 737)
                      alCambiar: (v) => _avion = v,
                    ),
                  ]),
                  if (avion != null) ...[
                    const SizedBox(height: 10),
                    ResumenAvion(avion: avion, precioBase: precio),
                  ],
                  const SizedBox(height: 14),
                  Wrap(spacing: 12, runSpacing: 12, children: [
                    _BotonFecha(etiqueta: 'Salida', valor: _mostrar(_salida), alPulsar: _elegirSalida),
                    _BotonFecha(
                      etiqueta: 'Llegada',
                      valor: _mostrar(_llegada),
                      alPulsar: _salida == null ? null : _elegirLlegada,
                    ),
                    if (_salida != null && _llegada != null && _llegada!.isAfter(_salida!))
                      Padding(
                        padding: const EdgeInsets.only(top: 14),
                        child: Text('Duración ${duracion(_iso(_salida!), _iso(_llegada!))}'),
                      ),
                  ]),
                  if (_duracionSugerida != null) _sugerencia(),
                  if (errorFechas != null || errorFechasServidor != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(errorFechas ?? errorFechasServidor!,
                          style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
                    ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: 340,
                    child: TextFormField(
                      controller: _precio,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [Filtro.formateador(_filtroPrecio)],
                      decoration: InputDecoration(
                        labelText: 'Precio base (Economy)',
                        prefixText: '\$ ',
                        errorText: _erroresServidor['precio'] as String?,
                      ),
                      onChanged: (_) => setState(() {}),
                      validator: (v) {
                        final n = double.tryParse(v ?? '');
                        if (n == null) return 'El precio es obligatorio';
                        if (n < 1 || n > 10000) return 'Entre \$1 y \$10000';
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(children: [
                    OutlinedButton(onPressed: _enviando ? null : _limpiar, child: const Text('Limpiar')),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: _enviando || _aviones.isEmpty ? null : _crear,
                      icon: const Icon(Icons.flight_takeoff),
                      label: Text(_enviando ? 'Creando...' : 'Crear vuelo'),
                    ),
                  ]),
                ]),
              ),
            ),
          ),
        ),
        if (_creado != null)
          Centrado(
            ancho: 760,
            child: Card(
              color: const Color(0xFFE3F4EA),
              child: ListTile(
                leading: const Icon(Icons.check_circle, color: Color(0xFF1F9D55)),
                title: Text('Vuelo ${_creado!['codigo']} creado: ${_creado!['origen']} – ${_creado!['destino']}'),
                subtitle: Text('${_creado!['aerolinea']} · ${_creado!['avion']} · ${_creado!['asientos_totales']} asientos\n'
                    'Salida ${fechaHora(_creado!['fecha_salida'] as String)} · '
                    'Llegada ${fechaHora(_creado!['fecha_llegada'] as String)}'),
                isThreeLine: true,
                trailing: TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => PantallaAsientos(sesion: widget.sesion, vueloId: _creado!['id'] as int)),
                  ),
                  child: const Text('Ver asientos'),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Solo números con hasta dos decimales.
String _filtroPrecio(String v) {
  final limpio = v.replaceAll(',', '.').replaceAll(RegExp(r'[^0-9.]'), '');
  final m = RegExp(r'^\d{0,5}(\.\d{0,2})?').firstMatch(limpio);
  return m?.group(0) ?? '';
}

class _BotonFecha extends StatelessWidget {
  const _BotonFecha({required this.etiqueta, required this.valor, required this.alPulsar});

  final String etiqueta;
  final String valor;
  final VoidCallback? alPulsar;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      child: InputDecorator(
        decoration: InputDecoration(labelText: etiqueta, enabled: alPulsar != null),
        child: InkWell(
          onTap: alPulsar,
          child: Row(children: [
            Expanded(child: Text(valor)),
            const Icon(Icons.event, size: 20),
          ]),
        ),
      ),
    );
  }
}

/// Asientos por clase de un avión y, si se da el precio base, el precio de cada clase.
class ResumenAvion extends StatelessWidget {
  const ResumenAvion({super.key, required this.avion, this.precioBase});

  final Map<String, dynamic> avion;
  final double? precioBase;

  @override
  Widget build(BuildContext context) {
    final clases = (avion['clases'] as List).cast<Map<String, dynamic>>();
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${avion['avion']}: ${avion['total_asientos']} asientos', style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Wrap(spacing: 14, runSpacing: 4, children: [
          for (final c in clases)
            Text('${c['nombre']}: ${c['asientos']} (${c['filas']} filas, ${c['configuracion']})'
                '${precioBase == null ? '' : ' · ${dinero(precioBase! * (c['factor'] as num))}'}'),
        ]),
      ]),
    );
  }
}
