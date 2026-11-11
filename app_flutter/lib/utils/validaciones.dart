// Reglas de validación de campos (las mismas que aplica el backend en common/validaciones.py)
import 'package:flutter/services.dart';

const int maxNombre = 60;
const int maxEmail = 50;
const int minPassword = 8;
const int maxPassword = 64;
const int maxAsientos = 5;
const int maxBusqueda = 30; // buscadores (ciudades, país, aerolíneas, aviones)
const int maxNombreCatalogo = 40; // nombre de aerolínea o de avión
const int maxUrl = 100;

const String _letras = 'A-Za-zÁÉÍÓÚÜÑáéíóúüñ';
final RegExp _nombreRe = RegExp('^[$_letras]+( [$_letras]+)*\$');
final RegExp _emailRe = RegExp(r'^[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$');
final RegExp _pasaporteRe = RegExp(r'^[A-Z0-9]{6,9}$');

class Validar {
  static String? nombre(String? valor) {
    final v = valor ?? '';
    if (v.isEmpty) return 'El nombre es obligatorio';
    if (v.length < 3 || v.length > maxNombre) return 'Debe tener entre 3 y $maxNombre caracteres';
    if (!_nombreRe.hasMatch(v)) return 'Solo letras y un espacio entre palabras';
    return null;
  }

  static String? email(String? valor) {
    final v = valor ?? '';
    if (v.isEmpty) return 'El email es obligatorio';
    if (v.length > maxEmail) return 'Máximo $maxEmail caracteres';
    if (v.contains(RegExp(r'\s'))) return 'No se permiten espacios';
    if (v != v.toLowerCase()) return 'No se permiten letras mayúsculas';
    if (!_emailRe.hasMatch(v) || v.contains('..') || v.startsWith('.') || v.contains('.@')) {
      return 'Formato de email inválido (ejemplo: nombre@uta.edu.ec)';
    }
    return null;
  }

  static String? password(String? valor) {
    final v = valor ?? '';
    if (v.isEmpty) return 'La contraseña es obligatoria';
    if (v.contains(RegExp(r'\s'))) return 'La contraseña no puede contener espacios';
    if (v.length < minPassword || v.length > maxPassword) {
      return 'Debe tener entre $minPassword y $maxPassword caracteres';
    }
    if (!v.contains(RegExp(r'[A-Za-z]')) || !v.contains(RegExp(r'\d'))) {
      return 'Debe contener al menos una letra y un número';
    }
    return null;
  }

  /// Algoritmo módulo 10 de la cédula ecuatoriana.
  static bool cedula(String cedula) {
    if (!RegExp(r'^\d{10}$').hasMatch(cedula)) return false;
    final provincia = int.parse(cedula.substring(0, 2));
    if (!((provincia >= 1 && provincia <= 24) || provincia == 30) || int.parse(cedula[2]) >= 6) {
      return false;
    }
    var suma = 0;
    for (var i = 0; i < 9; i++) {
      final valor = int.parse(cedula[i]) * (i.isEven ? 2 : 1);
      suma += valor > 9 ? valor - 9 : valor;
    }
    return (10 - suma % 10) % 10 == int.parse(cedula[9]);
  }

  static String? documento(String tipo, String? numero) {
    final v = numero ?? '';
    if (v.isEmpty) return 'El documento es obligatorio';
    if (tipo == 'CEDULA') return cedula(v) ? null : 'Cédula ecuatoriana inválida (10 dígitos)';
    return _pasaporteRe.hasMatch(v) ? null : 'De 6 a 9 letras mayúsculas o números';
  }
}

/// Filtros de escritura: limpian lo que el usuario teclea o pega, antes de validar.
class Filtro {
  static String email(String v) => _cortar(v.toLowerCase().replaceAll(RegExp(r'[^a-z0-9._%+@-]'), ''), maxEmail);

  static String nombre(String v) => _cortar(
      v.replaceAll(RegExp('[^$_letras ]'), '').replaceFirst(RegExp(r'^ +'), '').replaceAll(RegExp(r' {2,}'), ' '),
      maxNombre);

  static String password(String v) => _cortar(v.replaceAll(RegExp(r'\s'), ''), maxPassword);

  static String cedula(String v) => _cortar(v.replaceAll(RegExp(r'\D'), ''), 10);

  static String pasaporte(String v) => _cortar(v.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), ''), 9);

  static final _letra = RegExp(r'\p{L}', unicode: true);
  static final _letraODigito = RegExp(r'[\p{L}0-9]', unicode: true);

  /// Buscador de lugares (ciudad, país) o aerolíneas: solo letras de cualquier idioma, sin números y hasta
  /// 30 caracteres. Se admiten . ' - solo pegados detrás de una letra (San Juan, Saint-Denis, L'Aquila, St. Louis).
  static String busqueda(String v) => _palabras(v, _letra, ".'’-", maxBusqueda);

  /// Buscador de aviones: letras y números (Airbus A320, Boeing 737-800), hasta 30 caracteres.
  static String busquedaAlfanumerica(String v) => _palabras(v, _letraODigito, '.-/', maxBusqueda);

  /// Nombre de aerolínea: letras, números y . ' - detrás de una letra o número, hasta 40 caracteres.
  static String nombreAerolinea(String v) => _palabras(v, _letraODigito, ".'’-", maxNombreCatalogo);

  /// Nombre de avión: letras, números y . - / detrás de una letra o número, hasta 40 caracteres.
  static String nombreAvion(String v) => _palabras(v, _letraODigito, '.-/', maxNombreCatalogo);

  /// Dirección web: sin espacios, hasta 100 caracteres.
  static String url(String v) => _cortar(v.replaceAll(RegExp(r'\s'), ''), maxUrl);

  /// Deja solo palabras: empieza con letra (o número si [base] lo permite); cada símbolo de [simbolos] solo
  /// puede ir pegado detrás de una letra o número (nada de '''' ni ..(()) ni símbolos al inicio); un solo
  /// espacio entre palabras.
  static String _palabras(String v, RegExp base, String simbolos, int max) {
    final b = StringBuffer();
    var anterior = ''; // último carácter aceptado
    for (final c in v.split('')) {
      final esBase = base.hasMatch(c);
      final aceptar = esBase ||
          (c == ' ' && anterior.isNotEmpty && anterior != ' ' && (base.hasMatch(anterior) || anterior == '.')) ||
          (simbolos.contains(c) && anterior.isNotEmpty && base.hasMatch(anterior));
      if (aceptar) {
        b.write(c);
        anterior = c;
      }
    }
    return _cortar(b.toString(), max);
  }

  static String _cortar(String v, int max) => v.length > max ? v.substring(0, max) : v;

  /// Convierte un filtro en un formateador de TextField conservando el cursor.
  static TextInputFormatter formateador(String Function(String) filtro) {
    return TextInputFormatter.withFunction((anterior, nuevo) {
      final limpio = filtro(nuevo.text);
      if (limpio == nuevo.text) return nuevo;
      final cursor = (nuevo.selection.end - (nuevo.text.length - limpio.length)).clamp(0, limpio.length);
      return TextEditingValue(text: limpio, selection: TextSelection.collapsed(offset: cursor));
    });
  }
}

/// Al salir del campo: quita espacios del final y pone mayúscula inicial en cada palabra.
String formatearNombre(String texto) {
  return texto
      .trim()
      .toLowerCase()
      .split(' ')
      .where((p) => p.isNotEmpty)
      .map((p) => p[0].toUpperCase() + p.substring(1))
      .join(' ');
}
