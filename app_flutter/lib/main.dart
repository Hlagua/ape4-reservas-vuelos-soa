// Cliente Flutter del sistema de reservas de vuelos (SOA).
// Consume el backend Flask a través del API Gateway con HTTP + JSON.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'pantallas/acceso.dart';
import 'pantallas/catalogos.dart';
import 'pantallas/crear_vuelo.dart';
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
  final _perfil = GlobalKey<PantallaPerfilState>();
  final _crearVuelo = GlobalKey<PantallaCrearVueloState>();
  final _catalogos = GlobalKey<PantallaCatalogosState>();

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
    setState(() => _indice = 0); // las pestañas cambian según quién ingresó
    if (widget.sesion.sesionExpirada) {
      widget.sesion.sesionExpirada = false;
      avisar(context, 'La sesión expiró, vuelva a ingresar', TipoAviso.error);
    }
  }

  /// Pestañas visibles: sin sesión solo la búsqueda de vuelos; el cliente ve sus reservas y su perfil;
  /// el administrador (usuario con rol ADMIN) crea vuelos y catálogos, y solo consulta los vuelos.
  List<_Vista> _vistas() {
    final sesion = widget.sesion;
    return [
      _Vista(Icons.flight, 'Buscar vuelos', PantallaVuelos(sesion: sesion)),
      if (sesion.esCliente)
        _Vista(
          Icons.confirmation_number,
          'Mis reservas',
          PantallaReservas(key: _reservas, sesion: sesion),
          () => _reservas.currentState?.cargar(),
        ),
      if (sesion.esAdmin) ...[
        _Vista(
          Icons.add_circle,
          'Crear vuelos',
          PantallaCrearVuelo(key: _crearVuelo, sesion: sesion),
          () => _crearVuelo.currentState?.cargar(),
        ),
        _Vista(
          Icons.library_add,
          'Catálogos',
          PantallaCatalogos(key: _catalogos, sesion: sesion),
          () => _catalogos.currentState?.cargar(),
        ),
      ],
      if (sesion.autenticado)
        _Vista(
          Icons.person,
          'Perfil',
          PantallaPerfil(key: _perfil, sesion: sesion),
          () => _perfil.currentState?.cargar(),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final sesion = widget.sesion;
    final ancho = MediaQuery.sizeOf(context).width >= 760;
    final vistas = _vistas();
    final indice = _indice < vistas.length ? _indice : 0;
    void cambiarVista(int i) {
      setState(() => _indice = i);
      vistas[i].alMostrar?.call();
    }

    final contenido = IndexedStack(index: indice, children: [for (final v in vistas) v.pantalla]);
    // Con una sola pestaña (sin sesión) no se muestra la barra de navegación
    final conNavegacion = vistas.length > 1;

    return Scaffold(
      appBar: AppBar(
        title: const Row(children: [Icon(Icons.flight), SizedBox(width: 8), Text('AeroReservas')]),
        actions: [
          if (sesion.autenticado) ...[
            if (sesion.esAdmin)
              const Chip(avatar: Icon(Icons.admin_panel_settings, size: 18), label: Text('Administrador'))
            else if (ancho)
              Center(child: Text('Hola, ${sesion.usuario?['nombre'] ?? ''}')),
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
      body: ancho && conNavegacion
          ? Row(
              children: [
                NavigationRail(
                  selectedIndex: indice,
                  onDestinationSelected: cambiarVista,
                  labelType: NavigationRailLabelType.all,
                  destinations: [
                    for (final v in vistas) NavigationRailDestination(icon: Icon(v.icono), label: Text(v.texto)),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: contenido),
              ],
            )
          : contenido,
      bottomNavigationBar: ancho || !conNavegacion
          ? null
          : NavigationBar(
              selectedIndex: indice,
              onDestinationSelected: cambiarVista,
              destinations: [for (final v in vistas) NavigationDestination(icon: Icon(v.icono), label: v.texto)],
            ),
    );
  }
}

class _Vista {
  const _Vista(this.icono, this.texto, this.pantalla, [this.alMostrar]);

  final IconData icono;
  final String texto;
  final Widget pantalla;
  final VoidCallback? alMostrar;
}
