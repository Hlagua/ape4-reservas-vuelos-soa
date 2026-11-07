// Cliente Flutter del sistema de reservas de vuelos (SOA).
// Consume el backend Flask a través del API Gateway con HTTP + JSON.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'pantallas/acceso.dart';
import 'pantallas/estado.dart';
import 'pantallas/perfil.dart';
import 'pantallas/reservas.dart';
import 'pantallas/vuelos.dart';
import 'servicios/sesion.dart';
import 'utils/comunes.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(AeroReservas(sesion: await Sesion.cargar()));
}

class AeroReservas extends StatelessWidget {
  const AeroReservas({super.key, required this.sesion});

  final Sesion sesion;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AeroReservas SOA',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF1677C9),
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder(), isDense: true),
      ),
      locale: const Locale('es'),
      supportedLocales: const [Locale('es')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Inicio(sesion: sesion),
    );
  }
}

class Inicio extends StatefulWidget {
  const Inicio({super.key, required this.sesion});

  final Sesion sesion;

  @override
  State<Inicio> createState() => _InicioState();
}

class _InicioState extends State<Inicio> {
  int _indice = 0;
  final _reservas = GlobalKey<PantallaReservasState>();
  final _estado = GlobalKey<PantallaEstadoState>();
  final _perfil = GlobalKey<PantallaPerfilState>();

  static const _destinos = [
    (Icons.flight, 'Buscar vuelos'),
    (Icons.confirmation_number, 'Mis reservas'),
    (Icons.person, 'Perfil'),
    (Icons.monitor_heart, 'Estado'),
  ];

  @override
  void initState() {
    super.initState();
    widget.sesion.addListener(_alCambiarSesion);
  }

  @override
  void dispose() {
    widget.sesion.removeListener(_alCambiarSesion);
    super.dispose();
  }

  void _alCambiarSesion() {
    if (!mounted) return;
    setState(() {});
    if (widget.sesion.sesionExpirada) {
      widget.sesion.sesionExpirada = false;
      avisar(context, 'La sesión expiró, vuelva a ingresar', TipoAviso.error);
    }
  }

  void _cambiarVista(int i) {
    setState(() => _indice = i);
    if (i == 1) _reservas.currentState?.cargar();
    if (i == 2) _perfil.currentState?.cargar();
    if (i == 3) _estado.currentState?.cargar();
  }

  @override
  Widget build(BuildContext context) {
    final sesion = widget.sesion;
    final ancho = MediaQuery.sizeOf(context).width >= 760;
    final vistas = IndexedStack(index: _indice, children: [
      PantallaVuelos(sesion: sesion),
      PantallaReservas(key: _reservas, sesion: sesion),
      PantallaPerfil(key: _perfil, sesion: sesion),
      PantallaEstado(key: _estado, sesion: sesion),
    ]);

    return Scaffold(
      appBar: AppBar(
        title: const Row(children: [Icon(Icons.flight), SizedBox(width: 8), Text('AeroReservas')]),
        actions: [
          if (sesion.autenticado) ...[
            if (ancho) Center(child: Text('Hola, ${sesion.usuario?['nombre'] ?? ''}')),
            TextButton(onPressed: sesion.cerrar, child: const Text('Cerrar sesión')),
          ] else
            TextButton(
              onPressed: () =>
                  Navigator.push(context, MaterialPageRoute(builder: (_) => PantallaAcceso(sesion: sesion))),
              child: const Text('Iniciar sesión'),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: ancho
          ? Row(children: [
              NavigationRail(
                selectedIndex: _indice,
                onDestinationSelected: _cambiarVista,
                labelType: NavigationRailLabelType.all,
                destinations: [
                  for (final (icono, texto) in _destinos)
                    NavigationRailDestination(icon: Icon(icono), label: Text(texto)),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(child: vistas),
            ])
          : vistas,
      bottomNavigationBar: ancho
          ? null
          : NavigationBar(
              selectedIndex: _indice,
              onDestinationSelected: _cambiarVista,
              destinations: [
                for (final (icono, texto) in _destinos) NavigationDestination(icon: Icon(icono), label: texto),
              ],
            ),
    );
  }
}
