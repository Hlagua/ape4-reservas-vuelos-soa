// Mapa de asientos: selección con retención temporal y control de concurrencia
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../servicios/api.dart';
import '../servicios/sesion.dart';
import '../utils/comunes.dart';
import '../utils/validaciones.dart';
import 'acceso.dart';
import 'factura.dart';
import 'mapa_vuelo.dart';

const _intervaloActualizacion = Duration(seconds: 3);

/// Datos de una reserva que se está modificando.
class EdicionReserva {
  EdicionReserva(this.reservaId, this.pasajeros);

  final int reservaId;
  final List<dynamic> pasajeros;
  final Set<String> quitados = {};
}

class _Pasajero {
  _Pasajero({String nombre = '', this.tipo = 'CEDULA', String documento = ''})
      : nombre = TextEditingController(text: nombre),
        documento = TextEditingController(text: documento);

  final TextEditingController nombre;
  final TextEditingController documento;
  String tipo;

  void dispose() {
    nombre.dispose();
    documento.dispose();
  }
}

class PantallaAsientos extends StatefulWidget {
  const PantallaAsientos({super.key, required this.sesion, required this.vueloId, this.edicion});

  final Sesion sesion;
  final int vueloId;
  final EdicionReserva? edicion;

  @override
  State<PantallaAsientos> createState() => _PantallaAsientosState();
}

class _PantallaAsientosState extends State<PantallaAsientos> {
  final _form = GlobalKey<FormState>();
  final Map<String, _Pasajero> _pasajeros = {};
  final Map<String, DateTime> _expiran = {}; // asiento retenido -> hora de expiración
  final Set<String> _liberadosPorMi = {};
  final Map<String, String> _claseDe = {};
  final Map<String, double> _precioClase = {};

  Map<String, dynamic>? _datos;
  String? _claseActiva;
  String? _errorCarga;
  String _actualizado = '';
  bool _cargando = false;
  bool _enviando = false;
  Timer? _temporizador;
  Timer? _reloj;
  Set<String> _original = {}; // datos de la reserva al abrir la edición, para detectar cambios

  Api get _api => widget.sesion.api;

