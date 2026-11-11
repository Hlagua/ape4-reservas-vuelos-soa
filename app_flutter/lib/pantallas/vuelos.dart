// Búsqueda de vuelos
import 'dart:async';

import 'package:flutter/material.dart';

import '../servicios/api.dart';
import '../servicios/sesion.dart';
import '../utils/buscador.dart';
import '../utils/comunes.dart';
import '../utils/validaciones.dart';
import 'asientos.dart';

class PantallaVuelos extends StatefulWidget {
  const PantallaVuelos({super.key, required this.sesion});

  final Sesion sesion;

  @override
  State<PantallaVuelos> createState() => PantallaVuelosState();
}

class PantallaVuelosState extends State<PantallaVuelos> {
  List<String> _origenes = [];
  List<String> _destinos = [];
  String? _origen;
  String? _destino;
  DateTime? _fecha;
  int _pasajeros = 1;
  List<dynamic> _vuelos = [];
  String _resumen = '';
  bool _cargando = true;
  Timer? _refresco;

  /// Cada cuánto se vuelve a consultar la lista (vuelos nuevos y asientos disponibles).
  static const _intervalo = Duration(seconds: 30);

  @override
  void initState() {
    super.initState();
    widget.sesion.vuelosCambiados.addListener(actualizar);
    _refresco = Timer.periodic(_intervalo, (_) => actualizar());
    _iniciar();
  }

  @override
  void dispose() {
    widget.sesion.vuelosCambiados.removeListener(actualizar);
    _refresco?.cancel();
    super.dispose();
  }

  Future<void> _cargarCiudades({bool silencioso = false}) async {
    try {
      final c = await widget.sesion.api.ciudades();
      if (!mounted) return;
      setState(() {
        _origenes = (c['origenes'] as List).cast<String>();
        _destinos = (c['destinos'] as List).cast<String>();
      });
    } on ApiError catch (e) {
      if (mounted && !silencioso) avisar(context, e.texto, TipoAviso.error);
    }
  }

  Future<void> _iniciar() async {
    await _cargarCiudades();
    await _buscar();
  }

  /// Vuelve a consultar ciudades y vuelos sin borrar la lista ni mostrar errores
  /// (al crear un vuelo, al volver a la pestaña y cada 30 segundos).
  Future<void> actualizar() async {
    if (!mounted || _cargando) return;
    await _cargarCiudades(silencioso: true);
    await _buscar(silencioso: true);
  }

