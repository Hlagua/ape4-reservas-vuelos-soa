// Administración de servicios: apagar y encender servicios para probar la tolerancia a fallos.
// Protegida con la clave ADMIN_KEY del backend; la clave solo se guarda en memoria mientras la pantalla está abierta.
import 'package:flutter/material.dart';

import '../servicios/api.dart';
import '../servicios/sesion.dart';
import '../utils/comunes.dart';

class PantallaAdministracion extends StatefulWidget {
  const PantallaAdministracion({super.key, required this.sesion});

  final Sesion sesion;

  @override
  State<PantallaAdministracion> createState() => _PantallaAdministracionState();
}

class _PantallaAdministracionState extends State<PantallaAdministracion> {
  final _clave = TextEditingController();
  Map<String, dynamic>? _servicios;
  String? _baseDatos;
  final Set<String> _procesando = {};
  bool _verClave = false;
  bool _consultando = false;

  Api get _api => widget.sesion.api;

  @override
  void dispose() {
    _clave.dispose();
    super.dispose();
  }

  Future<void> _consultar() async {
    if (_clave.text.isEmpty) {
      avisar(context, 'Ingrese la clave de administración', TipoAviso.error);
      return;
    }
    setState(() => _consultando = true);
    try {
      final r = await _api.adminServicios(_clave.text);
      final salud = await _api.salud();
      if (!mounted) return;
      setState(() {
        _servicios = r['servicios'] as Map<String, dynamic>;
        _baseDatos = salud['base_datos'] as String?;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => _servicios = null);
      avisar(context, e.texto, TipoAviso.error);
    } finally {
      if (mounted) setState(() => _consultando = false);
    }
  }

  Future<void> _cambiar(String clave, bool encender) async {
    setState(() => _procesando.add(clave));
    try {
      final r = await _api.adminControlar(_clave.text, clave, encender ? 'iniciar' : 'detener');
      if (!mounted) return;
      setState(() => _servicios = r['servicios'] as Map<String, dynamic>);
      avisar(context, r['mensaje'] as String, encender ? TipoAviso.ok : TipoAviso.info);
    } on ApiError catch (e) {
      if (mounted) avisar(context, e.texto, TipoAviso.error);
    } finally {
      if (mounted) setState(() => _procesando.remove(clave));
    }
  }

  @override
  Widget build(BuildContext context) {
    final servicios = _servicios;
    return Scaffold(
      appBar: AppBar(title: const Text('Administración de servicios')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Centrado(
          ancho: 700,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Text('Apague un servicio para comprobar que el resto del sistema sigue funcionando '
                    '(tolerancia a fallos de la arquitectura SOA). El API Gateway no se puede apagar: '
                    'es el punto de entrada y el supervisor lo reinicia si se cae.'),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _clave,
                      obscureText: !_verClave,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: 'Clave de administración (ADMIN_KEY)',
                        suffixIcon: IconButton(
                          tooltip: _verClave ? 'Ocultar' : 'Mostrar',
                          icon: Icon(_verClave ? Icons.visibility_off : Icons.visibility),
                          onPressed: () => setState(() => _verClave = !_verClave),
                        ),
                      ),
                      onSubmitted: (_) => _consultar(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _consultando ? null : _consultar,
                    child: Text(_consultando ? 'Consultando...' : (servicios == null ? 'Ingresar' : 'Actualizar')),
                  ),
                ]),
              ]),
            ),
          ),
        ),
        if (_baseDatos != null)
          Centrado(
            ancho: 700,
            child: Card(
              child: ListTile(
                leading: const Icon(Icons.storage),
                title: const Text('Base de datos (PostgreSQL)'),
                subtitle: const Text('Se administra desde Supabase; aquí solo se muestra su estado'),
                trailing: EtiquetaEstado(_baseDatos!),
              ),
            ),
          ),
        if (servicios != null)
          for (final s in servicios.entries)
            Centrado(
              ancho: 700,
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
      ]),
    );
  }
}