  @override
  void initState() {
    super.initState();
    final edicion = widget.edicion;
    if (edicion != null) {
      var incompletos = false;
      for (final p in edicion.pasajeros) {
        final tipo = p['tipo_documento'] as String;
        // Las reservas hechas con el formato de la guía ({cantidad}) traen pasajeros como consumidor
        // final (tipo "CF"): se muestran como cédula vacía para que el usuario complete los datos reales
        final conocido = tipo == 'CEDULA' || tipo == 'PASAPORTE';
        incompletos = incompletos || !conocido;
        _pasajeros[p['asiento'] as String] = _Pasajero(
            nombre: p['nombre'] as String,
            tipo: conocido ? tipo : 'CEDULA',
            documento: conocido ? p['documento'] as String : '');
      }
      _original = _huella(_pasajeros.keys);
      if (incompletos) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            avisar(context, 'Complete los datos de los pasajeros para guardar los cambios', TipoAviso.info);
          }
        });
      }
    }
    _cargar();
    _temporizador = Timer.periodic(_intervaloActualizacion, (_) => _cargar());
    _reloj = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_expiran.isNotEmpty && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _temporizador?.cancel();
    _reloj?.cancel();
    // Al salir se liberan los asientos retenidos que no se confirmaron
    for (final a in _expiran.keys) {
      _api.soltar(widget.vueloId, a).catchError((_) => <String, dynamic>{});
    }
    for (final p in _pasajeros.values) {
      p.dispose();
    }
    super.dispose();
  }

  Future<void> _cargar() async {
    if (_cargando) return;
    _cargando = true;
    try {
      final datos = await _api.mapaAsientos(widget.vueloId);
      if (!mounted) return;
      final ahora = DateTime.now();
      final antes = _expiran.keys.toSet();
      _expiran.clear();
      for (final r in datos['mis_retenciones'] as List) {
        _expiran[r['asiento'] as String] = ahora.add(Duration(seconds: r['segundos_restantes'] as int));
      }
      final vencidos = antes.where((a) => !_expiran.containsKey(a) && !_liberadosPorMi.contains(a)).toList();
      _liberadosPorMi.clear();

      _claseDe.clear();
      for (final c in datos['clases'] as List) {
        _precioClase[c['clase'] as String] = (c['precio'] as num).toDouble();
        for (final fila in c['filas'] as List) {
          for (final grupo in c['grupos'] as List) {
            for (final letra in grupo as List) {
              _claseDe['$fila$letra'] = c['clase'] as String;
            }
          }
        }
      }
      setState(() {
        _datos = datos;
        _claseActiva ??= (datos['clases'] as List).last['clase'] as String;
        _errorCarga = null;
        final t = TimeOfDay.fromDateTime(ahora);
        _actualizado = 'Actualizado ${t.format(context)} · se actualiza cada ${_intervaloActualizacion.inSeconds} s';
        _sincronizarPasajeros();
      });
      // Mientras se guarda, los asientos retenidos pasan a OCUPADO: no es que hayan expirado
      if (vencidos.isNotEmpty && !_enviando) {
        avisar(context, 'Su selección de ${vencidos.join(', ')} expiró y fue liberada', TipoAviso.error);
      }
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => _errorCarga = e.texto);
      if (e.status == 404) {
        avisar(context, e.mensaje, TipoAviso.error);
        Navigator.pop(context);
      }
    } finally {
      _cargando = false;
    }
  }

  Map<String, dynamic> get _estados => _datos!['estados'] as Map<String, dynamic>;
  Map<String, dynamic> get _misReservados => _datos!['mis_reservados'] as Map<String, dynamic>;

  /// Asientos de esta reserva que siguen en ella (solo en edición).
  List<String> get _propios {
    final edicion = widget.edicion;
    if (edicion == null) return [];
    return _misReservados.keys
        .where((a) => _misReservados[a] == edicion.reservaId && !edicion.quitados.contains(a))
        .toList();
  }

  List<String> get _seleccion => [..._propios, ..._expiran.keys]..sort(_ordenAsientos);

  /// Asientos y datos de pasajeros en un formato comparable.
  Set<String> _huella(Iterable<String> asientos) => {
        for (final a in asientos)
          '$a|${formatearNombre(_pasajeros[a]!.nombre.text)}|${_pasajeros[a]!.tipo}|${_pasajeros[a]!.documento.text}'
      };

  /// En edición: true si cambió algún asiento o dato de pasajero respecto a la reserva guardada.
  bool get _hayCambios {
    if (widget.edicion == null || _datos == null) return false;
    return !setEquals(_huella(_seleccion), _original);
  }

  /// En edición: precio que ya se pagó por cada asiento de la reserva (se conserva si el asiento se mantiene).
  Map<String, double> get _pagado => {
        for (final p in widget.edicion?.pasajeros ?? const [])
          p['asiento'] as String: (p['precio'] as num).toDouble()
      };

  /// Precio de un asiento: el ya pagado si es de la reserva, o el de su clase si es nuevo.
  double _precioDe(String asiento) => _pagado[asiento] ?? _precioClase[_claseDe[asiento]] ?? 0;

  /// Totales con IVA antes y después de la modificación (solo en edición).
  ({double anterior, double nuevo, double diferencia}) get _comparacion {
    double conIva(double v) => (v * (1 + DesgloseIva.iva) * 100).roundToDouble() / 100;
    final anterior = conIva(_pagado.values.fold(0.0, (s, v) => s + v));
    final nuevo = conIva(_seleccion.fold(0.0, (s, a) => s + _precioDe(a)));
    return (anterior: anterior, nuevo: nuevo, diferencia: ((nuevo - anterior) * 100).roundToDouble() / 100);
  }

  /// La flecha atrás pasa por _alSalir en edición o si hay asientos seleccionados sin reservar.
  bool get _salidaControlada => widget.edicion != null || _expiran.isNotEmpty;

  /// Flecha atrás (o botón atrás del sistema): pide confirmación si se perderían asientos o cambios.
  Future<void> _alSalir(bool salio, Object? resultado) async {
    if (salio) return;
    if (widget.edicion == null && _expiran.isNotEmpty) {
      final asientos = _expiran.keys.toList()..sort(_ordenAsientos);
      final ok = await confirmar(context,
          titulo: 'Salir sin reservar',
          mensaje: 'Tiene seleccionados los asientos ${asientos.join(', ')} y aún no confirma la reserva. '
              'Si sale, los asientos se liberarán para otros usuarios. ¿Está seguro de salir?',
          textoOk: 'Sí, salir');
      if (!ok || !mounted) return;
      _liberadosPorMi.addAll(asientos);
      avisar(context, 'Reserva no realizada, los asientos ${asientos.join(', ')} quedaron libres', TipoAviso.info);
    } else if (_hayCambios) {
      final ok = await confirmar(context,
          titulo: 'Salir sin guardar',
          mensaje: '¿Está seguro de salir sin guardar los cambios realizados en la reserva '
              '#${widget.edicion!.reservaId}? Se descartarán y la reserva quedará como estaba.',
          textoOk: 'Sí, salir');
      if (!ok || !mounted) return;
      avisar(context, 'Cambios descartados, la reserva no se modificó', TipoAviso.info);
    }
    if (mounted) Navigator.pop(context); // dispose libera los asientos nuevos retenidos
  }

  int _ordenAsientos(String a, String b) {
    int fila(String s) => int.parse(s.substring(0, s.length - 1));
    final d = fila(a) - fila(b);
    return d != 0 ? d : a.compareTo(b);
  }

  /// Crea o elimina formularios de pasajero cuando cambia la selección.
  void _sincronizarPasajeros() {
    final seleccion = _seleccion.toSet();
    final sobran = _pasajeros.keys.where((a) => !seleccion.contains(a)).toList();
    for (final a in sobran) {
      // En edición se conservan los datos por si el asiento se vuelve a agregar
      if (widget.edicion?.quitados.contains(a) ?? false) continue;
      _pasajeros.remove(a)?.dispose();
    }
    for (final a in seleccion) {
      _pasajeros.putIfAbsent(a, _Pasajero.new);
    }
  }

  String _estadoAsiento(String asiento) {
    final edicion = widget.edicion;
    if (edicion != null && _misReservados[asiento] == edicion.reservaId) {
      return edicion.quitados.contains(asiento) ? 'QUITADO' : 'MIO';
    }
    return (_estados[asiento] as String?) ?? 'DISPONIBLE';
  }

  Future<void> _clicAsiento(String asiento, String estado) async {
    if (widget.sesion.esAdmin) {
      avisar(context, 'Asiento $asiento: ${_descripcion(estado).toLowerCase()}. '
          'El administrador solo puede ver los asientos, no comprarlos.', TipoAviso.info);
      return;
    }
    switch (estado) {
      case 'DISPONIBLE':
        if (!widget.sesion.autenticado) {
          avisar(context, 'Inicie sesión para seleccionar asientos', TipoAviso.info);
          await Navigator.push<bool>(
              context, MaterialPageRoute(builder: (_) => PantallaAcceso(sesion: widget.sesion)));
          await _cargar();
          return;
        }
        if (_seleccion.length >= maxAsientos) {
          avisar(context, 'Puede tener máximo $maxAsientos asientos por reserva', TipoAviso.error);
          return;
        }
        try {
          await _api.retener(widget.vueloId, asiento);
        } on ApiError catch (e) {
          if (mounted) {
            avisar(context, e.status == 409 ? 'El asiento $asiento acaba de ser tomado por otro usuario' : e.texto,
                TipoAviso.error);
          }
        }
        await _cargar();
      case 'SELECCIONADO':
        _liberadosPorMi.add(asiento);
        try {
          await _api.soltar(widget.vueloId, asiento);
        } on ApiError catch (e) {
          if (mounted) avisar(context, e.texto, TipoAviso.error);
        }
        await _cargar();
      case 'MIO':
        setState(() {
          widget.edicion!.quitados.add(asiento);
          _sincronizarPasajeros();
        });
      case 'QUITADO':
        if (_seleccion.length >= maxAsientos) {
          avisar(context, 'Puede tener máximo $maxAsientos asientos por reserva', TipoAviso.error);
          return;
        }
        setState(() {
          widget.edicion!.quitados.remove(asiento);
          _sincronizarPasajeros();
        });
      default:
        avisar(context, 'El asiento $asiento no está disponible: ${_descripcion(estado).toLowerCase()}', TipoAviso.info);
    }
  }

  String _descripcion(String estado) => switch (estado) {
        'DISPONIBLE' => 'Disponible',
        'BLOQUEADO' => 'Bloqueado (no disponible o en proceso por otro usuario)',
        'OCUPADO' => 'Ocupado',
        'SELECCIONADO' => 'Seleccionado por usted',
        'MIO' => 'De esta reserva (toque para quitar)',
        'QUITADO' => 'Se quitará de la reserva (toque para mantener)',
        _ => 'Ya reservado por usted en otra reserva',
      };

  Future<void> _confirmar() async {
    final seleccion = _seleccion;
    if (seleccion.isEmpty) {
      avisar(context, 'Seleccione al menos un asiento', TipoAviso.error);
      return;
    }
    for (final a in seleccion) {
      _pasajeros[a]!.nombre.text = formatearNombre(_pasajeros[a]!.nombre.text);
    }
    if (!_form.currentState!.validate()) return;
    final documentos = seleccion.map((a) => _pasajeros[a]!.documento.text).toList();
    if (documentos.toSet().length != documentos.length) {
      avisar(context, 'Un mismo documento no puede repetirse en la reserva', TipoAviso.error);
      return;
    }
    final pasajeros = [
      for (final a in seleccion)
        {
          'asiento': a,
          'nombre': _pasajeros[a]!.nombre.text,
          'tipo_documento': _pasajeros[a]!.tipo,
          'documento': _pasajeros[a]!.documento.text,
        }
    ];
    if (widget.edicion != null) {
      final c = _comparacion;
      if (c.diferencia != 0) {
        final ok = await confirmar(context,
            titulo: c.diferencia > 0 ? 'Pagar la diferencia' : 'Devolución de la diferencia',
            mensaje: 'Ya pagó ${dinero(c.anterior)} y el nuevo total es ${dinero(c.nuevo)} (IVA incluido).\n\n'
                '${c.diferencia > 0 ? 'Solo pagará la diferencia de ${dinero(c.diferencia)}; no se le cobra de nuevo la reserva.' : 'Se le devolverán ${dinero(-c.diferencia)}.'}'
                '\n\n¿Guardar los cambios?',
            textoOk: c.diferencia > 0 ? 'Pagar ${dinero(c.diferencia)} y guardar' : 'Guardar cambios');
        if (!ok || !mounted) return;
      }
    }
    setState(() => _enviando = true);
    try {
      final edicion = widget.edicion;
      final r = edicion != null
          ? await _api.modificarReserva(edicion.reservaId, pasajeros)
          : await _api.crearReserva(widget.vueloId, pasajeros);
      _expiran.clear(); // ya no son retenciones: pasaron a OCUPADO
      if (!mounted) return;
      final reserva = r['reserva'] as Map<String, dynamic>;
      if (edicion == null) {
        // Compra nueva: animación del vuelo en el mapa con los datos de salida y llegada
        await Navigator.push(
          context,
          PageRouteBuilder<void>(
            transitionDuration: const Duration(milliseconds: 400),
            pageBuilder: (_, _, _) => PantallaCompraConfirmada(
                sesion: widget.sesion, reserva: reserva, vuelo: r['vuelo'] as Map<String, dynamic>),
            transitionsBuilder: (_, animacion, _, hijo) => FadeTransition(opacity: animacion, child: hijo),
          ),
        );
        if (mounted) Navigator.pop(context, true);
        return;
      }
      final ajuste = r['ajuste'] as Map<String, dynamic>?;
      avisar(context,
          '${r['mensaje']}: reserva #${reserva['id']}, asientos ${(reserva['asientos'] as List).join(', ')}'
          '${ajuste != null ? '. ${ajuste['mensaje']}' : ', total ${dinero(reserva['total'] as num)}'}');
      Navigator.pop(context, true);
    } on ApiError catch (e) {
      if (!mounted) return;
      final detalle = e.detalle;
      if (e.status == 409 && detalle is Map && detalle['asientos_no_disponibles'] != null) {
        avisar(context, 'Otro usuario tomó: ${(detalle['asientos_no_disponibles'] as List).join(', ')}. Elija otros asientos.',
            TipoAviso.error);
      } else {
        avisar(context, e.texto, TipoAviso.error);
      }
      await _cargar();
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  Future<void> _cancelar() async {
    final edicion = widget.edicion;
    if (edicion != null) {
      final ok = await confirmar(context,
          titulo: 'Cancelar edición de la reserva #${edicion.reservaId}',
          mensaje: 'Se descartarán los cambios y la reserva quedará como estaba. ¿Continuar?',
          textoOk: 'Sí, descartar');
      if (!ok || !mounted) return;
      avisar(context, 'Cambios descartados, la reserva no se modificó', TipoAviso.info);
      Navigator.pop(context); // dispose libera los asientos nuevos retenidos
      return;
    }
    final asientos = _expiran.keys.toList()..sort(_ordenAsientos);
    final ok = await confirmar(context,
        titulo: 'Cancelar selección',
        mensaje: 'Se liberarán los asientos ${asientos.join(', ')} para otros usuarios. ¿Continuar?',
        textoOk: 'Sí, liberar');
    if (!ok) return;
    _liberadosPorMi.addAll(asientos);
    await Future.wait(asientos.map((a) => _api.soltar(widget.vueloId, a).catchError((_) => <String, dynamic>{})));
    if (mounted) avisar(context, 'Selección cancelada, los asientos quedaron libres', TipoAviso.info);
    await _cargar();
  }

  // ---------- Interfaz ----------

  @override
  Widget build(BuildContext context) {
    final datos = _datos;
    // La flecha atrás pasa por _alSalir; Navigator.pop (reservar, guardar o Cancelar) no se bloquea
    return PopScope(
      canPop: !_salidaControlada,
      onPopInvokedWithResult: _alSalir,
      child: Scaffold(
      appBar: AppBar(
          title: Text(widget.edicion != null ? 'Modificar reserva #${widget.edicion!.reservaId}' : 'Elegir asientos')),
      body: datos == null
          ? Center(child: _errorCarga != null ? Text(_errorCarga!) : const CircularProgressIndicator())
          : LayoutBuilder(builder: (context, c) {
              if (c.maxWidth >= 860) {
                return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 380, child: SingleChildScrollView(padding: const EdgeInsets.all(20), child: _panelVuelo())),
                  const VerticalDivider(width: 1),
                  Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(20), child: _panelMapa())),
                ]);
              }
              return SingleChildScrollView(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _panelVuelo(),
                  const Divider(height: 28),
                  _panelMapa(),
                ]),
              );
            }),
      ),
    );
  }

  Widget _panelVuelo() {
    final v = _datos!['vuelo'] as Map<String, dynamic>;
    final tema = Theme.of(context).textTheme;
    final salida = v['fecha_salida'] as String, llegada = v['fecha_llegada'] as String;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${v['origen']} – ${v['destino']}', style: tema.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
      const SizedBox(height: 4),
      Text('${fechaHora(salida).substring(0, 10)} · ${duracion(salida, llegada)}'),
      const SizedBox(height: 12),
      Text('${hora(salida)}  ${v['origen']}', style: tema.titleMedium),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text('${v['aerolinea']} ${v['codigo']} · ${_datos!['avion']}', style: tema.bodySmall),
      ),
      Text('${hora(llegada)}  ${v['destino']}', style: tema.titleMedium),
      const Divider(height: 28),
      _panelSeleccion(),
    ]);
  }

  Widget _panelSeleccion() {
    final seleccion = _seleccion;
    final total = seleccion.fold<double>(0, (s, a) => s + _precioDe(a));
    final edicion = widget.edicion != null;
    final restantes = _expiran.isEmpty
        ? null
        : _expiran.values.reduce((a, b) => a.isBefore(b) ? a : b).difference(DateTime.now()).inSeconds.clamp(0, 9999);

    if (widget.sesion.esAdmin) {
      final v = _datos!['vuelo'] as Map<String, dynamic>;
      return Card(
        color: const Color(0xFFEEF2F6),
        child: ListTile(
          leading: const Icon(Icons.visibility),
          title: const Text('Vista de administrador'),
          subtitle: Text('Puede ver el vuelo y el estado de los ${v['asientos_totales']} asientos, '
              'pero no seleccionarlos ni comprarlos.'),
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text('Su selección', style: Theme.of(context).textTheme.titleLarge),
        if (restantes != null)
          Chip(
            label: Text('Retenidos ${restantes ~/ 60}:${(restantes % 60).toString().padLeft(2, '0')}'),
            backgroundColor: restantes <= 60 ? const Color(0xFFF9D6D6) : const Color(0xFFFFF4D6),
          ),
      ]),
      if (seleccion.isEmpty)
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text('Elija hasta $maxAsientos asientos en el mapa. Quedan retenidos para usted durante unos minutos '
              'mientras completa los datos.'),
        ),
      Form(
        key: _form,
        child: Column(children: [
          for (final (i, a) in seleccion.indexed) _formPasajero(i, a),
        ]),
      ),
      if (seleccion.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: DesgloseIva(
              subtotal: total, etiqueta: '${seleccion.length} asiento${seleccion.length == 1 ? '' : 's'}'),
        ),
      if (edicion && seleccion.isNotEmpty) _diferencia(),
      Row(children: [
        if (edicion || seleccion.isNotEmpty)
          Expanded(
            child: OutlinedButton(
              onPressed: _enviando ? null : _cancelar,
              child: const Text('Cancelar'),
            ),
          ),
        if (seleccion.isNotEmpty) ...[
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton(
              onPressed: _enviando ? null : _confirmar,
              child: Text(_enviando ? 'Procesando...' : (edicion ? 'Guardar cambios' : 'Confirmar reserva')),
            ),
          ),
        ],
      ]),
    ]);
  }

  /// En edición: lo ya pagado, el nuevo total y la diferencia (cobro solo del aumento o devolución).
  Widget _diferencia() {
    final c = _comparacion;
    final (color, icono, texto) = c.diferencia > 0
        ? (const Color(0xFFFFF4D6), Icons.add_card, 'Solo paga la diferencia: ${dinero(c.diferencia)}')
        : c.diferencia < 0
            ? (const Color(0xFFE3F4EA), Icons.currency_exchange, 'Se le devuelve: ${dinero(-c.diferencia)}')
            : (const Color(0xFFEEF2F6), Icons.check, 'Sin diferencia de precio');
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('Ya pagado (con IVA)'),
          Text(dinero(c.anterior)),
        ]),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('Nuevo total (con IVA)'),
          Text(dinero(c.nuevo)),
        ]),
        const Divider(height: 12),
        Row(children: [
          Icon(icono, size: 18),
          const SizedBox(width: 6),
          Expanded(child: Text(texto, style: const TextStyle(fontWeight: FontWeight.bold))),
        ]),
      ]),
    );
  }

  Widget _formPasajero(int indice, String asiento) {
    final p = _pasajeros[asiento]!;
    final clase = (_datos!['clases'] as List).firstWhere((c) => c['clase'] == _claseDe[asiento]);
    final cedula = p.tipo == 'CEDULA';
    return Card(
      key: ValueKey('pasajero-$asiento'),
      margin: const EdgeInsets.only(top: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('Pasajero ${indice + 1} · Asiento $asiento', style: const TextStyle(fontWeight: FontWeight.w600)),
            Text('${clase['nombre']} · ${dinero(clase['precio'] as num)}', style: Theme.of(context).textTheme.bodySmall),
          ]),
          const SizedBox(height: 8),
          Focus(
            onFocusChange: (enfocado) {
              if (!enfocado) p.nombre.text = formatearNombre(p.nombre.text);
            },
            child: TextFormField(
              controller: p.nombre,
              maxLength: maxNombre,
              textCapitalization: TextCapitalization.words,
              inputFormatters: [Filtro.formateador(Filtro.nombre)],
              decoration: const InputDecoration(labelText: 'Nombre completo', counterText: ''),
              validator: (v) => Validar.nombre(v?.trim()),
            ),
          ),
          const SizedBox(height: 8),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Con Expanded e isExpanded el selector se adapta al ancho (no se desborda en pantallas angostas)
            Expanded(
              flex: 4,
              child: DropdownButtonFormField<String>(
                initialValue: p.tipo,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Tipo'),
                items: const [
                  DropdownMenuItem(value: 'CEDULA', child: Text('Cédula', overflow: TextOverflow.ellipsis)),
                  DropdownMenuItem(value: 'PASAPORTE', child: Text('Pasaporte', overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) => setState(() {
                  p.tipo = v!;
                  p.documento.clear();
                }),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 5,
              child: TextFormField(
                key: ValueKey('doc-$asiento-${p.tipo}'),
                controller: p.documento,
                keyboardType: cedula ? TextInputType.number : TextInputType.text,
                maxLength: cedula ? 10 : 9,
                inputFormatters: [Filtro.formateador(cedula ? Filtro.cedula : Filtro.pasaporte)],
                decoration: InputDecoration(
                    labelText: 'Documento', hintText: cedula ? '10 dígitos' : '6 a 9 caracteres', counterText: ''),
                validator: (v) => Validar.documento(p.tipo, v),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _panelMapa() {
    final clases = (_datos!['clases'] as List).cast<Map<String, dynamic>>();
    final clase = clases.firstWhere((c) => c['clase'] == _claseActiva);
    final r = clase['resumen'] as Map<String, dynamic>;
    final total = r['total'] as int;
    final porcentaje = (r['ocupados'] as int) * 100 ~/ total;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final c in clases.reversed)
          ChoiceChip(
            label: Text('${c['nombre']}  ${dinero(c['precio'] as num)}'),
            selected: c['clase'] == _claseActiva,
            selectedColor: const Color(0xFFA8E3C4),
            onSelected: (_) => setState(() => _claseActiva = c['clase'] as String),
          ),
      ]),
      const SizedBox(height: 14),
      Text('Asientos en ${clase['nombre']} ${(_datos!['vuelo'] as Map)['codigo']}',
          style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 10),
      const Wrap(spacing: 16, runSpacing: 6, children: [
        _Leyenda('DISPONIBLE', 'Disponible'),
        _Leyenda('BLOQUEADO', 'Bloqueado'),
        _Leyenda('OCUPADO', 'Ocupado'),
        _Leyenda('SELECCIONADO', 'Su selección'),
        _Leyenda('RESERVADO', 'Sus reservas'),
      ]),
      const SizedBox(height: 10),
      Text('Ocupados: ${r['ocupados']} / $total ($porcentaje%)\n'
          'Bloqueados: ${r['bloqueados']} / $total\n'
          'Disponibles: ${r['disponibles']} / $total · ${dinero(clase['precio'] as num)} por asiento'),
      const SizedBox(height: 12),
      SingleChildScrollView(scrollDirection: Axis.horizontal, child: _grilla(clase)),
      const SizedBox(height: 12),
      Text(_errorCarga ?? _actualizado, style: Theme.of(context).textTheme.bodySmall),
    ]);
  }

  Widget _grilla(Map<String, dynamic> clase) {
    final angosto = MediaQuery.sizeOf(context).width < 480;
    final ancho = angosto ? 25.0 : 34.0;
    final alto = angosto ? 24.0 : 30.0;
    final grupos = (clase['grupos'] as List).map((g) => (g as List).cast<String>()).toList();

    Widget fila(Widget etiqueta, Widget Function(String letra) celda) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: angosto ? 26 : 36, child: etiqueta),
          for (final (i, grupo) in grupos.indexed) ...[
            if (i > 0) SizedBox(width: angosto ? 8 : 20),
            for (final letra in grupo)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: angosto ? 1 : 2),
                child: SizedBox(width: ancho, height: alto, child: celda(letra)),
              ),
          ],
        ]),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      fila(const SizedBox(), (l) => Center(child: Text(l, style: const TextStyle(fontWeight: FontWeight.bold)))),
      for (final numero in clase['filas'] as List)
        fila(Text('$numero', textAlign: TextAlign.center), (letra) {
          final asiento = '$numero$letra';
          final estado = _estadoAsiento(asiento);
          return Tooltip(
            message: '$asiento · ${_descripcion(estado)}',
            child: Semantics(
              label: 'Asiento $asiento, ${_descripcion(estado)}',
              button: true,
              child: InkWell(
                onTap: () => _clicAsiento(asiento, estado),
                child: _CuadroAsiento(estado: estado, letra: letra),
              ),
            ),
          );
        }),
    ]);
  }
}

