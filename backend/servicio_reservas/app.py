"""Servicio de Reservas (proveedor y consumidor): reserva de asientos y gestión de reservas.

Es el único dueño del esquema `reservas`. Consume:
  - Autenticación: para validar el token del usuario.
  - Vuelos: para verificar el vuelo y ocupar/liberar asientos.
"""
from datetime import datetime

from flask import current_app, jsonify, request
from sqlalchemy import text

from common import config
from common.app_base import crear_app
from common.clientes import llamar_servicio, requerir_token
from common.db import engine
from common.errores import ErrorApi, leer_json
from common.validaciones import validar_documento, validar_nombre

app = crear_app(__name__, "Reservas", "Reserva de asientos y gestión de reservas del usuario")
app.config["VUELOS_URL"] = config.VUELOS_URL

MAX_PASAJEROS = config.MAX_ASIENTOS
COLUMNAS = """id, usuario_id, vuelo_id, codigo_vuelo, cantidad_asientos, total, estado,
              fecha_reserva, fecha_actualizacion"""


def reserva_a_dict(fila, pasajeros=None):
    datos = {
        "id": fila.id,
        "usuario_id": fila.usuario_id,
        "vuelo_id": fila.vuelo_id,
        "codigo_vuelo": fila.codigo_vuelo,
        "cantidad_asientos": fila.cantidad_asientos,
        "pasajeros": fila.cantidad_asientos,
        "total": float(fila.total),
        "estado": fila.estado,
        "fecha_reserva": fila.fecha_reserva.isoformat(timespec="seconds"),
        "fecha_actualizacion": fila.fecha_actualizacion.isoformat(timespec="seconds")
        if fila.fecha_actualizacion else None,
    }
    if pasajeros is not None:
        datos["detalle_pasajeros"] = [{
            "asiento": p.asiento, "clase": p.clase, "nombre": p.nombre,
            "tipo_documento": p.tipo_documento, "documento": p.documento, "precio": float(p.precio),
        } for p in pasajeros]
        datos["asientos"] = [p.asiento for p in pasajeros]
    return datos


def leer_pasajeros(data):
    """Valida la lista de pasajeros: [{asiento, nombre, tipo_documento, documento}]."""
    pasajeros = data.get("pasajeros")
    if not isinstance(pasajeros, list) or not pasajeros:
        raise ErrorApi("Debe enviar la lista de pasajeros con su asiento", 400)
    if len(pasajeros) > MAX_PASAJEROS:
        raise ErrorApi(f"Máximo {MAX_PASAJEROS} pasajeros por reserva", 400)

    errores, limpios = {}, []
    for i, p in enumerate(pasajeros):
        if not isinstance(p, dict):
            errores[f"pasajeros[{i}]"] = "Formato inválido"
            continue
        limpio = {
            "asiento": str(p.get("asiento", "")).strip().upper(),
            "nombre": str(p.get("nombre", "")),
            "tipo_documento": str(p.get("tipo_documento", "")).strip().upper(),
            "documento": str(p.get("documento", "")).strip().upper(),
        }
        if not limpio["asiento"]:
            errores[f"pasajeros[{i}].asiento"] = "El asiento es obligatorio"
        if error := validar_nombre(limpio["nombre"]):
            errores[f"pasajeros[{i}].nombre"] = error
        if error := validar_documento(limpio["tipo_documento"], limpio["documento"]):
            errores[f"pasajeros[{i}].documento"] = error
        limpios.append(limpio)

    asientos = [p["asiento"] for p in limpios]
    documentos = [p["documento"] for p in limpios]
    if len(set(asientos)) != len(asientos):
        errores["asientos"] = "Hay asientos repetidos"
    if len(set(documentos)) != len(documentos):
        errores["documentos"] = "Un mismo documento no puede repetirse en la reserva"
    if errores:
        raise ErrorApi("Datos de pasajeros inválidos", 400, errores)
    return limpios


# ---------- Consumo del servicio de Vuelos ----------

def url_vuelos(ruta):
    return f"{current_app.config['VUELOS_URL']}/api/vuelos/{ruta}"


