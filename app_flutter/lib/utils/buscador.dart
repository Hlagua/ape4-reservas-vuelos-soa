// Campo buscador: en vez de desplegar toda la lista, al escribir muestra solo las 5 opciones más parecidas
// (sin importar tildes ni mayúsculas y tolerando errores de tipeo).
import 'dart:math' as math;

import 'package:flutter/material.dart';

const _maxSugerencias = 5;

String _normalizar(String texto) {
  const con = 'áàäâãéèëêíìïîóòöôõúùüûñç';
  const sin = 'aaaaaeeeeiiiiooooouuuunc';
  final b = StringBuffer();
  for (final ch in texto.toLowerCase().trim().split('')) {
    final i = con.indexOf(ch);
    b.write(i >= 0 ? sin[i] : ch);
  }
  return b.toString();
}

/// Errores de tipeo entre a y b: letras de más, de menos, cambiadas o invertidas ("gauy" → "guay" = 1).
int _levenshtein(String a, String b) {
  final d = List.generate(a.length + 1, (i) => List<int>.generate(b.length + 1, (j) => i == 0 ? j : (j == 0 ? i : 0)));
  for (var i = 1; i <= a.length; i++) {
    for (var j = 1; j <= b.length; j++) {
      d[i][j] = math.min(math.min(d[i][j - 1] + 1, d[i - 1][j] + 1), d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1));
      if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]) d[i][j] = math.min(d[i][j], d[i - 2][j - 2] + 1);
    }
  }
  return d[a.length][b.length];
}

/// Qué tan cerca está el texto de la consulta (menor es mejor); null si no se parece.
int? _cercania(String consulta, String texto) {
  final q = _normalizar(consulta), t = _normalizar(texto);
  if (q.isEmpty) return 0;
  if (t == q) return 0;
  if (t.startsWith(q)) return 1;
  final palabras = t.split(RegExp(r'[\s\-().,]+')).where((p) => p.isNotEmpty);
  if (palabras.any((p) => p.startsWith(q))) return 2;
  if (t.contains(q)) return 3;
  // Errores de tipeo: se compara con el inicio de cada palabra del mismo largo que lo escrito
  final tolerancia = math.max(1, q.length ~/ 3);
  final distancia = [t, ...palabras]
      .map((p) => _levenshtein(q, p.substring(0, math.min(p.length, q.length))))
      .reduce(math.min);
  return distancia <= tolerancia ? 4 + distancia : null;
}

/// Las [_maxSugerencias] opciones más cercanas a lo escrito. [texto] da lo que se muestra de cada valor.
List<T> sugerencias<T>(String consulta, Iterable<T> opciones, String Function(T) texto) {
  final puntuadas = <(int, T)>[];
  for (final o in opciones) {
    final c = _cercania(consulta, texto(o));
    if (c != null) puntuadas.add((c, o));
  }
  puntuadas.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : texto(a.$2).compareTo(texto(b.$2)));
  return [for (final (_, o) in puntuadas.take(_maxSugerencias)) o];
}

/// Campo de texto que busca entre [opciones] (valor, texto) y deja elegir una de las 5 más cercanas.
class CampoBuscador extends StatefulWidget {
  const CampoBuscador({
    super.key,
    required this.etiqueta,
    required this.opciones,
    required this.valor,
    required this.alCambiar,
    this.textoVacio,
    this.errorText,
    this.validar,
    this.excluir,
    this.icono = Icons.search,
  });

  final String etiqueta;
  final List<(String, String)> opciones;
  final String? valor;
  final ValueChanged<String?> alCambiar;

  /// Texto de ayuda cuando no hay nada elegido (p. ej. "Todos").
  final String? textoVacio;
  final String? errorText;
  final String? Function(String? valor)? validar;

  /// Valor que no se puede elegir (p. ej. el destino igual al origen).
  final String? excluir;
  final IconData icono;

  @override
  State<CampoBuscador> createState() => _CampoBuscadorState();
}

class _CampoBuscadorState extends State<CampoBuscador> {
  final _controlador = TextEditingController();
  final _foco = FocusNode();

  String _textoDe(String? valor) {
    if (valor == null) return '';
    for (final (v, t) in widget.opciones) {
      if (v == valor) return t;
    }
    return valor;
  }

  @override
  void initState() {
    super.initState();
    _controlador.text = _textoDe(widget.valor);
    _foco.addListener(() {
      // Al salir del campo, si lo escrito no es una opción elegida se vuelve a la elegida
      if (!_foco.hasFocus && _controlador.text != _textoDe(widget.valor)) {
        _controlador.text = _textoDe(widget.valor);
      }
    });
  }

  @override
  void didUpdateWidget(CampoBuscador anterior) {
    super.didUpdateWidget(anterior);
    // Si el valor cambió desde fuera (limpiar formulario, destino igual al origen) se actualiza el texto,
    // sin borrar lo que el usuario está escribiendo
    if (widget.valor != anterior.valor) {
      final mostrado = _controlador.text;
      if (widget.valor != null || mostrado == _textoDe(anterior.valor) || !_foco.hasFocus) {
        _controlador.text = _textoDe(widget.valor);
      }
    }
  }

  @override
  void dispose() {
    _controlador.dispose();
    _foco.dispose();
    super.dispose();
  }

  void _elegir(String? valor) {
    _controlador.text = _textoDe(valor);
    widget.alCambiar(valor);
  }

  @override
  Widget build(BuildContext context) {
    return RawAutocomplete<(String, String)>(
      textEditingController: _controlador,
      focusNode: _foco,
      displayStringForOption: (o) => o.$2,
      optionsBuilder: (v) {
        final disponibles = widget.opciones.where((o) => o.$1 != widget.excluir);
        // Recién enfocado con una opción ya elegida: se sugieren las más cercanas a ella igual
        final consulta = v.text == _textoDe(widget.valor) ? '' : v.text;
        return sugerencias(consulta, disponibles, (o) => o.$2);
      },
      onSelected: (o) => _elegir(o.$1),
      fieldViewBuilder: (context, controlador, foco, alEnviar) => TextFormField(
        controller: controlador,
        focusNode: foco,
        decoration: InputDecoration(
          labelText: widget.etiqueta,
          hintText: widget.textoVacio ?? 'Buscar...',
          floatingLabelBehavior: widget.textoVacio != null ? FloatingLabelBehavior.always : null,
          errorText: widget.errorText,
          prefixIcon: Icon(widget.icono, size: 20),
          suffixIcon: widget.valor == null && controlador.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Quitar',
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () {
                    _elegir(null);
                    foco.requestFocus();
                  },
                ),
        ),
        onChanged: (t) {
          // Al editar el texto se descarta la opción elegida hasta que se elija otra
          if (widget.valor != null && t != _textoDe(widget.valor)) widget.alCambiar(null);
          setState(() {});
        },
        onFieldSubmitted: (_) => alEnviar(),
        validator: (_) => widget.validar?.call(widget.valor),
      ),
      optionsViewBuilder: (context, alElegir, opciones) => Align(
        alignment: Alignment.topLeft,
        child: Material(
          elevation: 6,
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 5 * 48.0, maxWidth: 360),
            child: ListView(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              children: [
                for (final o in opciones)
                  ListTile(
                    dense: true,
                    leading: Icon(widget.icono, size: 18),
                    title: Text(o.$2, overflow: TextOverflow.ellipsis),
                    onTap: () => alElegir(o),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
