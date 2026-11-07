// Estado de la aplicación: dirección del backend y usuario autenticado
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

/// Se puede fijar al compilar: flutter run --dart-define=API_URL=http://192.168.1.20:5000
const String apiPorDefecto = String.fromEnvironment('API_URL', defaultValue: 'http://127.0.0.1:5000');

class Sesion extends ChangeNotifier {
  Sesion._(this.api, this._prefs);

  final Api api;
  final SharedPreferences _prefs;
  Map<String, dynamic>? usuario;

  bool get autenticado => api.token != null;

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
