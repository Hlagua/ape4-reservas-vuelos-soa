import 'package:flutter_test/flutter_test.dart';
import 'package:aero_reservas/utils/validaciones.dart';

void main() {
  test('Buscador: sin números ni símbolos', () => expect(Filtro.busqueda('Quito123 <b>'), 'Quito b'));
  test('Buscador: máximo 30 caracteres', () => expect(Filtro.busqueda('a' * 40).length, 30));
  test('Buscador: acentos y letras de otros idiomas', () => expect(Filtro.busqueda('São Paulo'), 'São Paulo'));
  test('Buscador: sin espacios dobles ni al inicio', () => expect(Filtro.busqueda('  Santo   Domingo'), 'Santo Domingo'));
  test('Buscador de aviones: admite números', () => expect(Filtro.busquedaAlfanumerica('Boeing 737-800'), 'Boeing 737-800'));
  test('Nombre de avión: sin símbolos raros', () => expect(Filtro.nombreAvion(r'Airbus A320$%'), 'Airbus A320'));
  test('Nombre de aerolínea: máximo 40', () => expect(Filtro.nombreAerolinea('x' * 50).length, 40));
  test('URL: sin espacios', () => expect(Filtro.url('http://1.2.3.4 :5000'), 'http://1.2.3.4:5000'));
}
