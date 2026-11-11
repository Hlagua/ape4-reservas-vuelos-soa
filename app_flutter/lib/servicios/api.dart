// Cliente del backend: consume los servicios a través del API Gateway (HTTP + JSON)
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class ApiError implements Exception {
  ApiError(this.status, this.mensaje, [this.detalle]);

  final int status;
  final String mensaje;
  final dynamic detalle;

  /// Mensaje completo, con el detalle de validación si el backend lo envió.
  String get texto {
    final d = detalle;
    if (d is Map && d.isNotEmpty) {
      final valores = d.values.expand((v) => v is List ? v : [v]).join(', ');
      return '$mensaje: $valores';
    }
    return mensaje;
  }

  @override
  String toString() => texto;
}

class Api {
  Api(this.baseUrl, {this.alExpirarSesion});

  String baseUrl;
  String? token;
  void Function()? alExpirarSesion;

  // Render (plan gratuito) puede tardar cerca de un minuto en despertar el backend
  static const _tiempoMaximo = Duration(seconds: 60);
  final http.Client _cliente = http.Client();

  Future<http.Response> _enviar(String metodo, String ruta,
      {Object? cuerpo, Map<String, String>? query, Map<String, String>? cabecerasExtra}) async {
    final uri = Uri.parse('$baseUrl$ruta').replace(queryParameters: query);
    final cabeceras = <String, String>{
      if (token != null) 'Authorization': 'Bearer $token',
      if (cuerpo != null) 'Content-Type': 'application/json',
      ...?cabecerasExtra,
    };
    final peticion = http.Request(metodo, uri)..headers.addAll(cabeceras);
    if (cuerpo != null) peticion.body = jsonEncode(cuerpo);

    http.Response resp;
    try {
      resp = await http.Response.fromStream(await _cliente.send(peticion).timeout(_tiempoMaximo));
    } on TimeoutException {
      throw ApiError(0, 'El backend no respondió a tiempo ($baseUrl)');
    } on http.ClientException {
      throw ApiError(0, 'No se puede conectar con el backend ($baseUrl)');
    } catch (_) {
      throw ApiError(0, 'No se puede conectar con el backend ($baseUrl)');
    }
    return resp;
  }

  Future<Map<String, dynamic>> _pedir(String metodo, String ruta,
      {Object? cuerpo, Map<String, String>? query, Map<String, String>? cabecerasExtra}) async {
    final resp = await _enviar(metodo, ruta, cuerpo: cuerpo, query: query, cabecerasExtra: cabecerasExtra);
    if (resp.statusCode >= 200 && resp.statusCode < 300) return _json(resp);
    throw _error(resp, ruta);
  }

  Map<String, dynamic> _json(http.Response resp) {
    Map<String, dynamic> datos = {};
    try {
      final decodificado = jsonDecode(utf8.decode(resp.bodyBytes));
      if (decodificado is Map<String, dynamic>) datos = decodificado;
    } on FormatException {
      // Respuesta sin JSON: se usa el mensaje genérico
    }
    return datos;
  }

  ApiError _error(http.Response resp, String ruta) {
    final datos = _json(resp);
    if (resp.statusCode == 401 && token != null && !ruta.startsWith('/api/auth/')) alExpirarSesion?.call();
    // El servicio de facturación devuelve los errores de validación como lista en "errores"
    final detalle = datos['detalle'] ?? datos['errores'];
    return ApiError(resp.statusCode, (datos['error'] ?? datos['mensaje'])?.toString() ?? 'Error ${resp.statusCode}',
        detalle is List ? {for (final e in detalle) '${e['campo']}': e['error']} : detalle);
  }

  // ---------- Usuarios y autenticación ----------

  Future<Map<String, dynamic>> registrar(String nombre, String email, String password) =>
      _pedir('POST', '/api/usuarios/registro', cuerpo: {'nombre': nombre, 'email': email, 'password': password});

  Future<Map<String, dynamic>> login(String email, String password) =>
      _pedir('POST', '/api/auth/login', cuerpo: {'email': email, 'password': password});

  /// Revoca el token en el servidor (tabla tokens).
  Future<Map<String, dynamic>> logout() => _pedir('POST', '/api/auth/logout');

  Future<Map<String, dynamic>> perfil() => _pedir('GET', '/api/usuarios/perfil');

  // ---------- Vuelos y asientos ----------

  Future<Map<String, dynamic>> ciudades() => _pedir('GET', '/api/vuelos/ciudades');

  Future<Map<String, dynamic>> buscarVuelos(Map<String, String> filtros) =>
      _pedir('GET', '/api/vuelos', query: filtros.isEmpty ? null : filtros);

  Future<Map<String, dynamic>> mapaAsientos(int vueloId) => _pedir('GET', '/api/vuelos/$vueloId/asientos');

  Future<Map<String, dynamic>> retener(int vueloId, String asiento) =>
      _pedir('POST', '/api/vuelos/$vueloId/asientos/$asiento/retener');