def respuesta_vuelos(resp):
    if resp.status_code != 200:
        cuerpo = resp.json()
        raise ErrorApi(cuerpo.get("error", "Error en el servicio de Vuelos"), resp.status_code, cuerpo.get("detalle"))
    return resp.json()


def obtener_vuelo(vuelo_id):
    return respuesta_vuelos(llamar_servicio("GET", url_vuelos(vuelo_id)))


def ocupar_asientos(vuelo_id, usuario_id, reserva_id, asientos):
    """Devuelve {asiento: {clase, precio}} de los asientos ocupados."""
    datos = respuesta_vuelos(llamar_servicio("POST", url_vuelos(f"{vuelo_id}/asientos/confirmar"), interno=True,
                                             json={"usuario_id": usuario_id, "reserva_id": reserva_id,
                                                   "asientos": asientos}))
    return {a["asiento"]: a for a in datos["asientos"]}


def liberar_asientos(vuelo_id, reserva_id, asientos=None):
    cuerpo = {"reserva_id": reserva_id}
    if asientos:
        cuerpo["asientos"] = asientos
    respuesta_vuelos(llamar_servicio("POST", url_vuelos(f"{vuelo_id}/asientos/liberar"), interno=True, json=cuerpo))


# ---------- Acceso a datos ----------

def obtener_reserva_propia(con, reserva_id, usuario):
    fila = con.execute(text(f"SELECT {COLUMNAS} FROM reservas.reservas WHERE id = :id"), {"id": reserva_id}).first()
    if not fila or fila.estado == "PENDIENTE":
        raise ErrorApi("Reserva no encontrada", 404)
    if fila.usuario_id != usuario["id"]:
        raise ErrorApi("No tiene permiso sobre esta reserva", 403)
    return fila


def pasajeros_de(con, reserva_id):
    return con.execute(text("""
        SELECT asiento, clase, nombre, tipo_documento, documento, precio
        FROM reservas.pasajeros WHERE reserva_id = :id ORDER BY asiento
    """), {"id": reserva_id}).all()


def guardar_pasajeros(con, reserva_id, pasajeros, precios):
    con.execute(text("DELETE FROM reservas.pasajeros WHERE reserva_id = :id"), {"id": reserva_id})
    con.execute(text("""
        INSERT INTO reservas.pasajeros (reserva_id, asiento, clase, nombre, tipo_documento, documento, precio)
        VALUES (:reserva_id, :asiento, :clase, :nombre, :tipo_documento, :documento, :precio)
    """), [{**p, "reserva_id": reserva_id, "clase": precios[p["asiento"]]["clase"],
            "precio": precios[p["asiento"]]["precio"]} for p in pasajeros])
    return round(sum(precios[p["asiento"]]["precio"] for p in pasajeros), 2)


# ---------- Endpoints ----------

@app.post("/api/reservas")
def crear_reserva():
    """Reservar asientos de un vuelo
    ---
    tags: [Reservas]
    security: [{Bearer: []}]
    description: >
      Dos formatos de petición.
      (1) Con pasajeros: cada uno con su asiento (seleccionado/retenido o libre) y documento.
      (2) Formato de la guía: {usuario_id, vuelo_id, cantidad}; los asientos se asignan
      automáticamente y se responde {mensaje, reserva_id, total, estado}.
      Si otro usuario tomó un asiento primero se responde 409.
    parameters:
      - in: body
        name: body
        required: true
        schema:
          type: object
          required: [vuelo_id]
          properties:
            usuario_id: {type: integer, example: 1, description: "Formato (2); debe coincidir con el token"}
            vuelo_id: {type: integer, example: 10}
            cantidad: {type: integer, example: 2, description: "Formato (2): número de asientos (1 a 5)"}
            pasajeros:
              type: array
              items:
                type: object
                properties:
                  asiento: {type: string, example: 31A}
                  nombre: {type: string, example: Juan Pérez}
                  tipo_documento: {type: string, enum: [CEDULA, PASAPORTE]}
                  documento: {type: string, example: "1710034065"}
    responses:
      201: {description: Reserva creada}
      400: {description: Datos inválidos o vuelo ya despegó}
      401: {description: Token inválido o ausente}
      404: {description: Vuelo o asiento no existe}
      409: {description: Algún asiento ya fue tomado por otro usuario}
      503: {description: Un servicio requerido no está disponible}
    """
    usuario = requerir_token()
    data = leer_json(request)
    try:
        vuelo_id = int(data.get("vuelo_id"))
    except (TypeError, ValueError):
        raise ErrorApi("El campo 'vuelo_id' es obligatorio y debe ser un número entero", 400)
    if "cantidad" in data and "pasajeros" not in data:
        return reservar_por_cantidad(usuario, data, vuelo_id)
    pasajeros = leer_pasajeros(data)

    vuelo = obtener_vuelo(vuelo_id)
    if datetime.fromisoformat(vuelo["fecha_salida"]) <= config.ahora():
        raise ErrorApi("El vuelo ya despegó, no se puede reservar", 400)
    fila, detalle = registrar_reserva(usuario, vuelo, pasajeros)
    return jsonify({"mensaje": "Reserva creada correctamente", "reserva": reserva_a_dict(fila, detalle),
                    "vuelo": vuelo}), 201


