// Crear vuelos: solo la ve el administrador (ingresó con ADMIN_KEY).
// Se elige origen, destino, aerolínea, tipo de avión (cada uno con su número de asientos),
// fecha y hora de salida y de llegada, y el precio base (Economy).
import 'package:flutter/material.dart';

import '../servicios/api.dart';
import '../servicios/sesion.dart';
import '../utils/comunes.dart';
import '../utils/validaciones.dart';
import 'asientos.dart';

const _aerolineas = ['LATAM', 'Avianca', 'Equair', 'Iberia', 'UTA Air'];

class PantallaCrearVuelo extends StatefulWidget {
  const PantallaCrearVuelo({super.key, required this.sesion});

  final Sesion sesion;

  @override
  State<PantallaCrearVuelo> createState() => PantallaCrearVueloState();
}

class PantallaCrearVueloState extends State<PantallaCrearVuelo> {
  final _form = GlobalKey<FormState>();
  final _precio = TextEditingController();
  TextEditingController? _origen, _destino, _aerolinea;
  List<String> _ciudades = [];
  List<Map<String, dynamic>> _aviones = [];
  String? _avion;
  DateTime? _salida, _llegada;
  bool _enviando = false;
  String? _errorCarga;
  Map<String, dynamic>? _creado;
  Map<String, dynamic> _erroresServidor = {};

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