class _CuadroAsiento extends StatelessWidget {
  const _CuadroAsiento({required this.estado, this.letra});

  final String estado;
  final String? letra;

  @override
  Widget build(BuildContext context) {
    final (fondo, borde, texto) = switch (estado) {
      'DISPONIBLE' => (Colors.white, const Color(0xFF1F9D55), Colors.transparent),
      'BLOQUEADO' => (const Color(0xFFFBEFC4), const Color(0xFFE3B505), Colors.transparent),
      'OCUPADO' => (const Color(0xFFF9D6D6), const Color(0xFFDC4040), Colors.transparent),
      'RESERVADO' => (const Color(0xFFCFE3F6), const Color(0xFF7AA7CF), const Color(0xFF2B5D9B)),
      'QUITADO' => (Colors.white, const Color(0xFF1677C9), const Color(0xFF1677C9)),
      _ => (const Color(0xFF1677C9), const Color(0xFF0D4F86), Colors.white), // SELECCIONADO / MIO
    };
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fondo,
        borderRadius: BorderRadius.circular(5),
        border: Border(
          left: BorderSide(color: borde, width: 2),
          right: BorderSide(color: borde, width: 2),
          top: BorderSide(color: borde, width: 2),
          bottom: BorderSide(color: borde, width: 5),
        ),
      ),
      child: letra == null ? null : Text(letra!, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: texto)),
    );
  }
}

class _Leyenda extends StatelessWidget {
  const _Leyenda(this.estado, this.texto);

  final String estado;
  final String texto;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(width: 20, height: 20, child: _CuadroAsiento(estado: estado)),
      const SizedBox(width: 6),
      Text(texto),
    ]);
  }
}
