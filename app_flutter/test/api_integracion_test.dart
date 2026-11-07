// Pruebas contra el backend real: requieren `python run_backend.py` en ejecución.
// Dos clientes Api representan a dos computadoras distintas.
import 'dart:math';

import 'package:aero_reservas/servicios/api.dart';
import 'package:flutter_test/flutter_test.dart';

const url = String.fromEnvironment('API_URL', defaultValue: 'http://127.0.0.1:5000');

Future<Api> nuevoCliente() async {
  final api = Api(url);
  final email = 'flutter_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(9999)}@uta.edu.ec';
  await api.registrar('Usuario Flutter', email, 'clave1234');
  api.token = (await api.login(email, 'clave1234'))['token'] as String;
  return api;
}

Future<(int, String)> asientoLibre(Api api) async {
  final vuelos = (await api.buscarVuelos({'origen': 'Quito', 'destino': 'Guayaquil'}))['vuelos'] as List;
  final vuelo = vuelos.last['id'] as int;
  final mapa = await api.mapaAsientos(vuelo);
  final eco = (mapa['clases'] as List).last;
  for (final f in eco['filas'] as List) {
    for (final g in eco['grupos'] as List) {
      for (final l in g as List) {
        if (!(mapa['estados'] as Map).containsKey('$f$l')) return (vuelo, '$f$l');
      }
    }
  }
  throw StateError('Sin asientos libres');
}

Matcher esError(int status) => isA<ApiError>().having((e) => e.status, 'status', status);

void main() {
  test('dos clientes compiten: el segundo recibe 409 y ve el asiento bloqueado', () async {
    final a = await nuevoCliente(), b = await nuevoCliente();
    final (vuelo, asiento) = await asientoLibre(a);
    await a.retener(vuelo, asiento);
    await expectLater(b.retener(vuelo, asiento), throwsA(esError(409)));
    expect(((await b.mapaAsientos(vuelo))['estados'] as Map)[asiento], 'BLOQUEADO');
    expect(((await a.mapaAsientos(vuelo))['estados'] as Map)[asiento], 'SELECCIONADO');
    await a.soltar(vuelo, asiento);
  });

  test('diez clientes simultáneos por un asiento: solo uno lo obtiene', () async {
    final clientes = await Future.wait(List.generate(10, (_) => nuevoCliente()));
    final (vuelo, asiento) = await asientoLibre(clientes.first);
    final resultados = await Future.wait(clientes.map((c) async {
      try {
        await c.retener(vuelo, asiento);
        return c;
      } on ApiError catch (e) {
        expect(e.status, 409);
        return null;
      }
    }));
    final ganadores = resultados.whereType<Api>().toList();
    expect(ganadores.length, 1);
    await ganadores.single.soltar(vuelo, asiento);
  });

  test('flujo completo: reservar, modificar y cancelar', () async {
    final api = await nuevoCliente();
    final (vuelo, asiento) = await asientoLibre(api);
    Map<String, String> pasajero(String nombre) =>
        {'asiento': asiento, 'nombre': nombre, 'tipo_documento': 'CEDULA', 'documento': '1710034065'};

    await api.retener(vuelo, asiento);
    final creada = (await api.crearReserva(vuelo, [pasajero('Juan Pérez')]))['reserva'] as Map;
    expect(creada['estado'], 'CONFIRMADA');
    expect(((await api.mapaAsientos(vuelo))['estados'] as Map)[asiento], 'RESERVADO');

    final id = creada['id'] as int;
    await api.modificarReserva(id, [pasajero('Juan Carlos Pérez')]);
    final detalle = (await api.detalleReserva(id))['reserva'] as Map;
    expect((detalle['detalle_pasajeros'] as List).single['nombre'], 'Juan Carlos Pérez');

    await api.cancelarReserva(id);
    expect((await api.mapaAsientos(vuelo))['estados'] as Map, isNot(contains(asiento)));
  });

  test('factura XML con IVA y cierre de sesión que revoca el token', () async {
    final api = await nuevoCliente();
    final (vuelo, asiento) = await asientoLibre(api);
    final reserva = (await api.crearReserva(vuelo, [
      {'asiento': asiento, 'nombre': 'Ana Ruiz', 'tipo_documento': 'CEDULA', 'documento': '1710034065'}
    ]))['reserva'] as Map;

    final xml = await api.facturaXml(reserva['id'] as int);
    expect(xml, contains('<Factura>'));
    final subtotal = (reserva['total'] as num).toDouble();
    expect(xml, contains('<IVA>${(subtotal * 0.15).toStringAsFixed(2)}</IVA>'));
    expect((await api.perfil())['nombre'], 'Usuario Flutter');

    await api.logout();
    await expectLater(api.listarReservas(), throwsA(esError(401)));
  });

  test('errores del backend llegan al cliente', () async {
    final api = Api(url);
    await expectLater(api.login('nadie@uta.edu.ec', 'clave1234'), throwsA(esError(401)));
    await expectLater(api.retener(1, '31A'), throwsA(esError(401)));
    await expectLater(Api('http://127.0.0.1:5999').salud(), throwsA(esError(0)));
  });
}