def registrar_reserva(usuario, vuelo, pasajeros):
    """Crea la reserva confirmada con sus pasajeros. Devuelve (fila de la reserva, pasajeros)."""
    vuelo_id = vuelo["id"]
    # 1) Se registra la reserva como PENDIENTE para obtener su id
    with engine.begin() as con:
        reserva_id = con.execute(text("""
            INSERT INTO reservas.reservas (usuario_id, vuelo_id, codigo_vuelo, cantidad_asientos, total)
            VALUES (:u, :v, :c, :n, 0) RETURNING id
        """), {"u": usuario["id"], "v": vuelo_id, "c": vuelo["codigo"], "n": len(pasajeros)}).scalar()

    # 2) El servicio de Vuelos ocupa los asientos (todo o nada)
    try:
        precios = ocupar_asientos(vuelo_id, usuario["id"], reserva_id, [p["asiento"] for p in pasajeros])
    except ErrorApi:
        with engine.begin() as con:
            con.execute(text("DELETE FROM reservas.reservas WHERE id = :id"), {"id": reserva_id})
        raise

    # 3) Se guardan los pasajeros y se confirma; si falla, se compensa liberando los asientos
    try:
        with engine.begin() as con:
            total = guardar_pasajeros(con, reserva_id, pasajeros, precios)
            con.execute(text("""
                UPDATE reservas.reservas SET total = :t, estado = 'CONFIRMADA' WHERE id = :id
            """), {"t": total, "id": reserva_id})
            fila = con.execute(text(f"SELECT {COLUMNAS} FROM reservas.reservas WHERE id = :id"),
                               {"id": reserva_id}).first()
            detalle = pasajeros_de(con, reserva_id)
    except Exception:
        liberar_asientos(vuelo_id, reserva_id)
        with engine.begin() as con:
            con.execute(text("DELETE FROM reservas.reservas WHERE id = :id"), {"id": reserva_id})
        raise
    return fila, detalle


# Orden de preferencia al asignar asientos automáticamente
ORDEN_CLASES = ["ECONOMY", "PREMIUM", "BUSINESS", "FIRST"]
CONSUMIDOR_FINAL = {"tipo_documento": "CF", "documento": "9999999999999"}


def elegir_asientos(vuelo_id, cantidad):
    """Primeros asientos libres según el mapa del servicio de Vuelos (Economy primero)."""
    mapa = respuesta_vuelos(llamar_servicio("GET", url_vuelos(f"{vuelo_id}/asientos")))
    ocupados = mapa["estados"]
    clases = sorted(mapa["clases"], key=lambda c: ORDEN_CLASES.index(c["clase"]))
    libres = [f"{fila}{letra}" for c in clases for fila in c["filas"] for grupo in c["grupos"] for letra in grupo
              if f"{fila}{letra}" not in ocupados]
    if len(libres) < cantidad:
        raise ErrorApi("No hay asientos suficientes", 409, {"asientos_disponibles": len(libres), "solicitados": cantidad})
    return libres[:cantidad]


