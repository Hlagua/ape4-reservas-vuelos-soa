// Estado de los servicios y dirección del backend
import 'package:flutter/material.dart';

import '../servicios/api.dart';
import '../servicios/sesion.dart';
import '../utils/comunes.dart';

String? validarUrl(String? v) {
  final uri = Uri.tryParse((v ?? '').trim());
  if (uri == null || !uri.hasAuthority || !(uri.scheme == 'http' || uri.scheme == 'https')) {
    return 'Ejemplo: http://192.168.1.20:5000';
  }
  return null;
}

/// Diálogo para cambiar la dirección del API Gateway. Devuelve true si se cambió (cierra la sesión actual).
Future<bool> cambiarBackend(BuildContext context, Sesion sesion) async {
  final control = TextEditingController(text: sesion.api.baseUrl);
  final form = GlobalKey<FormState>();
  final url = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Dirección del backend'),
      content: Form(
        key: form,
        child: TextFormField(
          controller: control,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'API Gateway', hintText: 'http://192.168.1.20:5000'),
          validator: validarUrl,
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
          onPressed: () {
            if (form.currentState!.validate()) Navigator.pop(context, control.text);
          },
          child: const Text('Guardar'),
        ),
      ],
    ),
  );
  control.dispose();
  if (url == null) return false;
  await sesion.cambiarBackend(url);
  return true;
}

/// Estado de los servicios y de la base de datos (solo para el administrador).
class PantallaEstado extends StatefulWidget {
  const PantallaEstado({super.key, required this.sesion});

  final Sesion sesion;

  @override
  State<PantallaEstado> createState() => PantallaEstadoState();
}

class PantallaEstadoState extends State<PantallaEstado> {
  Map<String, dynamic>? _servicios;
  String? _baseDatos;
  String? _error;

  @override
  void initState() {
    super.initState();
    cargar();
  }

  Future<void> cargar() async {
    try {
      final r = await widget.sesion.api.salud();
      if (mounted) {
        setState(() {
          _servicios = r['servicios'] as Map<String, dynamic>;
          _baseDatos = r['base_datos'] as String?;
          _error = null;
        });
      }
    } on ApiError catch (e) {
      if (mounted) {
        setState(() {
          _servicios = null;
          _error = e.texto;
        });
      }
    }
  }

  Future<void> _cambiarBackend() async {
    if (await cambiarBackend(context, widget.sesion)) await cargar();
  }

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(widget.sesion.api.baseUrl);
    final host = uri?.host ?? '';
    // En un backend desplegado (Render) solo el Gateway es público: los contratos internos no se pueden abrir
    final local = host == '127.0.0.1' || host == 'localhost' || RegExp(r'^(10|172|192)\.').hasMatch(host);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Centrado(
          child: Card(
            child: ListTile(
              leading: const Icon(Icons.dns),
              title: const Text('Backend'),
              subtitle: Text(widget.sesion.api.baseUrl),
              trailing: Wrap(
                spacing: 4,
                children: [
                  IconButton(tooltip: 'Actualizar', onPressed: cargar, icon: const Icon(Icons.refresh)),
                  IconButton(tooltip: 'Cambiar dirección', onPressed: _cambiarBackend, icon: const Icon(Icons.edit)),
                ],
              ),
            ),
          ),
        ),
        if (_error != null)
          Centrado(
            child: Card(
              child: ListTile(
                title: const Text('Gateway'),
                subtitle: Text(_error!),
                trailing: const EtiquetaEstado('caído'),
              ),
            ),
          ),
        if (_baseDatos != null)
          Centrado(
            child: Card(
              child: ListTile(
                leading: const Icon(Icons.storage),
                title: const Text('Base de datos (PostgreSQL)'),
                subtitle: Text(
                  _baseDatos == 'caída'
                      ? 'Sin conexión: las operaciones que la necesitan responderán "Base de datos no disponible"'
                      : 'Conexión correcta',
                ),
                trailing: EtiquetaEstado(_baseDatos!),
              ),
            ),
          ),
        if (_servicios != null)
          for (final s in _servicios!.entries)
            Centrado(
              child: Card(
                child: ListTile(
                  title: Text(s.key),
                  subtitle: local
                      ? SelectableText('Contrato: http://$host:${s.value['puerto']}/apidocs')
                      : Text('Servicio interno (puerto ${s.value['puerto']}), accesible solo a través del Gateway'),
                  trailing: EtiquetaEstado(s.value['estado'] as String),
                ),
              ),
            ),
      ],
    );
  }
}
