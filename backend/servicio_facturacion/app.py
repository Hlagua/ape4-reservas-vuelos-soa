"""Servicio de Facturación (proveedor y consumidor): genera comprobantes en XML.

Recibe los datos de una compra en JSON y devuelve la factura en XML con IVA del 15 %
(mismo contrato que el servicio de facturación visto en clase). No tiene base de datos:
para facturar una reserva consume al servicio de Reservas.
"""
import xml.etree.ElementTree as ET

from flask import Response, jsonify, request

from common import config
from common.app_base import crear_app
from common.clientes import llamar_servicio
from common.errores import ErrorApi

app = crear_app(__name__, "Facturación", "Generación de facturas en XML a partir de datos JSON (IVA 15 %)")

porcentaje_iva = config.IVA_PORCENTAJE


def validar_datos(datos):
    errores = []
    if not isinstance(datos, dict) or len(datos) == 0:
        errores.append({"campo": "body", "error": "JSON esta vacio no es valido"})
        return errores

    factura = datos.get("factura")
    if not isinstance(factura, dict):
        errores.append({"campo": "factura", "error": "la etiqueta factura es requerida"})
    else:
        if not factura.get("numero"):
            errores.append({"campo": "numero", "error": "el numero de factura es requerido"})
        if not factura.get("fecha"):
            errores.append({"campo": "fecha", "error": "la fecha de factura es requerida"})

    cliente = datos.get("cliente")
    if not isinstance(cliente, dict):
        errores.append({"campo": "cliente", "error": "el cliente es requerido y debe ser un objeto"})
    else:
        if not cliente.get("nombre"):
            errores.append({"campo": "cliente.nombre", "error": "el nombre del cliente es requerido"})
        if not cliente.get("cedula_ruc"):
            errores.append({"campo": "cliente.cedula_ruc", "error": "la cedula_ruc del cliente es requerida"})

    productos = datos.get("detalles")
    if not isinstance(productos, list) or len(productos) == 0:
        errores.append({"campo": "detalles",
                        "error": "la lista de productos es requerida y debe contener al menos un producto"})
    else:
        for i, producto in enumerate(productos):
            if not isinstance(producto, dict):
                errores.append({"campo": f"detalles[{i}]", "error": "el producto debe ser un objeto"})
                continue
            if not producto.get("nombre"):
                errores.append({"campo": f"detalles[{i}].nombre", "error": "el nombre del producto es requerido"})
            try:
                if int(producto.get("cantidad", 0)) <= 0:
                    errores.append({"campo": f"detalles[{i}].cantidad",
                                    "error": "la cantidad del producto debe ser mayor a cero"})
            except (TypeError, ValueError):
                errores.append({"campo": f"detalles[{i}].cantidad",
                                "error": "la cantidad del producto debe ser numerica"})
            try:
                if float(producto.get("precio_unitario", 0)) <= 0:
                    errores.append({"campo": f"detalles[{i}].precio_unitario",
                                    "error": "el precio_unitario del producto debe ser mayor a cero"})
            except (TypeError, ValueError):
                errores.append({"campo": f"detalles[{i}].precio_unitario",
                                "error": "el precio_unitario del producto debe ser numerico"})
    return errores


