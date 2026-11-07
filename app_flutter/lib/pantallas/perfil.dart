// Perfil del usuario: datos de la cuenta, resumen de reservas y cierre de sesión
import 'package:flutter/material.dart';

import '../servicios/api.dart';
import '../servicios/sesion.dart';
import '../utils/comunes.dart';
import 'acceso.dart';

class PantallaPerfil extends StatefulWidget {
  const PantallaPerfil({super.key, required this.sesion});

  final Sesion sesion;

  @override
  State<PantallaPerfil> createState() => PantallaPerfilState();
}

class PantallaPerfilState extends State<PantallaPerfil> {
  Map<String, dynamic>? _perfil;
  List<dynamic> _reservas = [];
  bool _cargando = false;

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
    setState(() {
      _perfil = null;
      _reservas = [];
    });
    cargar();
  }

  Future<void> cargar() async {
    if (!widget.sesion.autenticado) return;
    setState(() => _cargando = true);
    try {
      // Dos servicios distintos: Usuarios (perfil) y Reservas (resumen)
      final resultados = await Future.wait([widget.sesion.api.perfil(), widget.sesion.api.listarReservas()]);
      if (!mounted) return;
      setState(() {
        _perfil = resultados[0];
        _reservas = resultados[1]['reservas'] as List;
      });
    } on ApiError catch (e) {
      if (mounted) avisar(context, e.texto, TipoAviso.error);
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  Future<void> _cerrarSesion() async {
    final ok = await confirmar(context,
        titulo: 'Cerrar sesión', mensaje: 'Su token será revocado en el servidor. ¿Continuar?', textoOk: 'Cerrar sesión');
    if (!ok) return;
    await widget.sesion.cerrar();
    if (mounted) avisar(context, 'Sesión cerrada correctamente', TipoAviso.info);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.sesion.autenticado) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Inicie sesión para ver su perfil'),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => PantallaAcceso(sesion: widget.sesion))),
            child: const Text('Iniciar sesión'),
          ),
        ]),
      );
    }
    final perfil = _perfil;
    final confirmadas = _reservas.where((r) => r['estado'] == 'CONFIRMADA').toList();
    final asientos = confirmadas.fold<int>(0, (s, r) => s + (r['pasajeros'] as int));
    final gastado = confirmadas.fold<double>(0, (s, r) => s + (r['total'] as num).toDouble());
    final nombre = (perfil?['nombre'] ?? widget.sesion.usuario?['nombre'] ?? '') as String;
    final iniciales = nombre.split(' ').where((p) => p.isNotEmpty).take(2).map((p) => p[0]).join();

    return RefreshIndicator(
      onRefresh: cargar,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        Centrado(
          ancho: 600,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(children: [
                CircleAvatar(radius: 36, child: Text(iniciales, style: const TextStyle(fontSize: 24))),
                const SizedBox(height: 12),
                Text(nombre, style: Theme.of(context).textTheme.titleLarge),
                Text((perfil?['email'] ?? widget.sesion.usuario?['email'] ?? '') as String),
                if (perfil != null)
                  Text('Registrado el ${fechaHora(perfil['fecha_registro'] as String).substring(0, 10)}',
                      style: Theme.of(context).textTheme.bodySmall),
                if (_cargando) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
              ]),
            ),
          ),
        ),
        Centrado(
          ancho: 600,
          child: Row(children: [
            _tarjeta('Reservas activas', '${confirmadas.length}'),
            _tarjeta('Asientos', '$asientos'),
            _tarjeta('Total reservado', dinero(gastado)),
          ]),
        ),
        const SizedBox(height: 12),
        Centrado(
          ancho: 600,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFDC4040)),
            onPressed: _cerrarSesion,
            icon: const Icon(Icons.logout),
            label: const Text('Cerrar sesión'),
          ),
        ),
      ]),
    );
  }

  Widget _tarjeta(String titulo, String valor) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(children: [
            Text(valor, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            Text(titulo, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      ),
    );
  }
}