def reservar_por_cantidad(usuario, data, vuelo_id):
    """Formato del ejemplo de la guía: {usuario_id, vuelo_id, cantidad}."""
    if data.get("usuario_id") is not None and data.get("usuario_id") != usuario["id"]:
        raise ErrorApi("El usuario_id no coincide con el usuario del token", 403)
    cantidad = data.get("cantidad")
    if not isinstance(cantidad, int) or isinstance(cantidad, bool) or not 1 <= cantidad <= MAX_PASAJEROS:
        raise ErrorApi(f"El campo 'cantidad' debe ser un número entero entre 1 y {MAX_PASAJEROS}", 400)

    vuelo = obtener_vuelo(vuelo_id)
    if datetime.fromisoformat(vuelo["fecha_salida"]) <= config.ahora():
        raise ErrorApi("El vuelo ya despegó, no se puede reservar", 400)

    # Si otro usuario toma alguno de los asientos elegidos a la vez, se vuelve a elegir (hasta 3 intentos)
    for intento in range(3):
        asientos = elegir_asientos(vuelo_id, cantidad)
        pasajeros = [{"asiento": a, "nombre": usuario["nombre"], **CONSUMIDOR_FINAL} for a in asientos]
        try:
            fila, detalle = registrar_reserva(usuario, vuelo, pasajeros)
            break
        except ErrorApi as e:
            if e.codigo != 409 or intento == 2:
                raise
    return jsonify({
        "mensaje": "Reserva creada",
        "reserva_id": fila.id,
        "total": float(fila.total),
        "estado": "confirmada",
        "cantidad": fila.cantidad_asientos,
        "asientos": [p.asiento for p in detalle],
    }), 201


@app.get("/api/reservas")
def listar_reservas():
    """Listar las reservas del usuario autenticado
    ---
    tags: [Reservas]
    security: [{Bearer: []}]
    parameters:
      - {in: query, name: estado, type: string, enum: [CONFIRMADA, CANCELADA]}
    responses:
      200: {description: Reservas del usuario}
      401: {description: Token inválido o ausente}
    """
    usuario = requerir_token()
    condicion, parametros = "usuario_id = :usuario_id AND estado <> 'PENDIENTE'", {"usuario_id": usuario["id"]}
    if request.args.get("estado"):
        condicion += " AND estado = :estado"
        parametros["estado"] = request.args["estado"].upper()
    with engine.connect() as con:
        filas = con.execute(text(f"""
            SELECT {COLUMNAS},
                   (SELECT string_agg(asiento, ', ' ORDER BY asiento)
                    FROM reservas.pasajeros p WHERE p.reserva_id = r.id) AS asientos
            FROM reservas.reservas r WHERE {condicion} ORDER BY fecha_reserva DESC
        """), parametros).all()
    return jsonify({"total": len(filas),
                    "reservas": [{**reserva_a_dict(f), "asientos": f.asientos or ""} for f in filas]})


@app.get("/api/reservas/<int:reserva_id>")
def obtener_reserva(reserva_id):
    """Consultar una reserva con sus pasajeros y el vuelo
    ---
    tags: [Reservas]
    security: [{Bearer: []}]
    parameters:
      - {in: path, name: reserva_id, type: integer, required: true}
    responses:
      200: {description: Reserva, pasajeros y vuelo}
      401: {description: Token inválido o ausente}
      403: {description: La reserva pertenece a otro usuario}
      404: {description: Reserva no encontrada}
    """
    usuario = requerir_token()
    with engine.connect() as con:
        fila = obtener_reserva_propia(con, reserva_id, usuario)
        detalle = pasajeros_de(con, reserva_id)
    return jsonify({"reserva": reserva_a_dict(fila, detalle), "vuelo": obtener_vuelo(fila.vuelo_id)})


