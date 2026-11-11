// Mis reservas: consultar, modificar y cancelar
import 'package:flutter/material.dart';

import '../servicios/api.dart';
import '../servicios/sesion.dart';
import '../utils/comunes.dart';
import 'acceso.dart';
import 'asientos.dart';
import 'factura.dart';

class PantallaReservas extends StatefulWidget {
  const PantallaReservas({super.key, required this.sesion});

  final Sesion sesion;

  @override
  State<PantallaReservas> createState() => PantallaReservasState();
}

class PantallaReservasState extends State<PantallaReservas> {
  List<dynamic> _reservas = [];
  String? _filtro;
  bool _cargando = false;

  Api get _api => widget.sesion.api;

  @override
  void initState() {
    super.initState();
    widget.sesion.addListener(_alCambiarSesion);
    cargar();
  }

  @override
  void dispose() {
    widget.sesion.removeListener(_alCambiarSesion);
    super.dispose();
  }

  void _alCambiarSesion() {
    if (!mounted) return;
    setState(() => _reservas = []);
    cargar();
  }

  Future<void> cargar() async {
    if (!widget.sesion.autenticado) return;
    setState(() => _cargando = true);
    try {
      final r = await _api.listarReservas(estado: _filtro);
      if (mounted) setState(() => _reservas = r['reservas'] as List);
    } on ApiError catch (e) {
      if (mounted) avisar(context, e.texto, TipoAviso.error);
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  Future<void> _verDetalle(int id) async {
    try {
      final r = await _api.detalleReserva(id);
      if (!mounted) return;
      final reserva = r['reserva'] as Map<String, dynamic>;
      final v = r['vuelo'] as Map<String, dynamic>;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Reserva #${reserva['id']} · ${reserva['estado']}'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${v['aerolinea']} ${v['codigo']}: ${v['origen']} – ${v['destino']}\n'
                  'Salida ${fechaHora(v['fecha_salida'] as String)} · Llegada ${fechaHora(v['fecha_llegada'] as String)}'),
              const SizedBox(height: 10),
              for (final p in reserva['detalle_pasajeros'] as List)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('${p['asiento']} (${p['clase']}) · ${p['nombre']} · ${p['tipo_documento']} '
                      '${p['documento']} · ${dinero(p['precio'] as num)}'),
                ),
              const SizedBox(height: 8),
              Text('Total: ${dinero(reserva['total'] as num)}', style: const TextStyle(fontWeight: FontWeight.bold)),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cerrar'))],
        ),
      );
    } on ApiError catch (e) {
      if (mounted) avisar(context, e.texto, TipoAviso.error);
    }
  }

  Future<void> _modificar(int id) async {
    try {
      final r = await _api.detalleReserva(id);
      if (!mounted) return;
      final reserva = r['reserva'] as Map<String, dynamic>;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PantallaAsientos(
            sesion: widget.sesion,
            vueloId: reserva['vuelo_id'] as int,
            edicion: EdicionReserva(reserva['id'] as int, reserva['detalle_pasajeros'] as List),
          ),
        ),
      );
      cargar();
    } on ApiError catch (e) {
      if (mounted) avisar(context, e.texto, TipoAviso.error);
    }
  }

  Future<void> _cancelar(Map<String, dynamic> reserva) async {
    final ok = await confirmar(context,
        titulo: 'Cancelar reserva #${reserva['id']}',
        mensaje: 'Los asientos ${reserva['asientos']} quedarán libres para otros usuarios. ¿Continuar?',
        textoOk: 'Sí, cancelar');
    if (!ok) return;
    try {
      final r = await _api.cancelarReserva(reserva['id'] as int);
      if (!mounted) return;
      avisar(context, r['mensaje'] as String);
      cargar();
    } on ApiError catch (e) {
      if (mounted) avisar(context, e.texto, TipoAviso.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.sesion.autenticado) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Inicie sesión para ver sus reservas'),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => PantallaAcceso(sesion: widget.sesion))),
            child: const Text('Iniciar sesión'),
          ),
        ]),
      );
    }
    return RefreshIndicator(
      onRefresh: cargar,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        Centrado(
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('Mis reservas', style: Theme.of(context).textTheme.titleLarge),
            DropdownButton<String?>(
              value: _filtro,
              items: const [
                DropdownMenuItem(value: null, child: Text('Todas')),
                DropdownMenuItem(value: 'CONFIRMADA', child: Text('Confirmadas')),
                DropdownMenuItem(value: 'CANCELADA', child: Text('Canceladas')),
              ],
              onChanged: (v) {
                setState(() => _filtro = v);
                cargar();
              },
            ),
          ]),
        ),
        const SizedBox(height: 8),
        if (_cargando) const LinearProgressIndicator(),
        if (!_cargando && _reservas.isEmpty)
          const Center(child: Padding(padding: EdgeInsets.all(30), child: Text('No tiene reservas'))),
        for (final r in _reservas)
          Centrado(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text('Reserva #${r['id']} · ${r['codigo_vuelo']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                    EtiquetaEstado(r['estado'] as String),
                  ]),
                  const SizedBox(height: 4),
                  Text('Asientos: ${r['asientos']} · Total ${dinero(r['total'] as num)}\n'
                      'Fecha: ${fechaHora(r['fecha_reserva'] as String)}'
                      '${r['fecha_salida'] != null ? '\nSalida del vuelo: ${fechaHora(r['fecha_salida'] as String)}' : ''}'),
                  if (r['estado'] == 'CONFIRMADA' && r['despegado'] == true)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('El vuelo ya despegó: la reserva no se puede modificar ni cancelar',
                          style: TextStyle(color: Theme.of(context).colorScheme.outline, fontStyle: FontStyle.italic)),
                    ),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 6, children: [
                    OutlinedButton(onPressed: () => _verDetalle(r['id'] as int), child: const Text('Detalle')),
                    if (r['estado'] == 'CONFIRMADA') ...[
                      FilledButton.tonalIcon(
                        onPressed: () => Navigator.push(context, MaterialPageRoute(
                            builder: (_) => PantallaFactura(sesion: widget.sesion, reservaId: r['id'] as int))),
                        icon: const Icon(Icons.receipt_long),
                        label: const Text('Factura XML'),
                      ),
                      if (r['despegado'] != true) ...[
                        FilledButton(onPressed: () => _modificar(r['id'] as int), child: const Text('Modificar')),
                        FilledButton(
                          style: FilledButton.styleFrom(backgroundColor: const Color(0xFFDC4040)),
                          onPressed: () => _cancelar(r as Map<String, dynamic>),
                          child: const Text('Cancelar'),
                        ),
                      ],
                    ],
                  ]),
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}
