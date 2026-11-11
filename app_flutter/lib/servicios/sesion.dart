// Estado de la aplicación: dirección del backend y usuario autenticado
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

/// Backend desplegado en Render; para uno local: flutter run --dart-define=API_URL=http://127.0.0.1:5000
const String apiPorDefecto = String.fromEnvironment(
  'API_URL',
  defaultValue: 'https://aeroreservas-backend.onrender.com',
);

class Sesion extends ChangeNotifier {
  Sesion._(this.api, this._prefs);

  final Api api;
  final SharedPreferences _prefs;
  Map<String, dynamic>? usuario;

  /// Clave ADMIN_KEY del administrador: solo se guarda en memoria, nunca en el dispositivo.
  String? claveAdmin;

  /// Cliente con cuenta (token JWT).
  bool get autenticado => api.token != null;

  /// Administrador: ingresó con la clave ADMIN_KEY del backend (no es un rol de la base de datos).
  bool get esAdmin => claveAdmin != null;

  /// Hay alguien dentro de la aplicación (cliente o administrador).
  bool get conSesion => autenticado || esAdmin;

  /// Se activa cuando el backend rechaza el token (sesión expirada).
  bool sesionExpirada = false;

  static Future<Sesion> cargar() async {
    final prefs = await SharedPreferences.getInstance();
    final sesion = Sesion._(Api(prefs.getString('api_url') ?? apiPorDefecto), prefs);
    sesion.api.alExpirarSesion = sesion._expirar;
    sesion.api.token = prefs.getString('token');
    final usuario = prefs.getString('usuario');
    if (usuario != null) sesion.usuario = jsonDecode(usuario) as Map<String, dynamic>;
    return sesion;
  }

  Future<void> iniciar(String email, String password) async {
    final r = await api.login(email, password);
    api.token = r['token'] as String;
    usuario = r['usuario'] as Map<String, dynamic>;
    sesionExpirada = false;
    await _prefs.setString('token', api.token!);
    await _prefs.setString('usuario', jsonEncode(usuario));
    notifyListeners();
  }

  /// Ingreso del administrador: el Gateway valida la clave consultando el estado de los servicios.
  Future<void> iniciarAdmin(String clave) async {
    if (autenticado) await cerrar();
    await api.adminServicios(clave);
    claveAdmin = clave;
    notifyListeners();
  }

  /// Cierra la sesión: revoca el token en el servidor y lo borra del dispositivo.
  Future<void> cerrar() async {
    if (api.token != null && !sesionExpirada) {
      try {
        await api.logout();
      } on ApiError {
        // Si el backend no responde, igual se cierra la sesión en el dispositivo
      }
    }
    api.token = null;
    usuario = null;
    claveAdmin = null;
    await _prefs.remove('token');
    await _prefs.remove('usuario');
    notifyListeners();
  }

  void _expirar() {
    sesionExpirada = true;
    cerrar();
  }

  Future<void> cambiarBackend(String url) async {
    await cerrar(); // se cierra la sesión en el backend anterior: su token no sirve en otro
    api.baseUrl = url.trim().replaceFirst(RegExp(r'/+$'), '');
    await _prefs.setString('api_url', api.baseUrl);
  }
}