  String _iso(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _buscar({bool silencioso = false}) async {
    if (!silencioso) setState(() => _cargando = true);
    try {
      final r = await widget.sesion.api.buscarVuelos({
        'origen': ?_origen,
        'destino': ?_destino,
        if (_fecha != null) 'fecha': _iso(_fecha!),
        'pasajeros': '$_pasajeros',
      });
      if (!mounted) return;
      final total = r['total'] as int;
      setState(() {
        _vuelos = r['vuelos'] as List;
        _resumen = '$total vuelo(s) encontrados${total == 100 ? ' (mostrando los primeros 100)' : ''}';
      });
    } on ApiError catch (e) {
      if (mounted && !silencioso) {
        setState(() => _resumen = e.texto);
        avisar(context, e.texto, TipoAviso.error);
      }
    } finally {
      if (mounted && !silencioso) setState(() => _cargando = false);
    }
  }

  Future<void> _elegirFecha() async {
    final hoy = DateUtils.dateOnly(DateTime.now());
    final fecha = await showDatePicker(
      context: context,
      firstDate: hoy,
      lastDate: DateTime(hoy.year + 1, hoy.month, hoy.day),
      initialDate: _fecha ?? hoy,
      helpText: 'Fecha del vuelo',
      cancelText: 'Cancelar',
      confirmText: 'Aceptar',
    );
    if (fecha != null) setState(() => _fecha = fecha);
  }

  Future<void> _abrirMapa(int vueloId) async {
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => PantallaAsientos(sesion: widget.sesion, vueloId: vueloId)));
    if (mounted) _buscar(); // los asientos disponibles pudieron cambiar
  }

  /// Buscador de ciudad: al escribir muestra las 5 más parecidas; vacío = todas.
  Widget _selector(String etiqueta, String? valor, List<String> opciones, ValueChanged<String?> cambio,
      {String? deshabilitada}) {
    return CampoBuscador(
      etiqueta: etiqueta,
      textoVacio: 'Todos',
      icono: etiqueta == 'Origen' ? Icons.flight_takeoff : Icons.flight_land,
      opciones: [for (final o in opciones) (o, o)],
      valor: valor,
      excluir: deshabilitada,
      alCambiar: (v) {
        cambio(v);
        _buscar(); // la lista se actualiza al elegir o quitar la ciudad
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(16), children: [
      Centrado(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: LayoutBuilder(builder: (context, c) {
              final ancho = c.maxWidth >= 760 ? (c.maxWidth - 48) / 5 : (c.maxWidth >= 400 ? (c.maxWidth - 12) / 2 : c.maxWidth);
              return Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
                SizedBox(
                    width: ancho,
                    child: _selector('Origen', _origen, _origenes, (v) {
                      setState(() {
                        _origen = v;
                        if (_destino == v) _destino = null; // el destino no puede ser el origen
                      });
                    })),
                SizedBox(
                    width: ancho,
                    child: _selector('Destino', _destino, _destinos, (v) => setState(() => _destino = v),
                        deshabilitada: _origen)),
                SizedBox(
                  width: ancho,
                  child: InkWell(
                    onTap: _elegirFecha,
                    child: InputDecorator(
                      decoration: InputDecoration(
                        labelText: 'Fecha',
                        suffixIcon: _fecha == null
                            ? const Icon(Icons.calendar_today, size: 18)
                            : IconButton(
                                tooltip: 'Quitar fecha',
                                icon: const Icon(Icons.clear, size: 18),
                                onPressed: () => setState(() => _fecha = null)),
                      ),
                      child: Text(_fecha == null ? 'Cualquiera' : _iso(_fecha!)),
                    ),
                  ),
                ),
                SizedBox(
                  width: ancho,
                  child: DropdownButtonFormField<int>(
                    initialValue: _pasajeros,
                    decoration: const InputDecoration(labelText: 'Pasajeros'),
                    items: [
                      for (var i = 1; i <= maxAsientos; i++) DropdownMenuItem(value: i, child: Text('$i')),
                    ],
                    onChanged: (v) => setState(() => _pasajeros = v ?? 1),
                  ),
                ),
                SizedBox(
                  width: ancho,
                  child: FilledButton.icon(
                    onPressed: _cargando ? null : _buscar,
                    icon: const Icon(Icons.search),
                    label: const Text('Buscar'),
                  ),
                ),
              ]);
            }),
          ),
        ),
      ),
      const SizedBox(height: 10),
      Centrado(child: Text(_resumen)),
      const SizedBox(height: 6),
      if (_cargando) const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator())),
      if (!_cargando && _vuelos.isEmpty)
        const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('No hay vuelos con esos filtros'))),
      if (!_cargando)
        for (final v in _vuelos)
          Centrado(
            child: Card(
              child: ListTile(
                leading: const Icon(Icons.flight_takeoff),
                title: Text('${v['origen']} – ${v['destino']}'),
                subtitle: Text('${v['aerolinea']} ${v['codigo']} · ${fechaHora(v['fecha_salida'] as String)} – '
                    '${hora(v['fecha_llegada'] as String)}\n'
                    'Desde ${dinero(v['precio'] as num)} · ${v['asientos_disponibles']} / ${v['asientos_totales']} disponibles'),
                isThreeLine: true,
                trailing: FilledButton(
                  onPressed: v['asientos_disponibles'] == 0 ? null : () => _abrirMapa(v['id'] as int),
                  child: const Text('Asientos'),
                ),
              ),
            ),
          ),
    ]);
  }
}