  Future<void> cargar() async {
    try {
      final r = await Future.wait([_api.aviones(), _api.ciudades()]);
      if (!mounted) return;
      setState(() {
        _aviones = (r[0]['aviones'] as List).cast<Map<String, dynamic>>();
        _ciudades = {...(r[1]['origenes'] as List).cast<String>(), ...(r[1]['destinos'] as List).cast<String>()}
            .toList()
          ..sort();
        _errorCarga = null;
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

  Future<void> _crear() async {
    setState(() => _erroresServidor = {});
    final fechasOk = _errorFechas() == null;
    if (!_form.currentState!.validate() || !fechasOk) {
      setState(() {}); // muestra el error de fechas
      return;
    }
    final avion = _avionElegido!;
    final origen = formatearNombre(_origen!.text), destino = formatearNombre(_destino!.text);
    final ok = await confirmar(context,
        titulo: 'Crear vuelo $origen – $destino',
        mensaje: '${_aerolinea!.text.trim()} · ${avion['avion']} (${avion['total_asientos']} asientos)\n'
            'Salida ${_mostrar(_salida)} · Llegada ${_mostrar(_llegada)}\n'
            'Precio base Economy ${dinero(double.parse(_precio.text))}',
        textoOk: 'Crear vuelo');
    if (!ok || !mounted) return;
    final clave = widget.sesion.claveAdmin;
    if (clave == null) return;
    setState(() => _enviando = true);
    try {
      final r = await _api.adminCrearVuelo(clave, {
        'origen': origen,
        'destino': destino,
        'aerolinea': _aerolinea!.text.trim(),
        'avion': avion['avion'] as String,
        'fecha_salida': _iso(_salida!),
        'fecha_llegada': _iso(_llegada!),
        'precio': double.parse(_precio.text),
      });
      if (!mounted) return;
      avisar(context, r['mensaje'] as String);
      setState(() => _creado = r['vuelo'] as Map<String, dynamic>);
      cargar(); // por si hay ciudades nuevas
    } on ApiError catch (e) {
      if (!mounted) return;
      avisar(context, e.texto, TipoAviso.error);
      if (e.status == 403) {
        widget.sesion.cerrar();
      } else if (e.detalle is Map) {
        setState(() => _erroresServidor = Map<String, dynamic>.from(e.detalle as Map));
      }
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  void _limpiar() {
    _form.currentState?.reset();
    _origen?.clear();
    _destino?.clear();
    _aerolinea?.clear();
    _precio.clear();
    setState(() {
      _avion = null;
      _salida = _llegada = null;
      _creado = null;
      _erroresServidor = {};
    });
  }

  Widget _autocompletar({
    required String etiqueta,
    required List<String> opciones,
    required void Function(TextEditingController) alCrear,
    required String campo,
    String? Function(String)? validarExtra,
  }) {
    return Autocomplete<String>(
      optionsBuilder: (v) {
        final t = v.text.trim().toLowerCase();
        return t.isEmpty ? opciones : opciones.where((o) => o.toLowerCase().contains(t));
      },
      fieldViewBuilder: (context, controller, foco, alEnviar) {
        alCrear(controller);
        return TextFormField(
          controller: controller,
          focusNode: foco,
          maxLength: 60,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(labelText: etiqueta, counterText: '', errorText: _erroresServidor[campo] as String?),
          validator: (v) {
            final t = (v ?? '').trim();
            if (t.length < 2) return '$etiqueta es obligatorio';
            return validarExtra?.call(t);
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final avion = _avionElegido;
    final precio = double.tryParse(_precio.text);
    final errorFechas = _salida == null && _llegada == null ? null : _errorFechas();
    return ListView(padding: const EdgeInsets.all(16), children: [
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
                const Text('Complete todos los datos. El mapa de asientos del vuelo será el del avión elegido.'),
                if (_errorCarga != null) ...[
                  const SizedBox(height: 8),
                  Text(_errorCarga!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  TextButton(onPressed: cargar, child: const Text('Reintentar')),
                ],
                const SizedBox(height: 14),
                Wrap(spacing: 12, runSpacing: 12, children: [
                  SizedBox(
                    width: 340,
                    child: _autocompletar(
                        etiqueta: 'Origen', opciones: _ciudades, campo: 'origen', alCrear: (c) => _origen = c),
                  ),
                  SizedBox(
                    width: 340,
                    child: _autocompletar(
                      etiqueta: 'Destino',
                      opciones: _ciudades,
                      campo: 'destino',
                      alCrear: (c) => _destino = c,
                      validarExtra: (t) => t.toLowerCase() == _origen?.text.trim().toLowerCase()
                          ? 'El destino debe ser distinto del origen'
                          : null,
                    ),
                  ),
                  SizedBox(
                    width: 340,
                    child: _autocompletar(
                        etiqueta: 'Aerolínea', opciones: _aerolineas, campo: 'aerolinea', alCrear: (c) => _aerolinea = c),
                  ),
                  SizedBox(
                    width: 340,
                    child: DropdownButtonFormField<String>(
                      key: ValueKey('avion-${_creado == null}'),
                      initialValue: _avion,
                      isExpanded: true,
                      decoration: InputDecoration(labelText: 'Tipo de avión', errorText: _erroresServidor['avion'] as String?),
                      items: [
                        for (final a in _aviones)
                          DropdownMenuItem(
                            value: a['avion'] as String,
                            child: Text('${a['avion']} · ${a['total_asientos']} asientos', overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      validator: (v) => v == null ? 'Elija el tipo de avión' : null,
                      onChanged: (v) => setState(() => _avion = v),
                    ),
                  ),
                ]),
                if (avion != null) ...[
                  const SizedBox(height: 10),
                  _ResumenAvion(avion: avion, precioBase: precio),
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
                if (errorFechas != null || _erroresServidor['fecha_salida'] != null || _erroresServidor['fecha_llegada'] != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      errorFechas ?? (_erroresServidor['fecha_salida'] ?? _erroresServidor['fecha_llegada']) as String,
                      style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12),
                    ),
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
    ]);
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

/// Asientos por clase del avión elegido y precio de cada clase con el precio base.
class _ResumenAvion extends StatelessWidget {
  const _ResumenAvion({required this.avion, required this.precioBase});

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
            Text('${c['nombre']}: ${c['asientos']}'
                '${precioBase == null ? '' : ' · ${dinero(precioBase! * (c['factor'] as num))}'}'),
        ]),
      ]),
    );
  }
}
