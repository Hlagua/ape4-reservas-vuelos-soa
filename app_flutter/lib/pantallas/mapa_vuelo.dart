// Compra confirmada: animación de un mapamundi que se acerca a la ruta y un avión que vuela
// del origen al destino; al terminar muestra los datos del vuelo (horas de salida y llegada).
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../servicios/api.dart';
import '../servicios/sesion.dart';
import '../utils/comunes.dart';

class PantallaCompraConfirmada extends StatefulWidget {
  const PantallaCompraConfirmada({super.key, required this.sesion, required this.reserva, required this.vuelo});

  final Sesion sesion;
  final Map<String, dynamic> reserva;
  final Map<String, dynamic> vuelo;

  @override
  State<PantallaCompraConfirmada> createState() => _PantallaCompraConfirmadaState();
}

class _PantallaCompraConfirmadaState extends State<PantallaCompraConfirmada> with SingleTickerProviderStateMixin {
  late final AnimationController _animacion =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 5200));
  Offset? _origen, _destino; // (longitud, latitud)

  @override
  void initState() {
    super.initState();
    _cargarCoordenadas();
  }

  @override
  void dispose() {
    _animacion.dispose();
    super.dispose();
  }

  Future<void> _cargarCoordenadas() async {
    Map<String, dynamic> coordenadas = {};
    try {
      coordenadas = ((await widget.sesion.api.catalogos())['coordenadas'] as Map?)?.cast<String, dynamic>() ?? {};
    } on ApiError {
      // Sin catálogos se usan posiciones aproximadas
    }
    Offset? punto(String ciudad) {
      final c = coordenadas[ciudad] as List?;
      return c == null ? null : Offset((c[1] as num).toDouble(), (c[0] as num).toDouble());
    }

    // Ciudad sin coordenadas: se ubica cerca de la otra para que la ruta igual se vea
    var origen = punto(widget.vuelo['origen'] as String);
    var destino = punto(widget.vuelo['destino'] as String);
    origen ??= (destino ?? const Offset(-78.47, -0.18)) + const Offset(-6, 3);
    destino ??= origen + const Offset(6, -3);
    if (!mounted) return;
    setState(() {
      _origen = origen;
      _destino = destino;
    });
    _animacion.forward();
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.vuelo;
    final r = widget.reserva;
    return PopScope(
      canPop: false, // se sale con el botón Listo
      child: Scaffold(
        backgroundColor: const Color(0xFF0B2545),
        body: SafeArea(
          child: Stack(children: [
            Positioned.fill(
              child: AnimatedBuilder(
                animation: _animacion,
                builder: (context, _) => CustomPaint(
                  painter: _PintorMapa(
                    origen: _origen,
                    destino: _destino,
                    nombreOrigen: v['origen'] as String,
                    nombreDestino: v['destino'] as String,
                    progreso: _animacion.value,
                  ),
                ),
              ),
            ),
            Positioned(
              top: 16,
              left: 16,
              right: 16,
              child: AnimatedBuilder(
                animation: _animacion,
                builder: (context, _) => Text(
                  _animacion.value < 0.3
                      ? 'Confirmando su vuelo...'
                      : _animacion.value < 0.95
                          ? 'En ruta: ${v['origen']} → ${v['destino']}'
                          : '¡Compra confirmada!',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: AnimatedBuilder(
                animation: _animacion,
                builder: (context, hijo) {
                  final t = ((_animacion.value - 0.88) / 0.12).clamp(0.0, 1.0);
                  return Opacity(
                    opacity: t,
                    child: Transform.translate(offset: Offset(0, 40 * (1 - t)), child: IgnorePointer(ignoring: t < 1, child: hijo)),
                  );
                },
                child: _TarjetaVuelo(vuelo: v, reserva: r, alTerminar: () => Navigator.pop(context)),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _TarjetaVuelo extends StatelessWidget {
  const _TarjetaVuelo({required this.vuelo, required this.reserva, required this.alTerminar});

  final Map<String, dynamic> vuelo;
  final Map<String, dynamic> reserva;
  final VoidCallback alTerminar;

  @override
  Widget build(BuildContext context) {
    final salida = vuelo['fecha_salida'] as String, llegada = vuelo['fecha_llegada'] as String;
    final total = (reserva['total'] as num).toDouble();
    final tema = Theme.of(context).textTheme;
    Widget extremo(String etiqueta, String ciudad, String fecha, CrossAxisAlignment alineacion) => Expanded(
          child: Column(crossAxisAlignment: alineacion, children: [
            Text(etiqueta, style: tema.labelMedium),
            Text(hora(fecha), style: tema.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
            Text(ciudad, style: tema.titleMedium),
            Text(fecha.substring(0, 10), style: tema.bodySmall),
          ]),
        );
    return Padding(
      padding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Card(
          elevation: 8,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                const Icon(Icons.check_circle, color: Color(0xFF1F9D55)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Reserva #${reserva['id']} confirmada', style: tema.titleLarge),
                ),
              ]),
              Text('${vuelo['aerolinea']} ${vuelo['codigo']} · ${vuelo['avion']}', style: tema.bodySmall),
              const Divider(height: 22),
              Row(children: [
                extremo('SALIDA', vuelo['origen'] as String, salida, CrossAxisAlignment.start),
                Column(children: [
                  const Icon(Icons.flight_takeoff),
                  Text(duracion(salida, llegada), style: tema.bodySmall),
                ]),
                extremo('LLEGADA', vuelo['destino'] as String, llegada, CrossAxisAlignment.end),
              ]),
              const Divider(height: 22),
              Text('Asientos: ${(reserva['asientos'] as List).join(', ')}'),
              Text('Total pagado: ${dinero(total * 1.15)} (IVA incluido)',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 14),
              FilledButton(onPressed: alTerminar, child: const Text('Listo')),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Dibuja el mapa (proyección equirectangular), la ruta y el avión.
/// progreso 0 a 0.3: acercamiento desde el mapamundi; 0.3 a 0.9: vuelo; luego queda la ruta completa.
class _PintorMapa extends CustomPainter {
  _PintorMapa({
    required this.origen,
    required this.destino,
    required this.nombreOrigen,
    required this.nombreDestino,
    required this.progreso,
  });

  final Offset? origen, destino;
  final String nombreOrigen, nombreDestino;
  final double progreso;

  static const _mar = Color(0xFF0B2545);
  static const _tierra = Color(0xFF2E5A7A);
  static const _borde = Color(0xFF4F86AD);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    // Vista final: los dos puntos con margen (al menos 26° de longitud para dar contexto)
    final o = origen ?? const Offset(-78.5, -0.2), d = destino ?? const Offset(-78.5, -0.2);
    final centroRuta = Offset((o.dx + d.dx) / 2, (o.dy + d.dy) / 2);
    final spanLon = math.max((o.dx - d.dx).abs() * 1.7, 26.0);
    final spanLat = math.max((o.dy - d.dy).abs() * 1.7 + 8, 14.0);
    final escalaRuta = math.min(w / spanLon, (h * 0.62) / spanLat);
    final escalaMundo = math.min(w / 360, h / 170);
    final acercamiento = Curves.easeInOutCubic.transform((progreso / 0.3).clamp(0.0, 1.0));
    // Interpolación logarítmica de la escala: el acercamiento se ve uniforme
    final escala = math.exp(ui.lerpDouble(math.log(escalaMundo), math.log(escalaRuta), acercamiento)!);
    // La ruta se ubica un poco arriba del centro para dejar lugar a la tarjeta de datos
    final centro = Offset.lerp(Offset(centroRuta.dx, 0), centroRuta - Offset(0, spanLat * 0.18), acercamiento)!;
    Offset proyectar(Offset lonLat) =>
        Offset((lonLat.dx - centro.dx) * escala + w / 2, (centro.dy - lonLat.dy) * escala + h * 0.45);

    canvas.drawRect(Offset.zero & size, Paint()..color = _mar);

    // Cuadrícula de meridianos y paralelos cada 15°
    final rejilla = Paint()
      ..color = Colors.white.withValues(alpha: 0.06)
      ..strokeWidth = 1;
    for (var lon = -180; lon <= 180; lon += 15) {
      canvas.drawLine(proyectar(Offset(lon.toDouble(), 85)), proyectar(Offset(lon.toDouble(), -85)), rejilla);
    }
    for (var lat = -75; lat <= 75; lat += 15) {
      canvas.drawLine(proyectar(Offset(-180, lat.toDouble())), proyectar(Offset(180, lat.toDouble())), rejilla);
    }

    // Continentes
    final relleno = Paint()..color = _tierra;
    final contorno = Paint()
      ..color = _borde
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final poligono in continentesMundo) {
      final path = Path();
      for (var i = 0; i < poligono.length; i += 2) {
        final p = proyectar(Offset(poligono[i], poligono[i + 1]));
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      path.close();
      canvas.drawPath(path, relleno);
      canvas.drawPath(path, contorno);
    }

    if (origen == null || destino == null) return;

    // Ruta: arco (curva de Bézier) entre origen y destino
    final a = proyectar(o), b = proyectar(d);
    final medio = Offset.lerp(a, b, 0.5)!;
    final distancia = (b - a).distance;
    final normal = distancia == 0 ? const Offset(0, -1) : Offset(-(b - a).dy, (b - a).dx) / distancia;
    final control = medio + (normal.dy > 0 ? -normal : normal) * distancia * 0.28;
    final ruta = Path()
      ..moveTo(a.dx, a.dy)
      ..quadraticBezierTo(control.dx, control.dy, b.dx, b.dy);
    final metrica = ruta.computeMetrics().first;

    final alcance = acercamiento.clamp(0.0, 1.0);
    // Ruta punteada completa
    final punteado = Paint()
      ..color = Colors.white.withValues(alpha: 0.45 * alcance)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    for (double s = 0; s < metrica.length; s += 10) {
      canvas.drawPath(metrica.extractPath(s, math.min(s + 5, metrica.length)), punteado);
    }

    final vuelo = Curves.easeInOut.transform(((progreso - 0.3) / 0.6).clamp(0.0, 1.0));
    // Estela recorrida
    canvas.drawPath(
      metrica.extractPath(0, metrica.length * vuelo),
      Paint()
        ..color = const Color(0xFFFFC857)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );

    _ciudad(canvas, a, nombreOrigen, alcance, arriba: a.dy <= b.dy);
    _ciudad(canvas, b, nombreDestino, alcance, arriba: b.dy < a.dy);

    // Avión orientado según la tangente de la ruta
    if (alcance > 0.6) {
      final tangente = metrica.getTangentForOffset(metrica.length * vuelo.clamp(0.0, 0.999));
      if (tangente != null) {
        final icono = TextPainter(
          text: TextSpan(
            text: String.fromCharCode(Icons.flight.codePoint),
            style: TextStyle(
              fontFamily: Icons.flight.fontFamily,
              package: Icons.flight.fontPackage,
              fontSize: 34,
              color: Colors.white,
              shadows: const [Shadow(color: Colors.black54, blurRadius: 6)],
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        canvas
          ..save()
          ..translate(tangente.position.dx, tangente.position.dy)
          ..rotate(-tangente.angle + math.pi / 2) // el ícono apunta hacia arriba
          ..translate(-icono.width / 2, -icono.height / 2);
        icono.paint(canvas, Offset.zero);
        canvas.restore();
      }
    }
  }

  void _ciudad(Canvas canvas, Offset p, String nombre, double opacidad, {required bool arriba}) {
    if (opacidad <= 0) return;
    canvas.drawCircle(p, 9, Paint()..color = const Color(0xFFFFC857).withValues(alpha: 0.25 * opacidad));
    canvas.drawCircle(p, 4.5, Paint()..color = const Color(0xFFFFC857).withValues(alpha: opacidad));
    final texto = TextPainter(
      text: TextSpan(
        text: nombre,
        style: TextStyle(
          color: Colors.white.withValues(alpha: opacidad),
          fontSize: 14,
          fontWeight: FontWeight.w600,
          shadows: const [Shadow(color: Colors.black, blurRadius: 4)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    texto.paint(canvas, p + Offset(-texto.width / 2, arriba ? -texto.height - 12 : 12));
  }

  @override
  bool shouldRepaint(_PintorMapa anterior) =>
      anterior.progreso != progreso || anterior.origen != origen || anterior.destino != destino;
}

/// Contornos simplificados de los continentes: pares (longitud, latitud).
const List<List<double>> continentesMundo = [
  // Sudamérica
  [-77.5, 8.5, -75.5, 10.8, -72, 12.2, -70, 11.5, -67, 10.6, -62, 10.5, -60, 8.5, -57, 6, -54, 5.8, -51.5, 4.5,
   -50, 1.5, -48, -1, -44, -2.5, -40, -3, -37, -5, -35, -7.5, -35.5, -10, -38.5, -13, -39, -17.5, -40.5, -21,
   -42, -23, -45, -24, -48.5, -26, -48.7, -28.5, -51, -31, -53, -34, -56, -35, -57.5, -36.5, -57, -38.5, -62, -39,
   -65, -41, -64, -42.5, -65.5, -45, -67.5, -46.5, -66, -48, -68.5, -50.5, -69, -52.5, -68.5, -54.5, -71, -54,
   -74, -52, -75.5, -48, -74, -44, -73.5, -40, -73.5, -37, -71.5, -33, -71.5, -28, -70.5, -23, -70.3, -18.5,
   -72, -17, -76, -14, -77.5, -11.5, -79.5, -7.5, -81.2, -6, -81, -4.5, -80.3, -3.4, -80, -2.9, -80.4, -2.5,
   -81, -2.2, -80.8, -1.5, -80.9, -1, -80.1, 0, -80, 0.8, -78.9, 1.4, -77.5, 3, -77.3, 4, -77.4, 6.5, -77.9, 7.2],
  // Galápagos
  [-91.6, -0.3, -90.8, -0.15, -89.3, -0.85, -90.5, -1.05, -91.5, -1.0],
  // Norteamérica y Centroamérica
  [-77.9, 7.2, -79.5, 9.3, -81.5, 8.2, -83, 8.6, -83.6, 10.9, -83.3, 15, -86, 16, -88.3, 15.8, -88.2, 18.5,
   -87.5, 21.5, -90.4, 21, -91, 18.7, -94.5, 18.5, -97.5, 21.5, -97.5, 25.8, -97.2, 27.8, -94, 29.6, -90, 29.2,
   -88, 30.4, -85, 29.7, -83, 29, -82.7, 27.5, -81.5, 25.2, -80.1, 25.8, -80.5, 28.5, -81.4, 30.7, -79, 33.3,
   -76.5, 35, -76, 37, -74, 40.5, -70, 41.5, -70.5, 43.5, -67, 44.8, -65, 43.5, -61, 45.5, -64.5, 47.5, -60, 50,
   -56, 52, -60, 55.5, -64, 59.5, -70, 58.5, -77, 62.5, -78, 58, -77, 55, -82, 52.5, -85, 55.5, -92, 57,
   -94.5, 59.5, -90, 64, -87, 66.5, -95, 68, -110, 68.5, -125, 70, -141, 69.6, -156, 71.2, -166, 68.5,
   -162, 64.5, -166, 61.5, -157, 58.5, -162, 55, -152, 59, -145, 60.3, -138, 59, -131, 55, -128, 51,
   -124.5, 48.3, -124, 46, -124.5, 42.5, -123.8, 39.5, -122.5, 37.5, -120.5, 34.5, -117, 32.5, -115, 29,
   -112, 25.5, -110, 23, -106, 23, -105.5, 20, -103.5, 18.3, -100, 17, -96.5, 15.7, -94, 16, -92, 14.5,
   -91, 13.9, -88, 13.2, -87.5, 13, -85.7, 11, -85.9, 10, -84.7, 9.6, -83.6, 8.4, -82, 8.1, -80, 7.3, -78.3, 8.2],
  // Cuba y La Española
  [-85, 21.8, -82, 23.2, -77.5, 22, -74.2, 20.2, -77.5, 19.9, -80, 21.7, -84, 21.9],
  [-74.4, 19.8, -72, 20, -68.4, 18.6, -70, 18.2, -74.3, 18.3],
  // Groenlandia
  [-73, 78, -60, 82, -30, 83.5, -20, 81.5, -18, 77, -22, 70.5, -32, 68, -40, 65, -43, 60, -48, 61, -53, 66,
   -55, 70.5, -60, 76, -70, 77.5],
  // Europa y Asia
  [-9, 37, -8.9, 43, -1.5, 43.4, -1.2, 46, -4.6, 48.5, -1.5, 48.7, 1.5, 50.9, 4, 51.4, 8.5, 54, 8.5, 57,
   10.5, 57.5, 10.8, 54.2, 14, 54, 19, 54.4, 21.2, 57, 24, 57.5, 23.5, 59.5, 30, 60, 22.5, 60.5, 21.5, 63.5,
   25.3, 65.3, 21, 64.8, 17.5, 62.5, 19, 60, 17, 57, 13, 55.5, 11, 58.8, 5.5, 59, 5, 62, 14, 67.5, 20, 70,
   28, 71, 33, 69.5, 41, 67, 44, 68.5, 55, 68.5, 60, 69.7, 70, 73, 80, 73.5, 88, 75.5, 104, 77.7, 113, 73.7,
   130, 71, 140, 72.5, 160, 70, 180, 69, 180, 65, 178, 64.5, 170, 60, 163, 56, 156, 51, 156, 57.5, 143, 59.2,
   135, 54.5, 140, 48, 132, 43, 129.5, 42.5, 129, 35.5, 126.5, 34.5, 126, 38, 121, 40.5, 122, 37, 119, 35,
   122, 31, 121.5, 28, 119, 25, 114, 22.3, 108, 21.5, 106.5, 18, 109, 13, 105, 8.7, 100.5, 13.5, 99, 10,
   100.3, 6.5, 103.5, 1.3, 101, 3, 98.5, 8, 98.5, 16, 94.5, 16.5, 92, 21.5, 89, 21.7, 86.5, 20, 80, 15.5,
   80.2, 13, 78, 8.2, 76.5, 8.8, 73, 17, 72.6, 21, 70, 22.5, 67, 24.8, 62, 25.2, 57, 25.8, 56.4, 27, 51.5, 27.9,
   48, 30, 50, 26.5, 51.5, 24, 56, 26, 59.8, 22.5, 56, 17.9, 52, 16, 45, 13, 43, 13.5, 39, 21.5, 35, 28,
   32.5, 30, 34.5, 31.5, 35.8, 34.5, 36, 36.8, 30, 36.2, 27, 37.5, 26.3, 40.2, 22.9, 40.6, 23, 36.5, 21, 38,
   19.4, 41.8, 16, 43.5, 13.6, 45.6, 12.3, 45.3, 14, 42, 16, 41, 18.5, 40.2, 16, 38, 15.7, 40, 12.5, 41.7,
   10.5, 43, 8.5, 44.4, 6, 43.1, 3.2, 43.3, 3.2, 42, 0.5, 40.5, -0.5, 38.5, -2, 36.7, -5.6, 36, -6.5, 36.8,
   -7.5, 37.2],
  // Gran Bretaña e Irlanda
  [-5.7, 50, -3, 50.6, 1.4, 51.2, 1.7, 52.7, 0, 53.5, -1.6, 55.6, -2, 57.6, -3.3, 58.6, -5, 58.6, -6.2, 56.6,
   -4.8, 54.8, -3, 54, -4.5, 53.3, -5.2, 51.7],
  [-6, 52, -6, 54.3, -7.3, 55.3, -10, 54.2, -10.2, 51.6, -8, 51.6],
  // África y Madagascar
  [-17, 21, -17, 14.7, -15, 11, -13, 8, -11, 6.5, -7.5, 4.4, -2, 4.8, 2, 6.2, 5, 5.6, 6.5, 4.3, 9.5, 4, 9.5, 1,
   9, -1, 11.8, -4.5, 13, -8.5, 13.5, -12, 11.8, -16.5, 14.5, -22.5, 15.5, -27, 17, -29.5, 18.4, -34, 20, -34.8,
   25.5, -34, 28, -32.5, 32.5, -28.5, 32.8, -26, 35.5, -24, 35.3, -22, 34.8, -20, 36.5, -18.5, 40, -16,
   40.5, -11, 39.3, -7, 39, -4.5, 41.5, -1.5, 44, 1.8, 48, 5, 51.2, 11.8, 49, 11.2, 43.4, 11.5, 42, 14,
   39, 17.5, 37.3, 21, 35, 24.5, 33.5, 27.5, 32.5, 30, 30, 31.3, 25, 31.7, 20, 30.8, 19, 30.3, 15.5, 31.7,
   11.5, 33.5, 10.5, 36.8, 8.5, 36.9, 3, 36.8, -1, 35.5, -5.9, 35.8, -6.8, 34, -9.5, 32, -9.8, 29.5, -13, 27.6,
   -14.5, 26, -16.3, 24],
  [44, -25, 47, -25, 50.4, -15.5, 49.5, -12, 48, -14, 44.3, -16.5, 43.5, -22],
  // Japón, Sumatra, Borneo y Nueva Guinea
  [130, 31.5, 131.5, 34.3, 135, 33.8, 140, 35, 141, 38, 142, 41.5, 140, 40.5, 139.5, 38, 136.5, 37, 133, 35.5,
   130.5, 34],
  [95.3, 5.6, 98, 4, 104, -1.5, 106, -5.8, 102, -4, 98.6, 0, 95.5, 3],
  [109, 1.8, 111, 1.5, 116.5, 6.8, 119, 5, 117.5, 0.5, 116, -3.5, 110, -3, 109, -0.5],
  [131, -1.5, 141, -2.6, 150.5, -10.5, 146, -8.5, 141, -9, 138, -8, 134, -3.5],
  // Australia
  [114, -22, 114.5, -26.5, 115.5, -33.5, 118, -35, 123, -33.8, 129, -31.6, 134, -32.5, 138, -35.5, 140, -38,
   146.5, -39, 150, -37.5, 153, -31, 153.5, -28, 153, -25, 149, -21, 146, -18.5, 145.3, -15, 142.5, -10.8,
   141.5, -13, 141.5, -17, 139, -17, 136.5, -15.5, 136.7, -12.2, 132.5, -11.5, 130, -13.5, 127, -14,
   125, -15.5, 122, -17.5, 121, -19.5, 117, -20.7],
];
