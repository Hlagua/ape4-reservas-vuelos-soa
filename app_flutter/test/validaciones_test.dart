import 'package:aero_reservas/utils/validaciones.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Filtros de escritura', () {
    test('email: minúsculas, sin espacios y máximo 50', () {
      expect(Filtro.email(' Maria Lopez@GMAIL.com '), 'marialopez@gmail.com');
      expect(Filtro.email('a' * 60).length, maxEmail);
    });

    test('nombre: solo letras, sin espacios iniciales ni dobles, máximo 60', () {
      expect(Filtro.nombre('  Juan  Pérez2 '), 'Juan Pérez ');
      expect(Filtro.nombre('a' * 70).length, maxNombre);
    });

    test('contraseña sin espacios', () => expect(Filtro.password('clave 12 34'), 'clave1234'));

    test('documentos', () {
      expect(Filtro.cedula('17100abc34065xx'), '1710034065');
      expect(Filtro.pasaporte('ab-123 456'), 'AB123456');
    });

    test('formato de nombre', () => expect(formatearNombre(' juan  PÉREZ '), 'Juan Pérez'));
  });

  group('Validaciones', () {
    test('nombre', () {
      expect(Validar.nombre('Ana Ruiz'), isNull);
      expect(Validar.nombre('An'), isNotNull);
      expect(Validar.nombre('A' * 61), isNotNull);
      expect(Validar.nombre('J0hn'), isNotNull);
    });

    test('email', () {
      expect(Validar.email('ana@uta.edu.ec'), isNull);
      expect(Validar.email('Ana@uta.edu.ec'), 'No se permiten letras mayúsculas');
      expect(Validar.email('ana ruiz@uta.edu.ec'), 'No se permiten espacios');
      expect(Validar.email('${'a' * 40}@uta.edu.ec'), 'Máximo 50 caracteres');
      expect(Validar.email('ana..r@uta.ec'), isNotNull);
    });

    test('contraseña', () {
      expect(Validar.password('clave1234'), isNull);
      expect(Validar.password('clave 1234'), isNotNull);
      expect(Validar.password('corta1'), isNotNull);
      expect(Validar.password('soloteletras'), isNotNull);
    });

    test('cédula ecuatoriana', () {
      expect(Validar.cedula('1710034065'), isTrue);
      expect(Validar.cedula('1234567890'), isFalse);
      expect(Validar.cedula('171003406'), isFalse);
    });

    test('pasaporte', () {
      expect(Validar.documento('PASAPORTE', 'AB123456'), isNull);
      expect(Validar.documento('PASAPORTE', 'AB'), isNotNull);
    });
  });
}