@app.put("/api/reservas/<int:reserva_id>")
def modificar_reserva(reserva_id):
    """Modificar pasajeros y asientos de una reserva
    ---
    tags: [Reservas]
    security: [{Bearer: []}]
    description: >
      Se envía la lista completa de pasajeros. Los asientos nuevos se ocupan,
      los que ya no aparecen se liberan y se recalcula el total.
    parameters:
      - {in: path, name: reserva_id, type: integer, required: true}
      - in: body
        name: body
        required: true
        schema:
          type: object
          required: [pasajeros]
          properties:
            pasajeros: {type: array, items: {type: object}}
    responses:
      200: {description: Reserva actualizada}
      400: {description: Datos inválidos o reserva cancelada}
      401: {description: Token inválido o ausente}
      403: {description: La reserva pertenece a otro usuario}
      404: {description: Reserva no encontrada}
      409: {description: Algún asiento nuevo ya fue tomado}
    """
    usuario = requerir_token()
    pasajeros = leer_pasajeros(leer_json(request))
    with engine.connect() as con:
        actual = obtener_reserva_propia(con, reserva_id, usuario)
        anteriores = {p.asiento: {"clase": p.clase, "precio": float(p.precio)} for p in pasajeros_de(con, reserva_id)}
    if actual.estado != "CONFIRMADA":
        raise ErrorApi("Solo se pueden modificar reservas confirmadas", 400)

    asientos = [p["asiento"] for p in pasajeros]
    nuevos = [a for a in asientos if a not in anteriores]
    quitados = [a for a in anteriores if a not in asientos]

    precios = dict(anteriores)
    if nuevos:
        precios.update(ocupar_asientos(actual.vuelo_id, usuario["id"], reserva_id, nuevos))
    try:
        with engine.begin() as con:
            total = guardar_pasajeros(con, reserva_id, pasajeros, precios)
            fila = con.execute(text(f"""
                UPDATE reservas.reservas
                SET cantidad_asientos = :n, total = :t, fecha_actualizacion = LOCALTIMESTAMP
                WHERE id = :id AND estado = 'CONFIRMADA'
                RETURNING {', '.join(c.strip() for c in COLUMNAS.split(','))}
            """), {"n": len(pasajeros), "t": total, "id": reserva_id}).first()
            if not fila:
                raise ErrorApi("La reserva fue cancelada mientras se modificaba", 409)
            detalle = pasajeros_de(con, reserva_id)
    except Exception:
        if nuevos:
            liberar_asientos(actual.vuelo_id, reserva_id, nuevos)  # compensación
        raise

    if quitados:
        liberar_asientos(actual.vuelo_id, reserva_id, quitados)
    return jsonify({"mensaje": "Reserva actualizada correctamente", "reserva": reserva_a_dict(fila, detalle)})


@app.delete("/api/reservas/<int:reserva_id>")
def cancelar_reserva(reserva_id):
    """Cancelar una reserva (los asientos vuelven a estar disponibles)
    ---
    tags: [Reservas]
    security: [{Bearer: []}]
    parameters:
      - {in: path, name: reserva_id, type: integer, required: true}
    responses:
      200: {description: Reserva cancelada}
      400: {description: La reserva ya estaba cancelada}
      401: {description: Token inválido o ausente}
      403: {description: La reserva pertenece a otro usuario}
      404: {description: Reserva no encontrada}
    """
    usuario = requerir_token()
    with engine.begin() as con:
        actual = obtener_reserva_propia(con, reserva_id, usuario)
        fila = con.execute(text(f"""
            UPDATE reservas.reservas
            SET estado = 'CANCELADA', fecha_actualizacion = LOCALTIMESTAMP
            WHERE id = :id AND estado = 'CONFIRMADA'
            RETURNING {', '.join(c.strip() for c in COLUMNAS.split(','))}
        """), {"id": reserva_id}).first()
        if not fila:
            raise ErrorApi("La reserva ya está cancelada", 400)
        # Si Vuelos no responde se lanza 503 y la transacción hace rollback
        liberar_asientos(actual.vuelo_id, reserva_id)
        detalle = pasajeros_de(con, reserva_id)

    return jsonify({"mensaje": "Reserva cancelada correctamente", "reserva": reserva_a_dict(fila, detalle)})


if __name__ == "__main__":
    app.run(host=config.BIND_HOST, port=config.RESERVAS_PORT, threaded=True)
