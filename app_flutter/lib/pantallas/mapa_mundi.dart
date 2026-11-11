// Mapamundi interactivo: se acerca con la rueda o con dos dedos, se arrastra y se toca para elegir un punto.
import 'package:flutter/material.dart';

import 'mapa_vuelo.dart' show continentesMundo;

/// Punto del mapa (ciudad).
class PuntoMapa {
  const PuntoMapa(this.nombre, this.latitud, this.longitud);

  final String nombre;
  final double latitud, longitud;
}

// Rango visible de la proyección equirectangular (sin los polos)
const _latNorte = 84.0, _latSur = -58.0;
const _relacion = 360 / (_latNorte - _latSur);

class MapaMundi extends StatefulWidget {
  const MapaMundi({super.key, this.puntos = const [], this.seleccionado, this.alTocar, this.enfocar});

  /// Ciudades ya registradas (puntos pequeños).
  final List<PuntoMapa> puntos;

  /// Punto elegido (marcador grande con su nombre).
  final PuntoMapa? seleccionado;

  /// Latitud y longitud del punto tocado.
  final void Function(double latitud, double longitud)? alTocar;

  /// Cada vez que cambia, el mapa se acerca a ese punto.
  final PuntoMapa? enfocar;

  @override
  State<MapaMundi> createState() => _MapaMundiState();
}

class _MapaMundiState extends State<MapaMundi> {
  final _transformacion = TransformationController();
  Size _tamano = Size.zero;
  int _version = 0; // se cambia al enfocar para que el visor tome la nueva transformación

  @override
  void initState() {
    super.initState();
    _transformacion.addListener(() => setState(() {}));
    final p = widget.enfocar;
    if (p != null) WidgetsBinding.instance.addPostFrameCallback((_) => _enfocar(p));
  }

  @override
  void didUpdateWidget(MapaMundi anterior) {
    super.didUpdateWidget(anterior);
    final p = widget.enfocar;
    if (p != null && p != anterior.enfocar) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _enfocar(p));
    }
  }

  @override
  void dispose() {
    _transformacion.dispose();
    super.dispose();
  }

  Offset _proyectar(double lat, double lon, Size s) =>
      Offset((lon + 180) / 360 * s.width, (_latNorte - lat) / (_latNorte - _latSur) * s.height);

  void _enfocar(PuntoMapa p, {double escala = 5}) {
    if (_tamano == Size.zero) return;
    final punto = _proyectar(p.latitud, p.longitud, _tamano);
    // Se limita el desplazamiento para no mostrar zonas fuera del mapa
    final x = (_tamano.width / 2 - punto.dx * escala).clamp(_tamano.width * (1 - escala), 0.0);
    final y = (_tamano.height / 2 - punto.dy * escala).clamp(_tamano.height * (1 - escala), 0.0);
    _transformacion.value = Matrix4.identity()
      ..translateByDouble(x, y, 0, 1)
      ..scaleByDouble(escala, escala, 1, 1);
    if (mounted) setState(() => _version++);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, limites) {
      var ancho = limites.maxWidth;
      var alto = ancho / _relacion;
      if (limites.hasBoundedHeight && alto > limites.maxHeight) {
        alto = limites.maxHeight;
        ancho = alto * _relacion;
      }
      _tamano = Size(ancho, alto);
      final escala = _transformacion.value.getMaxScaleOnAxis();
      return Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            width: ancho,
            height: alto,
            child: Stack(children: [
              InteractiveViewer(
                key: ValueKey(_version),
                transformationController: _transformacion,
                minScale: 1,
                maxScale: 40,
                child: GestureDetector(
                  onTapUp: widget.alTocar == null
                      ? null
                      : (d) {
                          final lon = d.localPosition.dx / ancho * 360 - 180;
                          final lat = _latNorte - d.localPosition.dy / alto * (_latNorte - _latSur);
                          widget.alTocar!(lat.clamp(-90.0, 90.0), lon.clamp(-180.0, 180.0));
                        },
                  child: CustomPaint(
                    size: _tamano,
                    painter: _PintorMundo(
                      puntos: widget.puntos,
                      seleccionado: widget.seleccionado,
                      escala: escala,
                      proyectar: _proyectar,
                    ),
                  ),
                ),
              ),
              Positioned(
                right: 6,
                bottom: 6,
                child: Column(children: [
                  _BotonMapa(icono: Icons.add, ayuda: 'Acercar', alPulsar: () => _zoom(2)),
                  const SizedBox(height: 4),
                  _BotonMapa(icono: Icons.remove, ayuda: 'Alejar', alPulsar: () => _zoom(0.5)),
                  const SizedBox(height: 4),
                  _BotonMapa(
                      icono: Icons.public,
                      ayuda: 'Ver todo el mundo',
                      alPulsar: () => _transformacion.value = Matrix4.identity()),
                ]),
              ),
            ]),
          ),
        ),
      );
    });
  }

  /// Acerca o aleja manteniendo el centro de la vista.
  void _zoom(double factor) {
    final actual = _transformacion.value.getMaxScaleOnAxis();
    final nueva = (actual * factor).clamp(1.0, 40.0);
    final centro = _transformacion.toScene(_tamano.center(Offset.zero));
    final lon = centro.dx / _tamano.width * 360 - 180;
    final lat = _latNorte - centro.dy / _tamano.height * (_latNorte - _latSur);
    _enfocar(PuntoMapa('', lat, lon), escala: nueva);
  }
}

