// Comprobante: factura XML generada por el servicio de Facturación
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../servicios/api.dart';
import '../servicios/sesion.dart';
import '../utils/comunes.dart';

class PantallaFactura extends StatefulWidget {
  const PantallaFactura({super.key, required this.sesion, required this.reservaId});

  final Sesion sesion;
  final int reservaId;

  @override
  State<PantallaFactura> createState() => _PantallaFacturaState();
}

class _PantallaFacturaState extends State<PantallaFactura> {
  String _xml = '';
  String _error = '';
  bool _generando = true;

  @override
  void initState() {
    super.initState();
    _generar();
  }

  Future<void> _generar() async {
    setState(() {
      _generando = true;
      _error = '';
    });
    try {
      final xml = await widget.sesion.api.facturaXml(widget.reservaId);
      if (mounted) setState(() => _xml = xml);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.texto);
    } finally {
      if (mounted) setState(() => _generando = false);
    }
  }

  /// Lee el valor de una etiqueta simple del XML (por ejemplo `<Total>`).
  String _valor(String etiqueta) =>
      RegExp('<$etiqueta>([^<]*)</$etiqueta>').firstMatch(_xml)?.group(1) ?? '-';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Factura de la reserva #${widget.reservaId}'),
        actions: [
          IconButton(
            tooltip: 'Copiar XML',
            icon: const Icon(Icons.copy),
            onPressed: _xml.isEmpty
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(text: _xml));
                    if (context.mounted) avisar(context, 'XML copiado');
                  },
          ),
          IconButton(tooltip: 'Generar de nuevo', icon: const Icon(Icons.refresh), onPressed: _generando ? null : _generar),
        ],
      ),
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_xml.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(spacing: 24, runSpacing: 8, children: [
              _dato('Número', _valor('Numero')),
              _dato('Subtotal', '\$${_valor('Subtotal')}'),
              _dato('IVA 15%', '\$${_valor('IVA')}'),
              _dato('Total', '\$${_valor('Total')}', destacado: true),
            ]),
          ),
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(16),
            color: Colors.black87,
            child: _generando
                ? const Center(child: CircularProgressIndicator())
                : SingleChildScrollView(
                    child: SelectableText(
                      _error.isNotEmpty ? _error : _xml,
                      style: TextStyle(
                        color: _error.isNotEmpty ? Colors.orangeAccent : Colors.white,
                        fontFamily: 'monospace',
                        fontSize: 13,
                      ),
                    ),
                  ),
          ),
        ),
      ]),
    );
  }

  Widget _dato(String titulo, String valor, {bool destacado = false}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(titulo, style: Theme.of(context).textTheme.bodySmall),
      Text(valor, style: TextStyle(fontSize: destacado ? 20 : 16, fontWeight: FontWeight.bold)),
    ]);
  }
}

/// Desglose usado en la selección de asientos: subtotal, IVA 15 % y total.
class DesgloseIva extends StatelessWidget {
  const DesgloseIva({super.key, required this.subtotal, required this.etiqueta});

  final double subtotal;
  final String etiqueta;
  static const iva = 0.15;

  @override
  Widget build(BuildContext context) {
    final montoIva = subtotal * iva;
    Widget fila(String texto, double monto, {bool total = false}) => Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(texto, style: TextStyle(fontWeight: total ? FontWeight.bold : FontWeight.normal)),
            Text(dinero(monto), style: TextStyle(fontWeight: total ? FontWeight.bold : FontWeight.normal, fontSize: total ? 18 : 14)),
          ],
        );
    return Column(children: [
      fila('Subtotal ($etiqueta)', subtotal),
      fila('IVA 15%', montoIva),
      const Divider(height: 10),
      fila('Total con IVA', subtotal + montoIva, total: true),
    ]);
  }
}
