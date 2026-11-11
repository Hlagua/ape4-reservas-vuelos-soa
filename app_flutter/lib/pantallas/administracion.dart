// Administración de servicios: apagar y encender servicios para probar la tolerancia a fallos.
// Solo la ve el administrador, que ingresó con la clave ADMIN_KEY del backend (se guarda solo en memoria).
import 'package:flutter/material.dart';

import '../servicios/api.dart';
import '../servicios/sesion.dart';
import '../utils/comunes.dart';

class PantallaAdministracion extends StatefulWidget {
  const PantallaAdministracion({super.key, required this.sesion});

  final Sesion sesion;

  @override
  State<PantallaAdministracion> createState() => PantallaAdministracionState();
}

class PantallaAdministracionState extends State<PantallaAdministracion> {
  Map<String, dynamic>? _servicios;
  final Set<String> _procesando = {};
  bool _consultando = false;

  Api get _api => widget.sesion.api;

  @override
  void initState() {
    super.initState();
    cargar();
  }

  /// Si la clave dejó de ser válida (cambió en el servidor) se cierra la sesión del administrador.
  void _manejarError(ApiError e) {
    if (!mounted) return;
    avisar(context, e.texto, TipoAviso.error);
    if (e.status == 403) widget.sesion.cerrar();
  }

  Future<void> cargar() async {
    final clave = widget.sesion.claveAdmin;
    if (clave == null) return;
    setState(() => _consultando = true);
    try {
      final r = await _api.adminServicios(clave);
      if (mounted) setState(() => _servicios = r['servicios'] as Map<String, dynamic>);
    } on ApiError catch (e) {
      _manejarError(e);
    } finally {
      if (mounted) setState(() => _consultando = false);
    }
  }

  Future<void> _cambiar(String servicio, bool encender) async {
    final clave = widget.sesion.claveAdmin;
    if (clave == null) return;
    setState(() => _procesando.add(servicio));
    try {
      final r = await _api.adminControlar(clave, servicio, encender ? 'iniciar' : 'detener');
      if (!mounted) return;
      setState(() => _servicios = r['servicios'] as Map<String, dynamic>);
      avisar(context, r['mensaje'] as String, encender ? TipoAviso.ok : TipoAviso.info);
    } on ApiError catch (e) {
      _manejarError(e);
    } finally {
      if (mounted) setState(() => _procesando.remove(servicio));
    }
  }

  @override
  Widget build(BuildContext context) {
    final servicios = _servicios;
    return RefreshIndicator(
      onRefresh: cargar,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Centrado(
            child: Card(
              child: ListTile(
                leading: const Icon(Icons.admin_panel_settings),
                title: const Text('Administración de servicios'),
                subtitle: const Text(
                  'Apague un servicio para comprobar que el resto del sistema sigue funcionando '
                  '(tolerancia a fallos de la arquitectura SOA). El API Gateway no se puede apagar: '
                  'es el punto de entrada y el supervisor lo reinicia si se cae.',
                ),
                isThreeLine: true,
                trailing: IconButton(
                  tooltip: 'Actualizar',
                  onPressed: _consultando ? null : cargar,
                  icon: const Icon(Icons.refresh),
                ),
              ),
            ),
          ),
          if (_consultando && servicios == null) const LinearProgressIndicator(),
          if (servicios != null)
            for (final s in servicios.entries)
              Centrado(
                child: Card(
                  child: s.key == 'gateway'
                      ? ListTile(
                          leading: const Icon(Icons.hub),
                          title: Text(s.value['nombre'] as String),
                          subtitle: const Text('Punto de entrada: no se puede apagar desde aquí'),
                          trailing: EtiquetaEstado(s.value['proceso'] as String),
                        )
                      : SwitchListTile(
                          secondary: _procesando.contains(s.key)
                              ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                              : Icon(s.value['proceso'] == 'activo' ? Icons.power : Icons.power_off),
                          title: Text(s.value['nombre'] as String),
                          subtitle: Text('Proceso: ${s.value['proceso']} · puerto ${s.value['puerto']}'),
                          value: s.value['proceso'] == 'activo',
                          onChanged: _procesando.contains(s.key) ? null : (encender) => _cambiar(s.key, encender),
                        ),
                ),
              ),
        ],
      ),
    );
  }
}