def generar_factura_xml(datos):
    """Construye la factura con ElementTree y la devuelve como texto XML con sangría."""
    subtotal_general = 0.0

    factura = ET.Element("Factura")
    cabecera = ET.SubElement(factura, "Cabecera")
    ET.SubElement(cabecera, "Numero").text = str(datos["factura"]["numero"])
    ET.SubElement(cabecera, "Fecha").text = str(datos["factura"]["fecha"])

    cliente = ET.SubElement(factura, "Cliente")
    ET.SubElement(cliente, "Nombre").text = str(datos["cliente"]["nombre"])
    ET.SubElement(cliente, "CedulaRuc").text = str(datos["cliente"]["cedula_ruc"])
    if datos["cliente"].get("correo"):
        ET.SubElement(cliente, "Correo").text = str(datos["cliente"]["correo"])

    # Datos del vuelo (solo cuando la factura proviene de una reserva)
    vuelo = datos.get("vuelo")
    if isinstance(vuelo, dict):
        elemento = ET.SubElement(factura, "Vuelo")
        for etiqueta, clave in (("Codigo", "codigo"), ("Aerolinea", "aerolinea"), ("Origen", "origen"),
                                ("Destino", "destino"), ("Salida", "fecha_salida"), ("Llegada", "fecha_llegada")):
            ET.SubElement(elemento, etiqueta).text = str(vuelo.get(clave, ""))

    detalle = ET.SubElement(factura, "detalle")
    for item in datos["detalles"]:
        cantidad = int(item["cantidad"])
        precio_unitario = float(item["precio_unitario"])
        subtotal_linea = cantidad * precio_unitario
        subtotal_general += subtotal_linea

        producto = ET.SubElement(detalle, "producto")
        ET.SubElement(producto, "nombre").text = str(item["nombre"])
        ET.SubElement(producto, "cantidad").text = str(cantidad)
        ET.SubElement(producto, "precio_unitario").text = f"{precio_unitario:.2f}"
        ET.SubElement(producto, "subtotal").text = f"{subtotal_linea:.2f}"

    iva_total = subtotal_general * porcentaje_iva
    total_general = subtotal_general + iva_total

    totales = ET.SubElement(factura, "totales")
    ET.SubElement(totales, "Subtotal").text = f"{subtotal_general:.2f}"
    ET.SubElement(totales, "IVA").text = f"{iva_total:.2f}"
    ET.SubElement(totales, "Total").text = f"{total_general:.2f}"

    ET.SubElement(factura, "Estado").text = "Generado"

    ET.indent(factura, space="  ", level=0)
    return '<?xml version="1.0" encoding="UTF-8"?>\n' + ET.tostring(factura, encoding="unicode")


def respuesta_xml(datos):
    errores = validar_datos(datos)
    if errores:
        return jsonify({"errores": errores, "estado": "error", "mensaje": "Datos invalidos"}), 400
    return Response(generar_factura_xml(datos), mimetype="application/xml")


@app.post("/api/facturas")
def generar_factura():
    """Generar una factura XML a partir de datos JSON
    ---
    tags: [Facturación]
    consumes: [application/json]
    produces: [application/xml]
    parameters:
      - in: body
        name: body
        required: true
        schema:
          type: object
          example:
            factura: {numero: F001-000010, fecha: "2026-11-07"}
            cliente: {nombre: Ana López, cedula_ruc: "1710034065", correo: ana@uta.edu.ec}
            detalles:
              - {nombre: "Asiento 31A - Economy", cantidad: 1, precio_unitario: 108.21}
    responses:
      200: {description: Factura en XML (application/xml)}
      400: {description: "Datos inválidos: lista de errores por campo"}
    """
    return respuesta_xml(request.get_json(silent=True))


@app.get("/api/facturas/reserva/<int:reserva_id>")
def facturar_reserva(reserva_id):
    """Generar la factura XML de una reserva confirmada del usuario
    ---
    tags: [Facturación]
    security: [{Bearer: []}]
    produces: [application/xml]
    parameters:
      - {in: path, name: reserva_id, type: integer, required: true}
    responses:
      200: {description: Factura en XML con subtotal, IVA 15 % y total}
      400: {description: La reserva está cancelada}
      401: {description: Token inválido o ausente}
      403: {description: La reserva pertenece a otro usuario}
      404: {description: Reserva no encontrada}
    """
    # Consumo del servicio de Reservas con el token del usuario (Reservas valida el dueño)
    resp = llamar_servicio("GET", f"{config.RESERVAS_URL}/api/reservas/{reserva_id}",
                           headers={"Authorization": request.headers.get("Authorization", "")})
    if resp.status_code != 200:
        cuerpo = resp.json()
        raise ErrorApi(cuerpo.get("error", "No se pudo obtener la reserva"), resp.status_code, cuerpo.get("detalle"))
    reserva, vuelo = resp.json()["reserva"], resp.json()["vuelo"]
    if reserva["estado"] != "CONFIRMADA":
        raise ErrorApi("Solo se pueden facturar reservas confirmadas", 400)

    pasajeros = reserva["detalle_pasajeros"]
    titular = pasajeros[0]
    datos = {
        "factura": {"numero": f"F001-{reserva['id']:09d}", "fecha": config.ahora().date().isoformat()},
        "cliente": {"nombre": titular["nombre"], "cedula_ruc": titular["documento"]},
        "vuelo": vuelo,
        "detalles": [{
            "nombre": f"Asiento {p['asiento']} ({p['clase']}) - {p['nombre']}",
            "cantidad": 1,
            "precio_unitario": p["precio"],
        } for p in pasajeros],
    }
    return respuesta_xml(datos)


if __name__ == "__main__":
    app.run(host=config.BIND_HOST, port=config.FACTURACION_PORT, threaded=True)
