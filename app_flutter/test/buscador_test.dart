import 'package:flutter_test/flutter_test.dart';
import 'package:aero_reservas/utils/buscador.dart';

void main() {
  const ciudades = ['Quito', 'Guayaquil', 'Cuenca', 'Manta', 'Loja', 'Machala', 'Esmeraldas', 'Bogotá', 'Lima',
      'Madrid', 'Tena', 'Salinas', 'Galápagos'];
  String t(String c) => c;

  test('Sin texto se muestran solo 5', () => expect(sugerencias('', ciudades, t).length, 5));
  test('Primero las que empiezan igual', () => expect(sugerencias('ma', ciudades, t).take(3), ['Machala', 'Madrid', 'Manta']));
  test('Sin importar tildes', () => expect(sugerencias('bogota', ciudades, t).first, 'Bogotá'));
  test('Tolera errores de tipeo', () => expect(sugerencias('Gauyaquil', ciudades, t).first, 'Guayaquil'));
  test('Letras invertidas', () => expect(sugerencias('gauy', ciudades, t).first, 'Guayaquil'));
  test('Contenido en medio del nombre', () => expect(sugerencias('quil', ciudades, t).first, 'Guayaquil'));
}
