// Crear vuelos: solo la ve el administrador (usuario con rol ADMIN).
// Se elige origen, destino, aerolínea y tipo de avión de los catálogos (pestaña Catálogos),
// la fecha y hora de salida y de llegada, y el precio base (Economy).
import 'package:flutter/material.dart';

import '../servicios/api.dart';
import '../servicios/sesion.dart';
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
      _salida = d;
      // Se propone una llegada una hora después si aún no hay una válida
      if (_llegada == null || !_llegada!.isAfter(d)) _llegada = d.add(const Duration(hours: 1));
    });
  }

  Future<void> _elegirLlegada() async {
    final d = await _elegirFechaHora(_llegada, _salida ?? DateTime.now());
    if (d != null) setState(() => _llegada = d);
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
      _creado = null;
      _erroresServidor = {};
      _mostrarErrorFechas = false;
      _version++;
    });
  }

  Widget _selector({
    required String etiqueta,
    required String campo,
    required String? valor,
    required List<(String, String)> opciones, // (valor, texto)
    required void Function(String?) alCambiar,
    String? Function(String?)? validar,
  }) {
    return SizedBox(
      width: 340,
      child: DropdownButtonFormField<String>(
        key: ValueKey('$campo-$_version-${opciones.length}'),
        initialValue: valor,
        isExpanded: true,
        decoration: InputDecoration(labelText: etiqueta, errorText: _erroresServidor[campo] as String?),
        items: [
          for (final (v, texto) in opciones)
            DropdownMenuItem(value: v, child: Text(texto, overflow: TextOverflow.ellipsis)),
        ],
        validator: (v) => v == null ? 'Elija ${etiqueta.toLowerCase()}' : validar?.call(v),
        onChanged: (v) => setState(() => alCambiar(v)),
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
                        alCambiar: (v) => _origen = v),
                    _selector(
                      etiqueta: 'Destino',
                      campo: 'destino',
                      valor: _destino,
                      opciones: ciudades,
                      alCambiar: (v) => _destino = v,
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