  Future<Map<String, dynamic>> soltar(int vueloId, String asiento) =>
      _pedir('DELETE', '/api/vuelos/$vueloId/asientos/$asiento/retener');

  // ---------- Reservas ----------

  Future<Map<String, dynamic>> crearReserva(int vueloId, List<Map<String, String>> pasajeros) =>
      _pedir('POST', '/api/reservas', cuerpo: {'vuelo_id': vueloId, 'pasajeros': pasajeros});

  Future<Map<String, dynamic>> modificarReserva(int id, List<Map<String, String>> pasajeros) =>
      _pedir('PUT', '/api/reservas/$id', cuerpo: {'pasajeros': pasajeros});

  Future<Map<String, dynamic>> listarReservas({String? estado}) =>
      _pedir('GET', '/api/reservas', query: estado == null ? null : {'estado': estado});

  Future<Map<String, dynamic>> detalleReserva(int id) => _pedir('GET', '/api/reservas/$id');

  Future<Map<String, dynamic>> cancelarReserva(int id) => _pedir('DELETE', '/api/reservas/$id');

  // ---------- Facturación ----------

  /// Factura de la reserva en XML (texto tal como lo devuelve el servicio).
  Future<String> facturaXml(int reservaId) async {
    final ruta = '/api/facturas/reserva/$reservaId';
    final resp = await _enviar('GET', ruta);
    if (resp.statusCode == 200) return utf8.decode(resp.bodyBytes);
    throw _error(resp, ruta);
  }

  // ---------- Estado ----------

  Future<Map<String, dynamic>> salud() => _pedir('GET', '/api/salud');

  // ---------- Catálogos y vuelos (crear: solo el usuario con rol ADMIN) ----------

  /// Ciudades (con coordenadas), aerolíneas y aviones registrados.
  Future<Map<String, dynamic>> catalogos() => _pedir('GET', '/api/vuelos/catalogos');

  /// Latitud y longitud de una ciudad (el backend las busca en OpenStreetMap).
  Future<Map<String, dynamic>> coordenadasCiudad(String nombre) =>
      _pedir('GET', '/api/vuelos/ciudades/coordenadas', query: {'nombre': nombre});

  /// Buscador de ciudades del mundo (OpenStreetMap): [{ciudad, pais, region, latitud, longitud}].
  Future<Map<String, dynamic>> buscarCiudades(String ciudad, {String? pais}) =>
      _pedir('GET', '/api/vuelos/ciudades/buscar',
          query: {'q': ciudad, if (pais != null && pais.trim().isNotEmpty) 'pais': pais.trim()});

  /// Ciudad más cercana al punto tocado en el mapa.
  Future<Map<String, dynamic>> ciudadEnMapa(double latitud, double longitud) =>
      _pedir('GET', '/api/vuelos/ciudades/en-mapa', query: {'latitud': '$latitud', 'longitud': '$longitud'});

  Future<Map<String, dynamic>> crearCiudad(String nombre, {String? pais, double? latitud, double? longitud}) =>
      _pedir('POST', '/api/vuelos/ciudades',
          cuerpo: {'nombre': nombre, 'pais': pais, 'latitud': latitud, 'longitud': longitud});

  Future<Map<String, dynamic>> editarCiudad(int id, String nombre,
          {String? pais, double? latitud, double? longitud}) =>
      _pedir('PUT', '/api/vuelos/ciudades/$id',
          cuerpo: {'nombre': nombre, 'pais': pais, 'latitud': latitud, 'longitud': longitud});

  Future<Map<String, dynamic>> crearAerolinea(String nombre, String codigo) =>
      _pedir('POST', '/api/vuelos/aerolineas', cuerpo: {'nombre': nombre, 'codigo': codigo});

  Future<Map<String, dynamic>> editarAerolinea(int id, String nombre, String codigo) =>
      _pedir('PUT', '/api/vuelos/aerolineas/$id', cuerpo: {'nombre': nombre, 'codigo': codigo});

  /// clases: [{clase, filas, configuracion: '3-3'}]
  Future<Map<String, dynamic>> crearAvion(String nombre, List<Map<String, Object>> clases) =>
      _pedir('POST', '/api/vuelos/aviones', cuerpo: {'nombre': nombre, 'clases': clases});

  /// Sin clases se conserva la cabina (solo cambia el nombre).
  Future<Map<String, dynamic>> editarAvion(int id, String nombre, List<Map<String, Object>>? clases) =>
      _pedir('PUT', '/api/vuelos/aviones/$id', cuerpo: {'nombre': nombre, 'clases': ?clases});

  /// origen, destino, aerolinea, avion, fecha_salida, fecha_llegada (YYYY-MM-DDTHH:MM) y precio.
  Future<Map<String, dynamic>> crearVuelo(Map<String, Object> datos) => _pedir('POST', '/api/vuelos', cuerpo: datos);
}
