// Dirección del backend (API Gateway): se puede cambiar desde la pantalla Iniciar sesión
import 'package:flutter/material.dart';

import '../servicios/sesion.dart';

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
