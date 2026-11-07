// Formatos y componentes pequeños compartidos por las pantallas
import 'package:flutter/material.dart';

String dinero(num n) => '\$${n.toStringAsFixed(2)}';

String fechaHora(String iso) => iso.replaceFirst('T', ' ').substring(0, 16);

String hora(String iso) => iso.substring(11, 16);

String duracion(String salida, String llegada) {
  final m = DateTime.parse(llegada).difference(DateTime.parse(salida)).inMinutes;
  return '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m';
}

enum TipoAviso { ok, error, info }

void avisar(BuildContext context, String texto, [TipoAviso tipo = TipoAviso.ok]) {
  final color = switch (tipo) {
    TipoAviso.ok => const Color(0xFF1F9D55),
    TipoAviso.error => const Color(0xFFC62828),
    TipoAviso.info => const Color(0xFF2B5D9B),
  };
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(texto), backgroundColor: color, behavior: SnackBarBehavior.floating));
}

Future<bool> confirmar(BuildContext context,
    {required String titulo, required String mensaje, String textoOk = 'Confirmar'}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(titulo),
      content: Text(mensaje),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('No')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(textoOk)),
      ],
    ),
  );
  return ok ?? false;
}

/// Limita el ancho del contenido en pantallas grandes.
class Centrado extends StatelessWidget {
  const Centrado({super.key, required this.child, this.ancho = 1100});

  final Widget child;
  final double ancho;

  @override
  Widget build(BuildContext context) {
    return Center(child: ConstrainedBox(constraints: BoxConstraints(maxWidth: ancho), child: child));
  }
}

class EtiquetaEstado extends StatelessWidget {
  const EtiquetaEstado(this.estado, {super.key});

  final String estado;

  @override
  Widget build(BuildContext context) {
    final bien = estado == 'CONFIRMADA' || estado == 'activo';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: bien ? const Color(0xFFDFF5E8) : const Color(0xFFF9D6D6),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(estado,
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: bien ? const Color(0xFF1F9D55) : const Color(0xFFDC4040))),
    );
  }
}