class _BotonMapa extends StatelessWidget {
  const _BotonMapa({required this.icono, required this.ayuda, required this.alPulsar});

  final IconData icono;
  final String ayuda;
  final VoidCallback alPulsar;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.9),
      shape: const CircleBorder(),
      child: IconButton(
        icon: Icon(icono, size: 18, color: const Color(0xFF0B2545)),
        tooltip: ayuda,
        visualDensity: VisualDensity.compact,
        onPressed: alPulsar,
      ),
    );
  }
}

class _PintorMundo extends CustomPainter {
  _PintorMundo({required this.puntos, required this.seleccionado, required this.escala, required this.proyectar});

  final List<PuntoMapa> puntos;
  final PuntoMapa? seleccionado;
  final double escala;
  final Offset Function(double lat, double lon, Size s) proyectar;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF0B2545));
    final rejilla = Paint()
      ..color = Colors.white.withValues(alpha: 0.07)
      ..strokeWidth = 1 / escala;
    for (var lon = -180; lon <= 180; lon += 30) {
      final x = proyectar(0, lon.toDouble(), size).dx;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), rejilla);
    }
    for (var lat = -45; lat <= 75; lat += 30) {
      final y = proyectar(lat.toDouble(), 0, size).dy;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), rejilla);
    }
    final ecuador = proyectar(0, 0, size).dy;
    canvas.drawLine(Offset(0, ecuador), Offset(size.width, ecuador),
        Paint()
          ..color = const Color(0xFFFFC857).withValues(alpha: 0.18)
          ..strokeWidth = 1 / escala);

    final relleno = Paint()..color = const Color(0xFF2E5A7A);
    final contorno = Paint()
      ..color = const Color(0xFF4F86AD)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1 / escala;
    for (final poligono in continentesMundo) {
      final path = Path();
      for (var i = 0; i < poligono.length; i += 2) {
        final p = proyectar(poligono[i + 1], poligono[i], size);
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      path.close();
      canvas.drawPath(path, relleno);
      canvas.drawPath(path, contorno);
    }

    // Ciudades registradas: el tamaño no cambia al acercar (se divide por la escala)
    final verNombres = escala >= 4;
    for (final p in puntos) {
      final c = proyectar(p.latitud, p.longitud, size);
      canvas.drawCircle(c, 3.2 / escala, Paint()..color = Colors.white);
      canvas.drawCircle(c, 1.8 / escala, Paint()..color = const Color(0xFF4FC3F7));
      if (verNombres) _texto(canvas, c + Offset(5 / escala, -7 / escala), p.nombre, 11, Colors.white70);
    }

    final s = seleccionado;
    if (s != null) {
      final c = proyectar(s.latitud, s.longitud, size);
      canvas.drawCircle(c, 12 / escala, Paint()..color = const Color(0xFFFFC857).withValues(alpha: 0.3));
      canvas.drawCircle(c, 6 / escala, Paint()..color = const Color(0xFFFFC857));
      canvas.drawCircle(
          c,
          6 / escala,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5 / escala);
      if (s.nombre.isNotEmpty) _texto(canvas, c + Offset(9 / escala, -20 / escala), s.nombre, 14, Colors.white);
    }
  }

  void _texto(Canvas canvas, Offset p, String texto, double tamano, Color color) {
    final pintor = TextPainter(
      text: TextSpan(
        text: texto,
        style: TextStyle(
          color: color,
          fontSize: tamano / escala,
          fontWeight: FontWeight.w600,
          shadows: [Shadow(color: Colors.black, blurRadius: 3 / escala)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    pintor.paint(canvas, p);
  }

  @override
  bool shouldRepaint(_PintorMundo anterior) =>
      anterior.escala != escala || anterior.seleccionado != seleccionado || anterior.puntos != puntos;
}
